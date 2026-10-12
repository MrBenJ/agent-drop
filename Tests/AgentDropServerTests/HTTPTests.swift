import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

struct HTTPAccessTests {
    @Test func missingOrWrongTokenIs401() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let wrong = AgentDropClient(port: s.server.port, token: "nope")
        let (body, status) = try await wrong.get("/drops")
        #expect(status == 401)
        #expect(String(decoding: body, as: UTF8.self) == #"{"error":"missing or invalid token","status":401}"#)
        let noAuth = try rawHTTP(port: s.server.port, "GET /drops HTTP/1.1\r\nHost: 127.0.0.1:\(s.server.port)\r\nConnection: close\r\n\r\n")
        #expect(noAuth.hasPrefix("HTTP/1.1 401"))
    }

    @Test(arguments: ["evil.example", "127.0.0.1", "127.0.0.1:1", "localhost.evil.example"])
    func foreignHostIs403EvenWithTheToken(_ host: String) async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let response = try rawHTTP(port: s.server.port,
            "GET /drops HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(s.server.token)\r\nConnection: close\r\n\r\n")
        #expect(response.hasPrefix("HTTP/1.1 403"))
        #expect(response.contains(#""status":403"#))
    }

    @Test func localhostAndLoopbackHostsAreAllowed() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        for host in ["127.0.0.1:\(s.server.port)", "localhost:\(s.server.port)"] {
            let response = try rawHTTP(port: s.server.port,
                "GET /drops HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(s.server.token)\r\nConnection: close\r\n\r\n")
            #expect(response.hasPrefix("HTTP/1.1 200"), "\(host)")
        }
    }

    @Test func unknownRouteIsJSON404() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let (body, status) = try await s.client.get("/nope")
        #expect(status == 404)
        #expect(String(decoding: body, as: UTF8.self).contains(#""status":404"#))
    }
}

struct HTTPDropsTests {
    @Test func listUsesListDefaultsAndFilters() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let a = try s.store.add("a.md", project: "app", handoff: true)
        let b = try s.store.add("b.md", project: "web")
        let c = try s.store.add("c.md", project: "app")
        _ = try s.store.store.setArchived(c.id, true)
        _ = try s.store.store.edit(b.id, EditRequest(addTags: ["PR", "x y"]))

        func ids(_ query: [String: String]) async throws -> [String] {
            let (body, status) = try await s.client.get("/drops", query: query.map { URLQueryItem(name: $0.key, value: $0.value) })
            #expect(status == 200)
            return try JSONDecoder().decode([[String: JSONValue]].self, from: body).compactMap { $0["id"]?.stringValue }
        }
        #expect(try await ids([:]) == [b.id, a.id])
        #expect(try await ids(["all": ""]) == [c.id, b.id, a.id])
        #expect(try await ids(["project": "app"]) == [a.id])
        #expect(try await ids(["tag": "x y"]) == [b.id])
        #expect(try await ids(["handoffs": "true", "status": "open"]) == [a.id])
        #expect(try await ids(["limit": "1"]) == [b.id])
        #expect(try await ids(["from-under": "tester"]) == [b.id, a.id])
        #expect(try await ids(["unread": "", "all": "true"]) == [b.id, a.id])
    }

    @Test(arguments: [["status": "maybe"], ["limit": "0"], ["limit": "x"], ["handoffs": "yes"], ["projct": "app"]])
    func badQueriesAre400(_ query: [String: String]) async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let (body, status) = try await s.client.get("/drops", query: query.map { URLQueryItem(name: $0.key, value: $0.value) })
        #expect(status == 400)
        #expect(String(decoding: body, as: UTF8.self).contains(#""status":400"#))
    }

    @Test func repeatedTagsMustAllMatch() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let both = try s.store.add("both.md")
        let one = try s.store.add("one.md")
        _ = try s.store.store.edit(both.id, EditRequest(addTags: ["a", "b"]))
        _ = try s.store.store.edit(one.id, EditRequest(addTags: ["a"]))
        let (body, _) = try await s.client.get("/drops", query: [URLQueryItem(name: "tag", value: "a"), URLQueryItem(name: "tag", value: "b")])
        let ids = try JSONDecoder().decode([[String: JSONValue]].self, from: body).compactMap { $0["id"]?.stringValue }
        #expect(ids == [both.id])
    }

    /// Review Focus: filenames with spaces, accents and emoji resolve through the URL path.
    @Test(arguments: ["Q3 plan — draft ✅.md", "a%b#c?.md", "café.md"])
    func showByIdOrEncodedFilename(_ name: String) async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let drop = try s.store.add(name)
        for ref in [drop.id, drop.filename] {
            let (body, status) = try await s.client.get(AgentDropClient.dropPath(ref))
            #expect(status == 200, "\(ref)")
            let json = try JSONDecoder().decode([String: JSONValue].self, from: body)
            #expect(json["id"]?.stringValue == drop.id)
            #expect(json["filename"]?.stringValue == drop.filename)
        }
        let (_, missing) = try await s.client.get(AgentDropClient.dropPath("zzzzzz"))
        #expect(missing == 404)
    }

    @Test func showNoticesAMissingFileAndStreamsTheEvent() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let drop = try s.store.add("gone.md")
        let stream = try await s.hub.subscribe(.drop(drop.id), resumeFrom: nil)
        try FileManager.default.removeItem(at: s.store.store.path(of: drop))
        let (body, _) = try await s.client.get(AgentDropClient.dropPath(drop.id))
        #expect(try JSONDecoder().decode([String: JSONValue].self, from: body)["missing"] == .bool(true))
        #expect(await collect(stream, count: 1).first?.message?.type == "missing")
    }

    @Test func fileContentIsByteExact() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x0A, 0x0D])
        let source = s.store.dir.url.appendingPathComponent("img.png")
        try bytes.write(to: source)
        let drop = try s.store.store.add(AddRequest(source: .path(source), from: "t"))
        let (body, status) = try await s.client.get(AgentDropClient.dropPath(drop.id) + "/content")
        #expect(status == 200)
        #expect(body == bytes)

        try FileManager.default.removeItem(at: s.store.store.path(of: drop))
        #expect(try await s.client.get(AgentDropClient.dropPath(drop.id) + "/content").1 == 404)
    }

    @Test func folderContentIsAListingThatNeverFollowsLinks() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let fm = FileManager.default
        let bundle = s.store.dir.url.appendingPathComponent("bundle", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("# B\n".utf8).write(to: bundle.appendingPathComponent("README.md"))
        try Data("x".utf8).write(to: bundle.appendingPathComponent("sub/x.txt"))
        try fm.createSymbolicLink(atPath: bundle.appendingPathComponent("link").path, withDestinationPath: "/etc")
        let drop = try s.store.store.add(AddRequest(source: .path(bundle), from: "t"))

        let (body, status) = try await s.client.get(AgentDropClient.dropPath(drop.id) + "/content")
        #expect(status == 200)
        let listing = try JSONDecoder().decode(FolderListing.self, from: body)
        #expect(listing.id == drop.id)
        #expect(listing.entries == [
            .init(path: "README.md", type: "file", size: 4, target: nil),
            .init(path: "link", type: "symlink", size: nil, target: "/etc"),
            .init(path: "sub", type: "directory", size: nil, target: nil),
            .init(path: "sub/x.txt", type: "file", size: 1, target: nil),
        ])
    }
}

