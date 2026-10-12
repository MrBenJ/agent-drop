import Foundation
import Testing
@testable import AgentDropCore

struct ConfigTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdrop-config-\(UUID().uuidString)", isDirectory: true)
    var store: ConfigStore {
        ConfigStore(configDir: root.appendingPathComponent("support", isDirectory: true),
                    homeDir: root.appendingPathComponent("home", isDirectory: true))
    }

    @Test func defaultsWhenFileAbsent() throws {
        let c = try store.load()
        #expect(c.folder == nil)
        #expect(c.eventRetentionDays == .days(30))
        #expect(!c.retentionWasInvalid)
        #expect(!c.setupComplete)
        #expect(store.folderURL(c).path == root.appendingPathComponent("home/AgentDrop").path)
    }

    @Test func setFolderAndRetentionRoundTrip() throws {
        let target = root.appendingPathComponent("Desk top/Agent Drop", isDirectory: true)
        try store.setFolder(target)
        try store.setRetention(.forever)
        let c = try store.load()
        #expect(store.folderURL(c).path == target.path)
        #expect(c.eventRetentionDays == .forever)
        try store.setRetention(.days(14))
        #expect(try store.load().eventRetentionDays == .days(14))
    }

    @Test func preservesUnknownKeysWrittenByTheApp() throws {
        try FileManager.default.createDirectory(at: store.configDir, withIntermediateDirectories: true)
        try Data(#"{"setupComplete": true, "futureKey": "keep me"}"#.utf8).write(to: store.configFile)
        try store.setRetention(.days(7))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.configFile)) as! [String: Any]
        #expect(raw["futureKey"] as? String == "keep me")
        #expect(raw["setupComplete"] as? Bool == true)
        #expect(try store.load().setupComplete)
    }

    @Test(arguments: [#"0"#, #"-3"#, #"14.5"#, #""weekly""#, #"null"#])
    func invalidRetentionFallsBackTo30(_ raw: String) throws {
        try FileManager.default.createDirectory(at: store.configDir, withIntermediateDirectories: true)
        try Data(#"{"eventRetentionDays": \#(raw)}"#.utf8).write(to: store.configFile)
        let c = try store.load()
        #expect(c.eventRetentionDays == .days(30))
        #expect(c.retentionWasInvalid)
    }

    @Test func corruptConfigIsAnError() throws {
        try FileManager.default.createDirectory(at: store.configDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.configFile)
        expectError(1) { _ = try store.load() }
    }

    @Test func retentionArgumentParsing() {
        #expect(Retention(argument: "forever") == .forever)
        #expect(Retention(argument: "1") == .days(1))
        #expect(Retention(argument: "0") == nil)
        #expect(Retention(argument: "-1") == nil)
        #expect(Retention(argument: "7.5") == nil)
        #expect(Retention(argument: "week") == nil)
    }
}
