import Foundation
import GRDB

/// Store APIs for the server's event stream and folder watcher (spec §5).
extension DropStore {
    /// The highest event `seq` written so far, or 0 for an empty log.
    public func latestSeq() throws -> Int64 {
        try read { db in try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM event") ?? 0 }
    }

    /// The drop registered under exactly this filename. Records store the on-disk
    /// spelling, which is also what FSEvents reports.
    public func drop(filename: String) throws -> Drop? {
        try read { db in
            try Self.fetchDrops(db, sql: "SELECT * FROM drops WHERE filename = ?", arguments: [filename]).first
        }
    }

    /// Spec §3.2 for one drop: re-checks its entry and records `missing` or
    /// `metadata {missing: false}` when that changed.
    public func checkPresence(_ id: String) throws -> Drop {
        guard let drop = try read({ db in try Self.fetchDrop(db, id: id) }) else {
            throw AgentDropError.notFound("No drop matches '\(id)'")
        }
        return try refreshMissing(drop)
    }

    /// Spec §5.1 `content`: the drop's file or folder contents changed. Written only by the
    /// server's folder watcher. Leaves the drop row untouched; skipped for a missing drop.
    public func recordContentChange(_ id: String) throws {
        let now = self.now()
        try mutate { db in
            guard let drop = try Self.fetchDrop(db, id: id) else {
                throw AgentDropError.notFound("No drop matches '\(id)'")
            }
            guard !drop.missing else { return }
            try EventLog.append(db, type: .content, dropID: id, dataJSON: "{}",
                                before: drop, after: drop, at: now, retention: retention)
        }
    }
}

extension DropStore {
    /// Calls `handler` after every committed transaction on this store instance that wrote
    /// event rows. The server uses it to deliver in-process writes immediately; writes from
    /// other processes reach it through FSEvents on `.agentdrop/` instead.
    public func observeEventCommits(_ handler: @escaping @Sendable () -> Void) {
        pool.add(transactionObserver: EventCommitObserver(handler: handler), extent: .databaseLifetime)
    }
}

private final class EventCommitObserver: TransactionObserver, @unchecked Sendable {
    // Touched only on the store's writer queue, one transaction at a time.
    private var wroteEvents = false
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        if case .insert(let table) = eventKind { return table == "event" }
        return false
    }

    func databaseDidChange(with event: DatabaseEvent) { wroteEvents = true }

    func databaseDidCommit(_ db: Database) {
        guard wroteEvents else { return }
        wroteEvents = false
        handler()
    }

    func databaseDidRollback(_ db: Database) { wroteEvents = false }
}
