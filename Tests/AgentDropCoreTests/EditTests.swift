import Foundation
import Testing
@testable import AgentDropCore

struct EditTests {
    @Test func editChangesFieldsAndEmitsOneMetadataEvent() throws {
        let f = try Fixture()
        let drop = try f.add("p.md", tags: ["a"])
        let edited = try f.store.edit(drop.id, EditRequest(title: "New", description: "Why", project: "proj",
                                                           addTags: ["b", "a"], removeTags: ["a"]))
        #expect(edited.title == "New" && edited.description == "Why" && edited.project == "proj")
        #expect(edited.tags == ["b"])
        let events = try f.store.events()
        #expect(events.map(\.type) == [.created, .metadata])
        let data = try JSONSerialization.jsonObject(with: Data(events[1].data.utf8)) as! [String: Any]
        #expect(Set(data.keys) == ["title", "description", "project", "tags"])
        #expect(events[1].projectBefore == nil && events[1].projectAfter == "proj")
    }

    @Test func noOpEditEmitsNothing() throws {
        let f = try Fixture()
        let drop = try f.add("p.md")
        _ = try f.store.edit(drop.id, EditRequest(title: drop.title))
        #expect(try f.store.events().count == 1)
    }

    @Test func kindChangeRules() throws {
        let f = try Fixture()
        let note = try f.add("n.md")
        let handoff = try f.store.edit(note.id, EditRequest(kind: .handoff))
        #expect(handoff.kind == .handoff && handoff.status == .open)
        let last = try f.store.events().last!
        #expect(last.type == .metadata && !last.inboxBefore && last.inboxAfter)

        let back = try f.store.edit(note.id, EditRequest(kind: .note))
        #expect(back.kind == .note && back.status == nil)

        let claimed = try f.add("c.md", handoff: true)
        _ = try f.store.claim(claimed.id, by: "agent-a")
        let msg = expectError(3) { _ = try f.store.edit(claimed.id, EditRequest(kind: .note)) }
        #expect(msg == "\(claimed.id) is claimed by agent-a; release it first")

        let done = try f.add("d.md", handoff: true)
        _ = try f.store.done(done.id, note: nil)
        let msg2 = expectError(3) { _ = try f.store.edit(done.id, EditRequest(kind: .note)) }
        #expect(msg2 == "\(done.id) is done; reopen it first")
    }

    @Test func archiveRoundTripAndInboxMembership() throws {
        let f = try Fixture()
        let drop = try f.add("h.md", handoff: true)
        #expect(try f.store.setArchived(drop.id, true).archived)
        #expect(try f.store.inbox(project: nil).isEmpty)
        _ = try f.store.setArchived(drop.id, true) // no-op, no event
        let restored = try f.store.setArchived(drop.id, false)
        #expect(!restored.archived)
        let events = try f.store.events()
        #expect(events.map(\.type) == [.created, .archived, .archived])
        #expect(events[2].inboxAfter && !events[2].inboxBefore)
        #expect(FileManager.default.fileExists(atPath: f.store.path(of: drop).path))
    }

    @Test func markReadOnlyOnce() throws {
        let f = try Fixture()
        let drop = try f.add("r.md")
        #expect(try f.store.markRead(drop.id).readAt == f.clock.now)
        f.clock.advance(seconds: 10)
        #expect(try f.store.markRead(drop.id).readAt != f.clock.now)
        #expect(try f.store.events().filter { $0.type == .read }.count == 1)
    }

    @Test func removeRecordOnlyForMissingDrops() throws {
        let f = try Fixture()
        let drop = try f.add("x.md")
        expectError(1) { try f.store.removeRecord(drop.id) }
        try FileManager.default.removeItem(at: f.store.path(of: drop))
        try f.store.removeRecord(drop.id)
        expectError(2) { _ = try f.store.resolve(drop.id) }
        #expect(try f.store.events().map(\.type) == [.created, .missing, .removed])
    }

    @Test func editValidatesInput() throws {
        let f = try Fixture()
        let drop = try f.add("v.md")
        expectError(1) { _ = try f.store.edit(drop.id, EditRequest(project: "  ")) }
        expectError(1) { _ = try f.store.edit(drop.id, EditRequest(addTags: ["a\nb"])) }
        expectError(2) { _ = try f.store.edit("zzzzzz", EditRequest(title: "x")) }
    }
}
