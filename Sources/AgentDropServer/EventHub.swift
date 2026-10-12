import AgentDropCore
import Foundation

/// Fans the store's event log out to SSE subscribers (spec §5.3).
///
/// The store is the source of truth: `poke()` reads every row after the last one it saw
/// and delivers each to the subscribers whose filter matches. Anything that writes to the
/// store (the CLI in another process, the content watcher, a lazy missing check) is
/// picked up on the next poke, which the folder watcher triggers on every store change.
public actor EventHub {
    public enum Frame: Equatable, Sendable {
        case event(EventMessage)
        /// First frame of a fresh (cursor-less) subscription: where "live" starts. Sent as an
        /// id-only SSE frame, so every client has a `Last-Event-ID` to resume with, and gets
        /// `reset` after a folder switch even if no event arrived before it.
        case cursor(EventCursor)
        /// The client's `Last-Event-ID` came from another store. Carries the cursor to resume from.
        case reset(EventCursor)
        case heartbeat
    }

    private struct Subscriber {
        let filter: EventFilter
        /// Only events with a larger seq go to this subscriber.
        let after: Int64
        let continuation: AsyncStream<Frame>.Continuation
    }

    public nonisolated let storeID: String
    private let store: DropStore
    private var lastSeq: Int64
    private var subscribers: [UUID: Subscriber] = [:]
    private var heartbeatTask: Task<Void, Never>?
    private var closed = false

    public init(store: DropStore) throws {
        self.store = store
        storeID = store.storeID
        lastSeq = try store.latestSeq()
    }

    public var subscriberCount: Int { subscribers.count }

    /// Without a cursor: live events only. With a cursor from this store: every surviving
    /// matching event after it, then live. With a cursor from another store: one `reset`,
    /// then live.
    public func subscribe(_ filter: EventFilter, resumeFrom cursor: EventCursor?) throws -> AsyncStream<Frame> {
        let (stream, continuation) = AsyncStream<Frame>.makeStream(bufferingPolicy: .unbounded)
        guard !closed else {
            continuation.finish()
            return stream
        }
        // Catch up first, so "live" means "written after this call", not "after the last poke".
        poke()
        var after = lastSeq
        if cursor == nil {
            continuation.yield(.cursor(EventCursor(storeID: storeID, seq: lastSeq)))
        }
        if let cursor {
            if cursor.storeID != storeID {
                continuation.yield(.reset(EventCursor(storeID: storeID, seq: lastSeq)))
            } else {
                for event in try store.events(afterSeq: cursor.seq) where event.seq <= lastSeq && filter.matches(event) {
                    continuation.yield(.event(EventMessage(storeID: storeID, event: event)))
                }
                after = max(cursor.seq, lastSeq)
            }
        }
        let id = UUID()
        subscribers[id] = Subscriber(filter: filter, after: after, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    /// Delivers every event written since the last poke. Cheap when nothing changed.
    public func poke() {
        guard !closed, let events = try? store.events(afterSeq: lastSeq), !events.isEmpty else { return }
        for event in events {
            let message = EventMessage(storeID: storeID, event: event)
            for subscriber in subscribers.values where event.seq > subscriber.after && subscriber.filter.matches(event) {
                subscriber.continuation.yield(.event(message))
            }
        }
        lastSeq = events.last!.seq
    }

    /// Keeps idle connections alive and lets the server notice clients that went away.
    public func startHeartbeat(every interval: Duration) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.broadcastHeartbeat()
            }
        }
    }

    /// Ends every stream. Called before the HTTP server stops, so shutdown never waits on
    /// an open SSE response.
    public func close() {
        closed = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for subscriber in subscribers.values { subscriber.continuation.finish() }
        subscribers.removeAll()
    }

    private func broadcastHeartbeat() {
        for subscriber in subscribers.values { subscriber.continuation.yield(.heartbeat) }
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }
}
