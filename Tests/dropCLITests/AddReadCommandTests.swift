import Foundation
import Testing
@testable import DropCLI

struct AddReadCommandTests {
    @Test func addPrintsIdAndRequiresFrom() throws {
        let env = try TestEnv()
        try env.file("plan.md", "# Auth plan")
        let missingFrom = env.run("add", "plan.md")
        #expect(missingFrom.code == 1)
        let r = env.run("add", "plan.md", "--from", "djleague/build-feature-x", "--project", "dj",
                        "--tag", "spec", "-m", "Why it matters", "--handoff")
        #expect(r.code == 0)
        let id = r.trimmedOut
        #expect(id.count == 6)
        let shown = env.run("show", id, "--json").json
        #expect(shown["title"] as? String == "Auth plan")
        #expect(shown["from"] as? String == "djleague/build-feature-x")
        #expect(shown["status"] as? String == "open")
        #expect(shown["path"] as? String == env.dropFolder.appendingPathComponent("plan.md").path)
    }

    @Test func addFromStdinAndJson() throws {
        let env = try TestEnv()
        env.stdin = Data("# Notes\nbody".utf8)
        let r = env.run("add", "-", "--name", "notes.md", "--from", "a", "--json")
        #expect(r.code == 0)
        #expect(r.json["filename"] as? String == "notes.md")
        #expect(env.run("cat", "notes.md").out == "# Notes\nbody")
        env.stdin = Data()
        #expect(env.run("add", "-", "--name", "e.md", "--from", "a").code == 1)
    }

    @Test func addErrorCodes() throws {
        let env = try TestEnv()
        #expect(env.run("add", "nope.md", "--from", "a").code == 2)
        try env.file(".hidden", "x")
        #expect(env.run("add", ".hidden", "--from", "a").code == 1)
        #expect(env.run("add", ".hidden", "--from", "a", "--name", "visible.md").code == 0)
    }

    @Test func unicodeAndSpacesRoundTrip() throws {
        let env = try TestEnv()
        let name = "Q3 plan — draft ✅.md"
        try env.file(name, "# Q3 ✅\nCafé")
        let id = env.run("add", name, "--from", "a").trimmedOut
        #expect(env.run("cat", name).out == "# Q3 ✅\nCafé")
        #expect(env.run("path", id).trimmedOut == env.dropFolder.appendingPathComponent(name).path)
        #expect(env.run("show", name, "--json").json["title"] as? String == "Q3 ✅")
    }

    @Test func catWritesBinaryBytesUnchanged() throws {
        let env = try TestEnv()
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0xFE])
        bytes.append(contentsOf: (0..<256).map { UInt8($0) })
        try env.data("pixel.png", bytes)
        let id = env.run("add", "pixel.png", "--from", "a").trimmedOut
        #expect(env.run("cat", id).outData == bytes)
    }

    @Test func catRejectsJsonFoldersAndMissingFiles() throws {
        let env = try TestEnv()
        try env.file("p.md", "x")
        let id = env.run("add", "p.md", "--from", "a").trimmedOut
        let json = env.run("cat", id, "--json")
        #expect(json.code == 1 && json.json["code"] as? Int == 1)
        try env.file("bundle/README.md", "# B")
        let folderID = env.run("add", "bundle", "--from", "a").trimmedOut
        #expect(env.run("cat", folderID).code == 1)
        #expect(env.run("path", folderID).trimmedOut == env.dropFolder.appendingPathComponent("bundle").path)
        try FileManager.default.removeItem(at: env.dropFolder.appendingPathComponent("p.md"))
        #expect(env.run("cat", id).code == 2)
        #expect(env.run("show", id, "--json").json["missing"] as? Bool == true)
    }

    @Test func listFiltersAndJsonArray() throws {
        let env = try TestEnv()
        try env.file("a.md", "a"); try env.file("b.md", "b"); try env.file("c.md", "c")
        _ = env.run("add", "a.md", "--from", "djleague/autodev/AutoDev DJ-1 [ef013ae]", "--tag", "PR")
        _ = env.run("add", "b.md", "--from", "djleague2", "--tag", "pr")
        _ = env.run("add", "c.md", "--from", "djleague", "--handoff")
        #expect(env.run("list", "--json").jsonArray.count == 3)
        #expect(env.run("list", "--from-under", "djleague", "--json").jsonArray.count == 2)
        #expect(env.run("list", "--tag", "PR", "--json").jsonArray.count == 1)
        #expect(env.run("list", "--handoffs", "--json").jsonArray.count == 1)
        #expect(env.run("list", "--status", "claimed", "--json").jsonArray.isEmpty)
        #expect(env.run("list", "--status", "bogus").code == 1)
        #expect(env.run("list", "--limit", "0").code == 1)
        #expect(env.run("list").out.split(separator: "\n").count == 3)
    }

    @Test func latestAndCatFlag() throws {
        let env = try TestEnv()
        #expect(env.run("latest").code == 2)
        try env.file("one.md", "first"); try env.file("two.md", "second")
        _ = env.run("add", "one.md", "--from", "a")
        _ = env.run("add", "two.md", "--from", "a", "--project", "p")
        #expect(env.run("latest", "--json").json["filename"] as? String == "two.md")
        #expect(env.run("latest", "--cat").out == "second")
        #expect(env.run("latest", "--cat", "--json").code == 1)
        #expect(env.run("latest", "--project", "nope").code == 2)
    }

    @Test func inboxListsOpenHandoffs() throws {
        let env = try TestEnv()
        try env.file("h1.md", "1"); try env.file("h2.md", "2"); try env.file("n.md", "n")
        _ = env.run("add", "h1.md", "--from", "a", "--project", "p", "--handoff")
        _ = env.run("add", "h2.md", "--from", "a", "--project", "q", "--handoff")
        _ = env.run("add", "n.md", "--from", "a", "--project", "p")
        #expect(env.run("inbox", "--json").jsonArray.count == 2)
        #expect(env.run("inbox", "--project", "p", "--json").jsonArray.count == 1)
        #expect(env.run("inbox", "--project", "none").out.isEmpty)
    }
}
