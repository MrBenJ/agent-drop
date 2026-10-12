import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

final class ScratchDir: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdrop-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

enum StoredEventFixture {
    static func make(seq: Int64 = 1, type: EventType = .created, dropID: String = "abcdef", data: String = "{}",
                     inboxBefore: Bool = false, inboxAfter: Bool = false,
                     projectBefore: String? = nil, projectAfter: String? = nil) -> StoredEvent {
        StoredEvent(seq: seq, type: type, dropID: dropID, at: Date(timeIntervalSince1970: 1_760_000_000), data: data,
                    inboxBefore: inboxBefore, inboxAfter: inboxAfter,
                    projectBefore: projectBefore, projectAfter: projectAfter)
    }
}

/// A real store in a scratch folder.
struct StoreFixture {
    let dir: ScratchDir
    let folder: URL
    let store: DropStore

    init(retention: Retention = .default) throws {
        dir = try ScratchDir()
        folder = dir.url.appendingPathComponent("AgentDrop", isDirectory: true)
        store = try DropStore.open(folder: folder, retention: retention)
    }

    @discardableResult
    func add(_ name: String = "plan.md", _ contents: String = "# Plan\n", project: String? = nil,
             handoff: Bool = false) throws -> Drop {
        let source = dir.url.appendingPathComponent("src-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: source)
        return try store.add(AddRequest(source: .path(source), project: project, from: "tester", handoff: handoff))
    }
}

/// Reads up to `count` frames, giving up after `timeout`.
func collect(_ stream: AsyncStream<EventHub.Frame>, count: Int,
             timeout: Duration = .seconds(5)) async -> [EventHub.Frame] {
    await withTaskGroup(of: [EventHub.Frame]?.self) { group in
        group.addTask {
            var frames: [EventHub.Frame] = []
            for await frame in stream {
                frames.append(frame)
                if frames.count == count { break }
            }
            return frames
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next()!
        group.cancelAll()
        return first ?? []
    }
}

extension EventHub.Frame {
    var message: EventMessage? {
        if case .event(let m) = self { return m }
        return nil
    }
}

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
func rawHTTP(port: Int, _ request: String) throws -> String {
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
