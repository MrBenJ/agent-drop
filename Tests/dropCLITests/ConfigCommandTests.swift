import Foundation
import Testing
@testable import DropCLI

struct ConfigCommandTests {
    @Test func whereDefaultsToHomeAgentDrop() throws {
        let env = try TestEnv()
        let r = env.run("where")
        #expect(r.code == 0)
        #expect(r.trimmedOut == env.dropFolder.path)
        #expect(env.run("where", "--json").json["folder"] as? String == env.dropFolder.path)
    }

    @Test func setFolderResolvesRelativeTildeAndSpaces() throws {
        let env = try TestEnv()
        #expect(env.run("config", "set-folder", "Agent Drop Folder").code == 0)
        let expected = env.cwd.appendingPathComponent("Agent Drop Folder").path
        #expect(env.run("where").trimmedOut == expected)
        #expect(FileManager.default.fileExists(atPath: expected))

        #expect(env.run("config", "set-folder", "~/Desk top/drops").code == 0)
        #expect(env.run("where").trimmedOut == env.home.appendingPathComponent("Desk top/drops").path)
    }

    @Test func setFolderRejectsAFile() throws {
        let env = try TestEnv()
        try env.file("not-a-dir", "x")
        let r = env.run("config", "set-folder", "not-a-dir")
        #expect(r.code == 1)
        #expect(r.err.hasPrefix("drop: "))
    }

    @Test func setRetentionValidates() throws {
        let env = try TestEnv()
        #expect(env.run("config", "set-retention", "14").code == 0)
        #expect(env.run("config", "show", "--json").json["eventRetentionDays"] as? Int == 14)
        #expect(env.run("config", "set-retention", "forever").code == 0)
        #expect(env.run("config", "show", "--json").json["eventRetentionDays"] as? String == "forever")
        for bad in ["0", "-1", "7.5", "weekly"] {
            #expect(env.run("config", "set-retention", bad).code == 1)
        }
    }

    @Test func showListsEverySettingAndDisclosesCleanup() throws {
        let env = try TestEnv()
        let r = env.run("config", "show")
        #expect(r.code == 0)
        for key in ["folder:", "eventRetentionDays:", "serverPort:", "setupComplete:", "confirmedFolder:"] {
            #expect(r.out.contains(key))
        }
        #expect(r.out.contains("Your drops and files are never deleted."))
        let json = env.run("config", "show", "--json").json
        #expect(json["serverPort"] as? Int == 47390)
        #expect(json["setupComplete"] as? Bool == false)
        #expect(json["confirmedFolder"] is NSNull)
        #expect((json["warnings"] as? [String])?.isEmpty == true)
    }

    @Test func showWarnsAboutInvalidRetention() throws {
        let env = try TestEnv()
        try FileManager.default.createDirectory(at: env.config.configDir, withIntermediateDirectories: true)
        try Data(#"{"eventRetentionDays": 0}"#.utf8).write(to: env.config.configFile)
        let r = env.run("config", "show")
        #expect(r.code == 0)
        #expect(r.err.contains("invalid"))
        #expect((env.run("config", "show", "--json").json["warnings"] as? [String])?.count == 1)
    }

    @Test func usageErrorsExitOneAndJsonErrorsGoToStdout() throws {
        let env = try TestEnv()
        let human = env.run("config", "set-retention")
        #expect(human.code == 1 && human.out.isEmpty && !human.err.isEmpty)
        let json = env.run("config", "set-retention", "0", "--json")
        #expect(json.code == 1 && json.err.isEmpty)
        #expect(json.json["code"] as? Int == 1)
        #expect(json.json["error"] is String)
    }

    @Test func helpExitsZero() throws {
        let env = try TestEnv()
        let r = env.run("--help")
        #expect(r.code == 0)
        #expect(r.out.contains("USAGE"))
    }
}
