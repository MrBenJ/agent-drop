import Foundation
import GRDB

enum Schema {
    /// Index i upgrades user_version i → i+1. Never edit a shipped entry; append new ones.
    static let migrations: [String] = [
        """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE drops (
            id TEXT PRIMARY KEY,
            filename TEXT NOT NULL UNIQUE,
            is_folder INTEGER NOT NULL,
            title TEXT NOT NULL,
            description TEXT,
            project TEXT,
            from_identity TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            read_at REAL,
            kind TEXT NOT NULL CHECK (kind IN ('note', 'handoff')),
            status TEXT CHECK (status IN ('open', 'claimed', 'done')),
            claimed_by TEXT,
            status_note TEXT,
            archived INTEGER NOT NULL DEFAULT 0,
            missing INTEGER NOT NULL DEFAULT 0,
            CHECK ((kind = 'handoff') = (status IS NOT NULL))
        );
        CREATE TABLE drop_tag (
            drop_id TEXT NOT NULL REFERENCES drops(id) ON DELETE CASCADE,
            tag TEXT NOT NULL,
            PRIMARY KEY (drop_id, tag)
        );
        CREATE TABLE event (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            drop_id TEXT NOT NULL,
            at REAL NOT NULL,
            data TEXT NOT NULL,
            inbox_before INTEGER NOT NULL,
            inbox_after INTEGER NOT NULL,
            project_before TEXT,
            project_after TEXT
        );
        CREATE INDEX event_at ON event(at);
        """,
    ]

    static func migrate(_ db: Database) throws {
        let current = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard current < migrations.count else { return }
        for sql in migrations[current...] {
            try db.execute(sql: sql)
        }
        if current == 0 {
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('store_id', ?)",
                           arguments: [DropID.storeID()])
        }
        try db.execute(sql: "PRAGMA user_version = \(migrations.count)")
    }
}

/// The metadata store for one drop folder (spec §3 "Metadata store").
public final class DropStore: Sendable {
    public let folder: URL
    public let storeID: String
    let pool: DatabasePool
    let retention: Retention
    let now: @Sendable () -> Date

    private init(folder: URL, storeID: String, pool: DatabasePool, retention: Retention,
                 now: @escaping @Sendable () -> Date) {
        self.folder = folder
        self.storeID = storeID
        self.pool = pool
        self.retention = retention
        self.now = now
    }

    public static func open(folder: URL, retention: Retention,
                            now: @escaping @Sendable () -> Date = { Date() }) throws -> DropStore {
        let metaDir = folder.appendingPathComponent(".agentdrop", isDirectory: true)
        let path = metaDir.appendingPathComponent("index.sqlite").path
        do {
            try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.busyMode = .timeout(5)
            let pool = try DatabasePool(path: path, configuration: configuration)
            let storeID: String = try pool.writeWithoutTransaction { db in
                try db.inTransaction(.immediate) {
                    try Schema.migrate(db)
                    return .commit
                }
                return try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'store_id'")!
            }
            return DropStore(folder: folder, storeID: storeID, pool: pool, retention: retention, now: now)
        } catch let error as AgentDropError {
            throw error
        } catch {
            throw AgentDropError.invalid("Can't open the store at \(path): \(error)")
        }
    }

    /// Runs `body` in an IMMEDIATE transaction (write lock held from the start).
    func mutate<T>(_ body: (Database) throws -> T) throws -> T {
        do {
            return try pool.writeWithoutTransaction { db in
                var result: T?
                try db.inTransaction(.immediate) {
                    result = try body(db)
                    return .commit
                }
                return result!
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
            throw AgentDropError.invalid("store busy, retry")
        }
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        do {
            return try pool.read(body)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
            throw AgentDropError.invalid("store busy, retry")
        }
    }

    public func path(of drop: Drop) -> URL {
        folder.appendingPathComponent(drop.filename, isDirectory: drop.isFolder)
    }

    public func json(_ drop: Drop) -> DropJSON {
        DropJSON(drop: drop, path: path(of: drop).path)
    }

    public func events(afterSeq: Int64 = 0) throws -> [StoredEvent] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM event WHERE seq > ? ORDER BY seq", arguments: [afterSeq])
                .map(StoredEvent.init(row:))
        }
    }

    static func fetchDrop(_ db: Database, id: String) throws -> Drop? {
        try fetchDrops(db, sql: "SELECT * FROM drops WHERE id = ?", arguments: [id]).first
    }

    static func fetchDrops(_ db: Database, sql: String, arguments: StatementArguments) throws -> [Drop] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            let id: String = row["id"]
            let tags = try String.fetchAll(db, sql: "SELECT tag FROM drop_tag WHERE drop_id = ? ORDER BY rowid",
                                           arguments: [id])
            return Drop(row: row, tags: tags)
        }
    }
}

extension Drop {
    init(row: Row, tags: [String]) {
        self.init(
            id: row["id"],
            filename: row["filename"],
            isFolder: row["is_folder"],
            title: row["title"],
            description: row["description"],
            project: row["project"],
            tags: tags,
            from: row["from_identity"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            readAt: (row["read_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
            kind: DropKind(rawValue: row["kind"])!,
            status: (row["status"] as String?).flatMap(HandoffStatus.init(rawValue:)),
            claimedBy: row["claimed_by"],
            statusNote: row["status_note"],
            archived: row["archived"],
            missing: row["missing"]
        )
    }
}
