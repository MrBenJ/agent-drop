import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

/// A real HTTP server on 127.0.0.1 over a scratch store.
struct ServerFixture {
    let store: StoreFixture
    let hub: EventHub
    let server: HTTPServer
    var client: AgentDropClient { AgentDropClient(port: server.port, token: server.token) }

    init(store: StoreFixture? = nil) async throws {
        let store = try store ?? StoreFixture()
        self.store = store
        hub = try EventHub(store: store.store)
        server = try await HTTPServer.start(store: store.store, hub: hub, token: ServerInfo.newToken(),
                                            portBase: randomPortBase(), attempts: 10)
    }
}

/// Parallel tests each start in a different range; collisions just fall through to the next port.
func randomPortBase() -> Int { Int.random(in: 20_000...59_000) }

/// Sends raw bytes, so tests can control headers URLSession would rewrite (e.g. `Host`).
/// The blocking socket calls run on a GCD thread: blocking a Swift concurrency thread
/// would starve the server under test on small CI machines.
func rawHTTP(port: Int, _ request: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        rawHTTPQueue.async {
            continuation.resume(with: Result { try blockingRawHTTP(port: port, request) })
        }
    }
}

/// Its own concurrent queue: `DispatchQueue.global()` has about one thread per core, and
/// other tests may be blocking all of them.
private let rawHTTPQueue = DispatchQueue(label: "tests.rawHTTP", attributes: .concurrent)

private func blockingRawHTTP(port: Int, _ request: String) throws -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    precondition(fd >= 0)
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
    let bytes = Array(request.utf8)
    _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, bytes.count, 0) }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { break }
        response.append(contentsOf: buffer[0..<n])
    }
    return String(decoding: response, as: UTF8.self)
}

/// The first event of a stream, or nil if it ends or nothing arrives in time.
func first(_ events: AsyncThrowingStream<SSEEvent, Error>, timeout: Duration = .seconds(5)) async throws -> SSEEvent? {
    try await withThrowingTaskGroup(of: SSEEvent?.self) { group in
        group.addTask {
            for try await event in events { return event }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// A `TailnetServer` on 127.0.0.1 over a scratch store, with a swappable key and free-space reading.
struct TailnetFixture {
    static let identity = TailnetIdentity(address: "100.100.1.2", dnsName: "laptop.tail-test.ts.net")

    let store: StoreFixture
    let server: TailnetServer
    let key: Locked<String?>
    let free: Locked<Int64?>
    var port: Int { server.port }
    var host: String { "laptop.tail-test.ts.net:\(port)" }
    var stagingRoot: URL { store.folder.appendingPathComponent(".agentdrop/staging", isDirectory: true) }

    init(maxBytes: Int64 = 1 << 20, identity: TailnetIdentity = TailnetFixture.identity,
         peerAllowed: @escaping @Sendable (String) -> Bool = { $0 == "127.0.0.1" })
        async throws {
        let store = try StoreFixture()
        let key = Locked<String?>(ServerInfo.newToken())
        let free = Locked<Int64?>(nil)
        self.store = store
        self.key = key
        self.free = free
        let base = randomPortBase()
        var started: TailnetServer?
        for port in base..<(base + 10) {
            do {
                started = try await TailnetServer.start(
                    store: store.store, bindHost: "127.0.0.1", port: port, identity: identity,
                    limits: .init(maxBytes: maxBytes), key: { key.value }, peerAllowed: peerAllowed,
                    freeBytes: { _ in free.value })
                break
            } catch is TailnetServer.PortInUse {
                continue
            }
        }
        guard let started else { throw TailnetServer.PortInUse(port: base) }
        server = started
    }

    /// `Host` and the key default to the right ones; pass "" to leave either header out.
    func request(_ method: String, _ target: String, host: String? = nil, key: String? = nil,
                 headers: [String] = [], body: Data? = nil) -> Data {
        var head = "\(method) \(target) HTTP/1.1\r\n"
        let host = host ?? self.host
        if !host.isEmpty { head += "Host: \(host)\r\n" }
        let key = key ?? (self.key.value ?? "")
        if !key.isEmpty { head += "Authorization: Bearer \(key)\r\n" }
        for header in headers { head += "\(header)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + (body ?? Data())
    }

    func send(_ method: String, _ target: String, host: String? = nil, key: String? = nil,
              headers: [String] = [], body: Data? = nil) async throws -> RawResponse {
        RawResponse(try await rawHTTP(port: port, request(method, target, host: host, key: key, headers: headers,
                                                          body: body)))
    }

    /// Entries directly under `.agentdrop/staging` (none if it doesn't exist).
    func stagingEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
    }
}

/// Status code and body of a raw HTTP/1.1 response.
struct RawResponse {
    let status: Int
    let body: String

    init(_ raw: String) {
        let parts = raw.components(separatedBy: "\r\n\r\n")
        status = parts.first.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) } ?? 0
        body = parts.dropFirst().joined(separator: "\r\n\r\n")
    }

    var json: [String: JSONValue] {
        (try? JSONDecoder().decode([String: JSONValue].self, from: Data(body.utf8))) ?? [:]
    }
}

/// `rawHTTP` with binary request bytes.
func rawHTTP(port: Int, _ request: Data) async throws -> String {
    let connection = try await rawHTTPConnection(port: port)
    try await connection.send(request)
    return await connection.readToEnd()
}

/// An open socket the test writes to in pieces and can leave hanging. As with `rawHTTP`,
/// every blocking call runs on `rawHTTPQueue`, never on a Swift concurrency thread.
final class RawConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    fileprivate init(fd: Int32) { self.fd = fd }
    deinit { close() }

    func send(_ string: String) async throws { try await send(Data(string.utf8)) }

    func send(_ data: Data) async throws {
        let fd = lock.withLock { self.fd }
        try await onRawQueue {
            let sent = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
            guard sent == data.count else { throw POSIXError(.EPIPE) }
        }
    }

    /// Everything the server sends until it closes (or 5 s of silence).
    func readToEnd() async -> String {
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { return "" }
        let data = (try? await onRawQueue { () -> Data in
            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                response.append(contentsOf: buffer[0..<n])
            }
            return response
        }) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func close() {
        lock.withLock {
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }
    }
}

func rawHTTPConnection(port: Int) async throws -> RawConnection {
    let fd = try await onRawQueue { () -> Int32 in
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }
    return RawConnection(fd: fd)
}

private func onRawQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        rawHTTPQueue.async { continuation.resume(with: Result { try body() }) }
    }
}
