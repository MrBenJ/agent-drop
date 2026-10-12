import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return try await condition()
}

struct FolderWatcherTests {
    @Test func classifiesPaths() {
        let root = "/private/var/x/AgentDrop"
        #expect(FolderWatcher.classify(path: root + "/plan.md", root: root) == .entry("plan.md"))
        #expect(FolderWatcher.classify(path: root + "/bundle/deep/file.txt", root: root) == .entry("bundle"))
        #expect(FolderWatcher.classify(path: root + "/.agentdrop/index.sqlite-wal", root: root) == .store)
        #expect(FolderWatcher.classify(path: root + "/.DS_Store", root: root) == nil)
        #expect(FolderWatcher.classify(path: root, root: root) == nil)
        #expect(FolderWatcher.classify(path: "/private/var/x/AgentDropOther/a", root: root) == nil)
    }

    /// Review Focus: temp folders live under /var, a symlink to /private/var. FSEvents
    /// reports real paths, so the watcher must compare against the real root.
    @Test func reportsTopLevelEntriesAndStoreChangesFromRealFSEvents() async throws {
        let dir = try ScratchDir()
        let folder = dir.url.appendingPathComponent("AgentDrop", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".agentdrop/x"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bundle"), withIntermediateDirectories: true)
        let seen = Locked<[FolderWatcher.Change]>([])
        let watcher = FolderWatcher(folder: folder) { changes in seen.withLock { $0 += changes } }
        try watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))

        try Data("a".utf8).write(to: folder.appendingPathComponent("plan.md"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("bundle/inner.txt"))
        try Data("c".utf8).write(to: folder.appendingPathComponent(".agentdrop/x/y"))
        try Data("d".utf8).write(to: folder.appendingPathComponent(".hidden"))

        #expect(await eventually {
            let changes = seen.value
            return changes.contains(.entry("plan.md")) && changes.contains(.entry("bundle")) && changes.contains(.store)
        })
        #expect(!seen.value.contains(.entry(".hidden")))
    }

    @Test func stopEndsDelivery() async throws {
        let dir = try ScratchDir()
        let seen = Locked<Int>(0)
        let watcher = FolderWatcher(folder: dir.url) { _ in seen.withLock { $0 += 1 } }
        try watcher.start()
        watcher.stop()
        try Data("a".utf8).write(to: dir.url.appendingPathComponent("a.md"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(seen.value == 0)
    }
}

struct ContentWatcherTests: Sendable {
    var fm: FileManager { .default }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    func make(_ f: StoreFixture) -> (ContentWatcher, Counter) {
        let counter = Counter()
        return (ContentWatcher(store: f.store, debounce: .milliseconds(50), onChange: { counter.bump() }), counter)
    }

    static func types(_ f: StoreFixture) throws -> [EventType] { try f.store.events().map(\.type) }

    func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }

    @Test func burstOfWritesIsOneContentEvent() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md", "1")
        let (watcher, changes) = make(f)
        await watcher.baselineNewDrops()
        for n in 2...6 {
            try write(String(repeating: "x", count: n), to: f.store.path(of: drop))
            await watcher.entryChanged("a.md")
        }
        #expect(await eventually { (try? Self.types(f)) == [.created, .content] })
        try await Task.sleep(for: .milliseconds(150))
        #expect(try Self.types(f) == [.created, .content])
        #expect(changes.value == 1)
    }

    @Test func addingADropIsNotAContentChange() async throws {
        let f = try StoreFixture()
        let (watcher, changes) = make(f)
        try f.add("new.md")
        await watcher.baselineNewDrops()
        await watcher.entryChanged("new.md")
        try await Task.sleep(for: .milliseconds(200))
        #expect(try Self.types(f) == [.created])
        #expect(changes.value == 0)
    }

    @Test func dropFirstSeenThroughItsOwnChangeGetsABaseline() async throws {
        let f = try StoreFixture()
        let drop = try f.add("late.md", "1")
        let (watcher, _) = make(f)
        await watcher.entryChanged("late.md")      // no baseline yet: this one only records it
        try await Task.sleep(for: .milliseconds(150))
        #expect(try Self.types(f) == [.created])
        try write("22", to: f.store.path(of: drop))
        await watcher.entryChanged("late.md")
        #expect(await eventually { (try? Self.types(f)) == [.created, .content] })
    }

    @Test func folderDropCountsNestedFilesButNotDotFiles() async throws {
        let f = try StoreFixture()
        let bundle = f.dir.url.appendingPathComponent("bundle", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try write("# B", to: bundle.appendingPathComponent("README.md"))
        let drop = try f.store.add(AddRequest(source: .path(bundle), from: "t"))
        let placed = f.store.path(of: drop)
        let (watcher, _) = make(f)
        await watcher.baselineNewDrops()

        try write("noise", to: placed.appendingPathComponent(".DS_Store"))
        await watcher.entryChanged("bundle")
        try await Task.sleep(for: .milliseconds(150))
        #expect(try Self.types(f) == [.created])

        try fm.createDirectory(at: placed.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write("new", to: placed.appendingPathComponent("sub/notes.md"))
        await watcher.entryChanged("bundle")
        #expect(await eventually { (try? Self.types(f)) == [.created, .content] })
    }

    @Test func deletionIsMissingAndReturnIsMetadataNeitherIsContent() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md", "1")
        let url = f.store.path(of: drop)
        let (watcher, changes) = make(f)
        await watcher.baselineNewDrops()

        try fm.removeItem(at: url)
        await watcher.entryChanged("a.md")
        #expect(await eventually { (try? Self.types(f)) == [.created, .missing] })

        try write("back again", to: url)
        await watcher.entryChanged("a.md")
        #expect(await eventually { (try? Self.types(f)) == [.created, .missing, .metadata] })
        try await Task.sleep(for: .milliseconds(150))
        #expect(try Self.types(f) == [.created, .missing, .metadata])
        #expect(changes.value == 2)

        // The return re-baselined it, so the next edit is an ordinary content change.
        try write("edited after return", to: url)
        await watcher.entryChanged("a.md")
        #expect(await eventually { (try? Self.types(f)).map { $0.last == .content } ?? false })
    }

    @Test func unregisteredEntriesAreIgnored() async throws {
        let f = try StoreFixture()
        let (watcher, changes) = make(f)
        try write("stray", to: f.folder.appendingPathComponent("stray.md"))
        await watcher.entryChanged("stray.md")
        try await Task.sleep(for: .milliseconds(150))
        #expect(try f.store.events().isEmpty)
        #expect(changes.value == 0)
    }

    @Test func rescanChecksEveryDrop() async throws {
        let f = try StoreFixture()
        let a = try f.add("a.md", "1")
        try f.add("b.md", "1")
        let (watcher, _) = make(f)
        await watcher.baselineNewDrops()
        try fm.removeItem(at: f.store.path(of: a))
        await watcher.rescan()
        #expect(await eventually { (try? Self.types(f)) == [.created, .created, .missing] })
    }
}
