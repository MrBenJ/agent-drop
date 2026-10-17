import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

/// A raw pack, so tests can build ones `DropPack.write` would refuse to.
private func rawPack(_ records: [(UInt8, String, Data?)]) -> Data {
    var out = Data("ADPK1\n".utf8)
    func be32(_ v: UInt32) { out.append(contentsOf: (0..<4).map { UInt8((v >> UInt32(24 - 8 * $0)) & 0xFF) }) }
    func be64(_ v: UInt64) { out.append(contentsOf: (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xFF) }) }
    for (type, path, payload) in records {
        out.append(type)
        if type == UInt8(ascii: "e") { continue }
        let bytes = Data(path.utf8)
        be32(UInt32(bytes.count))
        out.append(bytes)
        if type == UInt8(ascii: "f") {
            let body = payload ?? Data()
            be64(UInt64(body.count))
            out.append(body)
        }
    }
    return out
}

private let fileDrop = "/drops?kind=file&name=report.md&from=aria"

struct TailnetAccessTests {
    @Test func pingWithKeyIs204() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        #expect(try await s.send("POST", "/ping").status == 204)
    }

    @Test(arguments: ["evil.example:P", "127.0.0.1:P", "laptop.tail-test.ts.net:1", "laptop.tail-test.ts.net.evil:P"])
    func foreignHostIs403(_ host: String) async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let response = try await s.send("POST", "/ping", host: host.replacingOccurrences(of: "P", with: "\(s.port)"))
        #expect(response.status == 403)
        #expect(response.json["error"] == .string("Host not allowed"))
    }

    @Test func shortNameAndAddressHostsAreAllowed() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        #expect(try await s.send("POST", "/ping", host: "laptop:\(s.port)").status == 204)
        #expect(try await s.send("POST", "/ping", host: "100.100.1.2:\(s.port)").status == 204)
        #expect(try await s.send("POST", "/ping", host: "LAPTOP.tail-test.ts.net:\(s.port)").status == 204)
    }

    @Test func duplicateHostIs403() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let response = try await s.send("POST", "/ping", headers: ["Host: \(s.host)"])
        #expect(response.status == 403)
    }

    @Test func wrongOrMissingKeyIs401() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let wrong = try await s.send("POST", "/ping", key: ServerInfo.newToken())
        #expect(wrong.status == 401)
        #expect(wrong.json["error"] == .string("missing or invalid key"))
        #expect(try await s.send("POST", "/ping", key: "").status == 401)
    }

    @Test func noKeyFileMeansEverythingIs401() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let old = s.key.value!
        s.key.withLock { $0 = nil }
        #expect(try await s.send("POST", "/ping", key: old).status == 401)
        #expect(try await s.send("POST", "/ping", key: "").status == 401)
        #expect(try await s.send("POST", fileDrop, key: old, body: Data("x".utf8)).status == 401)
    }

    @Test func nonTailnetPeerIs403() async throws {
        let s = try await TailnetFixture(peerAllowed: { _ in false })
        defer { Task { await s.server.stop() } }
        let response = try await s.send("POST", "/ping")
        #expect(response.status == 403)
        #expect(response.json["error"] == .string("Not a tailnet address"))
    }

    @Test(arguments: ["GET /drops", "GET /events", "GET /drops/x", "GET /drops/x/content", "PUT /drops",
                      "DELETE /drops/x"])
    func readRoutesDoNotExist(_ line: String) async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        _ = try s.store.add("x.md")
        let parts = line.split(separator: " ").map(String.init)
        let response = try await s.send(parts[0], parts[1])
        #expect(response.status == 404)
        #expect(response.json["status"] == .number(404))
    }

    @Test func regeneratedKeyTakesEffectWithoutRestart() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let old = s.key.value!
        #expect(try await s.send("POST", "/ping", key: old).status == 204)
        let new = ServerInfo.newToken()
        s.key.withLock { $0 = new }
        #expect(try await s.send("POST", "/ping", key: old).status == 401)
        #expect(try await s.send("POST", "/ping", key: new).status == 204)
    }

    @Test func portInUseThrows() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        await #expect(throws: TailnetServer.PortInUse(port: s.port)) {
            let second = try await TailnetServer.start(
                store: s.store.store, bindHost: "127.0.0.1", port: s.port, identity: TailnetFixture.identity,
                limits: .init(maxBytes: 1000), key: { "k" })
            await second.stop()
        }
    }
}

