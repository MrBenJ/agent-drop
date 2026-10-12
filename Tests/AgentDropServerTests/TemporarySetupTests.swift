import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

struct TemporarySetupTests {
    func config() throws -> (ScratchDir, ConfigStore) {
        let dir = try ScratchDir()
        return (dir, ConfigStore(configDir: dir.url.appendingPathComponent("support"),
                                 homeDir: dir.url.appendingPathComponent("home")))
    }

    @Test func nothingToDoWhenAlreadySetUp() throws {
        let (_, config) = try config()
        try config.setSetupComplete(true)
        let before = try Data(contentsOf: config.configFile)
        let setup = try TemporarySetup.apply(to: config)
        #expect(!setup.changedAnything)
        setup.restore()
        #expect(try Data(contentsOf: config.configFile) == before)
    }

    @Test func setsAndRestoresSetupAndProtectedFolderConfirmation() throws {
        let (_, config) = try config()
        let desktop = config.homeDir.appendingPathComponent("Desktop/AgentDrop", isDirectory: true)
        try config.setFolder(desktop)
        try config.setRetention(.days(9))

        let setup = try TemporarySetup.apply(to: config)
        #expect(setup.changedAnything)
        var during = try config.load()
        #expect(during.setupComplete)
        #expect(!config.folderNeedsConfirmation(during))

        setup.restore()
        during = try config.load()
        #expect(!during.setupComplete)
        #expect(during.confirmedFolder == nil)
        #expect(config.folderNeedsConfirmation(during))
        #expect(during.eventRetentionDays == .days(9))
    }

    @Test func restoreLeavesNoTraceWhenThereWasNoConfig() throws {
        let (_, config) = try config()
        let setup = try TemporarySetup.apply(to: config)
        #expect(try config.load().setupComplete)
        setup.restore()
        #expect(!FileManager.default.fileExists(atPath: config.configFile.path))
    }

    @Test func restoreRemovesOnlyTheKeysItAddedAndKeepsLaterChanges() throws {
        let (_, config) = try config()
        try config.setRetention(.days(3))
        let setup = try TemporarySetup.apply(to: config)
        try config.setRetention(.forever)  // changed while the dev host ran
        setup.restore()
        let text = try String(contentsOf: config.configFile, encoding: .utf8)
        #expect(!text.contains("setupComplete"))
        #expect(try config.load().eventRetentionDays == .forever)
    }

    @Test func restoreKeepsAPreviouslyConfirmedOtherFolder() throws {
        let (_, config) = try config()
        let old = config.homeDir.appendingPathComponent("Documents/Old")
        try config.setConfirmedFolder(old)
        try config.setFolder(config.homeDir.appendingPathComponent("Desktop/New"))
        try config.setSetupComplete(true)
        let setup = try TemporarySetup.apply(to: config)
        setup.restore()
        #expect(try config.load().confirmedFolder == old.path)
    }
}
