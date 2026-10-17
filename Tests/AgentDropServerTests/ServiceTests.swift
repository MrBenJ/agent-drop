import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

/// A config in a scratch home, with setup finished and the folder outside protected places.
struct ServiceFixture {
    let dir: ScratchDir
    let config: ConfigStore
    var folder: URL { dir.url.appendingPathComponent("AgentDrop", isDirectory: true) }
    var infoFile: ServerInfoFile { ServerInfoFile(configDir: config.configDir) }

    init(setupComplete: Bool = true) throws {
        dir = try ScratchDir()
        config = ConfigStore(configDir: dir.url.appendingPathComponent("support", isDirectory: true),
                             homeDir: dir.url.appendingPathComponent("home", isDirectory: true))
        try config.setFolder(dir.url.appendingPathComponent("AgentDrop", isDirectory: true))
        if setupComplete { try config.setSetupComplete(true) }
    }

    func service(portBase: Int = randomPortBase(), attempts: Int = 10) -> AgentDropService {
        var options = AgentDropService.Options()
        options.portBase = portBase
        options.portAttempts = attempts
        options.debounce = .milliseconds(50)
        return AgentDropService(config: config, options: options)
    }

    /// Another process's view of the store, like the CLI.
    func cliStore() throws -> DropStore { try DropStore.open(folder: folder, retention: .default) }

    func client() throws -> AgentDropClient {
        let info = try #require(infoFile.read())
        return AgentDropClient(port: try #require(info.port), token: try #require(info.token))
    }
}

/// True when nothing listens on the port any more.
func isRefused(port: Int) async throws -> Bool {
    do {
        _ = try await AgentDropClient(port: port, token: "x").get("/drops", timeout: 2)
        return false
    } catch {
        return true
    }
}

func addFile(_ store: DropStore, _ name: String, _ text: String = "# T\n", in dir: URL,
             handoff: Bool = false, project: String? = nil) throws -> Drop {
    let source = dir.appendingPathComponent("src-\(UUID().uuidString)/\(name)")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: source)
    return try store.add(AddRequest(source: .path(source), project: project, from: "cli", handoff: handoff))
}

struct ServiceGateTests {
    @Test func refusesToStartBeforeSetupAndTouchesNothing() async throws {
        let f = try ServiceFixture(setupComplete: false)
        let service = f.service()
        await #expect(throws: AgentDropError.invalid(ServiceMessages.setupIncomplete)) { try await service.start() }
        #expect(!FileManager.default.fileExists(atPath: f.folder.path))
        #expect(f.infoFile.read() == nil)
    }

    @Test func refusesAnUnconfirmedProtectedFolder() async throws {
        let f = try ServiceFixture()
        let desktop = f.config.homeDir.appendingPathComponent("Desktop/AgentDrop", isDirectory: true)
        try f.config.setFolder(desktop)
        let service = f.service()
        await #expect(throws: AgentDropError.invalid(ServiceMessages.confirmFolder)) { try await service.start() }
        #expect(!FileManager.default.fileExists(atPath: desktop.path))

        try f.config.setConfirmedFolder(desktop)
        #expect(try await service.start() != .stopped)
        await service.stop()
    }
}

struct ServiceRunTests {
    @Test func startWritesPrivateServerInfoAndStopRemovesIt() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        guard case .running(let port) = try await service.start() else { Issue.record("not running"); return }
        let info = try #require(f.infoFile.read())
        #expect(info.status == .running)
        #expect(info.port == port)
        #expect(info.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(info.token?.count == 64)
        let mode = try FileManager.default.attributesOfItem(atPath: f.infoFile.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(try await f.client().get("/drops").1 == 200)

        await service.stop()
        #expect(f.infoFile.read() == nil)
        #expect(await service.state == .stopped)
    }

