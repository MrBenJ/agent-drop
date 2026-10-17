import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

/// A service over `ServiceFixture` whose tailnet listener binds 127.0.0.1 on a random port
/// written into config.json, with a locator the test controls.
private struct TailnetServiceFixture {
    let base: ServiceFixture
    let identity = Locked<TailnetIdentity?>(TailnetFixture.identity)
    let states = Locked<[TailnetState]>([])
    let port: Int
    let service: AgentDropService

    init(identity initial: TailnetIdentity? = TailnetFixture.identity) throws {
        base = try ServiceFixture()
        port = randomPortBase()
        var dict = try base.config.readDict()
        dict["tailnetPort"] = port
        try base.config.writeDict(dict)
        identity.withLock { $0 = initial }

        var options = AgentDropService.Options()
        options.portBase = randomPortBase()
        options.debounce = .milliseconds(50)
        let identity = identity
        let states = states
        options.tailnetLocator = TailnetLocator { identity.value }
        options.tailnetPoll = .milliseconds(100)
        options.tailnetBindHost = { _ in "127.0.0.1" }
        options.tailnetPeerAllowed = { $0 == "127.0.0.1" }
        options.onTailnetChange = { state in states.withLock { $0.append(state) } }
        service = AgentDropService(config: base.config, options: options)
    }

    var receiving: TailnetState { .receiving(host: "laptop.tail-test.ts.net", port: port) }

    func key() throws -> String { try TailnetKeyFile(configDir: base.config.configDir).create() }

    func send(_ method: String, _ target: String, body: Data? = nil) async throws -> RawResponse {
        var head = "\(method) \(target) HTTP/1.1\r\nHost: laptop.tail-test.ts.net:\(port)\r\n"
        head += "Authorization: Bearer \(try key())\r\n"
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: close\r\n\r\n"
        return RawResponse(try await rawHTTP(port: port, Data(head.utf8) + (body ?? Data())))
    }

    func tailnetRefused() async -> Bool {
        do {
            _ = try await rawHTTP(port: port, "POST /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            return false
        } catch {
            return true
        }
    }
}

struct TailnetServiceTests {
    @Test func offByDefaultNoListener() async throws {
        let f = try TailnetServiceFixture()
        _ = try await f.service.start()
        defer { Task { await f.service.stop() } }
        #expect(await f.service.tailnetState == .off)
        #expect(await f.tailnetRefused())
    }

    @Test func enablingStartsReceiving() async throws {
        let f = try TailnetServiceFixture()
        _ = try await f.service.start()
        defer { Task { await f.service.stop() } }
        #expect(await f.service.setTailnet(enabled: true) == f.receiving)
        #expect(await f.service.tailnetState == f.receiving)
        #expect(try await f.send("POST", "/ping").status == 204)
        #expect(f.states.value == [f.receiving])
    }

    @Test func disablingStopsTheListener() async throws {
        let f = try TailnetServiceFixture()
        _ = try await f.service.start()
        defer { Task { await f.service.stop() } }
        #expect(await f.service.setTailnet(enabled: true) == f.receiving)
        #expect(await f.service.setTailnet(enabled: false) == .off)
        #expect(await f.tailnetRefused())
        #expect(f.states.value == [f.receiving, .off])
    }

    @Test func enabledBeforeStartWaitsThenReceives() async throws {
        let f = try TailnetServiceFixture()
        #expect(await f.service.setTailnet(enabled: true) == .waiting)
        _ = try await f.service.start()
        #expect(await f.service.tailnetState == f.receiving)
        #expect(try await f.send("POST", "/ping").status == 204)
        // The flag outlives a stop: stopping waits, starting again receives, even right
        // after traffic left the old listener's side of the connection in TIME_WAIT.
        await f.service.stop()
        #expect(await f.service.tailnetState == .waiting)
        #expect(await f.tailnetRefused())
        _ = try await f.service.start()
        #expect(await f.service.tailnetState == f.receiving)
        await f.service.stop()
    }

    @Test func listenerFollowsTailscaleComingAndGoing() async throws {
        let f = try TailnetServiceFixture(identity: nil)
        _ = try await f.service.start()
        defer { Task { await f.service.stop() } }
        #expect(await f.service.setTailnet(enabled: true) == .notConnected)
        #expect(await f.tailnetRefused())

        f.identity.withLock { $0 = TailnetFixture.identity }
        #expect(await eventually(timeout: .seconds(1)) { await f.service.tailnetState == f.receiving })
        #expect(try await f.send("POST", "/ping").status == 204)

        f.identity.withLock { $0 = nil }
        #expect(await eventually(timeout: .seconds(1)) { await f.service.tailnetState == .notConnected })
        #expect(await f.tailnetRefused())
    }

