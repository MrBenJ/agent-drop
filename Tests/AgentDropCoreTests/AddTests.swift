import Foundation
import Testing
@testable import AgentDropCore

struct AddTests {
    let fm = FileManager.default

    @Test(arguments: [("case.md", "CASE.md"), ("caf\u{e9}.md", "cafe\u{301}.md")])
    func caseVariantOfRegisteredEntryIsStillAConflict(_ names: (String, String)) throws {
        let f = try Fixture()
        let drop = try f.add(names.0)
        let alias = f.folder.appendingPathComponent(names.1)
        // This alias exists only on a case-insensitive filesystem.
        guard fm.fileExists(atPath: alias.path) else { return }
        expectError(3) { _ = try f.store.add(AddRequest(source: .path(alias), from: "second")) }
        #expect(try f.store.list(ListFilter()).map(\.id) == [drop.id])
    }

    @Test func failedFolderCopyLeavesNoPartialDrop() throws {
        let f = try Fixture()
        let unreadable = try f.tmp.file("outside/broken/no-read.txt", "private")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        do {
            _ = try f.store.add(AddRequest(source: .path(unreadable.deletingLastPathComponent()), from: "a"))
            Issue.record("expected unreadable file to fail copying")
        } catch {}
        #expect(!fm.fileExists(atPath: f.folder.appendingPathComponent("broken").path))
        #expect(try f.store.events().isEmpty)
    }

