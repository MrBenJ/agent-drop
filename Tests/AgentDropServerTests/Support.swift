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