    @Test func identityChangeRebinds() async throws {
        let f = try TailnetServiceFixture()
        _ = try await f.service.start()
        defer { Task { await f.service.stop() } }
        #expect(await f.service.setTailnet(enabled: true) == f.receiving)
        f.identity.withLock { $0 = TailnetIdentity(address: "100.100.9.9", dnsName: "renamed.tail-test.ts.net") }
        let renamed = TailnetState.receiving(host: "renamed.tail-test.ts.net", port: f.port)
        #expect(await eventually(timeout: .seconds(1)) { await f.service.tailnetState == renamed })
        // The new listener answers the new name only.
        let ping = "POST /ping HTTP/1.1\r\nHost: renamed.tail-test.ts.net:\(f.port)\r\n"
            + "Authorization: Bearer \(try f.key())\r\nConnection: close\r\n\r\n"
        let response = RawResponse(try await rawHTTP(port: f.port, ping))
        #expect(response.status == 204)
        #expect(try await f.send("POST", "/ping").status == 403)
    }

    @Test func aMissingNameAtTheSameAddressKeepsTheListener() async throws {
        let f = try TailnetServiceFixture()
        _ = try await f.service.start()
        defer { Task { await f.service.stop() } }
        #expect(await f.service.setTailnet(enabled: true) == f.receiving)
        // `tailscale status` failing now and then: the name comes and goes, the address stays.
        let nameless = TailnetIdentity(address: TailnetFixture.identity.address, dnsName: nil)
        for located in [nameless, TailnetFixture.identity, nameless] {
            f.identity.withLock { $0 = located }
            try await Task.sleep(for: .milliseconds(350))
            #expect(await f.service.tailnetState == f.receiving)
            #expect(try await f.send("POST", "/ping").status == 204)
        }
        #expect(f.states.value == [f.receiving])
    }

    @Test func portInUseIsReported() async throws {
        let f = try TailnetServiceFixture()
        let blocker = try await TailnetServer.start(
            store: try StoreFixture().store, bindHost: "127.0.0.1", port: f.port, identity: TailnetFixture.identity,
            limits: .init(maxBytes: 1000), key: { nil })
        _ = try await f.service.start()
        defer { Task { await f.service.stop() } }
        #expect(await f.service.setTailnet(enabled: true) == .portInUse(f.port))
        // The next poll after the port frees up binds it.
        await blocker.stop()
        #expect(await eventually(timeout: .seconds(1)) { await f.service.tailnetState == f.receiving })
    }

    @Test func portInUseWithTailscaleGoneIsNotConnected() async throws {
        let f = try TailnetServiceFixture()
        // Fails the bind, and Tailscale is gone by the time the service looks again.
        let calls = Locked(0)
        var options = AgentDropService.Options()
        options.portBase = randomPortBase()
        options.tailnetLocator = TailnetLocator {
            calls.withLock { $0 += 1 }
            return calls.value == 1 ? TailnetIdentity(address: "100.100.1.2", dnsName: nil) : nil
        }
        options.tailnetPoll = .seconds(60)
        options.tailnetBindHost = { _ in "203.0.113.1" } // not an address on this Mac
        let service = AgentDropService(config: f.base.config, options: options)
        _ = try await service.start()
        defer { Task { await service.stop() } }
        #expect(await service.setTailnet(enabled: true) == .notConnected)
    }

    @Test func invalidConfiguredPortFallsBackToDefault() async throws {
        let f = try TailnetServiceFixture()
        var dict = try f.base.config.readDict()
        dict["tailnetPort"] = 70_000
        try f.base.config.writeDict(dict)
        _ = try await f.service.start()
        defer { Task { await f.service.stop() } }
        let state = await f.service.setTailnet(enabled: true)
        // 47400 may be taken on a developer machine; either way it's the port tried.
        #expect(state == .receiving(host: "laptop.tail-test.ts.net", port: AgentDropConfig.defaultTailnetPort)
            || state == .portInUse(AgentDropConfig.defaultTailnetPort))
    }

    @Test func stopRemovesTailnetListenerAndLoopbackStillWorks() async throws {
        let f = try TailnetServiceFixture()
        _ = try await f.service.start()
        #expect(await f.service.setTailnet(enabled: true) == f.receiving)
        #expect(try await f.base.client().get("/drops").1 == 200)
        await f.service.stop()
        #expect(await f.tailnetRefused())
        #expect(f.base.infoFile.read() == nil)

        _ = try await f.service.start()
        defer { Task { await f.service.stop() } }
        #expect(try await f.base.client().get("/drops").1 == 200)
    }

    @Test func remoteDropReachesTheEventStream() async throws {
        let f = try TailnetServiceFixture()
        _ = try await f.service.start()
        defer { Task { await f.service.stop() } }
        #expect(await f.service.setTailnet(enabled: true) == f.receiving)
        let events = try await f.base.client().events(query: [URLQueryItem(name: "inbox", value: "")])
        let response = try await f.send("POST", "/drops?kind=file&name=report.md&from=aria&handoff=true",
                                        body: Data("# Report\n".utf8))
        #expect(response.status == 201)
        let frame = try #require(try await first(events))
        #expect(frame.event == "created")
        #expect(frame.data.contains("report.md"))
    }
}
