import Foundation
import Testing
@testable import AgentDropCore

/// Core APIs the server and `drop watch` build on (Plan 2).
struct ServerSupportTests {
    let fm = FileManager.default

    @Test func latestSeqTracksTheLog() throws {
        let f = try Fixture()
        #expect(try f.store.latestSeq() == 0)
        let drop = try f.add(handoff: true)
        _ = try f.store.claim(drop.id, by: "b")
        #expect(try f.store.latestSeq() == 2)
        #expect(try f.store.events(afterSeq: 1).map(\.type) == [.status])
    }

    @Test func dropByExactFilename() throws {
        let f = try Fixture()
        let drop = try f.add("Plan.md")
        #expect(try f.store.drop(filename: "Plan.md")?.id == drop.id)
        #expect(try f.store.drop(filename: "plan.md") == nil)
        #expect(try f.store.drop(filename: drop.id) == nil)
    }

    @Test func checkPresenceEmitsMissingThenReturn() throws {
        let f = try Fixture()
        let drop = try f.add("a.md", "one")
        let url = f.store.path(of: drop)
        #expect(try f.store.checkPresence(drop.id).missing == false)
        #expect(try f.store.events().count == 1)

        try fm.removeItem(at: url)
        #expect(try f.store.checkPresence(drop.id).missing)
        try Data("back".utf8).write(to: url)
        #expect(try f.store.checkPresence(drop.id).missing == false)
        let events = try f.store.events()
        #expect(events.map(\.type) == [.created, .missing, .metadata])
        #expect(events.last?.data == #"{"missing":false}"#)
        expectError(2) { _ = try f.store.checkPresence("zzzzzz") }
    }

    @Test func recordContentChangeWritesOneContentEvent() throws {
        let f = try Fixture()
        let drop = try f.add(handoff: true)
        try f.store.recordContentChange(drop.id)
        let event = try #require(try f.store.events().last)
        #expect(event.type == .content)
        #expect(event.data == "{}")
        #expect(event.inboxBefore && event.inboxAfter)
        // Content events never change the drop row.
        #expect(try f.store.resolve(drop.id) == drop)
    }

    @Test func contentEventsRideRetentionCleanup() throws {
        let f = try Fixture(retention: .days(1))
        let drop = try f.add()
        f.clock.advance(days: 2)
        try f.store.recordContentChange(drop.id)
        #expect(try f.store.events().map(\.type) == [.content])
    }

    @Test func commitObserverFiresOncePerCommitThatWroteEvents() throws {
        let f = try Fixture()
        let count = Locked(0)
        f.store.observeEventCommits { count.withLock { $0 += 1 } }
        let drop = try f.add(handoff: true)
        _ = try f.store.claim(drop.id, by: "a")
        expectError(3) { _ = try f.store.claim(drop.id, by: "b") }  // rolled back: no event
        _ = try f.store.edit(drop.id, EditRequest())                // no change: no event
        #expect(count.value == 2)
    }

    @Test func noContentEventForMissingOrUnknownDrop() throws {
        let f = try Fixture()
        let drop = try f.add()
        try fm.removeItem(at: f.store.path(of: drop))
        _ = try f.store.checkPresence(drop.id)
        let before = try f.store.latestSeq()
        try f.store.recordContentChange(drop.id)
        #expect(try f.store.latestSeq() == before)
        expectError(2) { try f.store.recordContentChange("zzzzzz") }
    }
}

struct FolderProtectionTests {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test(arguments: ["Desktop", "Desktop/AgentDrop", "Documents/a/b", "Downloads/x",
                      "Library/Mobile Documents/com~apple~CloudDocs/AgentDrop"])
    func protectedLocations(_ relative: String) {
        #expect(FolderProtection.isProtected(home.appendingPathComponent(relative), homeDir: home))
    }

    @Test(arguments: ["AgentDrop", "DesktopStuff", "code/Desktop", "Library/Application Support/x"])
    func unprotectedLocations(_ relative: String) {
        #expect(!FolderProtection.isProtected(home.appendingPathComponent(relative), homeDir: home))
    }

    @Test(arguments: ["desktop/AgentDrop", "DESKTOP", "Documents/../Downloads/x", "./Desktop/y"])
    func spellingVariantsAreStillProtected(_ relative: String) {
        #expect(FolderProtection.isProtected(home.appendingPathComponent(relative), homeDir: home))
    }

    @Test func aSymlinkIntoAProtectedFolderIsProtected() throws {
        let tmp = try TempDir()
        let home = tmp.url.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("dt"),
                                                   withDestinationURL: home.appendingPathComponent("Desktop"))
        #expect(FolderProtection.isProtected(home.appendingPathComponent("dt/AgentDrop"), homeDir: home))
        #expect(!FolderProtection.isProtected(home.appendingPathComponent("AgentDrop"), homeDir: home))
    }

    @Test func tempFolderOnTheBootVolumeIsNotProtected() throws {
        let tmp = try TempDir()
        #expect(!FolderProtection.isProtected(tmp.url.appendingPathComponent("not/yet/created"),
                                              homeDir: home))
    }

    @Test func needsConfirmationUntilConfirmed() throws {
        let tmp = try TempDir()
        let config = ConfigStore(configDir: tmp.url.appendingPathComponent("support"),
                                 homeDir: tmp.url.appendingPathComponent("home"))
        #expect(!config.folderNeedsConfirmation(try config.load()))

        let desktop = config.homeDir.appendingPathComponent("Desktop/AgentDrop", isDirectory: true)
        try config.setFolder(desktop)
        #expect(config.folderNeedsConfirmation(try config.load()))
        try config.setConfirmedFolder(desktop)
        #expect(!config.folderNeedsConfirmation(try config.load()))
        try config.setFolder(config.homeDir.appendingPathComponent("Documents/Drops"))
        #expect(config.folderNeedsConfirmation(try config.load()))
    }

    @Test func setupCompleteRoundTripsAndKeepsOtherKeys() throws {
        let tmp = try TempDir()
        let config = ConfigStore(configDir: tmp.url.appendingPathComponent("support"),
                                 homeDir: tmp.url.appendingPathComponent("home"))
        try config.setRetention(.days(7))
        try config.setSetupComplete(true)
        let loaded = try config.load()
        #expect(loaded.setupComplete)
        #expect(loaded.eventRetentionDays == .days(7))
    }
}
