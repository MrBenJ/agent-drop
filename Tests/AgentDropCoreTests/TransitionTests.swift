import Foundation
import Testing
@testable import AgentDropCore

struct TransitionTests {
    @Test func fullLifecycle() throws {
        let f = try Fixture()
        let h = try f.add("h.md", handoff: true)
        let claimed = try f.store.claim(h.id, by: "djleague/build-feature-x")
        #expect(claimed.status == .claimed && claimed.claimedBy == "djleague/build-feature-x")
        let released = try f.store.release(h.id)
        #expect(released.status == .open && released.claimedBy == nil)
        _ = try f.store.claim(h.id, by: "b")
        let done = try f.store.done(h.id, note: "shipped in PR #42")
        #expect(done.status == .done && done.statusNote == "shipped in PR #42" && done.claimedBy == "b")
        let reopened = try f.store.reopen(h.id)
        #expect(reopened.status == .open && reopened.claimedBy == nil && reopened.statusNote == nil)
        let statusEvents = try f.store.events().filter { $0.type == .status }
        #expect(statusEvents.count == 5)
        let data = try JSONSerialization.jsonObject(with: Data(statusEvents[0].data.utf8)) as! [String: Any]
        #expect(data["from"] as? String == "open" && data["to"] as? String == "claimed")
        #expect(data["claimedBy"] as? String == "djleague/build-feature-x")
        #expect(data["statusNote"] is NSNull)
    }

    @Test func doneDirectlyFromOpen() throws {
        let f = try Fixture()
        let h = try f.add("h.md", handoff: true)
        #expect(try f.store.done(h.id, note: nil).status == .done)
    }

    @Test func illegalTransitionsAreConflictsWithCurrentState() throws {
        let f = try Fixture()
        let h = try f.add("h.md", handoff: true)
        _ = try f.store.claim(h.id, by: "djleague/build-feature-x")
        let msg = expectError(3) { _ = try f.store.claim(h.id, by: "other") }
        #expect(msg == "\(h.id) is claimed by djleague/build-feature-x")
        expectError(3) { _ = try f.store.reopen(h.id) }
        _ = try f.store.done(h.id, note: nil)
        #expect(expectError(3) { _ = try f.store.claim(h.id, by: "x") } == "\(h.id) is done")
        expectError(3) { _ = try f.store.release(h.id) }
        expectError(3) { _ = try f.store.done(h.id, note: nil) }
    }

    @Test func transitionsOnNotesAreInvalid() throws {
        let f = try Fixture()
        let n = try f.add("n.md")
        expectError(1) { _ = try f.store.claim(n.id, by: "a") }
        expectError(1) { _ = try f.store.done(n.id, note: nil) }
    }

    @Test func claimRequiresValidIdentity() throws {
        let f = try Fixture()
        let h = try f.add("h.md", handoff: true)
        expectError(1) { _ = try f.store.claim(h.id, by: " ") }
    }

    @Test func concurrentClaimsExactlyOneWins() throws {
        let f = try Fixture()
        let h = try f.add("race.md", handoff: true)
        let winners = Locked<[String]>([])
        let conflicts = Locked<Int>(0)
        DispatchQueue.concurrentPerform(iterations: 10) { i in
            let store = try! DropStore.open(folder: f.folder, retention: .default)
            do {
                _ = try store.claim(h.id, by: "agent-\(i)")
                winners.withLock { $0.append("agent-\(i)") }
            } catch let e as AgentDropError where e.exitCode == 3 {
                conflicts.withLock { $0 += 1 }
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        #expect(winners.value.count == 1)
        #expect(conflicts.value == 9)
        #expect(try f.store.resolve(h.id).claimedBy == winners.value.first)
    }
}

struct OneEventPerMutationTests {
    @Test func eachMutationAppendsExactlyOneRow() throws {
        let f = try Fixture()
        func count() throws -> Int { try f.store.events().count }
        let h = try f.add("h.md", handoff: true);                          #expect(try count() == 1)
        _ = try f.store.edit(h.id, EditRequest(title: "T", addTags: ["x"])); #expect(try count() == 2)
        _ = try f.store.claim(h.id, by: "a");                               #expect(try count() == 3)
        _ = try f.store.release(h.id);                                      #expect(try count() == 4)
        _ = try f.store.done(h.id, note: "n");                              #expect(try count() == 5)
        _ = try f.store.reopen(h.id);                                       #expect(try count() == 6)
        _ = try f.store.setArchived(h.id, true);                            #expect(try count() == 7)
        _ = try f.store.markRead(h.id);                                     #expect(try count() == 8)
    }
}
