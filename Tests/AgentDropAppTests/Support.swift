import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore

final class Scratch: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdrop-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A store in a scratch folder, with helpers that write the way the CLI does.
struct StoreFixture {
    let scratch: Scratch
    let store: DropStore
    var folder: URL { store.folder }

    init() throws {
        scratch = try Scratch()
        store = try DropStore.open(folder: scratch.url.appendingPathComponent("AgentDrop", isDirectory: true),
                                   retention: .default)
    }

    @discardableResult
    func add(_ name: String, _ contents: String = "# Title\n", from: String = "agent", project: String? = nil,
             tags: [String] = [], handoff: Bool = false, description: String? = nil) throws -> Drop {
        let source = scratch.url.appendingPathComponent("src-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: source)
        return try store.add(AddRequest(source: .path(source), description: description, project: project, tags: tags,
                                        from: from, handoff: handoff))
    }

    /// A top-level entry with no record.
    func loose(_ name: String) throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }
}

/// For a wait on something only FSEvents delivers (a CLI write, a config change). Under
/// the full parallel suite fseventsd can lag several seconds, so 5 s is too tight; the
/// polling still returns as soon as the condition holds.
let fsEventsTimeout: Duration = .seconds(20)

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try await condition()
}

/// Holds a loopback port open, so the service finds it taken.
final class PortBlocker: @unchecked Sendable {
    private var fd: Int32

    init(port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
    }

    func release() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    deinit { release() }
}

/// Runs blocking test work (a burst of CLI store writes) on a thread of its own. On the
/// main actor it would stall every other `@MainActor` test and the models they drive.
func offMainActor<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}
