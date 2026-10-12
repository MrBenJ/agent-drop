import Foundation
import Testing
@testable import AgentDropCore

/// Spec §3.2 as the app sees it: unregistered entries and reconciliation on launch.
struct FolderReconcileTests {
    let fm = FileManager.default

    @Test func unregisteredListsOnlyUnclaimedTopLevelFilesAndFolders() throws {
        let f = try Fixture()
        try f.add("plan.md")
        try Data("x".utf8).write(to: f.folder.appendingPathComponent("loose.md"))
        try fm.createDirectory(at: f.folder.appendingPathComponent("bundle/inner"), withIntermediateDirectories: true)
        try Data("y".utf8).write(to: f.folder.appendingPathComponent("bundle/inner/a.txt"))
        try Data().write(to: f.folder.appendingPathComponent(".hidden"))
        try fm.createSymbolicLink(at: f.folder.appendingPathComponent("link.md"),
                                  withDestinationURL: f.folder.appendingPathComponent("plan.md"))

        let entries = try f.store.unregisteredEntries()
        #expect(Set(entries.map(\.name)) == ["loose.md", "bundle"])
        #expect(entries.first { $0.name == "bundle" }?.isFolder == true)
        #expect(entries.first { $0.name == "loose.md" }?.isFolder == false)
    }

    @Test func aCaseAliasOfARegisteredNameIsStillUnregistered() throws {
        let f = try Fixture()
        let drop = try f.add("Plan.md")
        // The record's file is gone and a name differing only in case appeared: that is not
        // the drop returning (spec §3.2), so it shows as unregistered.
        try fm.removeItem(at: f.store.path(of: drop))
        try Data("x".utf8).write(to: f.folder.appendingPathComponent("plan.md"))
        #expect(try f.store.unregisteredEntries().map(\.name) == ["plan.md"])
    }

    @Test func emptyFolderHasNoUnregisteredEntries() throws {
        let f = try Fixture()
        #expect(try f.store.unregisteredEntries().isEmpty)
    }

    @Test func reconcileMarksMissingAndReturnedDropsIncludingArchived() throws {
        let f = try Fixture()
        let kept = try f.add("kept.md")
        let gone = try f.add("gone.md")
        let archived = try f.add("old.md")
        _ = try f.store.setArchived(archived.id, true)
        try fm.removeItem(at: f.store.path(of: gone))
        try fm.removeItem(at: f.store.path(of: archived))

        let changed = try f.store.reconcile()
        #expect(Set(changed.map(\.id)) == [gone.id, archived.id])
        #expect(try f.store.resolve(kept.id).missing == false)
        #expect(changed.allSatisfy { $0.missing })

        try Data("back".utf8).write(to: f.store.path(of: gone))
        #expect(try f.store.reconcile().map(\.id) == [gone.id])
        #expect(try f.store.events().last?.data == #"{"missing":false}"#)
        #expect(try f.store.reconcile().isEmpty) // nothing changed: no events
    }

    @Test func setRetentionAppliesToTheNextWrite() throws {
        let f = try Fixture(retention: .forever)
        let drop = try f.add()
        f.clock.advance(days: 10)
        try f.store.recordContentChange(drop.id)
        #expect(try f.store.events().count == 2) // forever: nothing trimmed

        f.store.setRetention(.days(5))
        #expect(f.store.retention == .days(5))
        try f.store.recordContentChange(drop.id)
        #expect(try f.store.events().map(\.type) == [.content, .content])
    }
}
