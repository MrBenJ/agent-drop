import Foundation
import Testing
@testable import AgentDropApp

/// Quick Look's snapshot is retaken only when the file changes: resetting it on every
/// library reload made PNGs flash while a tailnet upload streamed in (PR #12).
struct QuickLookSnapshotTests {
    let scratch: Scratch
    let fm = FileManager.default
    var root: URL { scratch.url.appendingPathComponent("AgentDrop", isDirectory: true) }

    init() throws {
        scratch = try Scratch()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: root.appendingPathComponent("shot.png"))
    }

    @Test func anUnchangedFileIsNeverReset() throws {
        let snapshot = QuickLookSnapshot()
        defer { snapshot.discard() }
        let first = try #require(snapshot.update("shot.png", under: root)?.url)
        try Data("other".utf8).write(to: root.appendingPathComponent("other.png"))
        #expect(snapshot.update("shot.png", under: root) == nil)
        #expect(snapshot.url == first)
    }

    @Test func aChangedFileIsRetakenAndTheOldCopyHandedBack() throws {
        let snapshot = QuickLookSnapshot()
        defer { snapshot.discard() }
        let first = try #require(snapshot.update("shot.png", under: root)?.url)
        try Data("new png".utf8).write(to: root.appendingPathComponent("shot.png"), options: .atomic)
        let change = try #require(snapshot.update("shot.png", under: root))
        #expect(change.previous == first)
        let second = try #require(change.url)
        #expect(second != first)
        #expect(try Data(contentsOf: second) == Data("new png".utf8))
    }

    /// Aria's review of PR #12: a same-size rewrite that restores the modification time
    /// (a timestamp-preserving copy or sync) is still a change.
    @Test func aRewriteThatRestoresTheModificationTimeIsRetaken() throws {
        let file = root.appendingPathComponent("shot.png")
        let snapshot = QuickLookSnapshot()
        defer { snapshot.discard() }
        let first = try #require(snapshot.update("shot.png", under: root)?.url)
        var before = stat()
        #expect(stat(file.path, &before) == 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("PNG".utf8)) // in place, same size
        try handle.close()
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), before.st_mtimespec]
        #expect(utimensat(AT_FDCWD, file.path, &times, 0) == 0)
        var after = stat()
        #expect(stat(file.path, &after) == 0)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
            && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec && after.st_size == before.st_size)
        let change = try #require(snapshot.update("shot.png", under: root))
        #expect(change.previous == first)
        #expect(try Data(contentsOf: try #require(change.url)) == Data("PNG".utf8))
    }

    /// Aria's review of PR #12: a failed snapshot of an unchanged file must be retried.
    @Test func aFailedSnapshotIsRetriedWhileTheFileIsUnchanged() throws {
        var failing = true
        let snapshot = QuickLookSnapshot { path, root in failing ? nil : NoFollowFile.snapshot(path, under: root) }
        defer { snapshot.discard() }
        #expect(snapshot.update("shot.png", under: root) == nil)
        #expect(snapshot.url == nil)
        failing = false
        let recovered = try #require(snapshot.update("shot.png", under: root)?.url)
        #expect(try Data(contentsOf: recovered) == Data("png".utf8))
        #expect(snapshot.update("shot.png", under: root) == nil)
    }

    @Test func aFailureAfterASnapshotClearsItThenRecovers() throws {
        var failing = false
        let snapshot = QuickLookSnapshot { path, root in failing ? nil : NoFollowFile.snapshot(path, under: root) }
        defer { snapshot.discard() }
        let first = try #require(snapshot.update("shot.png", under: root)?.url)
        failing = true
        try Data("new png".utf8).write(to: root.appendingPathComponent("shot.png"), options: .atomic)
        #expect(snapshot.update("shot.png", under: root) == QuickLookSnapshot.Change(url: nil, previous: first))
        failing = false
        #expect(snapshot.update("shot.png", under: root)?.url != nil)
    }

    @Test func aLinkIsRefusedAndNotRetriedUntilItChanges() throws {
        let secret = scratch.url.appendingPathComponent("secret.png")
        try Data("SECRET".utf8).write(to: secret)
        try fm.removeItem(at: root.appendingPathComponent("shot.png"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("shot.png"), withDestinationURL: secret)
        var takes = 0
        let snapshot = QuickLookSnapshot { path, root in
            takes += 1
            return NoFollowFile.snapshot(path, under: root)
        }
        #expect(snapshot.update("shot.png", under: root) == nil)
        #expect(snapshot.update("shot.png", under: root) == nil)
        #expect(snapshot.url == nil)
        #expect(takes == 1)
    }
}
