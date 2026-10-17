import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore

@MainActor
struct LibraryModelTests {
    @Test func loadsDropsAndUnregisteredEntriesWithCounts() async throws {
        let f = try StoreFixture()
        try f.add("note.md")
        let handoff = try f.add("task.md", handoff: true)
        let archived = try f.add("old.md")
        _ = try f.store.setArchived(archived.id, true)
        try f.loose("loose.txt")

        let library = LibraryModel()
        await library.attach(f.store)
        #expect(library.drops.count == 3)
        #expect(library.unregistered.map(\.name) == ["loose.txt"])
        #expect(library.unreadCount == 2) // archived drops are never unread
        #expect(library.inboxDrops.map(\.id) == [handoff.id])
        #expect(library.unregisteredCount == 1)
        #expect(!library.recentDrops.contains { $0.id == archived.id })
    }

    @Test func sidebarItemsFilterLikeTheCLI() async throws {
        let f = try StoreFixture()
        let a = try f.add("a.md", from: "djleague/build-x", project: "courses-app", tags: ["spec"])
        let b = try f.add("b.md", from: "djleague2", project: "courses-app/web", handoff: true)
        let c = try f.add("c.md", from: "djleague/autodev/AutoDev DJ-1 [ef0]", project: "other")
        let gone = try f.add("d.md", from: "djleague", handoff: true)
        try FileManager.default.removeItem(at: f.store.path(of: gone))
        _ = try f.store.resolve(gone.id) // the CLI notices it missing
        let archived = try f.add("e.md", tags: ["spec"])
        _ = try f.store.setArchived(archived.id, true)

        let library = LibraryModel()
        await library.attach(f.store)
        func ids(_ item: SidebarItem) -> Set<String> {
            library.sidebar = item
            return Set(library.visibleDrops.map(\.id))
        }
        #expect(ids(.allDrops) == [a.id, b.id, c.id, gone.id])
        #expect(ids(.inbox) == [b.id]) // a missing handoff is not in the Inbox
        #expect(ids(.handoffs) == [b.id, gone.id])
        #expect(ids(.archived) == [archived.id])
        #expect(ids(.from("djleague")) == [a.id, c.id, gone.id]) // not djleague2
        #expect(ids(.project("courses-app")) == [a.id, b.id])
        #expect(ids(.tag("spec")) == [a.id]) // archived excluded
        #expect(ids(.unregistered).isEmpty)
    }

    @Test func searchMatchesTitleDescriptionAndFilename() async throws {
        let f = try StoreFixture()
        let byTitle = try f.add("one.md", "# Auth refactor\n")
        let byDescription = try f.add("two.md", description: "Moves sessions to cookies")
        let byFilename = try f.add("cookie-notes.txt", "plain")
        try f.add("other.md")
        try f.loose("COOKIE.png")

        let library = LibraryModel()
        await library.attach(f.store)
        library.search = "  cookie "
        #expect(Set(library.visibleDrops.map(\.id)) == [byDescription.id, byFilename.id])
        library.search = "AUTH"
        #expect(library.visibleDrops.map(\.id) == [byTitle.id])
        library.sidebar = .unregistered
        library.search = "cookie"
        #expect(library.visibleEntries.map(\.name) == ["COOKIE.png"])
    }

    @Test func handoffGroupsAreOrderedOpenClaimedDone() async throws {
        let f = try StoreFixture()
        let open = try f.add("o.md", handoff: true)
        let claimed = try f.add("c.md", handoff: true)
        let done = try f.add("d.md", handoff: true)
        _ = try f.store.claim(claimed.id, by: "x")
        _ = try f.store.done(done.id, note: nil)

        let library = LibraryModel()
        await library.attach(f.store)
        library.sidebar = .handoffs
        #expect(library.handoffGroups.map(\.status) == [.open, .claimed, .done])
        #expect(library.handoffGroups.map { $0.drops.map(\.id) } == [[open.id], [claimed.id], [done.id]])
    }

    @Test func selectingAnUnreadDropMarksItReadOnce() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md")
        let library = LibraryModel()
        await library.attach(f.store)
        library.selection = [.drop(drop.id)]
        #expect(await eventually { library.drop(drop.id)?.readAt != nil })
        #expect(library.unreadCount == 0)

