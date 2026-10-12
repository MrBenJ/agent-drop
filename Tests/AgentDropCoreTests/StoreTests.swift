import Foundation
import GRDB
import Testing
@testable import AgentDropCore

struct StoreTests {
    @Test func openCreatesStoreInsideTheFolder() throws {
        let tmp = try TempDir()
        let folder = tmp.url.appendingPathComponent("AgentDrop", isDirectory: true)
        let store = try DropStore.open(folder: folder, retention: .default)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".agentdrop/index.sqlite").path))
        #expect(store.storeID.count == 12)
        let (version, mode) = try store.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA user_version"), try String.fetchOne(db, sql: "PRAGMA journal_mode"))
        }
        #expect(version == Schema.migrations.count)
        #expect(mode == "wal")
    }

    @Test func storeIDIsStableAcrossReopenAndDistinctPerFolder() throws {
        let tmp = try TempDir()
        let a = tmp.url.appendingPathComponent("A", isDirectory: true)
        let b = tmp.url.appendingPathComponent("B", isDirectory: true)
        let first = try DropStore.open(folder: a, retention: .default).storeID
        #expect(try DropStore.open(folder: a, retention: .default).storeID == first)
        #expect(try DropStore.open(folder: b, retention: .default).storeID != first)
    }

    @Test func eventSeqIsStrictlyIncreasing() throws {
        let tmp = try TempDir()
        let clock = TestClock()
        let store = try DropStore.open(folder: tmp.url, retention: .default, now: { clock.now })
        for i in 0..<3 {
            try store.mutate { db in
                try EventLog.append(db, type: .metadata, dropID: "aaaaa\(i + 2)", dataJSON: "{}",
                                    before: nil, after: nil, at: clock.now, retention: .default)
            }
        }
        let seqs = try store.events().map(\.seq)
        #expect(seqs.count == 3)
        #expect(seqs == seqs.sorted() && Set(seqs).count == 3)
    }

    @Test func retentionDeletesOnlyExpiredEventRows() throws {
        let tmp = try TempDir()
        let clock = TestClock()
        let store = try DropStore.open(folder: tmp.url, retention: .days(30), now: { clock.now })
        func append(_ id: String) throws {
            try store.mutate { db in
                try EventLog.append(db, type: .metadata, dropID: id, dataJSON: "{}",
                                    before: nil, after: nil, at: clock.now, retention: .days(30))
            }
        }
        try append("aaaaa2")
        clock.advance(days: 31)
        try append("aaaaa3")
        #expect(try store.events().map(\.dropID) == ["aaaaa3"])
    }

    @Test func foreverRetentionKeepsEverything() throws {
        let tmp = try TempDir()
        let clock = TestClock()
        let store = try DropStore.open(folder: tmp.url, retention: .forever, now: { clock.now })
        for id in ["aaaaa2", "aaaaa3"] {
            try store.mutate { db in
                try EventLog.append(db, type: .metadata, dropID: id, dataJSON: "{}",
                                    before: nil, after: nil, at: clock.now, retention: .forever)
            }
            clock.advance(days: 400)
        }
        #expect(try store.events().count == 2)
    }

    @Test func dropJSONMatchesSpecShapeWithNulls() throws {
        let drop = Drop(id: "k7f2qa", filename: "auth-plan.md", isFolder: false, title: "Auth refactor plan",
                        description: nil, project: nil, tags: ["spec"], from: "djleague/x",
                        createdAt: Date(timeIntervalSince1970: 1_760_208_240),
                        updatedAt: Date(timeIntervalSince1970: 1_760_208_240), readAt: nil,
                        kind: .handoff, status: .open, claimedBy: nil, statusNote: nil,
                        archived: false, missing: false)
        let data = try JSONEncoder().encode(DropJSON(drop: drop, path: "/x/auth-plan.md"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(obj.keys) == ["id", "filename", "path", "title", "description", "project", "tags", "from",
                                  "kind", "status", "claimedBy", "statusNote", "createdAt", "updatedAt",
                                  "readAt", "archived", "isFolder", "missing"])
        #expect(obj["description"] is NSNull)
        #expect(obj["claimedBy"] is NSNull)
        #expect(obj["createdAt"] as? String == "2025-10-11T18:44:00Z")
        #expect(obj["status"] as? String == "open")
    }
}
