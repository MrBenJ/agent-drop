import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore

@MainActor
struct ActionTests {
    func attached(_ f: StoreFixture) async -> LibraryModel {
        let library = LibraryModel()
        await library.attach(f.store)
        return library
    }

    @Test func handoffButtonsUseTheCoreTransitions() async throws {
        let f = try StoreFixture()
        let drop = try f.add("t.md", handoff: true)
        _ = try f.store.claim(drop.id, by: "codex")
        let library = await attached(f)

        await library.release(drop.id)
        #expect(library.drop(drop.id)?.status == .open && library.drop(drop.id)?.claimedBy == nil)
        await library.markDone(drop.id, note: "  shipped in PR #42 ")
        #expect(library.drop(drop.id)?.status == .done && library.drop(drop.id)?.statusNote == "shipped in PR #42")
        await library.reopen(drop.id)
        #expect(library.drop(drop.id)?.status == .open && library.drop(drop.id)?.statusNote == nil)
        await library.markDone(drop.id, note: "   ")
        #expect(library.drop(drop.id)?.statusNote == nil)
        #expect(library.alert == nil)
    }

    @Test func aConflictBecomesAnAlertAndShowsTheCurrentState() async throws {
        let f = try StoreFixture()
        let drop = try f.add("t.md", handoff: true)
        let library = await attached(f)
        _ = try f.store.claim(drop.id, by: "codex") // another agent, after the window loaded
        await library.reopen(drop.id)
        #expect(library.alert?.contains("claimed by codex") == true)
        #expect(library.drop(drop.id)?.status == .claimed)
    }

    @Test func archiveAndRemoveRecord() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md")
        let library = await attached(f)
        await library.setArchived([drop.id], true)
        #expect(library.drop(drop.id)?.archived == true)
        await library.setArchived([drop.id], false)
        #expect(library.drop(drop.id)?.archived == false)

