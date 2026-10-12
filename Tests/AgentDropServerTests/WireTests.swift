import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

struct ServerInfoTests {
    @Test func runningAndNoPortShapes() throws {
        let running = String(decoding: try ServerInfo.running(port: 47390, token: "t", pid: 42).encoded(), as: UTF8.self)
        #expect(running == #"{"pid":42,"port":47390,"status":"running","token":"t"}"#)
        let noPort = String(decoding: try ServerInfo.noPort(pid: 42).encoded(), as: UTF8.self)
        #expect(noPort == #"{"pid":42,"status":"no-port"}"#)
    }

    @Test func writeIsPrivateAndAtomicAndRemovable() throws {
        let tmp = try ScratchDir()
        let file = ServerInfoFile(configDir: tmp.url.appendingPathComponent("support"))
        #expect(file.read() == nil)
        try file.write(.running(port: 1, token: "a", pid: 7))
        try file.write(.running(port: 2, token: "b", pid: 7))
        #expect(file.read() == .running(port: 2, token: "b", pid: 7))
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.url.deletingLastPathComponent().path)
        #expect(leftovers == ["server.json"])
        file.remove()
        #expect(file.read() == nil)
    }

    @Test func unreadableFileReadsAsAbsent() throws {
        let tmp = try ScratchDir()
        let file = ServerInfoFile(configDir: tmp.url)
        try Data("not json".utf8).write(to: file.url)
        #expect(file.read() == nil)
    }

    @Test func processLiveness() {
        #expect(ServerInfo.isProcessAlive(getpid()))
        #expect(!ServerInfo.isProcessAlive(0))
        #expect(!ServerInfo.isProcessAlive(Int32.max))
    }

    @Test func tokensAreLongAndFresh() {
        let a = ServerInfo.newToken(), b = ServerInfo.newToken()
        #expect(a.count == 64)
        #expect(a != b)
    }
}

struct SSETests {
    @Test func frameFormat() {
        #expect(SSE.frame(id: "s:3", event: "status", data: #"{"a":1}"#) == "id: s:3\nevent: status\ndata: {\"a\":1}\n\n")
        #expect(SSE.comment("keepalive") == ": keepalive\n\n")
    }

    @Test func parserHandlesCommentsCRLFAndMultipleFrames() {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        let text = ": connected\n\nid: s:1\r\nevent: created\ndata: {}\n\nid: s:2\nevent: status\ndata: {\"x\":\ndata: 1}\n\n"
        for byte in Array(text.utf8) {
            if let event = parser.feed(byte: byte) { events.append(event) }
        }
        #expect(events == [SSEEvent(id: "s:1", event: "created", data: "{}"),
                           SSEEvent(id: "s:2", event: "status", data: "{\"x\":\n1}")])
    }

    @Test func eventMessageEmbedsDataAsJSON() throws {
        let stored = StoredEventFixture.make(seq: 9, type: .status, data: #"{"from":"open","to":"claimed"}"#)
        let message = EventMessage(storeID: "st", event: stored)
        #expect(message.jsonString() ==
            #"{"at":"2025-10-09T08:53:20Z","data":{"from":"open","to":"claimed"},"dropId":"abcdef","seq":9,"storeId":"st","type":"status"}"#)
        let decoded = try JSONDecoder().decode(EventMessage.self, from: Data(message.jsonString().utf8))
        #expect(decoded == message)
    }
}

struct EventCursorTests {
    @Test func parsesStoreAndSeq() {
        #expect(EventCursor(lastEventID: "abc123:42") == EventCursor(storeID: "abc123", seq: 42))
        #expect(EventCursor(lastEventID: "a:b:7") == EventCursor(storeID: "a:b", seq: 7))
    }

    @Test(arguments: ["", "abc", ":4", "abc:", "abc:-1", "abc:x", "abc:1.5"])
    func rejectsMalformed(_ raw: String) {
        #expect(EventCursor(lastEventID: raw) == nil)
    }

    @Test func idString() {
        #expect(EventCursor(storeID: "s", seq: 3).id == "s:3")
    }
}

struct EventFilterTests {
    typealias E = StoredEventFixture

    @Test func allAndDrop() {
        let e = E.make(dropID: "aaaaaa")
        #expect(EventFilter.all.matches(e))
        #expect(EventFilter.drop("aaaaaa").matches(e))
        #expect(!EventFilter.drop("bbbbbb").matches(e))
    }

    @Test func inboxDeliversArrivalsOnly() {
        let inbox = EventFilter.inbox(project: nil)
        #expect(inbox.matches(E.make(inboxBefore: false, inboxAfter: true)))
        #expect(!inbox.matches(E.make(inboxBefore: true, inboxAfter: true)))   // still there
        #expect(!inbox.matches(E.make(inboxBefore: true, inboxAfter: false)))  // departure
        #expect(!inbox.matches(E.make(inboxBefore: false, inboxAfter: false)))
    }

    @Test func projectScopedInboxCountsAProjectMoveAsAnArrival() {
        let scoped = EventFilter.inbox(project: "app")
        #expect(scoped.matches(E.make(inboxBefore: false, inboxAfter: true, projectAfter: "app")))
        #expect(!scoped.matches(E.make(inboxBefore: false, inboxAfter: true, projectAfter: "other")))
        #expect(!scoped.matches(E.make(inboxBefore: false, inboxAfter: true, projectAfter: nil)))
        // In the global Inbox already, but it just moved into "app": an arrival for "app".
        #expect(scoped.matches(E.make(inboxBefore: true, inboxAfter: true, projectBefore: "other", projectAfter: "app")))
        #expect(!scoped.matches(E.make(inboxBefore: true, inboxAfter: true, projectBefore: "app", projectAfter: "app")))
    }
}
