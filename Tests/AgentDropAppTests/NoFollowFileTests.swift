import Foundation
import Testing
@testable import AgentDropApp

/// Spec §3: links are never followed, also when one is swapped in after a check
/// (Aria's review of PR #3: time-of-check/time-of-use on preview reads).
struct NoFollowFileTests {
    let scratch: Scratch
    let fm = FileManager.default
    var root: URL { scratch.url.appendingPathComponent("AgentDrop", isDirectory: true) }
    var secret: URL { scratch.url.appendingPathComponent("secret.txt") }

    init() throws {
        scratch = try Scratch()
        try fm.createDirectory(at: root.appendingPathComponent("bundle/docs"), withIntermediateDirectories: true)
        try Data("plan".utf8).write(to: root.appendingPathComponent("plan.md"))
        try Data("deep".utf8).write(to: root.appendingPathComponent("bundle/docs/a.md"))
        try Data("SECRET".utf8).write(to: secret)
    }

    func swapForLink(_ relative: String, to target: URL) throws {
        let url = root.appendingPathComponent(relative)
        try fm.removeItem(at: url)
        try fm.createSymbolicLink(at: url, withDestinationURL: target)
    }

    @Test func readsRegularFilesAtAnyDepth() {
        #expect(NoFollowFile.read("plan.md", under: root) == Data("plan".utf8))
        #expect(NoFollowFile.read("bundle/docs/a.md", under: root) == Data("deep".utf8))
        #expect(NoFollowFile.read("bundle/docs/a.md", under: root, maxBytes: 2) == Data("de".utf8))
    }

    @Test func refusesAFileSwappedForALink() throws {
        try swapForLink("plan.md", to: secret)
        #expect(NoFollowFile.read("plan.md", under: root) == nil)
    }

    @Test func refusesADirectorySwappedForALink() throws {
        let elsewhere = scratch.url.appendingPathComponent("elsewhere/docs")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("SECRET".utf8).write(to: elsewhere.appendingPathComponent("a.md"))
        try fm.removeItem(at: root.appendingPathComponent("bundle/docs"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("bundle/docs"), withDestinationURL: elsewhere)
        #expect(NoFollowFile.read("bundle/docs/a.md", under: root) == nil)
    }

    @Test func refusesClimbingAndNonFiles() throws {
        #expect(NoFollowFile.read("../secret.txt", under: root) == nil)
        #expect(NoFollowFile.read("bundle", under: root) == nil)
        #expect(NoFollowFile.read("", under: root) == nil)
        #expect(mkfifo(root.appendingPathComponent("pipe").path, 0o600) == 0)
        #expect(NoFollowFile.read("pipe", under: root) == nil) // never blocks on a FIFO
    }

    @Test func previewResourcesRefuseALinkSwappedInAfterTheCheck() throws {
        let url = URL(string: "agentdrop-preview://root/plan.md")!
        #expect(PreviewResources.file(for: url, root: root) != nil)
        try swapForLink("plan.md", to: secret)
        #expect(PreviewResources.data(for: url, root: root) == nil)
    }

    @Test func sniffingNeverFollowsALink() throws {
        try swapForLink("plan.md", to: secret)
        #expect(!PreviewKind.looksLikeText(root.appendingPathComponent("plan.md")))
    }

    @Test func quickLookGetsAPrivateSnapshotNeverTheLink() throws {
        let snapshot = try #require(NoFollowFile.snapshot("bundle/docs/a.md", under: root))
        #expect(try Data(contentsOf: snapshot) == Data("deep".utf8))
        #expect(snapshot.lastPathComponent == "a.md")
        #expect(!snapshot.path.hasPrefix(root.path))
        let attributes = try fm.attributesOfItem(atPath: snapshot.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        NoFollowFile.discardSnapshot(snapshot)
        #expect(!fm.fileExists(atPath: snapshot.path))

        try swapForLink("plan.md", to: secret)
        #expect(NoFollowFile.snapshot("plan.md", under: root) == nil)
    }

    /// Quick Look retakes its snapshot only when this changes, not on every library reload:
    /// resetting the preview on each reload made PNGs flash while a tailnet upload streamed in.
    @Test func identityIsStableUntilTheFileChanges() throws {
        let first = try #require(NoFollowFile.identity("bundle/docs/a.md", under: root))
        #expect(NoFollowFile.identity("bundle/docs/a.md", under: root) == first)
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("other.png"))
        #expect(NoFollowFile.identity("bundle/docs/a.md", under: root) == first)

        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("bundle/docs/a.md"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("er".utf8)) // in place: same file number
        try handle.close()
        let rewritten = try #require(NoFollowFile.identity("bundle/docs/a.md", under: root))
        #expect(rewritten != first)
        try Data("deeper".utf8).write(to: root.appendingPathComponent("bundle/docs/a.md"), options: .atomic)
        #expect(NoFollowFile.identity("bundle/docs/a.md", under: root) != rewritten) // replaced, same size

        try swapForLink("plan.md", to: secret)
        #expect(NoFollowFile.identity("plan.md", under: root) == nil)
    }
}
