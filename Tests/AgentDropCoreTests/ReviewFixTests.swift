import Foundation
import Testing
@testable import AgentDropCore

/// Regressions from the PR #1 review.
struct ReviewFixTests {
    let fm = FileManager.default

    struct InjectedFailure: Error {}

    /// On a case- or normalization-insensitive filesystem, a new entry whose name only
    /// differs in spelling must not make a missing drop's record look present again.
    @Test(arguments: [("Plan.md", "plan.md"), ("caf\u{e9}.md", "cafe\u{301}.md")])
    func spellingAliasDoesNotRestoreMissingDrop(_ names: (String, String)) throws {
        let f = try Fixture()
        let old = try f.add(names.0, "# Old\n")
        try fm.removeItem(at: f.store.path(of: old))
        #expect(try f.store.resolve(old.id).missing)

        let new = try f.add(names.1, "# New\n")
        #expect(try f.store.resolve(old.id).missing)
        #expect(try f.store.resolve(new.id).missing == false)
    }

    /// A slow copy must not block other agents' writes (spec §3: busy timeout 5 s).
    @Test func copyingDoesNotHoldTheWriteLock() throws {
        let f = try Fixture()
        let handoff = try f.add("handoff.md", handoff: true)
        let claimer = try DropStore.open(folder: f.folder, retention: .default)
        let claimResult = Locked<Result<Drop, Error>?>(nil)
        let copier = try DropStore.open(folder: f.folder, retention: .default, now: { Date() },
                                        hooks: StoreHooks(afterStaging: {
            claimResult.withLock { $0 = Result { try claimer.claim(handoff.id, by: "b") } }
        }))
        _ = try copier.add(AddRequest(source: .path(try f.outside("big.md")), from: "a"))
        #expect(try claimResult.value?.get().status == .claimed)
    }

    @Test func failedRegistrationMovesTheSourceBack() throws {
        let f = try Fixture()
        let source = try f.outside("moved.md", "mine")
        let store = try DropStore.open(folder: f.folder, retention: .default, now: { Date() },
                                       hooks: StoreHooks(beforeInsert: { throw InjectedFailure() }))
        #expect(throws: InjectedFailure.self) {
            _ = try store.add(AddRequest(source: .path(source), from: "a", move: true))
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "mine")
        #expect(!fm.fileExists(atPath: f.folder.appendingPathComponent("moved.md").path))
        #expect(try f.store.events().isEmpty)
    }

    @Test func failedRegistrationUndoesTheInPlaceRename() throws {
        let f = try Fixture()
        let entry = f.folder.appendingPathComponent("raw.md")
        try Data("mine".utf8).write(to: entry)
        let store = try DropStore.open(folder: f.folder, retention: .default, now: { Date() },
                                       hooks: StoreHooks(beforeInsert: { throw InjectedFailure() }))
        #expect(throws: InjectedFailure.self) {
            _ = try store.add(AddRequest(source: .path(entry), name: "nice.md", from: "a"))
        }
        #expect(try String(contentsOf: entry, encoding: .utf8) == "mine")
        #expect(!fm.fileExists(atPath: f.folder.appendingPathComponent("nice.md").path))
    }

    /// Links inside a folder drop are kept as links and never followed (spec §3).
    @Test(arguments: [false, true])
    func nestedSymlinksAreCopiedAsLinks(move: Bool) throws {
        let f = try Fixture()
        try f.tmp.file("outside/secret.txt", "do not copy")
        let bundle = try f.tmp.file("outside/bundle/README.md", "# Bundle\n").deletingLastPathComponent()
        try fm.createSymbolicLink(atPath: bundle.appendingPathComponent("link").path,
                                  withDestinationPath: "../secret.txt")
        let drop = try f.store.add(AddRequest(source: .path(bundle), from: "a", move: move))
        let link = f.store.path(of: drop).appendingPathComponent("link").path
        #expect(try fm.attributesOfItem(atPath: link)[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try fm.destinationOfSymbolicLink(atPath: link) == "../secret.txt")
    }
}
