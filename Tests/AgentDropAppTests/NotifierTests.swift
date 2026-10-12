import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore

@MainActor
final class RecordingPoster: NoticePosting {
    var posted: [NewDropNotice] = []
    func post(_ notices: [NewDropNotice]) { posted += notices }
}

@MainActor
struct NotifierTests {
    @Test func announcesOnlyDropsCreatedAfterTheFirstCheck() async throws {
        let f = try StoreFixture()
        try f.add("before.md")
        let library = LibraryModel()
        await library.attach(f.store)
        let notifier = NewDropNotifier()
        #expect(await notifier.check(f.store, library: library, enabled: true).isEmpty) // baseline

        let drop = try f.add("new.md", "# New plan\n", from: "codex", project: "app", handoff: true,
                             description: "Implement it")
        await library.reload()
        let notices = await notifier.check(f.store, library: library, enabled: true)
        #expect(notices == [NewDropNotice(title: "New plan", body: "Handoff from codex · app\nImplement it",
                                          dropID: drop.id)])
        #expect(await notifier.check(f.store, library: library, enabled: true).isEmpty) // once only
    }

    @Test func aDropCreatedBetweenTheSnapshotAndTheCheckIsAnnouncedLater() async throws {
        let f = try StoreFixture()
        let library = LibraryModel()
        await library.attach(f.store)
        let notifier = NewDropNotifier()
        _ = await notifier.check(f.store, library: library, enabled: true)
        let first = try f.add("a.md", "# First\n")
        await library.reload()
        let late = try f.add("late.md", "# Late\n") // an agent writes after the snapshot was read
        #expect(await notifier.check(f.store, library: library, enabled: true).map(\.dropID) == [first.id])
        await library.reload()
        #expect(await notifier.check(f.store, library: library, enabled: true).map(\.dropID) == [late.id])
    }

    @Test func disabledStillAdvancesSoTurningItOnDoesntReplayOldDrops() async throws {
        let f = try StoreFixture()
        let library = LibraryModel()
        await library.attach(f.store)
        let notifier = NewDropNotifier()
        _ = await notifier.check(f.store, library: library, enabled: false)
        try f.add("a.md")
        await library.reload()
        #expect(await notifier.check(f.store, library: library, enabled: false).isEmpty)
        #expect(await notifier.check(f.store, library: library, enabled: true).isEmpty)
    }

    @Test func manyAtOnceBecomeOneSummary() async throws {
        let f = try StoreFixture()
        let library = LibraryModel()
        await library.attach(f.store)
        let notifier = NewDropNotifier()
        _ = await notifier.check(f.store, library: library, enabled: true)
        for i in 1...4 { try f.add("n\(i).md", "# N\(i)\n") }
        await library.reload()
        let notices = await notifier.check(f.store, library: library, enabled: true)
        #expect(notices.count == 1)
        #expect(notices.first?.title == "4 new drops" && notices.first?.dropID == nil)
    }

    @Test func skipsDropsRegisteredInTheAppArchivedOrMissing() async throws {
        let f = try StoreFixture()
        try f.loose("mine.md")
        let library = LibraryModel()
        await library.attach(f.store)
        let notifier = NewDropNotifier()
        _ = await notifier.check(f.store, library: library, enabled: true)

        var form = RegisterForm()
        form.from = "ben"
        #expect(await library.register(try #require(library.unregistered.first), form) == nil)
        let archived = try f.add("arch.md")
        _ = try f.store.setArchived(archived.id, true)
        await library.reload()
        #expect(await notifier.check(f.store, library: library, enabled: true).isEmpty)
    }

    @Test func aNewStoreStartsFromItsCurrentEnd() async throws {
        let first = try StoreFixture()
        let second = try StoreFixture()
        try second.add("old-in-other-folder.md")
        let library = LibraryModel()
        await library.attach(first.store)
        let notifier = NewDropNotifier()
        _ = await notifier.check(first.store, library: library, enabled: true)
        await library.attach(second.store) // folder switch
        #expect(await notifier.check(second.store, library: library, enabled: true).isEmpty)
    }
}