        await library.removeRecord(drop.id) // file still there: refused
        #expect(library.alert?.contains("still has its file") == true)
        library.alert = nil
        try FileManager.default.removeItem(at: f.store.path(of: drop))
        await library.removeRecord(drop.id)
        #expect(library.alert == nil && library.drop(drop.id) == nil)
    }

    @Test func archivingSeveralDropsArchivesEach() async throws {
        let f = try StoreFixture()
        let a = try f.add("a.md")
        let b = try f.add("b.md")
        let other = try f.add("c.md")
        let library = await attached(f)
        await library.setArchived([a.id, b.id], true)
        #expect(library.drop(a.id)?.archived == true && library.drop(b.id)?.archived == true)
        #expect(library.drop(other.id)?.archived == false)
        await library.setArchived([a.id, b.id], false)
        #expect(library.drop(a.id)?.archived == false && library.drop(b.id)?.archived == false)
        #expect(library.alert == nil)
    }

    @Test func editAppliesOnlyWhatChanged() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md", project: "p", tags: ["x", "y"])
        let library = await attached(f)
        var form = MetadataForm(try #require(library.drop(drop.id)))
        form.title = "  New title "
        form.tags = ["y", "z", "z", " "]
        form.kind = .handoff
        #expect(await library.edit(drop.id, form) == nil)
        let edited = try #require(library.drop(drop.id))
        #expect(edited.title == "New title" && edited.tags == ["y", "z"])
        #expect(edited.kind == .handoff && edited.status == .open && edited.project == "p")
        #expect(try f.store.events().filter { $0.type == .metadata }.count == 1)

        // Nothing changed: no write, no event.
        #expect(await library.edit(drop.id, MetadataForm(edited)) == nil)
        #expect(try f.store.events().filter { $0.type == .metadata }.count == 1)
    }

    @Test func editErrorsStayInTheSheet() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md", project: "p", handoff: true)
        _ = try f.store.claim(drop.id, by: "codex")
        let library = await attached(f)
        var form = MetadataForm(try #require(library.drop(drop.id)))
        form.project = ""
        #expect(await library.edit(drop.id, form)?.contains("can't clear the project") == true)
        form = MetadataForm(try #require(library.drop(drop.id)))
        form.kind = .note
        #expect(await library.edit(drop.id, form)?.contains("Release or reopen") == true)
        form = MetadataForm(try #require(library.drop(drop.id)))
        form.project = "bad\nvalue"
        #expect(await library.edit(drop.id, form) != nil) // the store's identity rules apply
        #expect(library.alert == nil)
    }

    @Test func registerAddsTheEntryInPlaceAndSelectsIt() async throws {
        let f = try StoreFixture()
        try f.loose("notes.md")
        let library = await attached(f)
        let entry = try #require(library.unregistered.first)

        var form = RegisterForm()
        #expect(await library.register(entry, form)?.contains("From") == true) // never filled in
        form.from = " ben "
        form.project = "agent-drop"
        form.tags = ["spec"]
        form.handoff = true
        #expect(await library.register(entry, form) == nil)
        let drop = try #require(library.selectedDrop)
        #expect(drop.filename == "notes.md" && drop.from == "ben" && drop.project == "agent-drop")
        #expect(drop.kind == .handoff && drop.tags == ["spec"])
        #expect(library.unregistered.isEmpty)
        #expect(library.registeredInApp == [drop.id])
        #expect(FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("notes.md").path))
    }

    @Test func aDecomposedUnicodeNameRegistersInPlace() async throws {
        let f = try StoreFixture()
        let decomposed = "Cafe\u{301} notes.md" // as Finder may write it (NFD)
        try f.loose(decomposed)
        let library = await attached(f)
        let entry = try #require(library.unregistered.first)
        var form = RegisterForm()
        form.from = "ben"
        #expect(await library.register(entry, form) == nil)
        #expect(library.unregistered.isEmpty)
        #expect(library.selectedDrop.map { Array($0.filename.utf8) } == Array(entry.name.utf8))
        #expect(try f.store.unregisteredEntries().isEmpty)
    }

    @Test func registeringAFolderEntryKeepsItAFolderDrop() async throws {
        let f = try StoreFixture()
        try FileManager.default.createDirectory(at: f.folder.appendingPathComponent("bundle"), withIntermediateDirectories: true)
        try Data("# Bundle\n".utf8).write(to: f.folder.appendingPathComponent("bundle/README.md"))
        let library = await attached(f)
        var form = RegisterForm()
        form.from = "ben"
        #expect(await library.register(try #require(library.unregistered.first), form) == nil)
        #expect(library.selectedDrop?.isFolder == true && library.selectedDrop?.title == "Bundle")
    }
}

struct FormTests {
    func drop(status: HandoffStatus?) -> Drop {
        Drop(id: "abcdef", filename: "a.md", isFolder: false, title: "T", description: nil, project: nil, tags: [],
             from: "x", createdAt: Date(), updatedAt: Date(), readAt: nil, kind: status == nil ? .note : .handoff,
             status: status, claimedBy: nil, statusNote: nil, archived: false, missing: false)
    }

    @Test func kindIsEditableOnlyForNotesAndOpenHandoffs() {
        #expect(MetadataForm.canChangeKind(drop(status: nil)))
        #expect(MetadataForm.canChangeKind(drop(status: .open)))
        #expect(!MetadataForm.canChangeKind(drop(status: .claimed)))
        #expect(!MetadataForm.canChangeKind(drop(status: .done)))
    }

    @Test func emptyTitleIsRejectedAndEmptyOptionalFieldsAreFineWhenAlreadyEmpty() throws {
        var form = MetadataForm(drop(status: nil))
        #expect(try form.request(for: drop(status: nil)) == nil)
        form.title = "  "
        #expect(throws: AgentDropError.self) { try form.request(for: drop(status: nil)) }
    }

    @Test func aTagTypedButNotYetAddedIsKept() throws {
        var form = MetadataForm(drop(status: nil))
        form.pendingTag = " urgent "
        #expect(try form.request(for: drop(status: nil))?.addTags == ["urgent"])
        var register = RegisterForm()
        register.from = "ben"
        register.pendingTag = "spec"
        let entry = UnregisteredEntry(name: "a.md", isFolder: false, modifiedAt: nil)
        #expect(try register.request(for: entry, in: URL(fileURLWithPath: "/tmp")).tags == ["spec"])
    }

    @Test func tagListTrimsAndDeduplicatesExactly() {
        #expect(TagList.normalized([" PR", "pr", "PR", "", "  "]) == ["PR", "pr"])
    }
}
