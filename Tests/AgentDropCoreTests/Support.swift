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
