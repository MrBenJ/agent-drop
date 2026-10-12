import Foundation
import Testing
@testable import DropCLI

struct HandoffCommandTests {
    @Test func codeFailureCapturesDiagnosticsInJsonError() throws {
        let env = try TestEnv()
        let fake = try env.file("fake-code", "#!/bin/sh\necho child-output\necho child-error >&2\nexit 5\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        env.codeExecutable = fake
        env.useRealProcess = true
        try env.file("p.md", "content")
        let id = env.run("add", "p.md", "--from", "a").trimmedOut
        let result = env.run("code", id, "--json")
        #expect(result.code == 1 && result.err.isEmpty)
        let message = result.json["error"] as? String ?? ""
        #expect(message.contains("child-output") && message.contains("child-error"))
        #expect(message.contains("5"))
    }

    func handoff(_ env: TestEnv, project: String = "p") throws -> String {
        env.stdin = Data("# Do the thing".utf8)
        return env.run("add", "-", "--name", "task-\(UUID().uuidString.prefix(4)).md", "--from", "agent-a",
                       "--project", project, "--handoff").trimmedOut
    }

    @Test func endToEndHandoffLifecycle() throws {
        let env = try TestEnv()
        let id = try handoff(env)
        #expect(env.run("inbox", "--project", "p", "--json").jsonArray.first?["id"] as? String == id)

        let claim = env.run("claim", id, "--by", "djleague/build-feature-x", "--json")
        #expect(claim.code == 0 && claim.json["claimedBy"] as? String == "djleague/build-feature-x")
        #expect(env.run("inbox", "--json").jsonArray.isEmpty)

        let second = env.run("claim", id, "--by", "other")
        #expect(second.code == 3)
        #expect(second.err.contains("\(id) is claimed by djleague/build-feature-x"))

        let done = env.run("done", id, "--note", "shipped in PR #42", "--json")
        #expect(done.json["status"] as? String == "done" && done.json["statusNote"] as? String == "shipped in PR #42")
        #expect(env.run("release", id).code == 3)

        #expect(env.run("reopen", id).code == 0)
        #expect(env.run("inbox", "--json").jsonArray.count == 1)
        #expect(env.run("claim", id, "--by", "b").code == 0)
        #expect(env.run("release", id, "--json").json["status"] as? String == "open")
    }

    @Test func claimRequiresBy() throws {
        let env = try TestEnv()
        let id = try handoff(env)
        #expect(env.run("claim", id).code == 1)
    }

    @Test func transitionsOnNotesExitOne() throws {
        let env = try TestEnv()
        try env.file("n.md", "n")
        let id = env.run("add", "n.md", "--from", "a").trimmedOut
        #expect(env.run("claim", id, "--by", "x").code == 1)
        #expect(env.run("claim", "zzzzzz", "--by", "x").code == 2)
    }

    @Test func editAndKindChanges() throws {
        let env = try TestEnv()
        try env.file("n.md", "n")
        let id = env.run("add", "n.md", "--from", "a", "--tag", "x").trimmedOut
        let edited = env.run("edit", id, "--title", "New", "--tag", "y", "--untag", "x", "--kind", "handoff", "--json")
        #expect(edited.code == 0)
        #expect(edited.json["title"] as? String == "New")
        #expect(edited.json["tags"] as? [String] == ["y"])
        #expect(edited.json["status"] as? String == "open")
        _ = env.run("claim", id, "--by", "a")
        let blocked = env.run("edit", id, "--kind", "note")
        #expect(blocked.code == 3 && blocked.err.contains("release it first"))
        #expect(env.run("edit", id, "--kind", "bogus").code == 1)
    }

    @Test func archiveAndUndo() throws {
        let env = try TestEnv()
        let id = try handoff(env)
        #expect(env.run("archive", id, "--json").json["archived"] as? Bool == true)
        #expect(env.run("list", "--json").jsonArray.isEmpty)
        #expect(env.run("inbox", "--json").jsonArray.isEmpty)
        #expect(env.run("archive", "--undo", id).code == 0)
        #expect(env.run("inbox", "--json").jsonArray.count == 1)
    }

    @Test func codeRunsVSCodeOrExplains() throws {
        let env = try TestEnv()
        try env.file("c.md", "c")
        let id = env.run("add", "c.md", "--from", "a").trimmedOut
        let missing = env.run("code", id)
        #expect(missing.code == 1 && missing.err.contains("code"))
        env.codeExecutable = URL(fileURLWithPath: "/usr/local/bin/code")
        #expect(env.run("code", id).code == 0)
        #expect(env.processCalls.first?.1 == [env.dropFolder.appendingPathComponent("c.md").path])
    }

    @Test func agentInstructionsMentionTheEssentials() throws {
        let env = try TestEnv()
        let r = env.run("agent-instructions")
        #expect(r.code == 0)
        for needle in ["drop add", "--from", "drop inbox", "drop claim", "--by", "drop done", "quote",
                       "store busy", "drop latest --cat"] {
            #expect(r.out.contains(needle), "missing \(needle)")
        }
        #expect(env.run("agent-instructions", "--json").json["instructions"] is String)
    }
}