struct HTTPEventsTests {
    @Test func streamsFramesWithStoreScopedIDs() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let events = try await s.client.events()
        let drop = try s.store.add(handoff: true)
        await s.hub.poke()
        let frame = try #require(try await first(events))
        #expect(frame.event == "created")
        #expect(frame.id == "\(s.store.store.storeID):1")
        let message = try JSONDecoder().decode(EventMessage.self, from: Data(frame.data.utf8))
        #expect(message.dropId == drop.id)
        #expect(message.data["kind"]?.stringValue == "handoff")
    }

    @Test func resumesFromLastEventIDAndResetsAcrossStores() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        try s.store.add("a.md")
        try s.store.add("b.md")
        await s.hub.poke()
        let resumed = try await s.client.events(lastEventID: "\(s.store.store.storeID):1")
        #expect(try await first(resumed)?.id == "\(s.store.store.storeID):2")

        let foreign = try await s.client.events(lastEventID: "someotherstore:9")
        let reset = try #require(try await first(foreign))
        #expect(reset.event == "reset")
        #expect(reset.data == #"{"reason":"drop folder changed"}"#)
        #expect(reset.id == "\(s.store.store.storeID):2")
    }

    @Test func dropAndInboxFilters() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let note = try s.store.add("n.md", project: "app")
        let byFilename = try await s.client.events(query: [URLQueryItem(name: "drop", value: note.filename)])
        let inbox = try await s.client.events(query: [URLQueryItem(name: "inbox", value: ""), URLQueryItem(name: "project", value: "app")])
        _ = try s.store.store.edit(note.id, EditRequest(kind: .handoff))
        await s.hub.poke()
        #expect(try await first(byFilename)?.event == "metadata")
        #expect(try await first(inbox)?.event == "metadata")
    }

    @Test func badEventRequests() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let drop = try s.store.add()
        func status(_ query: [URLQueryItem], lastEventID: String? = nil) async throws -> Int {
            do {
                _ = try await s.client.events(query: query, lastEventID: lastEventID)
                return 200
            } catch let error as AgentDropClient.HTTPFailure {
                return error.status
            }
        }
        #expect(try await status([URLQueryItem(name: "drop", value: "zzzzzz")]) == 404)
        #expect(try await status([URLQueryItem(name: "drop", value: drop.id), URLQueryItem(name: "inbox", value: "")]) == 400)
        #expect(try await status([URLQueryItem(name: "project", value: "app")]) == 400)
        #expect(try await status([URLQueryItem(name: "dorp", value: drop.id)]) == 400)
        #expect(try await status([], lastEventID: "garbage") == 400)
    }

    /// Review Focus: stopping the server with a client still connected must not hang.
    @Test func stopEndsOpenStreamsPromptly() async throws {
        let s = try await ServerFixture()
        let events = try await s.client.events()
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await s.server.stop() }
        #expect(elapsed < .seconds(2))
        #expect(try await first(events, timeout: .seconds(2)) == nil)
    }
}

struct HTTPPortTests {
    @Test func fallsThroughTakenPortsAndReportsExhaustion() async throws {
        let store = try StoreFixture()
        let hub = try EventHub(store: store.store)
        let base = randomPortBase()
        let first = try await HTTPServer.start(store: store.store, hub: hub, token: "t", portBase: base, attempts: 2)
        let second = try await HTTPServer.start(store: store.store, hub: hub, token: "t", portBase: first.port, attempts: 2)
        #expect(second.port == first.port + 1)
        await #expect(throws: HTTPServer.PortsExhausted.self) {
            _ = try await HTTPServer.start(store: store.store, hub: hub, token: "t", portBase: first.port, attempts: 2)
        }
        await second.stop()
        await first.stop()
    }
}

/// The first event of a stream, or nil if it ends or nothing arrives in time.
func first(_ events: AsyncThrowingStream<SSEEvent, Error>, timeout: Duration = .seconds(5)) async throws -> SSEEvent? {
    try await withThrowingTaskGroup(of: SSEEvent?.self) { group in
        group.addTask {
            for try await event in events { return event }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
