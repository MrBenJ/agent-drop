import Foundation
import GRDB

/// Spec §5.1 event types. `content` is written by the server's watcher (Plan 2).
public enum EventType: String, Sendable, CaseIterable {
    case created, content, metadata, status, archived, missing, read, removed
}

public struct StoredEvent: Equatable, Sendable {
    public let seq: Int64
    public let type: EventType
    public let dropID: String
    public let at: Date
    public let data: String
    public let inboxBefore: Bool
    public let inboxAfter: Bool
    public let projectBefore: String?
    public let projectAfter: String?

    init(seq: Int64, type: EventType, dropID: String, at: Date, data: String, inboxBefore: Bool,
         inboxAfter: Bool, projectBefore: String?, projectAfter: String?) {
        self.seq = seq
        self.type = type
        self.dropID = dropID
        self.at = at
        self.data = data
        self.inboxBefore = inboxBefore
        self.inboxAfter = inboxAfter
        self.projectBefore = projectBefore
        self.projectAfter = projectAfter
    }

    init(row: Row) {
        seq = row["seq"]
        type = EventType(rawValue: row["type"])!
        dropID = row["drop_id"]
        at = Date(timeIntervalSince1970: row["at"])
        data = row["data"]
        inboxBefore = row["inbox_before"]
        inboxAfter = row["inbox_after"]
        projectBefore = row["project_before"]
        projectAfter = row["project_after"]
    }
}

enum EventLog {
    /// Appends one event row and applies retention cleanup, inside the caller's transaction.
    static func append(_ db: Database, type: EventType, dropID: String, dataJSON: String,
                       before: Drop?, after: Drop?, at: Date, retention: Retention) throws {
        try db.execute(
            sql: """
                INSERT INTO event (type, drop_id, at, data, inbox_before, inbox_after, project_before, project_after)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [type.rawValue, dropID, at.unixTime, dataJSON,
                        before?.isInInbox ?? false, after?.isInInbox ?? false,
                        before?.project, after?.project])
        if case .days(let days) = retention {
            try db.execute(sql: "DELETE FROM event WHERE at < ?",
                           arguments: [at.addingTimeInterval(-Double(days) * 86_400).unixTime])
        }
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }

    /// Encodes a dictionary whose values are String, Bool, Int, [String], or NSNull.
    static func encodeObject(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

func orNull(_ value: String?) -> Any {
    if let value { return value }
    return NSNull()
}