    @Test func startRemovesOnlyStaleStagingDirectories() async throws {
        let f = try ServiceFixture()
        let staging = f.folder.appendingPathComponent(".agentdrop/staging", isDirectory: true)
        let fm = FileManager.default
        let old = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fresh = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Old by its own date but with a recently written child: still in use.
        let busy = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        for dir in [old, fresh, busy] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("upload"))
        }
        let twoHoursAgo = Date().addingTimeInterval(-2 * 3600)
        for url in [old, old.appendingPathComponent("upload"), busy] {
            try fm.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: url.path)
        }

        let service = f.service()
        try await service.start()
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(fm.fileExists(atPath: busy.path))
        await service.stop()
    }

    @Test func eachStartGetsANewToken() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        let first = f.infoFile.read()?.token
        await service.stop()
        _ = try await service.start()
        #expect(f.infoFile.read()?.token != first)
        await service.stop()
    }

    @Test func stopLeavesAnotherInstancesServerInfoAlone() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        try f.infoFile.write(.running(port: 1, token: "other", pid: 1))
        await service.stop()
        #expect(f.infoFile.read()?.token == "other")
    }

    /// The CLI writes from another process; FSEvents on `.agentdrop/` must deliver it live.
    @Test func writesFromAnotherStoreStreamLive() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let events = try await f.client().events(query: [URLQueryItem(name: "inbox", value: "")])
        let drop = try addFile(try f.cliStore(), "handoff.md", in: f.dir.url, handoff: true)
        let frame = try #require(try await first(events))
        #expect(frame.event == "created")
        #expect(frame.data.contains(drop.id))
    }

    @Test func editingADropFileStreamsOneContentEvent() async throws {
        let f = try ServiceFixture()
        let cli = try f.cliStore()
        let drop = try addFile(cli, "notes.md", "one", in: f.dir.url)
        let service = f.service()
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let events = try await f.client().events(query: [URLQueryItem(name: "drop", value: drop.id)])
        for text in ["two", "three!", "four!!"] {
            try Data(text.utf8).write(to: cli.path(of: drop))
        }
        let frame = try #require(try await first(events))
        #expect(frame.event == "content")
        #expect(try cli.events().filter { $0.type == .content }.count == 1)
    }

    @Test func deletingADropFileStreamsMissing() async throws {
        let f = try ServiceFixture()
        let cli = try f.cliStore()
        let drop = try addFile(cli, "gone.md", in: f.dir.url)
        let service = f.service()
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let events = try await f.client().events(query: [URLQueryItem(name: "drop", value: drop.id)])
        try FileManager.default.removeItem(at: cli.path(of: drop))
        #expect(try await first(events)?.event == "missing")
    }

    @Test func noPortStillWatchesContentAndRetryRecovers() async throws {
        let f = try ServiceFixture()
        let blocker = try ServiceFixture()
        let base = randomPortBase()
        let holder = blocker.service(portBase: base, attempts: 1)
        guard case .running(let taken) = try await holder.start() else { Issue.record("blocker"); return }

        let cli = try f.cliStore()
        let drop = try addFile(cli, "a.md", "1", in: f.dir.url)
        let service = f.service(portBase: taken, attempts: 1)
        #expect(try await service.start() == .noPort)
        #expect(f.infoFile.read() == .noPort(pid: ProcessInfo.processInfo.processIdentifier))

        try Data("22".utf8).write(to: cli.path(of: drop))
        #expect(await eventually { (try? cli.events().last?.type) == .content })

        #expect(await service.retryPort() == .noPort)
        await holder.stop()
        #expect(await service.retryPort() == .running(port: taken))
        #expect(f.infoFile.read()?.status == .running)
        // Clients catch up on what happened while there was no server.
        let events = try await f.client().events(lastEventID: "\(cli.storeID):1")
        #expect(try await first(events)?.event == "content")
        await service.stop()
    }

    @Test func switchingFoldersMeansResetForOldCursors() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        let oldStore = try f.cliStore()
        _ = try addFile(oldStore, "old.md", in: f.dir.url)
        await service.stop()

        try f.config.setFolder(f.dir.url.appendingPathComponent("Other", isDirectory: true))
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let events = try await f.client().events(lastEventID: "\(oldStore.storeID):1")
        let frame = try #require(try await first(events))
        #expect(frame.event == "reset")
        #expect(frame.data == SSE.resetData)
    }

    /// Review M1: overlapping calls run one at a time; nothing is left running after stop.
    @Test func overlappingStartsShareOneServerAndStopWins() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        async let a = service.start()
        async let b = service.start()
        let (first, second) = try await (a, b)
        #expect(first == second)
        guard case .running(let port) = first else { Issue.record("not running"); return }
        await service.stop()
        #expect(try await isRefused(port: port))

        // Whichever of these reaches the service first, the result is consistent: the
        // reported state, server.json and the listening port always agree.
        for _ in 0..<5 {
            let starting = Task { try await service.start() }
            await service.stop()
            let started = try await starting.value
            guard case .running(let port2) = started else { Issue.record("not running"); return }
            switch await service.state {
            case .stopped:
                #expect(f.infoFile.read() == nil)
                #expect(try await isRefused(port: port2))
            case .running(let port3):
                #expect(f.infoFile.read()?.port == port3)
                await service.stop()
                #expect(try await isRefused(port: port3))
            case .noPort:
                Issue.record("unexpected no-port")
            }
        }
    }

    /// Review M2: the app writes through the service's own store, whose connection stays
    /// open, so FSEvents never fires for it. Its commits must still stream at once.
    @Test func writesThroughTheServicesOwnStoreStreamLive() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let store = try #require(await service.store)
        let drop = try addFile(store, "h.md", in: f.dir.url, handoff: true)
        _ = try store.claim(drop.id, by: "x")
        let events = try await f.client().events(query: [URLQueryItem(name: "inbox", value: "")])
        _ = try store.release(drop.id)
        #expect(try await first(events, timeout: .seconds(2))?.event == "status")
    }

    /// Review M2: another long-lived writer is caught by the keepalive tick at the latest.
    @Test func aLongLivedExternalWriterIsCaughtByTheKeepaliveTick() async throws {
        let f = try ServiceFixture()
        var options = AgentDropService.Options()
        options.portBase = randomPortBase()
        options.heartbeat = .milliseconds(300)
        let service = AgentDropService(config: f.config, options: options)
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let external = try f.cliStore()      // stays open for the whole test
        let drop = try addFile(external, "h.md", in: f.dir.url, handoff: true)
        _ = try external.claim(drop.id, by: "x")
        try await Task.sleep(for: .milliseconds(400))
        let events = try await f.client().events(query: [URLQueryItem(name: "inbox", value: "")])
        _ = try external.release(drop.id)
        #expect(try await first(events, timeout: .seconds(3))?.event == "status")
        withExtendedLifetime(external) {}
    }

    @Test func stopWithAConnectedClientIsPrompt() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        let events = try await f.client().events()
        #expect(await eventually { await service.clientCount == 1 })
        let elapsed = await ContinuousClock().measure { await service.stop() }
        #expect(elapsed < .seconds(2))
        #expect(try await first(events, timeout: .seconds(2)) == nil)
    }
}