struct TailnetUploadTests {
    @Test func fileUploadCreatesADrop() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let hub = try EventHub(store: s.store.store)
        let stream = try await hub.subscribe(.all, resumeFrom: nil)
        let response = try await s.send(
            "POST", "/drops?kind=file&name=report.md&from=aria&project=courses-app&tag=a&tag=b&desc=Why&handoff=true",
            body: Data("# Report\n".utf8))
        #expect(response.status == 201)
        let json = response.json
        #expect(json["filename"] == .string("report.md"))
        #expect(json["title"] == .string("Report"))
        #expect(json["from"] == .string("aria"))
        #expect(json["project"] == .string("courses-app"))
        #expect(json["description"] == .string("Why"))
        #expect(json["tags"] == .array([.string("a"), .string("b")]))
        #expect(json["kind"] == .string("handoff"))
        #expect(json["status"] == .string("open"))
        #expect(json["isFolder"] == .bool(false))

        let listed = try s.store.store.list(ListFilter())
        #expect(listed.map(\.filename) == ["report.md"])
        let saved = try String(contentsOf: s.store.store.path(of: listed[0]), encoding: .utf8)
        #expect(saved == "# Report\n")
        await hub.poke()
        #expect(await collect(stream, count: 1).first?.message?.type == "created")
        #expect(s.stagingEntries().isEmpty)
    }

    @Test func folderUploadCreatesAFolderDrop() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let source = s.store.dir.url.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try Data("# A\n".utf8).write(to: source.appendingPathComponent("a.md"))
        try Data("bee".utf8).write(to: source.appendingPathComponent("sub/b.txt"))
        let packFile = s.store.dir.url.appendingPathComponent("notes.adpk")
        try DropPack.write(folder: source, to: packFile)

        let response = try await s.send("POST", "/drops?kind=folder&name=notes&from=aria",
                                        body: try Data(contentsOf: packFile))
        #expect(response.status == 201)
        #expect(response.json["isFolder"] == .bool(true))
        #expect(response.json["filename"] == .string("notes"))

        let drop = try #require(try s.store.store.list(ListFilter()).first)
        let stored = s.store.store.path(of: drop)
        let fm = FileManager.default
        #expect(fm.subpaths(atPath: stored.path)?.sorted() == fm.subpaths(atPath: source.path)?.sorted())
        #expect(try Data(contentsOf: stored.appendingPathComponent("a.md")) == Data("# A\n".utf8))
        #expect(try Data(contentsOf: stored.appendingPathComponent("sub/b.txt")) == Data("bee".utf8))
        #expect(s.stagingEntries().isEmpty)
    }

    @Test(arguments: [
        "/drops?kind=file&name=report.md",
        "/drops?kind=zip&name=report.md&from=aria",
        "/drops?kind=file&name=report.md&from=aria&frm=x",
        "/drops?name=report.md&from=aria",
        "/drops?kind=file&from=aria",
        "/drops?kind=file&name=report.md&from=aria&handoff=maybe",
    ])
    func missingOrUnknownQueryIs400(_ target: String) async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let response = try await s.send("POST", target, body: Data("x".utf8))
        #expect(response.status == 400)
        #expect(response.json["status"] == .number(400))
        #expect(try s.store.store.list(ListFilter()).isEmpty)
    }

    @Test func unknownQueryParameterIsNamed() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let response = try await s.send("POST", fileDrop + "&frm=x", body: Data("x".utf8))
        #expect(response.json["error"] == .string("unknown query parameter 'frm'"))
    }

    @Test func oversizeByContentLengthIs413() async throws {
        let s = try await TailnetFixture(maxBytes: 1000)
        defer { Task { await s.server.stop() } }
        let response = try await s.send("POST", fileDrop, body: Data(repeating: 0x61, count: 5000))
        #expect(response.status == 413)
        #expect(response.json["error"] == .string("Drop is larger than the 0 MB limit"))
        #expect(try s.store.store.list(ListFilter()).isEmpty)
    }

    @Test func newlineDenseMarkdownWithoutATitleGetsTheFilenameFallback() async throws {
        let s = try await TailnetFixture(maxBytes: 4 * 1_048_576)
        defer { Task { await s.server.stop() } }
        let response = try await s.send(
            "POST", "/drops?kind=file&name=big.md&from=agent",
            body: Data(repeating: UInt8(ascii: "\n"), count: 2 * 1_048_576))
        #expect(response.status == 201)
        #expect(response.json["title"] == .string("big"))
    }

    @Test func oversizeMessageNamesTheLimitInMegabytes() async throws {
        let s = try await TailnetFixture(maxBytes: 3 * 1_048_576)
        defer { Task { await s.server.stop() } }
        let response = try await s.send("POST", fileDrop, headers: ["Content-Length: 99999999"])
        #expect(response.status == 413)
        #expect(response.json["error"] == .string("Drop is larger than the 3 MB limit"))
    }

    @Test func oversizeWhileStreamingIs413() async throws {
        let s = try await TailnetFixture(maxBytes: 1000)
        defer { Task { await s.server.stop() } }
        var request = s.request("POST", fileDrop, headers: ["Transfer-Encoding: chunked"])
        for _ in 0..<3 {
            request += Data("1f4\r\n".utf8) + Data(repeating: 0x61, count: 500) + Data("\r\n".utf8)
        }
        request += Data("0\r\n\r\n".utf8)
        let response = RawResponse(try await rawHTTP(port: s.port, request))
        #expect(response.status == 413)
        #expect(try s.store.store.list(ListFilter()).isEmpty)
        #expect(await eventually(timeout: .seconds(2)) { s.stagingEntries().isEmpty })
    }

    @Test func maliciousFolderIs400AndLeavesNothing() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let F = UInt8(ascii: "f"), E = UInt8(ascii: "e")
        let pack = rawPack([(F, "../escape", Data("pwned".utf8)), (E, "", nil)])
        let response = try await s.send("POST", "/drops?kind=folder&name=evil&from=aria", body: pack)
        #expect(response.status == 400)
        let message = response.json["error"]?.stringValue ?? ""
        #expect(message.hasPrefix("invalid folder upload: "))
        #expect(try s.store.store.list(ListFilter()).isEmpty)
        #expect(s.stagingEntries().isEmpty)
        let fm = FileManager.default
        let everything = fm.subpaths(atPath: s.store.dir.url.path) ?? []
        #expect(!everything.contains { $0.hasSuffix("escape") })
        #expect(!fm.fileExists(atPath: s.store.folder.appendingPathComponent("evil").path))
    }

    @Test func caseCollidingFolderIs400NotA500() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let D = UInt8(ascii: "d"), E = UInt8(ascii: "e")
        let pack = rawPack([(D, "A", nil), (D, "a", nil), (E, "", nil)])
        let response = try await s.send("POST", "/drops?kind=folder&name=dirs&from=aria", body: pack)
        #expect(response.status == 400)
        let message = response.json["error"]?.stringValue ?? ""
        #expect(message.hasPrefix("invalid folder upload: "))
        #expect(s.stagingEntries().isEmpty)
    }

    @Test func lowDiskIs507() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        s.free.withLock { $0 = (1 << 30) + 10 }
        let response = try await s.send("POST", fileDrop, body: Data(repeating: 0x61, count: 100))
        #expect(response.status == 507)
        #expect(response.json["error"] == .string("Not enough free disk space on the receiving Mac"))
        s.free.withLock { $0 = (1 << 30) + 1000 }
        #expect(try await s.send("POST", fileDrop, body: Data(repeating: 0x61, count: 100)).status == 201)
    }

    /// No Content-Length: the upload may still grow to the cap, so it reserves the cap.
    @Test func chunkedUploadReservesTheCap() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        s.free.withLock { $0 = (1 << 30) + 10 }
        var request = s.request("POST", fileDrop, headers: ["Transfer-Encoding: chunked"])
        request += Data("5\r\nhello\r\n0\r\n\r\n".utf8)
        let response = RawResponse(try await rawHTTP(port: s.port, request))
        #expect(response.status == 507)
        #expect(s.stagingEntries().isEmpty)
        #expect(try s.store.store.list(ListFilter()).isEmpty)
    }

    /// Concurrent uploads can't each pass against the same free space.
    @Test func overlappingUploadsShareTheFreeSpace() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        s.free.withLock { $0 = (1 << 30) + 150 } // room for one 100-byte upload, not two
        let first = try await rawHTTPConnection(port: s.port)
        defer { first.close() }
        try await first.send(s.request("POST", "/drops?kind=file&name=one.txt&from=aria",
                                       headers: ["Content-Length: 100"]))
        try await first.send(Data(repeating: 0x61, count: 50))
        #expect(await eventually { s.stagingEntries().count == 1 })

        let second = try await s.send("POST", "/drops?kind=file&name=two.txt&from=aria",
                                      body: Data(repeating: 0x62, count: 100))
        #expect(second.status == 507)

        try await first.send(Data(repeating: 0x61, count: 50))
        #expect(RawResponse(await first.readToEnd()).status == 201)
        // Its reservation went with it.
        let third = try await s.send("POST", "/drops?kind=file&name=three.txt&from=aria",
                                     body: Data(repeating: 0x63, count: 100))
        #expect(third.status == 201)
        #expect(try s.store.store.list(ListFilter()).map(\.filename).sorted() == ["one.txt", "three.txt"])
    }

    /// A cap near Int64.max (config bypassed) must not overflow the reservation arithmetic.
    @Test func hugeCapFolderUploadIs507NotACrash() async throws {
        let s = try await TailnetFixture(maxBytes: Int64.max)
        defer { Task { await s.server.stop() } }
        var request = s.request("POST", "/drops?kind=folder&name=notes&from=aria",
                                headers: ["Transfer-Encoding: chunked"])
        request += Data("5\r\nhello\r\n0\r\n\r\n".utf8)
        let response = RawResponse(try await rawHTTP(port: s.port, request))
        #expect(response.status == 507)
        #expect(s.stagingEntries().isEmpty)
        #expect(try s.store.store.list(ListFilter()).isEmpty)
    }

    /// Two reservations that together overflow Int64 are refused even with no free-space reading.
    @Test func overlappingReservationsThatOverflowAre507() async throws {
        let s = try await TailnetFixture(maxBytes: Int64.max)
        defer { Task { await s.server.stop() } }
        let first = try await rawHTTPConnection(port: s.port)
        defer { first.close() }
        try await first.send(s.request("POST", fileDrop, headers: ["Transfer-Encoding: chunked"])
                             + Data("5\r\nhello\r\n".utf8))
        #expect(await eventually { s.stagingEntries().count == 1 })

        var second = s.request("POST", fileDrop, headers: ["Transfer-Encoding: chunked"])
        second += Data("5\r\nhello\r\n0\r\n\r\n".utf8)
        #expect(RawResponse(try await rawHTTP(port: s.port, second)).status == 507)
    }

    /// A 500's raw error text can name receiver paths; senders get a generic message.
    @Test func internalErrorsDoNotLeakDetails() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        // A file where the staging directory belongs: creating a staging dir throws.
        try? FileManager.default.removeItem(at: s.stagingRoot)
        try FileManager.default.createDirectory(at: s.stagingRoot.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: s.stagingRoot)
        let response = try await s.send("POST", fileDrop, body: Data("hi".utf8))
        #expect(response.status == 500)
        #expect(response.json["error"] == .string("Internal error on the receiving Mac"))
        #expect(response.json["status"] == .number(500))
    }

    /// A folder upload holds the pack and its unpacked tree at once, so it needs twice its
    /// declared size free; a file needs it once.
    @Test func folderUploadNeedsTwiceItsSizeFree() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let source = s.store.dir.url.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 4000).write(to: source.appendingPathComponent("a.txt"))
        let packFile = s.store.dir.url.appendingPathComponent("notes.adpk")
        try DropPack.write(folder: source, to: packFile)
        let pack = try Data(contentsOf: packFile)
        let size = Int64(pack.count)
        let overhead = Int64(DropPack.maxEntries) * TailnetServer.entryOverheadBytes

        s.free.withLock { $0 = (1 << 30) + overhead + size + size / 2 } // enough for 1×, not 2×
        let folder = try await s.send("POST", "/drops?kind=folder&name=notes&from=aria", body: pack)
        #expect(folder.status == 507)
        #expect(s.stagingEntries().isEmpty)
        let file = try await s.send("POST", "/drops?kind=file&name=notes.adpk&from=aria", body: pack)
        #expect(file.status == 201)

        s.free.withLock { $0 = (1 << 30) + overhead + 2 * size }
        #expect(try await s.send("POST", "/drops?kind=folder&name=notes&from=aria", body: pack).status == 201)
    }

    /// 5,000 one-byte files: a small pack on the wire, a large tree on disk.
    private func manySmallFilesPack() -> Data {
        rawPack((0..<5000).map { (UInt8(ascii: "f"), "f\($0)", Data([0x61])) } + [(UInt8(ascii: "e"), "", nil)])
    }

    /// Each unpacked entry takes at least a block of disk, so a folder reserves that per entry too.
    @Test func manySmallFilesReserveTheirBlockOverhead() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let pack = manySmallFilesPack()
        let wire = Int64(pack.count)
        let folder = "/drops?kind=folder&name=many&from=aria"

        s.free.withLock { $0 = (1 << 30) + (2 << 20) } // 2× the wire bytes fit; the entries' blocks don't
        #expect(try await s.send("POST", folder, body: pack).status == 507)
        #expect(s.stagingEntries().isEmpty)

        let overhead = Int64(DropPack.maxEntries) * TailnetServer.entryOverheadBytes
        s.free.withLock { $0 = (1 << 30) + 2 * wire + overhead + 4096 }
        #expect(try await s.send("POST", folder, body: pack).status == 201)
    }

    /// The per-entry overhead counts in the cross-upload total, not just per request.
    @Test func overlappingFolderReservationsIncludeEntryOverhead() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let pack = rawPack([(UInt8(ascii: "f"), "a.txt", Data("hi".utf8)), (UInt8(ascii: "e"), "", nil)])
        let needed = 2 * Int64(pack.count) + Int64(DropPack.maxEntries) * TailnetServer.entryOverheadBytes
        s.free.withLock { $0 = (1 << 30) + needed + 4096 } // room for one reservation, not two

        let first = try await rawHTTPConnection(port: s.port)
        defer { first.close() }
        try await first.send(s.request("POST", "/drops?kind=folder&name=one&from=aria",
                                       headers: ["Content-Length: \(pack.count)"]))
        try await first.send(pack.prefix(10))
        #expect(await eventually { s.stagingEntries().count == 1 })

        let second = try await s.send("POST", "/drops?kind=folder&name=two&from=aria", body: pack)
        #expect(second.status == 507)

        try await first.send(pack.dropFirst(10))
        #expect(RawResponse(await first.readToEnd()).status == 201)
        #expect(try await s.send("POST", "/drops?kind=folder&name=three&from=aria", body: pack).status == 201)
    }

    /// Headers and the first chunk of a chunked upload, then nothing.
    private func stalledUpload(_ s: TailnetFixture, name: String) async throws -> RawConnection {
        let connection = try await rawHTTPConnection(port: s.port)
        try await connection.send(s.request("POST", "/drops?kind=file&name=\(name)&from=aria",
                                            headers: ["Transfer-Encoding: chunked"]))
        try await connection.send("5\r\nhello\r\n")
        return connection
    }

    @Test func thirdConcurrentUploadIs503() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let first = try await stalledUpload(s, name: "one.txt")
        let second = try await stalledUpload(s, name: "two.txt")
        #expect(await eventually { s.stagingEntries().count == 2 })

        let third = try await s.send("POST", "/drops?kind=file&name=three.txt&from=aria", body: Data("x".utf8))
        #expect(third.status == 503)
        #expect(third.json["error"] == .string("Agent Drop is busy receiving; retry shortly"))

        for connection in [first, second] {
            try await connection.send("6\r\n world\r\n0\r\n\r\n")
            #expect(RawResponse(await connection.readToEnd()).status == 201)
        }
        let names = try s.store.store.list(ListFilter()).map(\.filename).sorted()
        #expect(names == ["one.txt", "two.txt"])
        #expect(try String(contentsOf: s.store.folder.appendingPathComponent("one.txt"), encoding: .utf8)
            == "hello world")
    }

    @Test func abortedUploadCleansUpAndFreesTheSlot() async throws {
        let s = try await TailnetFixture()
        defer { Task { await s.server.stop() } }
        let first = try await stalledUpload(s, name: "one.txt")
        let second = try await stalledUpload(s, name: "two.txt")
        #expect(await eventually { s.stagingEntries().count == 2 })
        first.close()
        second.close()

        let succeeded = await eventually(timeout: .seconds(2)) {
            let response = try? await s.send("POST", "/drops?kind=file&name=three.txt&from=aria",
                                             body: Data("x".utf8))
            return response?.status == 201
        }
        #expect(succeeded)
        #expect(await eventually(timeout: .seconds(2)) { s.stagingEntries().isEmpty })
        // The cut-off uploads never become (truncated) drops.
        #expect(try s.store.store.list(ListFilter()).map(\.filename) == ["three.txt"])
    }

    /// Senders that go quiet mid-body lose their slots after the idle timeout.
    @Test func stalledUploadsTimeOutAndFreeTheirSlots() async throws {
        let s = try await TailnetFixture(bodyIdleTimeout: .milliseconds(500))
        defer { Task { await s.server.stop() } }
        let first = try await stalledUpload(s, name: "one.txt")
        let second = try await stalledUpload(s, name: "two.txt")
        defer { first.close(); second.close() }
        #expect(await eventually { s.stagingEntries().count == 2 })

        let succeeded = await eventually(timeout: .seconds(3)) {
            let response = try? await s.send("POST", "/drops?kind=file&name=three.txt&from=aria",
                                             body: Data("x".utf8))
            return response?.status == 201
        }
        #expect(succeeded)
        #expect(await eventually(timeout: .seconds(2)) { s.stagingEntries().isEmpty })
        #expect(try s.store.store.list(ListFilter()).map(\.filename) == ["three.txt"])
    }

    /// A sender that never finishes its body can't hold shutdown up past the 2 s grace.
    @Test func stopDoesNotWaitForAStalledUpload() async throws {
        let s = try await TailnetFixture()
        let stalled = try await stalledUpload(s, name: "one.txt")
        defer { stalled.close() }
        #expect(await eventually { s.stagingEntries().count == 1 })

        let stopped = Locked(false)
        Task {
            await s.server.stop()
            stopped.withLock { $0 = true }
        }
        #expect(await eventually(timeout: .seconds(5)) { stopped.value })
        #expect(await eventually(timeout: .seconds(2)) { s.stagingEntries().isEmpty })
        #expect(try s.store.store.list(ListFilter()).isEmpty)
    }
}
