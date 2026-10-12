import Foundation
import GRDB
import Testing
@testable import AgentDropCore

struct QueryTests {
    @Test func idAndFilenameAmbiguityDoesNotReadTheWrongDrop() throws {
        let f = try Fixture()
        let first = try f.add("first.md")
        _ = try f.add(first.id, "second file")
        expectError(1) { _ = try f.store.resolve(first.id) }
        #expect(try f.store.resolve("first.md").id == first.id)
    }

    @Test func restoredFileBecomesAvailableAndCannotBeRemoved() throws {
        let f = try Fixture()
        let drop = try f.add("restored.md", handoff: true)
        let path = f.store.path(of: drop)
        try FileManager.default.removeItem(at: path)
        #expect(try f.store.resolve(drop.id).missing)
        try Data("restored".utf8).write(to: path)
        expectError(1) { try f.store.removeRecord(drop.id) }
        #expect(try !f.store.resolve(drop.id).missing)
        #expect(try f.store.inbox(project: nil).map(\.id) == [drop.id])
        let events = try f.store.events()
        #expect(events.map(\.type) == [.created, .missing, .metadata])
        #expect(events.last?.inboxAfter == true)
        #expect(try String(contentsOf: path, encoding: .utf8) == "restored")
    }

    @Test func resolveByIdThenExactFilename() throws {
        let f = try Fixture()
        let drop = try f.add("auth-plan.md")
        #expect(try f.store.resolve(drop.id).id == drop.id)
        #expect(try f.store.resolve("auth-plan.md").id == drop.id)
        expectError(2) { _ = try f.store.resolve(String(drop.id.prefix(3))) } // no prefix matching
        expectError(2) { _ = try f.store.resolve("AUTH-PLAN.md") }
    }

    @Test func deletedFileBecomesMissingAndLeavesInbox() throws {
        let f = try Fixture()
        let drop = try f.add("h.md", handoff: true)
        #expect(try f.store.inbox(project: nil).map(\.id) == [drop.id])
        try FileManager.default.removeItem(at: f.store.path(of: drop))
        let resolved = try f.store.resolve(drop.id)
        #expect(resolved.missing)
        #expect(try f.store.inbox(project: nil).isEmpty)
        _ = try f.store.resolve(drop.id) // second resolve: no second event
        let types = try f.store.events().map(\.type)
        #expect(types == [.created, .missing])
        let last = try f.store.events().last!
        #expect(last.inboxBefore && !last.inboxAfter)
    }

    @Test func listIsNewestFirstWithDefaultLimitAndArchivedExcluded() throws {
        let f = try Fixture()
        var ids: [String] = []
        for i in 0..<55 {
            ids.append(try f.add("n\(i).md").id)
            f.clock.advance(seconds: 1)
        }
        let listed = try f.store.list(ListFilter())
        #expect(listed.count == 50)
        #expect(listed.first?.id == ids.last)
        try f.store.mutate { db in try db.execute(sql: "UPDATE drops SET archived = 1 WHERE id = ?", arguments: [ids.last!]) }
        #expect(try f.store.list(ListFilter()).first?.id == ids[53])
        var all = ListFilter(); all.includeArchived = true; all.limit = nil
        #expect(try f.store.list(all).count == 55)
    }

    @Test func filtersCombine() throws {
        let f = try Fixture()
        let a = try f.add("a.md", from: "djleague/autodev/AutoDev DJ-1234 [ef013ae]", project: "dj", tags: ["PR"], handoff: true)
        let b = try f.add("b.md", from: "djleague2", project: "dj", tags: ["pr"])
        let c = try f.add("c.md", from: "djleague", project: "other")

        var under = ListFilter(); under.fromUnder = "djleague"
        #expect(Set(try f.store.list(under).map(\.id)) == [a.id, c.id])

        var exact = ListFilter(); exact.from = "djleague"
        #expect(try f.store.list(exact).map(\.id) == [c.id])

        var tag = ListFilter(); tag.tags = ["PR"]
        #expect(try f.store.list(tag).map(\.id) == [a.id], "tags match exactly, case included")

        var project = ListFilter(); project.project = "dj"; project.handoffsOnly = true
        #expect(try f.store.list(project).map(\.id) == [a.id])

        var status = ListFilter(); status.status = .open
        #expect(try f.store.list(status).map(\.id) == [a.id])
        _ = b
    }

    @Test func unreadExcludesArchivedAndMissingEvenWithAll() throws {
        let f = try Fixture()
        let keep = try f.add("keep.md")
        let archived = try f.add("arch.md")
        let gone = try f.add("gone.md")
        try f.store.mutate { db in try db.execute(sql: "UPDATE drops SET archived = 1 WHERE id = ?", arguments: [archived.id]) }
        try FileManager.default.removeItem(at: f.store.path(of: gone))
        _ = try f.store.resolve(gone.id)
        var filter = ListFilter(); filter.unreadOnly = true; filter.includeArchived = true
        #expect(try f.store.list(filter).map(\.id) == [keep.id])
    }

    @Test func inboxScopedByProjectAndExcludesArchived() throws {
        let f = try Fixture()
        let one = try f.add("1.md", project: "p", handoff: true)
        _ = try f.add("2.md", project: "q", handoff: true)
        _ = try f.add("3.md", project: "p")
        let archived = try f.add("4.md", project: "p", handoff: true)
        try f.store.mutate { db in try db.execute(sql: "UPDATE drops SET archived = 1 WHERE id = ?", arguments: [archived.id]) }
        #expect(try f.store.inbox(project: "p").map(\.id) == [one.id])
        #expect(try f.store.inbox(project: nil).count == 2)
    }
}
