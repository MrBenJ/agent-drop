import Foundation
import GRDB

public struct EditRequest: Sendable {
    public var title: String?
    public var description: String?
    public var project: String?
    public var addTags: [String]
    public var removeTags: [String]
    public var kind: DropKind?

    public init(title: String? = nil, description: String? = nil, project: String? = nil,
                addTags: [String] = [], removeTags: [String] = [], kind: DropKind? = nil) {
        self.title = title
        self.description = description
        self.project = project
        self.addTags = addTags
        self.removeTags = removeTags
        self.kind = kind
    }
}

extension DropStore {
    /// Spec §4 `drop edit`; kind changes follow §4.2 "Changing kind". One `metadata` event.
    public func edit(_ ref: String, _ request: EditRequest) throws -> Drop {
        let target = try resolve(ref)
        let title = try request.title.map { try Validation.text($0, field: "--title") }
        let description = try request.description.map { try Validation.text($0, field: "--desc") }
        let project = try request.project.map { try Validation.identity($0, field: "--project") }
        let addTags = Validation.unique(try request.addTags.map(Validation.tag))
        let removeTags = request.removeTags.map { $0.trimmingCharacters(in: .whitespaces) }
        let now = self.now()

        return try mutate { db in
            guard let before = try Self.fetchDrop(db, id: target.id) else {
                throw AgentDropError.notFound("No drop matches '\(ref)'")
            }
            var changes: [String: Any] = [:]
            var sets: [String] = []
            var setArguments: [(any DatabaseValueConvertible)?] = []
            var condition = "id = ?"
            var conditionArguments: [(any DatabaseValueConvertible)?] = [before.id]

            if let title, title != before.title {
                sets.append("title = ?"); setArguments.append(title); changes["title"] = title
            }
            if let description, description != before.description {
                sets.append("description = ?"); setArguments.append(description); changes["description"] = description
            }
            if let project, project != before.project {
                sets.append("project = ?"); setArguments.append(project); changes["project"] = project
            }
            if request.kind != nil {
                if before.status == .claimed {
                    throw AgentDropError.conflict(
                        "\(before.id) is claimed by \(before.claimedBy ?? "unknown"); release it first")
                }
                if before.status == .done {
                    throw AgentDropError.conflict("\(before.id) is done; reopen it first")
                }
            }
            if let kind = request.kind, kind != before.kind {
                if kind == .handoff {
                    sets += ["kind = 'handoff'", "status = 'open'"]
                } else {
                    sets += ["kind = 'note'", "status = NULL", "claimed_by = NULL", "status_note = NULL"]
                }
                condition += " AND kind = ? AND status IS ?"
                conditionArguments += [before.kind.rawValue, before.status?.rawValue]
                changes["kind"] = kind.rawValue
                changes["status"] = kind == .handoff ? "open" : NSNull()
            }

            let newTags = addTags.filter { !before.tags.contains($0) }
            let droppedTags = removeTags.filter { before.tags.contains($0) }
            if !newTags.isEmpty || !droppedTags.isEmpty {
                changes["tags"] = before.tags.filter { !droppedTags.contains($0) } + newTags
            }
            guard !changes.isEmpty else { return before }

            sets.append("updated_at = ?"); setArguments.append(now.unixTime)
            try db.execute(sql: "UPDATE drops SET \(sets.joined(separator: ", ")) WHERE \(condition)",
                           arguments: StatementArguments(setArguments + conditionArguments))
            guard db.changesCount == 1 else {
                throw AgentDropError.conflict("\(before.id) changed while editing; retry")
            }
            for tag in newTags {
                try db.execute(sql: "INSERT INTO drop_tag (drop_id, tag) VALUES (?, ?)", arguments: [before.id, tag])
            }
            for tag in droppedTags {
                try db.execute(sql: "DELETE FROM drop_tag WHERE drop_id = ? AND tag = ?", arguments: [before.id, tag])
            }
            let after = try Self.fetchDrop(db, id: before.id)!
            try EventLog.append(db, type: .metadata, dropID: before.id, dataJSON: EventLog.encodeObject(changes),
                                before: before, after: after, at: now, retention: retention)
            return after
        }
    }

    /// Spec §4 `drop archive` / `--undo`. The file is never touched.
    public func setArchived(_ ref: String, _ archived: Bool) throws -> Drop {
        let target = try resolve(ref)
        let now = self.now()
        return try mutate { db in
            guard let before = try Self.fetchDrop(db, id: target.id) else {
                throw AgentDropError.notFound("No drop matches '\(ref)'")
            }
            guard before.archived != archived else { return before }
            try db.execute(sql: "UPDATE drops SET archived = ?, updated_at = ? WHERE id = ?",
                           arguments: [archived, now.unixTime, before.id])
            let after = try Self.fetchDrop(db, id: before.id)!
            try EventLog.append(db, type: .archived, dropID: before.id,
                                dataJSON: EventLog.encodeObject(["archived": archived]),
                                before: before, after: after, at: now, retention: retention)
            return after
        }
    }

    /// Spec §5.1 `read`: first view in the app only. Used by Plan 3.
    public func markRead(_ ref: String) throws -> Drop {
        let target = try resolve(ref)
        let now = self.now()
        return try mutate { db in
            guard let before = try Self.fetchDrop(db, id: target.id) else {
                throw AgentDropError.notFound("No drop matches '\(ref)'")
            }
            guard before.readAt == nil else { return before }
            try db.execute(sql: "UPDATE drops SET read_at = ? WHERE id = ? AND read_at IS NULL",
                           arguments: [now.unixTime, before.id])
            let after = try Self.fetchDrop(db, id: before.id)!
            try EventLog.append(db, type: .read, dropID: before.id,
                                dataJSON: EventLog.encodeObject(["readAt": now.iso]),
                                before: before, after: after, at: now, retention: retention)
            return after
        }
    }

    /// Spec §3.2 "Remove record": only for drops whose file is gone. Used by Plan 3.
    public func removeRecord(_ ref: String) throws {
        let target = try resolve(ref)
        guard target.missing else {
            throw AgentDropError.invalid("\(target.id) still has its file; only missing drops can be removed")
        }
        let now = self.now()
        try mutate { db in
            guard let before = try Self.fetchDrop(db, id: target.id) else {
                throw AgentDropError.notFound("No drop matches '\(ref)'")
            }
            guard before.missing, !entryIsPresent(before) else {
                throw AgentDropError.invalid("\(before.id) still has its file; only missing drops can be removed")
            }
            try db.execute(sql: "DELETE FROM drops WHERE id = ?", arguments: [target.id])
            guard db.changesCount == 1 else { throw AgentDropError.notFound("No drop matches '\(ref)'") }
            try EventLog.append(db, type: .removed, dropID: target.id, dataJSON: "{}",
                                before: before, after: nil, at: now, retention: retention)
        }
    }
}
