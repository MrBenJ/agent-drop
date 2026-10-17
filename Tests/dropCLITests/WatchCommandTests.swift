import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer
@testable import DropCLI

/// `drop watch` end-to-end against an in-process AgentDropService (spec §8).
struct WatchCommandTests {
    func ready(_ env: TestEnv) throws {
        try env.config.setSetupComplete(true)
    }

    func service(_ env: TestEnv) -> AgentDropService {
        var options = AgentDropService.Options()
        options.portBase = Int.random(in: 20_000...59_000)
        options.debounce = .milliseconds(50)
        return AgentDropService(config: env.config, options: options)
    }

    /// 20 s: most waits here hang on FSEvents, which can lag several seconds under the
    /// full parallel suite. The polling still returns as soon as the condition holds.
    func waitFor(_ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    func handoff(_ env: TestEnv, _ name: String = "task.md", project: String = "p") -> String {
        env.stdin = Data("# Do the thing".utf8)
        return env.run("add", "-", "--name", name, "--from", "agent-a", "--project", project, "--handoff").trimmedOut
    }

    // MARK: - Gates and arguments

    @Test func beforeSetupExits1WithTheSpecMessage() async throws {
        let env = try TestEnv()
        let r = await env.runAsync(["watch", "--inbox"])
        #expect(r.code == 1)
        #expect(r.err == "drop: \(ServiceMessages.setupIncomplete)\n")
    }

    @Test func unconfirmedProtectedFolderExits1() async throws {
        let env = try TestEnv()
        try ready(env)
        try env.config.setFolder(env.home.appendingPathComponent("Desktop/AgentDrop"))
        let r = await env.runAsync(["watch", "--inbox", "--json"])
        #expect(r.code == 1)
        #expect(r.json["error"] as? String == ServiceMessages.confirmFolder)
    }

    @Test(arguments: [["watch"], ["watch", "abcdef", "--inbox"], ["watch", "abcdef", "--project", "p"]])
    func needsExactlyOneTarget(_ arguments: [String]) async throws {
        let env = try TestEnv()
        try ready(env)
        #expect(await env.runAsync(arguments).code == 1)
    }

    @Test func syncRunnerRefusesWatch() throws {
        let env = try TestEnv()
        #expect(env.run("watch", "--inbox").code == 1)
    }

    // MARK: - Finding the app

    @Test func noPortExits1WithoutLaunching() async throws {
        let env = try TestEnv()
        try ready(env)
        try ServerInfoFile(configDir: env.config.configDir).write(.noPort(pid: getpid()))
        let launches = Locked(0)
        env.launchApp = { launches.withLock { $0 += 1 } }
        let r = await env.runAsync(["watch", "--inbox"])
        #expect(r.code == 1)
        #expect(r.err.contains("no port was free"))
        #expect(launches.value == 0)
    }

    @Test func launchesTheAppWhenServerInfoIsMissingOrStale() async throws {
        for stale in [false, true] {
            let env = try TestEnv()
            try ready(env)
            if stale { try ServerInfoFile(configDir: env.config.configDir).write(.running(port: 1, token: "x", pid: Int32.max)) }
            let service = service(env)
            let launches = Locked(0)
            env.launchApp = {
                launches.withLock { $0 += 1 }
                Task { try await service.start() }
            }
            let out = OutputSink()
            let watch = Task { await env.runAsync(["watch", "--inbox", "--once", "--json"], out: out) }
            #expect(await waitFor { await service.clientCount == 1 }, "stale: \(stale)")
            let id = handoff(env)
            let r = await watch.value
            #expect(r.code == 0)
            #expect(launches.value == 1)
            #expect(r.json["dropId"] as? String == id)
            #expect(r.json["type"] as? String == "created")
            await service.stop()
        }
    }

    @Test func launchFailureOrSilenceExits1() async throws {
        let env = try TestEnv()
        try ready(env)
        env.launchApp = { throw AgentDropError.invalid("Couldn't launch Agent Drop. Is AgentDrop.app installed?") }
        let failed = await env.runAsync(["watch", "--inbox"])
        #expect(failed.code == 1)
        #expect(failed.err.contains("Is AgentDrop.app installed?"))

        env.launchApp = {}
        env.serverWait = .milliseconds(300)
        let silent = await env.runAsync(["watch", "--inbox"])
        #expect(silent.code == 1)
        #expect(silent.err.contains("didn't start its server"))
    }

    // MARK: - Watching

    @Test func unknownIdExits2() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        defer { Task { await service.stop() } }
        let r = await env.runAsync(["watch", "zzzzzz", "--json"])
        #expect(r.code == 2)
        #expect(r.json["code"] as? Int == 2)
    }

    @Test func watchOneDropByFilenamePrintsHumanLinesAndEndsOnMissing() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        defer { Task { await service.stop() } }
        let id = handoff(env, "my task.md")
        let out = OutputSink()
        let watch = Task { await env.runAsync(["watch", "my task.md"], out: out) }
        #expect(await waitFor { await service.clientCount == 1 })

        #expect(env.run("claim", id, "--by", "djleague/autodev/AutoDev DJ-1 [ef0]").code == 0)
        #expect(await waitFor { out.text.contains("open → claimed by djleague/autodev/AutoDev DJ-1 [ef0]") })
        try FileManager.default.removeItem(at: env.dropFolder.appendingPathComponent("my task.md"))

