import Foundation
import Testing
@testable import AgentDropCore

struct PinnedFileTests {
    @Test func snapshotCopiesTheFileIntoAPrivateDirectory() throws {
        let src = try TempDir()
        let file = try src.file("report.md", "# Report\n")
        let work = try TempDir()
        let snapshot = try PinnedFile.snapshot(of: file, into: work.url)
        #expect(try Data(contentsOf: snapshot) == Data("# Report\n".utf8))
        let fm = FileManager.default
        let dirMode = try fm.attributesOfItem(atPath: snapshot.deletingLastPathComponent().path)[.posixPermissions]
        let fileMode = try fm.attributesOfItem(atPath: snapshot.path)[.posixPermissions]
        #expect(dirMode as? Int == 0o700)
        #expect(fileMode as? Int == 0o600)
        #expect(snapshot.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == work.url.standardizedFileURL.path)
    }

    @Test func snapshotCopiesEmptyAndMultiChunkFiles() throws {
        let src = try TempDir()
        let work = try TempDir()
        let empty = try src.data("empty.txt", Data())
        #expect(try Data(contentsOf: PinnedFile.snapshot(of: empty, into: work.url)).isEmpty)
        let big = Data((0..<(200 * 1024)).map { UInt8($0 % 251) })
        let bigFile = try src.data("big.bin", big)
        #expect(try Data(contentsOf: PinnedFile.snapshot(of: bigFile, into: work.url)) == big)
    }

    @Test func snapshotRejectsSymlinksAndDirectories() throws {
        let src = try TempDir()
        let real = try src.file("real.txt", "x")
        let link = src.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let work = try TempDir()
        expectError(1) { _ = try PinnedFile.snapshot(of: link, into: work.url) }
        expectError(1) { _ = try PinnedFile.snapshot(of: src.url, into: work.url) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.url.path).isEmpty)
    }

    @Test func snapshotFollowsASymlinkedParentTheUserChose() throws {
        let real = try TempDir()
        try real.file("a.txt", "via parent link")
        let links = try TempDir()
        let parentLink = links.url.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: real.url)
        let work = try TempDir()
        let snapshot = try PinnedFile.snapshot(of: parentLink.appendingPathComponent("a.txt"), into: work.url)
        #expect(try String(contentsOf: snapshot, encoding: .utf8) == "via parent link")
    }

    /// Snapshots `file` while `swap` runs after it is checked; the secret must never be copied.
    private func expectSecretNotCopied(_ file: URL, secret: Data, swap: @escaping (URL) -> Void,
                                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        let work = try TempDir()
        let snapshot: URL
        do {
            snapshot = try PinnedFile.snapshot(of: file, into: work.url, afterCheck: swap)
        } catch let error as AgentDropError {
            #expect(error.exitCode == 1, "message: \(error.message)", sourceLocation: sourceLocation)
            #expect(try FileManager.default.contentsOfDirectory(atPath: work.url.path).isEmpty,
                    "a failed snapshot leaves nothing behind", sourceLocation: sourceLocation)
            return
        }
        #expect(try Data(contentsOf: snapshot).range(of: secret) == nil, "snapshot contains the outside secret",
                sourceLocation: sourceLocation)
    }

    @Test func snapshotDoesNotFollowFileSwappedForSymlink() throws {
        let outside = try TempDir()
        let secret = Data("TOP-SECRET-FILE-BYTES".utf8)
        let target = try outside.data("secret.txt", secret)
        let src = try TempDir()
        // Same length as the secret, so a size-bounded read through the link would copy all of it.
        let file = try src.data("a.txt", Data(repeating: UInt8(ascii: "o"), count: secret.count))
        let work = try TempDir()
        let message = expectError(1) {
            _ = try PinnedFile.snapshot(of: file, into: work.url) { url in
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            }
        }
        #expect(message?.contains("a.txt") == true)
        try expectSecretNotCopied(file, secret: secret) { url in
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        }
    }

    @Test func snapshotDoesNotFollowFileReplacedByAnotherFile() throws {
        let src = try TempDir()
        let secret = Data("TOP-SECRET-REPLACED".utf8)
        let file = try src.data("a.txt", Data(repeating: UInt8(ascii: "o"), count: secret.count))
        try expectSecretNotCopied(file, secret: secret) { url in
            try? FileManager.default.removeItem(at: url)
            try? secret.write(to: url)
        }
    }

    @Test func snapshotDoesNotFollowParentSwappedForSymlink() throws {
        let outside = try TempDir()
        let secret = Data("TOP-SECRET-PARENT-BYTES".utf8)
        try outside.data("a.txt", secret)
        let src = try TempDir()
        let file = try src.data("sub/a.txt", Data(repeating: UInt8(ascii: "o"), count: secret.count))
        try expectSecretNotCopied(file, secret: secret) { url in
            let fm = FileManager.default
            let parent = url.deletingLastPathComponent()
            try? fm.moveItem(at: parent, to: parent.deletingLastPathComponent().appendingPathComponent("sub-moved"))
            try? fm.createSymbolicLink(at: parent, withDestinationURL: outside.url)
        }
    }
}