        library.selection = []
        library.selection = [.drop(drop.id)]
        try await Task.sleep(for: .milliseconds(100))
        #expect(try f.store.events().filter { $0.type == .read }.count == 1)
    }

    @Test func selectingAnEntryMarksNothing() async throws {
        let f = try StoreFixture()
        try f.loose("loose.md")
        let library = LibraryModel()
        await library.attach(f.store)
        library.selection = [.entry("loose.md")]
        #expect(library.selectedEntry?.name == "loose.md")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try f.store.events().allSatisfy { $0.type == .created })
    }

    @Test func revealSwitchesToAViewThatShowsTheDrop() async throws {
        let f = try StoreFixture()
        let archived = try f.add("old.md")
        _ = try f.store.setArchived(archived.id, true)
        let library = LibraryModel()
        await library.attach(f.store)
        library.sidebar = .inbox
        library.search = "nothing matches this"

        #expect(await library.reveal(archived.id))
        #expect(library.sidebar == .archived && library.search.isEmpty)
        #expect(library.selection == [.drop(archived.id)])

        // A drop created after the last reload is found by reloading.
        let fresh = try f.add("new.md")
        #expect(await library.reveal(fresh.id))
        #expect(library.sidebar == .allDrops)

        #expect(await library.reveal("zzzzzz") == false)
        #expect(library.alert?.contains("zzzzzz") == true)
    }

    @Test func reloadDropsASelectionThatNoLongerExists() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md")
        try f.loose("loose.md")
        let library = LibraryModel()
        await library.attach(f.store)
        library.selection = [.entry("loose.md")]
        try FileManager.default.removeItem(at: f.folder.appendingPathComponent("loose.md"))
        await library.reload()
        #expect(library.selection.isEmpty)

        library.selection = [.drop(drop.id)]
        try FileManager.default.removeItem(at: f.store.path(of: drop))
        _ = try f.store.checkPresence(drop.id)
        try f.store.removeRecord(drop.id)
        await library.reload()
        #expect(library.selection.isEmpty)
    }

    @Test func selectingSeveralDropsShowsNoSingleDropAndMarksNoneRead() async throws {
        let f = try StoreFixture()
        let a = try f.add("a.md")
        let b = try f.add("b.md")
        let library = LibraryModel()
        await library.attach(f.store)
        library.selection = [.drop(a.id), .drop(b.id)]
        #expect(library.selectedDrop == nil)
        #expect(Set(library.drops(in: library.selection).map(\.id)) == [a.id, b.id])
        try await Task.sleep(for: .milliseconds(100))
        #expect(try f.store.events().allSatisfy { $0.type == .created })
    }

    @Test func urlsForASelectionSkipMissingDrops() async throws {
        let f = try StoreFixture()
        let present = try f.add("a.md")
        let gone = try f.add("b.md")
        try f.loose("loose.md")
        try FileManager.default.removeItem(at: f.store.path(of: gone))
        _ = try f.store.checkPresence(gone.id)
        let library = LibraryModel()
        await library.attach(f.store)
        let urls = library.urls(for: [.drop(present.id), .drop(gone.id), .entry("loose.md")])
        #expect(Set(urls.map(\.lastPathComponent)) == ["a.md", "loose.md"])
    }

    @Test func reloadKeepsTheRestOfASelectionWhenOneItemGoes() async throws {
        let f = try StoreFixture()
        let kept = try f.add("a.md")
        try f.loose("loose.md")
        let library = LibraryModel()
        await library.attach(f.store)
        library.sidebar = .allDrops
        library.selection = [.drop(kept.id), .entry("loose.md")]
        try FileManager.default.removeItem(at: f.folder.appendingPathComponent("loose.md"))
        await library.reload()
        #expect(library.selection == [.drop(kept.id)])
    }

    @Test func everyReloadBumpsTheRevision() async throws {
        let f = try StoreFixture()
        let library = LibraryModel()
        await library.attach(f.store)
        let first = library.revision
        await library.reload()
        #expect(library.revision == first + 1)
    }

    @Test func detachClearsEverything() async throws {
        let f = try StoreFixture()
        try f.add("a.md")
        let library = LibraryModel()
        await library.attach(f.store)
        library.sidebar = .archived
        library.detach()
        #expect(library.store == nil && library.drops.isEmpty && library.sidebar == .allDrops)
        await library.reload() // no store: nothing happens
        #expect(library.drops.isEmpty)
    }
}

struct IdentityTreeTests {
    @Test func flatValuesStayFlat() {
        let nodes = IdentityTree.build(["codex", "claude", "codex"])
        #expect(nodes.map(\.name) == ["claude", "codex"])
        #expect(nodes.map(\.count) == [1, 2])
        #expect(nodes.allSatisfy { $0.children == nil })
    }

    @Test func slashValuesBecomeATreeWhosePathsArePrefixes() {
        let nodes = IdentityTree.build(["djleague/build-x", "djleague/autodev/AutoDev DJ-1 [ef0]", "djleague", "pi"])
        #expect(nodes.map(\.path) == ["djleague", "pi"])
        let djleague = nodes[0]
        #expect(djleague.count == 3)
        #expect(djleague.children?.map(\.path) == ["djleague/autodev", "djleague/build-x"])
        #expect(djleague.children?[0].children?.map(\.path) == ["djleague/autodev/AutoDev DJ-1 [ef0]"])
        #expect(djleague.children?[1].children == nil)
    }

    @Test func emptyLevelsKeepExactPrefixes() {
        let nodes = IdentityTree.build(["a//b", "a/"])
        #expect(nodes.map(\.path) == ["a"])
        #expect(nodes[0].children?.map(\.path) == ["a/"])
        #expect(nodes[0].children?[0].children?.map(\.path) == ["a//b"])
        #expect(nodes[0].children?[0].count == 2)
    }

    @Test func treeFilterMatchesTheSidebarFilter() {
        let values = ["djleague/build-x", "djleague2", "djleague"]
        let node = IdentityTree.build(values).first { $0.path == "djleague" }!
        #expect(values.filter { Validation.isUnder($0, prefix: node.path) }.count == node.count)
    }
}
