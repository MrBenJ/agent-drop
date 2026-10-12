import Foundation

public enum DropKind: String, Sendable, CaseIterable {
    case note, handoff
}

public enum HandoffStatus: String, Sendable, CaseIterable {
    case open, claimed, done
}

/// One registered drop (spec §3 data model).
public struct Drop: Equatable, Sendable {
    public var id: String
    public var filename: String
    public var isFolder: Bool
    public var title: String
    public var description: String?
    public var project: String?
    public var tags: [String]
    public var from: String
    public var createdAt: Date
    public var updatedAt: Date
    public var readAt: Date?
    public var kind: DropKind
    public var status: HandoffStatus?
    public var claimedBy: String?
    public var statusNote: String?
    public var archived: Bool
    public var missing: Bool

    /// Spec §4 Terms: open handoff, not archived, not missing.
    public var isInInbox: Bool { kind == .handoff && status == .open && !archived && !missing }
    /// Spec §4 Terms: never viewed in the app, not archived, not missing.
    public var isUnread: Bool { readAt == nil && !archived && !missing }
}

/// Spec §4 "JSON shape". Optional fields are always present (as `null`).
public struct DropJSON: Encodable, Sendable {
    public let drop: Drop
    public let path: String

    public init(drop: Drop, path: String) {
        self.drop = drop
        self.path = path
    }

    enum Key: String, CodingKey {
        case id, filename, path, title, description, project, tags, from, kind, status
        case claimedBy, statusNote, createdAt, updatedAt, readAt, archived, isFolder, missing
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(drop.id, forKey: .id)
        try c.encode(drop.filename, forKey: .filename)
        try c.encode(path, forKey: .path)
        try c.encode(drop.title, forKey: .title)
        try c.encode(drop.description, forKey: .description)
        try c.encode(drop.project, forKey: .project)
        try c.encode(drop.tags, forKey: .tags)
        try c.encode(drop.from, forKey: .from)
        try c.encode(drop.kind.rawValue, forKey: .kind)
        try c.encode(drop.status?.rawValue, forKey: .status)
        try c.encode(drop.claimedBy, forKey: .claimedBy)
        try c.encode(drop.statusNote, forKey: .statusNote)
        try c.encode(drop.createdAt.iso, forKey: .createdAt)
        try c.encode(drop.updatedAt.iso, forKey: .updatedAt)
        try c.encode(drop.readAt?.iso, forKey: .readAt)
        try c.encode(drop.archived, forKey: .archived)
        try c.encode(drop.isFolder, forKey: .isFolder)
        try c.encode(drop.missing, forKey: .missing)
    }
}

extension Date {
    /// `2026-10-11T18:44:00Z`
    public var iso: String { formatted(.iso8601) }
    var unixTime: Double { timeIntervalSince1970 }
}
