import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

final class ScratchDir: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdrop-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

enum StoredEventFixture {
    static func make(seq: Int64 = 1, type: EventType = .created, dropID: String = "abcdef", data: String = "{}",
                     inboxBefore: Bool = false, inboxAfter: Bool = false,
                     projectBefore: String? = nil, projectAfter: String? = nil) -> StoredEvent {
        StoredEvent(seq: seq, type: type, dropID: dropID, at: Date(timeIntervalSince1970: 1_760_000_000), data: data,
                    inboxBefore: inboxBefore, inboxAfter: inboxAfter,
                    projectBefore: projectBefore, projectAfter: projectAfter)
    }
}

/// A real store in a scratch folder.
struct StoreFixture {
    let dir: ScratchDir
    let folder: URL
    let store: DropStore

    init(retention: Retention = .default) throws {
        dir = try ScratchDir()
        folder = dir.url.appendingPathComponent("AgentDrop", isDirectory: true)
        store = try DropStore.open(folder: folder, retention: retention)
    }

    @discardableResult
    func add(_ name: String = "plan.md", _ contents: String = "# Plan\n", project: String? = nil,
             handoff: Bool = false) throws -> Drop {
        let source = dir.url.appendingPathComponent("src-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: source)
        return try store.add(AddRequest(source: .path(source), project: project, from: "tester", handoff: handoff))
    }
}

/// Reads up to `count` frames, giving up after `timeout`.
func collect(_ stream: AsyncStream<EventHub.Frame>, count: Int,
             timeout: Duration = .seconds(5)) async -> [EventHub.Frame] {
    await withTaskGroup(of: [EventHub.Frame]?.self) { group in
        group.addTask {
            var frames: [EventHub.Frame] = []
            for await frame in stream {
                frames.append(frame)
                if frames.count == count { break }
            }
            return frames
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next()!
        group.cancelAll()
        return first ?? []
    }
}

extension EventHub.Frame {
    var message: EventMessage? {
        if case .event(let m) = self { return m }
        return nil
    }
}
