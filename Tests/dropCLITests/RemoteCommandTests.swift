import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer
@testable import DropCLI

/// A `TailnetServer` on 127.0.0.1 over its own scratch store (never the TestEnv's drop folder).
private final class Receiver: @unchecked Sendable {
    let folder: URL
    let store: DropStore
    let server: TailnetServer
    let key = ServerInfo.newToken()
    var url: String { "http://127.0.0.1:\(server.port)" }

    init() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropcli-receiver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try DropStore.open(folder: folder, retention: .default)
        let key = self.key
        let base = Int.random(in: 20_000...59_000)
        var started: TailnetServer?
        for port in base..<(base + 10) {
            do {
                started = try await TailnetServer.start(
                    store: store, bindHost: "127.0.0.1", port: port,
                    identity: TailnetIdentity(address: "127.0.0.1", dnsName: nil),
                    limits: .init(maxBytes: 1 << 20), key: { key }, peerAllowed: { $0 == "127.0.0.1" },
                    freeBytes: { _ in nil })
                break
            } catch is TailnetServer.PortInUse {
                continue
            }
        }
        guard let started else { throw TailnetServer.PortInUse(port: base) }
        server = started
    }

    func stop() async {
        await server.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func drops() throws -> [Drop] { try store.list(ListFilter()) }
}

private let sampleKey = String(repeating: "ab", count: 32)

struct RemoteCommandTests {
    @Test func addListRemoveRoundTrip() throws {
        let env = try TestEnv()
        let add = env.run("remote", "add", "laptop", "--url", "http://100.64.0.2:47400", "--key", sampleKey)
        #expect(add.code == 0)
        #expect(add.trimmedOut == "Saved remote 'laptop'")
        #expect(env.run("remote", "add", "desk", "--url", "https://desk.tail.ts.net:47400", "--key", sampleKey).code == 0)

        let file = env.config.configDir.appendingPathComponent("remotes.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let remotes = saved?["remotes"] as? [String: [String: String]]
        #expect(remotes?["laptop"] == ["url": "http://100.64.0.2:47400", "key": sampleKey])

        let list = env.run("remote", "list")
        #expect(list.code == 0)
        #expect(list.out == "desk\thttps://desk.tail.ts.net:47400\nlaptop\thttp://100.64.0.2:47400\n")
        #expect(!list.out.contains(sampleKey))

        let json = env.run("remote", "list", "--json")
        #expect(json.code == 0)
        #expect(!json.out.contains(sampleKey))
        #expect(json.jsonArray.count == 2)
        #expect(json.jsonArray.allSatisfy { Set($0.keys) == ["name", "url"] })
        #expect(json.jsonArray.first?["name"] as? String == "desk")

        // Overwrites.
        #expect(env.run("remote", "add", "laptop", "--url", "http://100.64.0.3:47400", "--key", sampleKey).code == 0)
        #expect(env.run("remote", "list").out.contains("laptop\thttp://100.64.0.3:47400"))

        #expect(env.run("remote", "remove", "laptop").code == 0)
        #expect(env.run("remote", "list").out == "desk\thttps://desk.tail.ts.net:47400\n")
    }

    @Test(arguments: [
        ["env", "http://100.64.0.2:47400", String(repeating: "ab", count: 32)],
        ["bad name", "http://100.64.0.2:47400", String(repeating: "ab", count: 32)],
        ["", "http://100.64.0.2:47400", String(repeating: "ab", count: 32)],
        [String(repeating: "a", count: 65), "http://100.64.0.2:47400", String(repeating: "ab", count: 32)],
        ["laptop", "http://100.64.0.2", String(repeating: "ab", count: 32)],
        ["laptop", "ftp://100.64.0.2:47400", String(repeating: "ab", count: 32)],
        ["laptop", "http://:47400", String(repeating: "ab", count: 32)],
        ["laptop", "http://100.64.0.2:47400", String(repeating: "a", count: 63)],
        ["laptop", "http://100.64.0.2:47400", String(repeating: "z", count: 64)],
    ])
    func remoteAddValidates(_ args: [String]) throws {
        let env = try TestEnv()
        let r = env.run("remote", "add", args[0], "--url", args[1], "--key", args[2])
        #expect(r.code == 1)
        #expect(r.err.hasPrefix("drop: "))
        #expect(!FileManager.default.fileExists(atPath: env.config.configDir.appendingPathComponent("remotes.json").path))
    }

    @Test func remoteAddReadsKeyFromStdin() throws {
        let env = try TestEnv()
        env.stdin = Data((sampleKey + "\n").utf8)
        #expect(env.run("remote", "add", "laptop", "--url", "http://100.64.0.2:47400", "--key", "-").code == 0)
        let saved = try RemotesFile(configDir: env.config.configDir).load()
        #expect(saved["laptop"]?.key == sampleKey)

        env.stdin = Data()
        let empty = env.run("remote", "add", "desk", "--url", "http://100.64.0.2:47400", "--key", "-")
        #expect(empty.code == 1)
        #expect(try RemotesFile(configDir: env.config.configDir).load()["desk"] == nil)
    }

    @Test func remoteResponseIsSanitized() throws {
        let body = Data(#"{"id":"ab\u001b[31mcd","from":"aria","isFolder":false,"title":"x/y"}"#.utf8)
        let plain = try Add.formatRemoteResponse(body, json: false, remoteName: "laptop")
        #expect(!plain.contains("\u{1B}"))
        #expect(plain == "ab\u{FFFD}[31mcd")

        let json = try Add.formatRemoteResponse(body, json: true, remoteName: "laptop")
        #expect(!json.contains("\u{1B}"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "ab\u{1B}[31mcd")
        #expect(object["from"] as? String == "aria")
        #expect(object["isFolder"] as? Bool == false)
        #expect(object["title"] as? String == "x/y")

        for bad in [#"["id"]"#, #"{"from":"aria"}"#, #"{"id":42}"#, "not json", ""] {
            #expect(throws: AgentDropError.invalid("'laptop' sent an unexpected response")) {
                try Add.formatRemoteResponse(Data(bad.utf8), json: false, remoteName: "laptop")
            }
            #expect(throws: AgentDropError.invalid("'laptop' sent an unexpected response")) {
                try Add.formatRemoteResponse(Data(bad.utf8), json: true, remoteName: "laptop")
            }
        }
    }

