import Foundation
import Testing
@testable import AgentDropServer

struct TailnetKeyTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tailnet-key-\(UUID().uuidString)")
    }

    @Test func createIsStableAndPrivate() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = TailnetKeyFile(configDir: dir)
        let first = try file.create()
        let second = try file.create()
        #expect(first == second)
        #expect(first.count == 64)
        #expect(first.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(file.read() == first)
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func regenerateChangesIt() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = TailnetKeyFile(configDir: dir)
        let first = try file.create()
        let second = try file.regenerate()
        #expect(first != second)
        #expect(file.read() == second)
    }

    @Test func readIsNilWhenAbsent() {
        #expect(TailnetKeyFile(configDir: scratch()).read() == nil)
    }

    @Test func readIsNilWhenMalformed() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = TailnetKeyFile(configDir: dir)
        try PrivateFile.write(Data(#"{"key":"NOT-HEX"}"#.utf8), to: file.url)
        #expect(file.read() == nil)
    }
}