        let r = await watch.value
        #expect(r.code == 0)
        let lines = r.out.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        #expect(lines.map { $0[1] } == ["status", "missing"])
        #expect(lines.allSatisfy { $0[2] == id && $0.count == 4 })
        #expect(lines.last?[3] == "file is missing")
    }

    @Test func inboxWatchDeliversArrivalsOnlyForItsProject() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        defer { Task { await service.stop() } }
        let out = OutputSink()
        let watch = Task { await env.runAsync(["watch", "--inbox", "--project", "p", "--json"], out: out) }
        #expect(await waitFor { await service.clientCount == 1 })

        let other = handoff(env, "other.md", project: "q")
        let mine = handoff(env, "mine.md", project: "p")
        _ = env.run("claim", mine, "--by", "x")     // departure: not delivered
        _ = env.run("release", mine)                 // arrival again
        #expect(await waitFor { out.text.split(separator: "\n").count == 2 })
        watch.cancel()
        _ = await watch.value

        // Cancelling the command makes it print one error object; keep only events.
        let lines = out.text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["type"] != nil }
        #expect(lines.map { $0["type"] as? String } == ["created", "status"])
        #expect(lines.allSatisfy { $0["dropId"] as? String == mine })
        #expect(!out.text.contains(other))
    }

    /// Spec §5.3: a folder switch restarts the server; `--inbox` prints `reset` and goes on
    /// with the new folder, a watch on one drop exits 2.
    @Test func folderSwitchResetsInboxWatchesAndEndsDropWatches() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        let id = handoff(env, "old.md")
        let inboxOut = OutputSink()
        let inbox = Task { await env.runAsync(["watch", "--inbox", "--json"], out: inboxOut) }
        let dropWatch = Task { await env.runAsync(["watch", id, "--json"]) }
        #expect(await waitFor { await service.clientCount == 2 })

        await service.stop()
        #expect(env.run("config", "set-folder", env.root.appendingPathComponent("Second").path).code == 0)
        try await service.start()

        let ended = await dropWatch.value
        #expect(ended.code == 2)
        #expect(ended.json["error"] as? String == "drop folder changed; \(id) is not in the current folder")

        #expect(await waitFor { inboxOut.text.contains(#""type":"reset""#) })
        #expect(await waitFor { await service.clientCount == 1 })
        let fresh = handoff(env, "new.md")
        #expect(await waitFor { inboxOut.text.contains(fresh) })
        inbox.cancel()
        _ = await inbox.value
        let types = inboxOut.text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["type"] as? String
        }
        #expect(types == ["reset", "created"])
        await service.stop()
    }

    @Test func appQuittingEndsTheWatchWithExit1() async throws {
        let env = try TestEnv()
        try ready(env)
        env.serverWait = .milliseconds(500)
        let service = service(env)
        try await service.start()
        let watch = Task { await env.runAsync(["watch", "--inbox"]) }
        #expect(await waitFor { await service.clientCount == 1 })
        await service.stop()
        let r = await watch.value
        #expect(r.code == 1)
        #expect(r.err.contains("Lost the connection to Agent Drop"))
    }

    /// Review M3: the drop was deleted and its record removed while the server was down.
    /// Same folder, so the watch replays `missing` and ends with exit 0, not "folder changed".
    @Test func dropRemovedWhileDisconnectedReplaysAndExits0() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        let id = handoff(env, "gone.md")
        let out = OutputSink()
        let watch = Task { await env.runAsync(["watch", id, "--json"], out: out) }
        #expect(await waitFor { await service.clientCount == 1 })
        await service.stop()

        let store = try DropStore.open(folder: env.dropFolder, retention: .default)
        try FileManager.default.removeItem(at: env.dropFolder.appendingPathComponent("gone.md"))
        _ = try store.checkPresence(id)
        try store.removeRecord(id)
        try await service.start()

        let r = await watch.value
        #expect(r.code == 0)
        let types = r.out.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["type"] as? String
        }
        #expect(types == ["missing"])
        await service.stop()
    }

    @Test func eventsWhileReconnectingAreReplayed() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        let id = handoff(env)
        let out = OutputSink()
        let watch = Task { await env.runAsync(["watch", id, "--json"], out: out) }
        #expect(await waitFor { await service.clientCount == 1 })
        _ = env.run("claim", id, "--by", "a")
        #expect(await waitFor { out.text.contains(#""to":"claimed""#) })

        await service.stop()
        _ = env.run("release", id)           // written while no server runs
        try await service.start()
        #expect(await waitFor { out.text.contains(#""to":"open""#) })
        _ = env.run("archive", id)
        #expect(await waitFor { out.text.contains(#""type":"archived""#) })
        watch.cancel()
        _ = await watch.value
        await service.stop()
    }

    /// Human lines never carry terminal control characters (titles come from file contents).
    @Test func watchLinesAreSafe() async throws {
        let env = try TestEnv()
        try env.config.setSetupComplete(true)
        var options = AgentDropService.Options()
        options.portBase = Int.random(in: 20_000...59_000)
        let service = AgentDropService(config: env.config, options: options)
        try await service.start()
        defer { Task { await service.stop() } }
        let out = OutputSink()
        let watch = Task { await env.runAsync(["watch", "--inbox", "--once"], out: out) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await service.clientCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try env.file("evil.md", "# \(TerminalSafetyTests.evil)\n")
        #expect(env.run("add", "evil.md", "--from", "a", "--handoff").code == 0)
        let r = await watch.value
        #expect(r.code == 0)
        #expect(!TerminalSafetyTests().hasControls(r.out))
        #expect(r.out.split(separator: "\n").count == 1)
        #expect(r.out.split(separator: "\t").count == 4)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func withLock(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}
