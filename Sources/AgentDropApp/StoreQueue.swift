import Foundation

/// Store calls from the app run here, never on the main thread: a write can wait up to
/// 5 s for another process's lock (spec §3), and the UI must not freeze meanwhile. A
/// private serial queue, not `DispatchQueue.global()`, so it always gets a thread.
enum StoreQueue {
    private static let queue = DispatchQueue(label: "AgentDrop.app.store")

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
