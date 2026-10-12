import Foundation
import GRDB

extension DropStore {
    private enum FieldChange {
        case keep, set(String), clear
    }

    /// Spec §4.2: `open → claimed`.
    public func claim(_ ref: String, by: String) throws -> Drop {
        let by = try Validation.identity(by, field: "--by")
        return try transition(ref, from: [.open], to: .claimed, claimedBy: .set(by), statusNote: .keep)
    }

    /// Spec §4.2: `claimed → open`.
    public func release(_ ref: String) throws -> Drop {
        try transition(ref, from: [.claimed], to: .open, claimedBy: .clear, statusNote: .keep)
    }

    /// Spec §4.2: `open → done`, `claimed → done`.
    public func done(_ ref: String, note: String?) throws -> Drop {
        let note = try note.map { try Validation.text($0, field: "--note") }
        return try transition(ref, from: [.open, .claimed], to: .done, claimedBy: .keep,
                              statusNote: note.map { .set($0) } ?? .keep)
    }

    /// Spec §4.2: `done → open`.
    public func reopen(_ ref: String) throws -> Drop {
        try transition(ref, from: [.done], to: .open, claimedBy: .clear, statusNote: .clear)
    }

    private func transition(_ ref: String, from allowed: Set<HandoffStatus>, to target: HandoffStatus,
                            claimedBy: FieldChange, statusNote: FieldChange) throws -> Drop {
        let resolved = try resolve(ref)
        let now = self.now()
        return try mutate { db in
            guard let before = try Self.fetchDrop(db, id: resolved.id) else {
                throw AgentDropError.notFound("No drop matches '\(ref)'")
            }
            guard before.kind == .handoff, let current = before.status else {
                throw AgentDropError.invalid("\(before.id) is a note, not a handoff")
            }
            guard allowed.contains(current) else {
                throw AgentDropError.conflict(Self.stateMessage(before))
            }
            var sets = ["status = ?", "updated_at = ?"]
            var arguments: [(any DatabaseValueConvertible)?] = [target.rawValue, now.unixTime]
            for (column, change) in [("claimed_by", claimedBy), ("status_note", statusNote)] {
                switch change {
                case .keep: break
                case .set(let value): sets.append("\(column) = ?"); arguments.append(value)
                case .clear: sets.append("\(column) = NULL")
                }
            }
            arguments += [before.id, current.rawValue]
            // Conditional update: a concurrent writer that moved the status first makes this a no-op.
            try db.execute(sql: "UPDATE drops SET \(sets.joined(separator: ", ")) WHERE id = ? AND status = ?",
                           arguments: StatementArguments(arguments))
            guard db.changesCount == 1 else {
                let latest = try Self.fetchDrop(db, id: before.id) ?? before
                throw AgentDropError.conflict(Self.stateMessage(latest))
            }
            let after = try Self.fetchDrop(db, id: before.id)!
            let data: [String: Any] = ["from": current.rawValue, "to": target.rawValue,
                                       "claimedBy": orNull(after.claimedBy), "statusNote": orNull(after.statusNote)]
            try EventLog.append(db, type: .status, dropID: before.id, dataJSON: EventLog.encodeObject(data),
                                before: before, after: after, at: now, retention: retention)
            return after
        }
    }

    /// e.g. `k7f2qa is claimed by djleague/build-feature-x` (spec §4.2).
    static func stateMessage(_ drop: Drop) -> String {
        switch drop.status {
        case .claimed?: "\(drop.id) is claimed by \(drop.claimedBy ?? "unknown")"
        case .done?: "\(drop.id) is done"
        case .open?: "\(drop.id) is open"
        case nil: "\(drop.id) is a note, not a handoff"
        }
    }
}