    @Test func concurrentInPlaceRegistrationCannotLoseCopiedFile() throws {
        let f = try Fixture()
        let source = try f.outside("race.md", "keep this content")
        let placed = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let registrationFinished = DispatchSemaphore(value: 0)
        let successes = Locked<[Drop]>([])
        let copier = try DropStore.open(folder: f.folder, retention: .default, now: {
            placed.signal()
            _ = resume.wait(timeout: .now() + 10)
            return Date()
        })
        let registrar = try DropStore.open(folder: f.folder, retention: .default)
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do {
                let drop = try copier.add(AddRequest(source: .path(source), from: "copier"))
                successes.withLock { $0.append(drop) }
            } catch let error as AgentDropError where error.exitCode == 3 {} catch {
                Issue.record("unexpected copy error: \(error)")
            }
        }
        #expect(placed.wait(timeout: .now() + 5) == .success)
        finished.enter()
        DispatchQueue.global().async {
            defer { registrationFinished.signal(); finished.leave() }
            do {
                let drop = try registrar.add(AddRequest(
                    source: .path(f.folder.appendingPathComponent("race.md")), from: "registrar"))
                successes.withLock { $0.append(drop) }
            } catch let error as AgentDropError where error.exitCode == 3 {} catch {
                Issue.record("unexpected registration error: \(error)")
            }
        }
        // A competing registrar either finishes or waits on the store's write lock.
        _ = registrationFinished.wait(timeout: .now() + 0.2)
        resume.signal()
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(successes.value.count == 1)
        #expect(try String(contentsOf: f.folder.appendingPathComponent("race.md"), encoding: .utf8) == "keep this content")
        #expect(try f.store.events().count == 1)
    }

    @Test func copiesFileRegistersAndEmitsCreated() throws {
        let f = try Fixture()
        let src = try f.outside("auth-plan.md", "intro\n# Auth refactor plan\nbody")
        let drop = try f.store.add(AddRequest(source: .path(src), description: "Codex should implement",
                                              project: "courses-app", tags: ["spec", "spec", "PR"],
                                              from: "djleague/build-feature-x", handoff: true))
        #expect(DropID.isWellFormed(drop.id))
        #expect(drop.filename == "auth-plan.md")
        #expect(drop.title == "Auth refactor plan")
        #expect(drop.tags == ["spec", "PR"])
        #expect(drop.kind == .handoff && drop.status == .open)
        #expect(fm.fileExists(atPath: src.path), "copy, not move")
        #expect(fm.fileExists(atPath: f.folder.appendingPathComponent("auth-plan.md").path))
        let events = try f.store.events()
        #expect(events.map(\.type) == [.created])
        #expect(events[0].inboxBefore == false && events[0].inboxAfter == true)
        #expect(events[0].projectAfter == "courses-app")
    }

    @Test func titleFallsBackToFilenameWithoutExtension() throws {
        let f = try Fixture()
        #expect(try f.add("notes.txt", "# not markdown").title == "notes")
        #expect(try f.add("empty.md", "no heading").title == "empty")
        let explicit = try f.store.add(AddRequest(source: .path(f.outside("x.md")), title: "  Given  ", from: "t"))
        #expect(explicit.title == "Given")
    }

    @Test func folderDropCopiesRecursivelyAndTitlesFromReadme() throws {
        let f = try Fixture()
        try f.tmp.file("outside/bundle/README.md", "# Handoff bundle\n")
        try f.tmp.file("outside/bundle/shots/a.png", "png")
        let drop = try f.store.add(AddRequest(source: .path(f.tmp.url.appendingPathComponent("outside/bundle/")),
                                              from: "t"))
        #expect(drop.isFolder && drop.filename == "bundle" && drop.title == "Handoff bundle")
        #expect(fm.fileExists(atPath: f.folder.appendingPathComponent("bundle/shots/a.png").path))
    }

    @Test func folderTitleUsesFirstMarkdownAlphabeticallyWithoutReadme() throws {
        let f = try Fixture()
        try f.tmp.file("outside/b2/zeta.md", "# Zeta")
        try f.tmp.file("outside/b2/alpha.md", "# Alpha")
        let drop = try f.store.add(AddRequest(source: .path(f.tmp.url.appendingPathComponent("outside/b2")), from: "t"))
        #expect(drop.title == "Alpha")
    }

    @Test func collisionGetsSuffix() throws {
        let f = try Fixture()
        #expect(try f.add("plan.md").filename == "plan.md")
        #expect(try f.add("plan.md").filename == "plan-2.md")
        #expect(try f.add("plan.md").filename == "plan-3.md")
    }

    @Test func concurrentAddsOfSameNameBothSucceed() throws {
        let f = try Fixture()
        let sources = try (0..<8).map { try f.tmp.file("src\($0)/plan.md", "# P\($0)") }
        let results = Locked<[String]>([])
        DispatchQueue.concurrentPerform(iterations: sources.count) { i in
            // Separate DropStore per "agent", as separate processes would have.
            let store = try! DropStore.open(folder: f.folder, retention: .default)
            let drop = try! store.add(AddRequest(source: .path(sources[i]), from: "agent\(i)"))
            results.withLock { $0.append(drop.filename) }
        }
        let names = results.value
        #expect(Set(names).count == 8)
        #expect(names.contains("plan.md") && names.contains("plan-8.md"))
    }

    @Test func stdinRequiresNameAndContent() throws {
        let f = try Fixture()
        let drop = try f.store.add(AddRequest(source: .stdin(Data("# From stdin".utf8)), name: "notes.md", from: "t"))
        #expect(drop.filename == "notes.md" && drop.title == "From stdin")
        expectError(1) { _ = try f.store.add(AddRequest(source: .stdin(Data("x".utf8)), from: "t")) }
        expectError(1) { _ = try f.store.add(AddRequest(source: .stdin(Data()), name: "e.md", from: "t")) }
        expectError(1) { _ = try f.store.add(AddRequest(source: .stdin(Data("x".utf8)), name: ".hidden", from: "t")) }
    }

    @Test func moveRemovesSource() throws {
        let f = try Fixture()
        let src = try f.outside("moved.md")
        _ = try f.store.add(AddRequest(source: .path(src), from: "t", move: true))
        #expect(!fm.fileExists(atPath: src.path))
        #expect(fm.fileExists(atPath: f.folder.appendingPathComponent("moved.md").path))
    }

    @Test func nameOverridesAndHiddenSourceNeedsName() throws {
        let f = try Fixture()
        let hidden = try f.outside(".notes.md")
        expectError(1) { _ = try f.store.add(AddRequest(source: .path(hidden), from: "t")) }
        let drop = try f.store.add(AddRequest(source: .path(hidden), name: "notes.md", from: "t"))
        #expect(drop.filename == "notes.md")
    }

    @Test func inPlaceRegistrationAndRename() throws {
        let f = try Fixture()
        let inside = try f.tmp.file("AgentDrop/loose.md", "# Loose")
        let drop = try f.store.add(AddRequest(source: .path(inside), from: "t"))
        #expect(drop.filename == "loose.md")
        expectError(3) { _ = try f.store.add(AddRequest(source: .path(inside), from: "t")) }

        let other = try f.tmp.file("AgentDrop/other.md", "x")
        try f.tmp.file("AgentDrop/taken.md", "x")
        expectError(3) { _ = try f.store.add(AddRequest(source: .path(other), name: "taken.md", from: "t")) }
        let renamed = try f.store.add(AddRequest(source: .path(other), name: "renamed.md", from: "t"))
        #expect(renamed.filename == "renamed.md")
        #expect(!fm.fileExists(atPath: other.path))
    }

    @Test func rejectsSubfolderDotfileSymlinkMissingAndTheFolderItself() throws {
        let f = try Fixture()
        let nested = try f.tmp.file("AgentDrop/bundle/inner.md", "x")
        expectError(1) { _ = try f.store.add(AddRequest(source: .path(nested), from: "t")) }
        let dot = try f.tmp.file("AgentDrop/.secret", "x")
        expectError(1) { _ = try f.store.add(AddRequest(source: .path(dot), from: "t")) }
        let target = try f.outside("real.md")
        let link = f.tmp.url.appendingPathComponent("outside/link.md")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        expectError(1) { _ = try f.store.add(AddRequest(source: .path(link), from: "t")) }
        expectError(2) { _ = try f.store.add(AddRequest(source: .path(f.tmp.url.appendingPathComponent("nope.md")), from: "t")) }
        expectError(1) { _ = try f.store.add(AddRequest(source: .path(f.folder), from: "t")) }
        expectError(1) { _ = try f.store.add(AddRequest(source: .path(f.tmp.url), from: "t")) }
    }

    @Test func invalidIdentityRejectedBeforeAnyCopy() throws {
        let f = try Fixture()
        let src = try f.outside("p.md")
        expectError(1) { _ = try f.store.add(AddRequest(source: .path(src), from: "  ")) }
        expectError(1) { _ = try f.store.add(AddRequest(source: .path(src), project: "a\nb", from: "t")) }
        #expect(!fm.fileExists(atPath: f.folder.appendingPathComponent("p.md").path))
    }

    // MARK: staged source

    private func stagedFile(_ f: Fixture, _ contents: String = "# Hello\n") throws -> URL {
        let url = try f.store.makeStagingDirectory().appendingPathComponent("content")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func stagedFileIsPlacedLikeACopy() throws {
        let f = try Fixture()
        let url = try stagedFile(f, "# Hello\n")
        let drop = try f.store.add(AddRequest(source: .staged(url, isFolder: false), name: "plan.md", from: "aria"))
        #expect(drop.filename == "plan.md")
        #expect(drop.title == "Hello")
        #expect(fm.fileExists(atPath: f.folder.appendingPathComponent("plan.md").path))
        #expect(try f.store.events().filter { $0.type == .created }.count == 1)
    }

    @Test func stagedFolderWorks() throws {
        let f = try Fixture()
        let dir = try f.store.makeStagingDirectory().appendingPathComponent("content", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("# Inside\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        let drop = try f.store.add(AddRequest(source: .staged(dir, isFolder: true), name: "bundle", from: "aria"))
        #expect(drop.isFolder)
        #expect(drop.filename == "bundle")
        #expect(fm.fileExists(atPath: f.folder.appendingPathComponent("bundle/README.md").path))
    }

    @Test func stagedNameCollisionGetsSuffix() throws {
        let f = try Fixture()
        try f.add("plan.md")
        let url = try stagedFile(f)
        let drop = try f.store.add(AddRequest(source: .staged(url, isFolder: false), name: "plan.md", from: "aria"))
        #expect(drop.filename == "plan-2.md")
    }

    @Test func stagedOutsideStagingIsRejected() throws {
        let f = try Fixture()
        let outside = try f.outside("x.md")
        expectError(1) { _ = try f.store.add(AddRequest(source: .staged(outside, isFolder: false), name: "x.md", from: "a")) }
        #expect(fm.fileExists(atPath: outside.path))
    }

    @Test func stagedWithoutNameIsRejected() throws {
        let f = try Fixture()
        let url = try stagedFile(f)
        expectError(1) { _ = try f.store.add(AddRequest(source: .staged(url, isFolder: false), from: "a")) }
    }

    @Test func stagedWithMoveIsRejected() throws {
        let f = try Fixture()
        let url = try stagedFile(f)
        expectError(1) {
            _ = try f.store.add(AddRequest(source: .staged(url, isFolder: false), name: "p.md", from: "a", move: true))
        }
    }
}
