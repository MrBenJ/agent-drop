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
