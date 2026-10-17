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

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func withLock(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}

/// For a wait on something only FSEvents delivers (another store's write, a file edit).
/// Under the full parallel suite fseventsd can lag several seconds, so 5 s is too tight;
/// the polling still returns as soon as the condition holds.
let fsEventsTimeout: Duration = .seconds(20)

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return try await condition()
}
