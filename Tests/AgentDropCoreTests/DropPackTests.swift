import Foundation
import Testing
@testable import AgentDropCore

/// Builds a raw pack. Type `e` and `d` carry no payload; `f` carries file bytes.
/// A record with a nil path (`e`) writes no path.
func pack(_ records: [(UInt8, String, Data?)]) -> Data {
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

private let D = UInt8(ascii: "d"), F = UInt8(ascii: "f"), E = UInt8(ascii: "e")

struct DropPackTests {
    private func relativeFiles(_ root: URL) throws -> [String] {
        let fm = FileManager.default
        return (fm.subpaths(atPath: root.path) ?? []).sorted()
    }

    private func unpack(_ data: Data, maxBytes: Int64 = 1 << 20) throws -> (TempDir, URL) {
        let dir = try TempDir()
        let packFile = dir.url.appendingPathComponent("in.adpk")
        try data.write(to: packFile)
        let dest = dir.url.appendingPathComponent("out")
        try DropPack.unpack(packFile, into: dest, maxBytes: maxBytes)
        return (dir, dest)
    }

    private func expectMalformed(_ data: Data, maxBytes: Int64 = 1 << 20,
                                 sourceLocation: SourceLocation = #_sourceLocation) throws {
        let dir = try TempDir()
        let packFile = dir.url.appendingPathComponent("in.adpk")
        try data.write(to: packFile)
        let dest = dir.url.appendingPathComponent("out")
        do {
            try DropPack.unpack(packFile, into: dest, maxBytes: maxBytes)
            Issue.record("expected .malformed", sourceLocation: sourceLocation)
        } catch let failure as DropPack.Failure {
            guard case .malformed = failure else {
                Issue.record("expected .malformed, got \(failure)", sourceLocation: sourceLocation)
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path), sourceLocation: sourceLocation)
    }

    @Test func roundTripPreservesTreeAndBytes() throws {
        let src = try TempDir()
        try src.file("a.md", "# hello")
        let random = Data((0..<100_000).map { _ in UInt8.random(in: 0...255) })
        try src.data("sub/b.bin", random)
        try src.file("sub/deeper/c.txt", "deep")

        let work = try TempDir()
        let packFile = work.url.appendingPathComponent("p.adpk")
        try DropPack.write(folder: src.url, to: packFile)
        let dest = work.url.appendingPathComponent("out")
        try DropPack.unpack(packFile, into: dest, maxBytes: 1 << 20)

        #expect(try relativeFiles(dest) == relativeFiles(src.url))
        #expect(try Data(contentsOf: dest.appendingPathComponent("sub/b.bin")) == random)
        #expect(try String(contentsOf: dest.appendingPathComponent("a.md"), encoding: .utf8) == "# hello")
        #expect(try String(contentsOf: dest.appendingPathComponent("sub/deeper/c.txt"), encoding: .utf8) == "deep")
    }

    @Test func emptyFilesAndEmptyFoldersSurvive() throws {
        let src = try TempDir()
        try src.file("empty.txt", "")
        try FileManager.default.createDirectory(at: src.url.appendingPathComponent("hollow"),
                                                withIntermediateDirectories: true)
        let work = try TempDir()
        let packFile = work.url.appendingPathComponent("p.adpk")
        try DropPack.write(folder: src.url, to: packFile)
        let dest = work.url.appendingPathComponent("out")
        try DropPack.unpack(packFile, into: dest, maxBytes: 1 << 20)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("hollow").path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        let empty = dest.appendingPathComponent("empty.txt")
        #expect(FileManager.default.fileExists(atPath: empty.path))
        #expect(try Data(contentsOf: empty).isEmpty)
    }

    @Test func writeRejectsSymlinks() throws {
        let src = try TempDir()
        try src.file("real.txt", "x")
        try FileManager.default.createSymbolicLink(at: src.url.appendingPathComponent("link"),
                                                   withDestinationURL: src.url.appendingPathComponent("real.txt"))
        let work = try TempDir()
        expectError(1) {
            try DropPack.write(folder: src.url, to: work.url.appendingPathComponent("p.adpk"))
        }
    }

    @Test(arguments: ["../escape", "/abs", "a/../b", "a//b", "./a", "", "a\u{0}b"])
    func unpackRejectsBadPaths(_ path: String) throws {
        try expectMalformed(pack([(F, path, Data("x".utf8)), (E, "", nil)]))
    }

    @Test func unpackRejectsOverlongPath() throws {
        let path = String(repeating: "a", count: 4097)
        try expectMalformed(pack([(F, path, Data()), (E, "", nil)]))
    }

    @Test func unpackRejectsUndeclaredParent() throws {
        try expectMalformed(pack([(F, "x/y.txt", Data("x".utf8)), (E, "", nil)]))
    }

    @Test func unpackRejectsDuplicates() throws {
        try expectMalformed(pack([(F, "a.txt", Data()), (F, "a.txt", Data()), (E, "", nil)]))
        try expectMalformed(pack([(D, "x", nil), (F, "x", Data()), (E, "", nil)]))
    }

    @Test func unpackRejectsBadMagic() throws {
        var data = pack([(E, "", nil)])
        data[0] = UInt8(ascii: "X")
        try expectMalformed(data)
    }

    @Test func unpackRejectsTruncation() throws {
        let data = pack([(F, "a.txt", Data("hello".utf8)), (E, "", nil)])
        try expectMalformed(data.dropLast(3))
    }

    @Test func unpackRejectsMissingEnd() throws {
        try expectMalformed(pack([(F, "a.txt", Data("hello".utf8))]))
    }

    @Test func unpackRejectsTrailingBytes() throws {
        var data = pack([(F, "a.txt", Data("hello".utf8)), (E, "", nil)])
        data.append(0)
        try expectMalformed(data)
    }

    @Test func unpackRejectsUnknownType() throws {
        try expectMalformed(pack([(UInt8(ascii: "l"), "a", nil), (E, "", nil)]))
    }

    @Test func unpackEnforcesLimit() throws {
        let data = pack([(F, "a", Data(repeating: 1, count: 600)),
                         (F, "b", Data(repeating: 2, count: 600)),
                         (E, "", nil)])
        let dir = try TempDir()
        let packFile = dir.url.appendingPathComponent("in.adpk")
        try data.write(to: packFile)
        let dest = dir.url.appendingPathComponent("out")
        #expect(throws: DropPack.Failure.tooLarge(limit: 1000)) {
            try DropPack.unpack(packFile, into: dest, maxBytes: 1000)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func unpackAcceptsDeclaredParents() throws {
        let (dir, dest) = try unpack(pack([(D, "x", nil), (F, "x/y.txt", Data("hi".utf8)), (E, "", nil)]))
        _ = dir
        #expect(try String(contentsOf: dest.appendingPathComponent("x/y.txt"), encoding: .utf8) == "hi")
    }
}