    @Test func removeMissingIsExit2() throws {
        let env = try TestEnv()
        #expect(env.run("remote", "remove", "laptop").code == 2)
        #expect(env.run("remote", "list").out == "")
        #expect(env.run("remote", "list", "--json").trimmedOut == "[]")
    }

    @Test func addToSendsWithoutLocalSetup() async throws {
        let receiver = try await Receiver()
        defer { Task { await receiver.stop() } }
        let env = try TestEnv()
        try env.file("plan.md", "# Plan\n")
        #expect(env.run("remote", "add", "laptop", "--url", receiver.url, "--key", receiver.key).code == 0)
        #expect(!FileManager.default.fileExists(atPath: env.config.configDir.appendingPathComponent("config.json").path))

        let r = await env.runAsync(["add", "plan.md", "--to", "laptop", "--from", "aria", "-m", "Why", "--json"])
        #expect(r.code == 0, "\(r.err)\(r.out)")
        #expect(r.json["from"] as? String == "aria")
        #expect(r.json["description"] as? String == "Why")
        let drop = try #require(try receiver.drops().first)
        #expect(drop.id == r.json["id"] as? String)
        #expect(drop.filename == "plan.md")
        #expect(!FileManager.default.fileExists(atPath: env.dropFolder.path))
        #expect(!FileManager.default.fileExists(atPath: env.config.configDir.appendingPathComponent("config.json").path))
        #expect(FileManager.default.fileExists(atPath: env.cwd.appendingPathComponent("plan.md").path))

        // Without --json: just the id.
        let plain = await env.runAsync(["add", "plan.md", "--to", "laptop", "--from", "aria", "--name", "plan-2.md"])
        #expect(plain.code == 0)
        #expect(try receiver.drops().contains { $0.id == plain.trimmedOut && $0.filename == "plan-2.md" })
    }

    @Test func addToFolderAndStdin() async throws {
        let receiver = try await Receiver()
        defer { Task { await receiver.stop() } }
        let env = try TestEnv()
        try env.file("bundle/a.md", "# A\n")
        try env.file("bundle/sub/b.txt", "bee")
        #expect(env.run("remote", "add", "laptop", "--url", receiver.url, "--key", receiver.key).code == 0)

        let folder = await env.runAsync(["add", "bundle/", "--to", "laptop", "--from", "aria", "--json"])
        #expect(folder.code == 0, "\(folder.err)\(folder.out)")
        #expect(folder.json["isFolder"] as? Bool == true)
        #expect(folder.json["filename"] as? String == "bundle")
        let stored = try #require(try receiver.drops().first { $0.isFolder })
        #expect(try Data(contentsOf: receiver.store.path(of: stored).appendingPathComponent("sub/b.txt")) == Data("bee".utf8))

        env.stdin = Data("hello".utf8)
        let piped = await env.runAsync(["add", "-", "--name", "note.txt", "--to", "laptop", "--from", "aria"])
        #expect(piped.code == 0, "\(piped.err)")
        let note = try #require(try receiver.drops().first { $0.filename == "note.txt" })
        #expect(note.id == piped.trimmedOut)
        #expect(try Data(contentsOf: receiver.store.path(of: note)) == Data("hello".utf8))

        let noName = await env.runAsync(["add", "-", "--to", "laptop", "--from", "aria"])
        #expect(noName.code == 1)
        env.stdin = Data()
        let empty = await env.runAsync(["add", "-", "--name", "empty.txt", "--to", "laptop", "--from", "aria"])
        #expect(empty.code == 1)
        #expect(empty.err.contains("stdin was empty"))
    }

