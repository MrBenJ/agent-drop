import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

private let loopbackIdentity = TailnetIdentity(address: "127.0.0.1", dnsName: nil)

private func client(_ s: TailnetFixture, key: String? = nil,
                    temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> TailnetClient {
    TailnetClient(remoteName: "laptop",
                  remote: .init(url: URL(string: "http://127.0.0.1:\(s.port)")!, key: key ?? s.key.value ?? ""),
                  temporaryDirectory: temporaryDirectory)
}

private func metadata(_ name: String = "report.md") -> TailnetClient.Metadata {
    .init(name: name, from: "aria", title: nil, desc: nil, project: nil, tags: [], handoff: false)
}

private func json(_ data: Data) throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: data)
}

struct TailnetClientTests {
    @Test func sendsAFileAndReturnsTheDrop() async throws {
        let s = try await TailnetFixture(identity: loopbackIdentity)
        defer { Task { await s.server.stop() } }
        let file = s.store.dir.url.appendingPathComponent("report.md")
        try Data("# Report\n".utf8).write(to: file)
        var meta = metadata()
        meta.project = "courses-app"
        meta.handoff = true
        let body = try json(try await client(s).send(.file(file), meta))
        #expect(body["filename"] == .string("report.md"))
        #expect(body["project"] == .string("courses-app"))
        #expect(body["kind"] == .string("handoff"))
        let drop = try #require(try s.store.store.list(ListFilter()).first)
        #expect(try String(contentsOf: s.store.store.path(of: drop), encoding: .utf8) == "# Report\n")
    }

    @Test func sendsAFolder() async throws {
        let s = try await TailnetFixture(identity: loopbackIdentity)
        defer { Task { await s.server.stop() } }
        let source = s.store.dir.url.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("# A\n".utf8).write(to: source.appendingPathComponent("a.md"))
        try Data("bee".utf8).write(to: source.appendingPathComponent("sub/b.txt"))
        // Its own temp dir: the shared one can hold other tests' packs mid-send.
        let temp = s.store.dir.url.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let body = try json(try await client(s, temporaryDirectory: temp).send(.folder(source), metadata("notes")))
        #expect(body["isFolder"] == .bool(true))
        let drop = try #require(try s.store.store.list(ListFilter()).first)
        let stored = s.store.store.path(of: drop)
        #expect(try Data(contentsOf: stored.appendingPathComponent("sub/b.txt")) == Data("bee".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
    }

    @Test func sendsData() async throws {
        let s = try await TailnetFixture(identity: loopbackIdentity)
        defer { Task { await s.server.stop() } }
        _ = try await client(s).send(.data(Data("hello".utf8)), metadata("note.txt"))
        let drop = try #require(try s.store.store.list(ListFilter()).first)
        #expect(try Data(contentsOf: s.store.store.path(of: drop)) == Data("hello".utf8))
    }

    @Test func emptyFileSends() async throws {
        let s = try await TailnetFixture(identity: loopbackIdentity)
        defer { Task { await s.server.stop() } }
        let file = s.store.dir.url.appendingPathComponent("empty.txt")
        try Data().write(to: file)
        let body = try json(try await client(s).send(.file(file), metadata("empty.txt")))
        #expect(body["filename"] == .string("empty.txt"))
        let drop = try #require(try s.store.store.list(ListFilter()).first)
        #expect(try Data(contentsOf: s.store.store.path(of: drop)).isEmpty)
    }

    @Test func unicodeNamesAndDescriptionsRoundTrip() async throws {
        let s = try await TailnetFixture(identity: loopbackIdentity)
        defer { Task { await s.server.stop() } }
        var meta = metadata("Q3 plan — draft ✅.md")
        meta.desc = "Why & how? 100% — \"quoted\""
        meta.title = "a=b #1 + c"
        meta.tags = ["a+b"]
        _ = try await client(s).send(.data(Data("# x\n".utf8)), meta)
        let drop = try #require(try s.store.store.list(ListFilter()).first)
        #expect(drop.filename == "Q3 plan — draft ✅.md")
        #expect(drop.description == "Why & how? 100% — \"quoted\"")
        #expect(drop.title == "a=b #1 + c")
        #expect(drop.tags == ["a+b"])
    }

    @Test func pingSucceeds() async throws {
        let s = try await TailnetFixture(identity: loopbackIdentity)
        defer { Task { await s.server.stop() } }
        try await client(s).ping()
    }

    @Test func badKeyMessage() async throws {
        let s = try await TailnetFixture(identity: loopbackIdentity)
        defer { Task { await s.server.stop() } }
        let url = "http://127.0.0.1:\(s.port)"
        let expected = AgentDropError.invalid(
            "The key for 'laptop' was rejected. It may have been regenerated: run `drop remote add laptop --url \(url) --key <new key>` again.")
        await #expect(throws: expected) { try await client(s, key: "wrong").ping() }
        await #expect(throws: expected) { _ = try await client(s, key: "wrong").send(.data(Data()), metadata()) }
    }

    @Test func unreachableMessage() async throws {
        let s = try await TailnetFixture(identity: loopbackIdentity)
        let port = s.port
        await s.server.stop()
        let url = "http://127.0.0.1:\(port)"
        let c = TailnetClient(remoteName: "laptop", remote: .init(url: URL(string: url)!, key: "k"))
        let expected = AgentDropError.invalid(
            "Can't reach 'laptop' (\(url)). Is that Mac awake, on Tailscale, with Agent Drop running and Tailnet turned on?")
        await #expect(throws: expected) { try await c.ping() }
        await #expect(throws: expected) { _ = try await c.send(.data(Data()), metadata()) }
    }

    @Test func tooLargeMessage() async throws {
        let s = try await TailnetFixture(maxBytes: 1024, identity: loopbackIdentity)
        defer { Task { await s.server.stop() } }
        do {
            _ = try await client(s).send(.data(Data(count: 4096)), metadata())
            Issue.record("expected a failure")
        } catch let AgentDropError.invalid(message) {
            #expect(message.contains("MB limit"))
        }
    }

    @Test func largeOverLimitUploadIsNotReportedAsUnreachable() async throws {
        let s = try await TailnetFixture(maxBytes: 1000, identity: loopbackIdentity)
        defer { Task { await s.server.stop() } }
        let file = s.store.dir.url.appendingPathComponent("big.bin")
        try Data(count: 8 * 1024 * 1024).write(to: file)
        do {
            _ = try await client(s).send(.file(file), metadata("big.bin"))
            Issue.record("expected a failure")
        } catch let AgentDropError.invalid(message) {
            #expect(!message.hasPrefix("Can't reach"), "\(message)")
            #expect(message.contains("MB limit") || message.hasPrefix("Lost the connection to 'laptop'"), "\(message)")
        }
    }
}
