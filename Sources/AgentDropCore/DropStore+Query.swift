import Foundation
import GRDB

public struct ListFilter: Equatable, Sendable {
    public var project: String?
    public var tags: [String] = []
    public var from: String?
    public var fromUnder: String?
    public var handoffsOnly = false
    public var status: HandoffStatus?
    public var unreadOnly = false
    public var includeArchived = false
    /// Spec §4 `drop list`: default 50. `nil` = no limit.
    public var limit: Int? = 50
    public var inboxOnly = false

    public init() {}
}

extension DropStore {
    /// Id first, then exact filename (spec §3.1). Marks the drop missing (with one `missing`
    /// event) if its file is gone (spec §3.2 "lazily when it resolves an id").
    public func resolve(_ ref: String) throws -> Drop {
        let found: Drop? = try read { db in
            if DropID.isWellFormed(ref), let drop = try Self.fetchDrop(db, id: ref) { return drop }
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM drops WHERE filename = ?",
                                               arguments: [ref]) else { return nil }
            return try Self.fetchDrop(db, id: id)
        }
        guard let drop = found else { throw AgentDropError.notFound("No drop matches '\(ref)'") }
        return try refreshMissing(drop)
    }

    private func refreshMissing(_ drop: Drop) throws -> Drop {
        guard !drop.missing, !FileManager.default.fileExists(atPath: path(of: drop).path) else { return drop }
        let now = self.now()
        return try mutate { db in
            guard let before = try Self.fetchDrop(db, id: drop.id) else {
                throw AgentDropError.notFound("No drop matches '\(drop.id)'")
            }
            guard !before.missing else { return before }
            try db.execute(sql: "UPDATE drops SET missing = 1, updated_at = ? WHERE id = ?",
                           arguments: [now.unixTime, drop.id])
            let after = try Self.fetchDrop(db, id: drop.id)!
            try EventLog.append(db, type: .missing, dropID: drop.id, dataJSON: "{}",
                                before: before, after: after, at: now, retention: retention)
            return after
        }
    }

    /// Newest first (spec §4 `drop list`).
    public func list(_ filter: ListFilter) throws -> [Drop] {
        var clauses: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []
        if !filter.includeArchived { clauses.append("archived = 0") }
        if let project = filter.project { clauses.append("project = ?"); arguments.append(project) }
        for tag in filter.tags {
            clauses.append("EXISTS (SELECT 1 FROM drop_tag t WHERE t.drop_id = drops.id AND t.tag = ?)")
            arguments.append(tag)
        }
        if let from = filter.from { clauses.append("from_identity = ?"); arguments.append(from) }
        if let prefix = filter.fromUnder {
            // Whole levels only: the prefix itself, or "prefix/…". substr counts code points.
            clauses.append("(from_identity = ? OR substr(from_identity, 1, ?) = ?)")
            arguments += [prefix, prefix.unicodeScalars.count + 1, prefix + "/"]
        }
        if filter.handoffsOnly { clauses.append("kind = 'handoff'") }
        if let status = filter.status { clauses.append("status = ?"); arguments.append(status.rawValue) }
        if filter.unreadOnly { clauses.append("read_at IS NULL AND archived = 0 AND missing = 0") }
        if filter.inboxOnly {
            clauses.append("kind = 'handoff' AND status = 'open' AND archived = 0 AND missing = 0")
        }
        var sql = "SELECT * FROM drops"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY created_at DESC, rowid DESC"
        if let limit = filter.limit { sql += " LIMIT ?"; arguments.append(limit) }
        let finalSQL = sql
        let finalArguments = StatementArguments(arguments)
        return try read { db in try Self.fetchDrops(db, sql: finalSQL, arguments: finalArguments) }
    }

    /// Spec §4 Terms "Inbox".
    public func inbox(project: String?) throws -> [Drop] {
        var filter = ListFilter()
        filter.inboxOnly = true
        filter.project = project
        filter.limit = nil
        return try list(filter)
    }
}