    @Test func addToRejectsSymlinksAndMissingPaths() async throws {
        let env = try TestEnv()
        try env.file("real.md", "x")
        try FileManager.default.createSymbolicLink(at: env.cwd.appendingPathComponent("link.md"),
                                                   withDestinationURL: env.cwd.appendingPathComponent("real.md"))
        #expect(env.run("remote", "add", "laptop", "--url", "http://127.0.0.1:1", "--key", sampleKey).code == 0)
        let link = await env.runAsync(["add", "link.md", "--to", "laptop", "--from", "aria"])
        #expect(link.code == 1)
        #expect(link.err.contains("symlink"))
        #expect(await env.runAsync(["add", "nope.md", "--to", "laptop", "--from", "aria"]).code == 2)
    }

    @Test func addToWithMoveIsRejected() async throws {
        let env = try TestEnv()
        let source = try env.file("plan.md", "# Plan\n")
        #expect(env.run("remote", "add", "laptop", "--url", "http://127.0.0.1:1", "--key", sampleKey).code == 0)
        let r = await env.runAsync(["add", "plan.md", "--to", "laptop", "--from", "aria", "--move"])
        #expect(r.code == 1)
        #expect(r.err == "drop: --move can't be used with --to; nothing is deleted on this Mac\n")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func addToUnknownRemoteIsExit2() async throws {
        let env = try TestEnv()
        try env.file("plan.md", "x")
        let r = await env.runAsync(["add", "plan.md", "--to", "laptop", "--from", "aria"])
        #expect(r.code == 2)
        #expect(r.err.contains("No remote named 'laptop'. Add it with `drop remote add laptop --url … --key …`"))
        let json = await env.runAsync(["add", "plan.md", "--to", "laptop", "--from", "aria", "--json"])
        #expect(json.code == 2)
        #expect(json.json["code"] as? Int == 2)
        #expect((json.json["error"] as? String)?.hasPrefix("No remote named 'laptop'") == true)
    }

    @Test func addToEnvRemote() async throws {
        let receiver = try await Receiver()
        defer { Task { await receiver.stop() } }
        let env = try TestEnv()
        try env.file("plan.md", "# Plan\n")

        let unset = await env.runAsync(["add", "plan.md", "--to", "env", "--from", "aria"])
        #expect(unset.code == 1)
        #expect(unset.err == "drop: --to env needs AGENT_DROP_REMOTE_URL and AGENT_DROP_REMOTE_KEY\n")

        env.environment = ["AGENT_DROP_REMOTE_URL": receiver.url, "AGENT_DROP_REMOTE_KEY": receiver.key]
        let r = await env.runAsync(["add", "plan.md", "--to", "env", "--from", "aria"])
        #expect(r.code == 0, "\(r.err)")
        #expect(try receiver.drops().first?.id == r.trimmedOut)
    }

    @Test func syncRunOfAddToIsRejected() throws {
        let env = try TestEnv()
        try env.file("plan.md", "x")
        #expect(env.run("remote", "add", "laptop", "--url", "http://127.0.0.1:1", "--key", sampleKey).code == 0)
        let r = env.run("add", "plan.md", "--from", "aria", "--to", "laptop")
        #expect(r.code == 1)
        #expect(r.err.contains("--to needs DropCLI.runAsync"))
        #expect(!FileManager.default.fileExists(atPath: env.dropFolder.path))
    }

    @Test func remoteTestReportsReachable() async throws {
        let receiver = try await Receiver()
        defer { Task { await receiver.stop() } }
        let env = try TestEnv()
        #expect(env.run("remote", "add", "laptop", "--url", receiver.url, "--key", receiver.key).code == 0)
        let r = await env.runAsync(["remote", "test", "laptop"])
        #expect(r.code == 0, "\(r.err)")
        #expect(r.trimmedOut == "'laptop' is reachable and accepted the key.")
        #expect(await env.runAsync(["remote", "test", "desk"]).code == 2)
    }

    @Test func remoteTestReportsBadKey() async throws {
        let receiver = try await Receiver()
        defer { Task { await receiver.stop() } }
        let env = try TestEnv()
        #expect(env.run("remote", "add", "laptop", "--url", receiver.url, "--key", sampleKey).code == 0)
        let r = await env.runAsync(["remote", "test", "laptop"])
        #expect(r.code == 1)
        #expect(r.err.contains("The key for 'laptop' was rejected"))
        let json = await env.runAsync(["remote", "test", "laptop", "--json"])
        #expect(json.code == 1)
        #expect(json.json["code"] as? Int == 1)
        #expect((json.json["error"] as? String)?.contains("was rejected") == true)
    }

    @Test func agentInstructionsMentionsTo() throws {
        let env = try TestEnv()
        let r = env.run("agent-instructions")
        #expect(r.code == 0)
        #expect(r.out.contains("--to <remote>"))
        #expect(r.out.contains("drop remote list"))
    }
}
