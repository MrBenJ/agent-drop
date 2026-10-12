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
