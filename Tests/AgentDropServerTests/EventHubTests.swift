import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

struct EventHubTests {
    @Test func deliversNewEventsLiveAfterPoke() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        let stream = try await hub.subscribe(.all, resumeFrom: nil)
        let drop = try f.add(handoff: true)
        _ = try f.store.claim(drop.id, by: "b")
        await hub.poke()
        let frames = await collect(stream, count: 2)
        #expect(frames.compactMap(\.message).map(\.type) == ["created", "status"])
        #expect(frames.first?.message?.storeId == f.store.storeID)
        #expect(frames.last?.message?.data["to"]?.stringValue == "claimed")
    }

    @Test func liveOnlyWithoutCursorReplayWithCursor() async throws {
        let f = try StoreFixture()
        let a = try f.add("a.md")
        let b = try f.add("b.md")
        let hub = try EventHub(store: f.store)

        let fresh = try await hub.subscribe(.all, resumeFrom: nil)
        let resumed = try await hub.subscribe(.all, resumeFrom: EventCursor(storeID: f.store.storeID, seq: 1))
        _ = try f.store.setArchived(a.id, true)
        await hub.poke()

        #expect(await collect(fresh, count: 1).compactMap(\.message).map(\.type) == ["archived"])
        let replayed = await collect(resumed, count: 2).compactMap(\.message)
        #expect(replayed.map(\.dropId) == [b.id, a.id])
        #expect(replayed.map(\.seq) == [2, 3])
    }

    @Test func foreignStoreCursorGetsResetThenLiveOnly() async throws {
        let f = try StoreFixture()
        try f.add("a.md")
        let hub = try EventHub(store: f.store)
        let stream = try await hub.subscribe(.all, resumeFrom: EventCursor(storeID: "otherstore", seq: 0))
        try f.add("b.md")
        await hub.poke()
        let frames = await collect(stream, count: 2)
        #expect(frames.first == .reset(EventCursor(storeID: f.store.storeID, seq: 1)))
        #expect(frames.last?.message?.seq == 2)
    }

    @Test func subscribingWithoutCursorSkipsEverythingAlreadyWritten() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        try f.add("a.md")   // written after the hub started, never poked
        let stream = try await hub.subscribe(.all, resumeFrom: nil)
        try f.add("b.md")
        await hub.poke()
        #expect(await collect(stream, count: 1).compactMap(\.message).map(\.seq) == [2])
    }

    @Test func freshSubscriptionsOpenWithTheirStartingCursor() async throws {
        let f = try StoreFixture()
        try f.add("a.md")
        let hub = try EventHub(store: f.store)
        let fresh = try await hub.subscribe(.all, resumeFrom: nil)
        #expect(await collect(fresh, count: 1, includeCursor: true) == [.cursor(EventCursor(storeID: f.store.storeID, seq: 1))])
        let resumed = try await hub.subscribe(.all, resumeFrom: EventCursor(storeID: f.store.storeID, seq: 1))
        try f.add("b.md")
        await hub.poke()
        #expect(await collect(resumed, count: 1, includeCursor: true).first?.message?.seq == 2)
    }

    @Test func cursorAheadOfTheLogNeverDuplicates() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        try f.add("a.md")   // seq 1, not yet poked
        let stream = try await hub.subscribe(.all, resumeFrom: EventCursor(storeID: f.store.storeID, seq: 1))
        try f.add("b.md")   // seq 2
        await hub.poke()
        #expect(await collect(stream, count: 1).compactMap(\.message).map(\.seq) == [2])
        #expect(await collect(stream, count: 1, timeout: .milliseconds(200)).isEmpty)
    }

    @Test func filtersApplyToReplayAndLive() async throws {
        let f = try StoreFixture()
        let handoff = try f.add("h.md", project: "app", handoff: true)
        try f.add("n.md", project: "app")
        let hub = try EventHub(store: f.store)
        let inbox = try await hub.subscribe(.inbox(project: "app"), resumeFrom: EventCursor(storeID: f.store.storeID, seq: 0))
        let one = try await hub.subscribe(.drop(handoff.id), resumeFrom: EventCursor(storeID: f.store.storeID, seq: 0))
        _ = try f.store.claim(handoff.id, by: "x")      // departure: not an inbox arrival
        _ = try f.store.release(handoff.id)             // arrival again
        await hub.poke()

        let arrivals = await collect(inbox, count: 2).compactMap(\.message)
        #expect(arrivals.map(\.type) == ["created", "status"])
        #expect(arrivals.last?.data["to"]?.stringValue == "open")
        #expect(await collect(one, count: 3).compactMap(\.message).map(\.type) == ["created", "status", "status"])
    }

    /// Review Focus: a burst of writes with pokes racing them arrives complete, in order, once.
    @Test func burstArrivesInOrderWithoutGapsOrDuplicates() async throws {
        let f = try StoreFixture()
        let drop = try f.add(handoff: true)
        let hub = try EventHub(store: f.store)
        let stream = try await hub.subscribe(.all, resumeFrom: EventCursor(storeID: f.store.storeID, seq: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<25 {
                    _ = try f.store.claim(drop.id, by: "a")
                    _ = try f.store.release(drop.id)
                }
            }
            group.addTask {
                for _ in 0..<40 {
                    await hub.poke()
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            try await group.waitForAll()
        }
        await hub.poke()
        let seqs = await collect(stream, count: 51).compactMap(\.message).map(\.seq)
        #expect(seqs == Array(1...51))
    }

    @Test func heartbeatsReachSubscribers() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        await hub.startHeartbeat(every: .milliseconds(50))
        let stream = try await hub.subscribe(.all, resumeFrom: nil)
        #expect(await collect(stream, count: 2) == [.heartbeat, .heartbeat])
        await hub.close()
    }

    @Test func closeEndsStreamsAndRefusesNewOnes() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        let stream = try await hub.subscribe(.all, resumeFrom: nil)
        await hub.close()
        #expect(await collect(stream, count: 1).isEmpty)
        let late = try await hub.subscribe(.all, resumeFrom: nil)
        #expect(await collect(late, count: 1).isEmpty)
    }

    @Test func abandonedSubscriptionsAreDropped() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        let task = Task {
            let stream = try await hub.subscribe(.all, resumeFrom: nil)
            for await _ in stream {}
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await hub.subscriberCount == 1)
        task.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await hub.subscriberCount == 0)
    }
}
