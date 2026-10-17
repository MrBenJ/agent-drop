import Foundation
import Testing
@testable import AgentDropCore

/// Asserts `body` throws an AgentDropError with the given exit code; returns its message.
@discardableResult
func expectError(_ exitCode: Int32, _ body: () throws -> Void,
                 sourceLocation: SourceLocation = #_sourceLocation) -> String? {
    do {
        try body()
        Issue.record("expected AgentDropError(\(exitCode)), nothing was thrown", sourceLocation: sourceLocation)
    } catch let error as AgentDropError {
        #expect(error.exitCode == exitCode, "message: \(error.message)", sourceLocation: sourceLocation)
        return error.message
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
    return nil
}

final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_760_000_000)) { now = start }
    func advance(days: Double) { now = now.addingTimeInterval(days * 86_400) }
    func advance(seconds: Double) { now = now.addingTimeInterval(seconds) }
}

final class TempDir: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdrop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ relative: String, _ contents: String) throws -> URL {
        try data(relative, Data(contents.utf8))
    }

    @discardableResult
    func data(_ relative: String, _ data: Data) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }
}

struct Fixture {
    let tmp: TempDir
    let clock: TestClock
    let store: DropStore
    var folder: URL { store.folder }

    init(retention: Retention = .default) throws {
        let tmp = try TempDir()
        let clock = TestClock()
        let folder = tmp.url.appendingPathComponent("AgentDrop", isDirectory: true)
        self.tmp = tmp
        self.clock = clock
        self.store = try DropStore.open(folder: folder, retention: retention, now: { clock.now })
    }

    /// A file outside the drop folder.
    func outside(_ name: String, _ contents: String = "# Plan\n") throws -> URL {
        try tmp.file("outside/\(name)", contents)
    }

    @discardableResult
    func add(_ name: String = "plan.md", _ contents: String = "# Plan\n", from: String = "tester",
             project: String? = nil, tags: [String] = [], handoff: Bool = false) throws -> Drop {
        let source = try tmp.file("outside-\(UUID().uuidString)/\(name)", contents)
        return try store.add(AddRequest(source: .path(source), project: project, tags: tags,
                                        from: from, handoff: handoff))
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func withLock(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}

/// Runs a test worker that blocks (on semaphores or the store's lock) on a thread of its
/// own. Not `DispatchQueue.global()`, nor a private concurrent queue (which draws from the
/// same pool): that pool has about one thread per core, other tests may be blocking all of
/// them, and a starved worker times the test out.
func onOwnThread(_ body: @escaping @Sendable () -> Void) {
    Thread.detachNewThread(body)
}
