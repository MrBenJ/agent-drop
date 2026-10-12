# Agent Drop — Plan 2: `AgentDropServer` + `drop watch` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the local server (HTTP + SSE on 127.0.0.1), `content` events from a folder watcher, and `drop watch`, so agents and other apps can follow drops live.

**Architecture:** A new library target, `AgentDropServer`, holds everything server-side. `EventHub` fans the store's event log out to subscribers. `HTTPServer`/`HTTPAPI` serve it over Hummingbird 2 behind a token and `Host` check. `FolderWatcher` (FSEvents) and `ContentWatcher` (debounce + fingerprints) write `content` events and notice missing files. `AgentDropService` ties them together the way the app will host them, including `server.json`. The store stays the single source of truth: any process can write to it, and the hub picks rows up after FSEvents reports a change under `.agentdrop/`. `drop watch` is an async command in `DropCLI` that finds or launches the app through `server.json` and reads the SSE stream with a small shared client. Until the app exists (Plan 3), a dev-only executable, `agentdrop-devhost`, hosts the same service.

**Tech Stack:** Swift 6 (tools 6.0, language mode 6, built with Swift 6.2), macOS 14+, GRDB 7, swift-argument-parser 1.5, Hummingbird 2, swift-log, FSEvents, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-11-agent-drop-design.md`

**This plan covers:** spec §2 (`AgentDropServer` product), §3 (protected-folder check), §3.2 (missing/return detection by the watcher), §4 Watching (`drop watch`), §5.1 (`content` events), §5.2 (server, `server.json`, port fallback, token, `Host`), §5.3 (all endpoints, SSE, `Last-Event-ID`, `reset`), §7 (server rows), §8 (`AgentDropServerTests`, `drop watch` end-to-end in `dropCLITests`).
**Later plan:** Plan 3 = `AgentDrop.app` (setup, Settings, menu bar, rendering, hosting `AgentDropService`), `drop open`, reconciliation of unregistered entries.

**How this plan was produced.** It was written alongside the implementation, overnight, while Ben was away. Each task's code was compiled and tested before it was copied in here, so the code blocks are the branch's final files, not a guess. Tasks are in the order they can be executed: each task compiles and passes with only the earlier tasks in place. Where a later task changes a file from an earlier one, the later task shows the complete new version.

## Global Constraints

- Minimum macOS **14**; `// swift-tools-version: 6.0`. CI builds on **`macos-26` (Swift 6.2)**: Hummingbird 2.27 and several of its dependencies need Swift 6.2.
- New dependencies for this plan: **Hummingbird ≥ 2.0.0** (products `Hummingbird`, `HummingbirdCore`), **swift-log ≥ 1.5.0**, **swift-service-lifecycle ≥ 2.0.0** (graceful shutdown) and **swift-service-context ≥ 1.1.0** (declared only so packages depending on `AgentDropServer` build, see Task 2). All four are already in Hummingbird's own dependency graph.
- Server: **HTTP on `127.0.0.1` only**. Port **47390** by default (`serverPort` in `config.json` overrides), then the **next 9**.
- Every request needs `Authorization: Bearer <token>` (else **401**). `Host` must be `127.0.0.1:<port>` or `localhost:<port>` (else **403**). Both checks apply to every route, including unknown ones.
- Errors: `{"error": "<message>", "status": <HTTP status>}`.
- `server.json` in `~/Library/Application Support/AgentDrop/`, permissions **0600**: `{"status":"running","port":…,"token":"…","pid":…}` or `{"status":"no-port","pid":…}`. New random token on every start. Not written before setup is complete. Removed on clean stop.
- SSE: `id: <storeId>:<seq>`, `event: <type>`, `data: {"storeId","seq","type","dropId","at","data"}`. `reset` carries `data: {"reason":"drop folder changed"}`.
- `content` events: debounced per drop, **300 ms** of quiet. Retention cleanup rides on them like any event.
- Nothing runs before `setupComplete` is true, or while a protected folder is unconfirmed. Before setup, **nothing touches the drop folder**.
- `drop watch` messages, verbatim: "Agent Drop hasn't been set up yet. Open the Agent Drop app once to finish setup." · "Confirm the new drop folder in Agent Drop" · "drop folder changed; <id> is not in the current folder". It waits up to **10 s** for the server. Exit codes are 0/1/2/3, as in Plan 1.
- Tests never touch real paths. The real-binary smoke test runs only on GitHub Actions. `agentdrop-devhost` is never run by tests.
- Never block a Swift concurrency thread in tests (CI's runner has 3 cores): blocking socket I/O goes through GCD.

## Review Focus

Five inputs or failure modes the spec implies but doesn't spell out, most likely to bite first. Each has its test in the task that owns the code:

1. **A client still connected when the server stops** must not hang shutdown. Tests: Task 4 `stopEndsOpenStreamsPromptly`, Task 6 `stopWithAConnectedClientIsPrompt`.
2. **Filenames with spaces, accents, emoji, `%`, `#` or `?`** in `/drops/:id` must resolve (path parameters arrive percent-encoded). Test: Task 4 `showByIdOrEncodedFilename`.
3. **Temp and real folders under a symlinked path** (`/var` → `/private/var`): FSEvents reports real paths, so the watcher must compare against the real root. Test: Task 5 `reportsTopLevelEntriesAndStoreChangesFromRealFSEvents`.
4. **A burst of writes while pokes race them** must arrive complete, in order, exactly once. Test: Task 3 `burstArrivesInOrderWithoutGapsOrDuplicates`.
5. **A watcher that has seen no events yet when the folder switches** must still get `reset`. That's why fresh streams open with an id-only cursor frame. Tests: Task 3 `freshSubscriptionsOpenWithTheirStartingCursor`, Task 8 `folderSwitchResetsInboxWatchesAndEndsDropWatches`.

---

## File Structure

```
Package.swift                         + AgentDropServer, agentdrop-devhost, Hummingbird, swift-log
.github/workflows/ci.yml              macos-26; builds the dev host; smoke test gets both binaries
Scripts/smoke.sh                      + real-binary drop watch against the dev host
Sources/AgentDropCore/
  DropStore+Watch.swift               latestSeq, drop(filename:), checkPresence, recordContentChange
  FolderProtection.swift              protected locations; folderNeedsConfirmation; setSetupComplete/setConfirmedFolder
  (Config.swift, DropStore+Query.swift, EventLog.swift: small visibility changes)
Sources/AgentDropServer/
  ServerInfo.swift                    server.json shape, 0600 atomic writes, pid liveness, tokens
  Wire.swift                          JSONValue, EventMessage, EventCursor, EventFilter, SSE framing + parser
  EventHub.swift                      replay, live delivery, filters, reset, cursor frames, heartbeats, close
  HTTPServer.swift                    bind with port fallback, stop
  HTTPAPI.swift                       routes, query parsing, JSON errors, Host/token middleware, folder listing
  AgentDropClient.swift               client for drop watch and tests
  FolderWatcher.swift                 FSEvents → .store / .entry(name) / .rescan
  ContentWatcher.swift                debounced fingerprints → content / missing / return
  AgentDropService.swift              what the app hosts: gates, watchers, server, server.json, retry, stop
  TemporarySetup.swift                dev host only: setup complete while running, exact restore
Sources/DropCLI/
  Output.swift                        + terminalSafe for human output
  CLIContext.swift                    + launchApp, isProcessAlive, serverWait, appBundleID
  DropCLI.swift                       + runAsync
  Commands/WatchCommand.swift         drop watch
Sources/drop/main.swift               awaits DropCLI.runAsync
Sources/agentdrop-devhost/main.swift  stand-in for the app until Plan 3
Tests/AgentDropCoreTests/ServerSupportTests.swift
Tests/AgentDropServerTests/           one file per area, plus support files
Tests/dropCLITests/                   TestEnv (+ async), TerminalSafetyTests, WatchCommandTests
```

---

### Task 1: Core support for the server: event cursor, filename lookup, presence check, `content` events, folder protection

**Files:**
- Create: `Sources/AgentDropCore/DropStore+Watch.swift`, `Sources/AgentDropCore/FolderProtection.swift`
- Modify: `Sources/AgentDropCore/DropStore+Query.swift` (`refreshMissing` becomes internal), `Sources/AgentDropCore/Config.swift` (`readDict`/`writeDict` become internal), `Sources/AgentDropCore/EventLog.swift` (memberwise `StoredEvent.init` for tests)
- Test: `Tests/AgentDropCoreTests/ServerSupportTests.swift`

**Interfaces:**
- Consumes (Plan 1): `DropStore.read/mutate`, `fetchDrop`, `fetchDrops`, `refreshMissing(_:)`, `EventLog.append`, `ConfigStore.load/folderURL`.
- Produces:
  - `DropStore.latestSeq() throws -> Int64`
  - `DropStore.drop(filename: String) throws -> Drop?`
  - `DropStore.checkPresence(_ id: String) throws -> Drop`
  - `DropStore.recordContentChange(_ id: String) throws`
  - `FolderProtection.isProtected(_ folder: URL, homeDir: URL) -> Bool`
  - `ConfigStore.folderNeedsConfirmation(_:) -> Bool`, `ConfigStore.setSetupComplete(_ Bool) throws`, `ConfigStore.setConfirmedFolder(_ URL?) throws`
  - `StoredEvent.init(seq:type:dropID:at:data:inboxBefore:inboxAfter:projectBefore:projectAfter:)` (internal, for tests)

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropCoreTests/ServerSupportTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore

/// Core APIs the server and `drop watch` build on (Plan 2).
struct ServerSupportTests {
    let fm = FileManager.default

    @Test func latestSeqTracksTheLog() throws {
        let f = try Fixture()
        #expect(try f.store.latestSeq() == 0)
        let drop = try f.add(handoff: true)
        _ = try f.store.claim(drop.id, by: "b")
        #expect(try f.store.latestSeq() == 2)
        #expect(try f.store.events(afterSeq: 1).map(\.type) == [.status])
    }

    @Test func dropByExactFilename() throws {
        let f = try Fixture()
        let drop = try f.add("Plan.md")
        #expect(try f.store.drop(filename: "Plan.md")?.id == drop.id)
        #expect(try f.store.drop(filename: "plan.md") == nil)
        #expect(try f.store.drop(filename: drop.id) == nil)
    }

    @Test func checkPresenceEmitsMissingThenReturn() throws {
        let f = try Fixture()
        let drop = try f.add("a.md", "one")
        let url = f.store.path(of: drop)
        #expect(try f.store.checkPresence(drop.id).missing == false)
        #expect(try f.store.events().count == 1)

        try fm.removeItem(at: url)
        #expect(try f.store.checkPresence(drop.id).missing)
        try Data("back".utf8).write(to: url)
        #expect(try f.store.checkPresence(drop.id).missing == false)
        let events = try f.store.events()
        #expect(events.map(\.type) == [.created, .missing, .metadata])
        #expect(events.last?.data == #"{"missing":false}"#)
        expectError(2) { _ = try f.store.checkPresence("zzzzzz") }
    }

    @Test func recordContentChangeWritesOneContentEvent() throws {
        let f = try Fixture()
        let drop = try f.add(handoff: true)
        try f.store.recordContentChange(drop.id)
        let event = try #require(try f.store.events().last)
        #expect(event.type == .content)
        #expect(event.data == "{}")
        #expect(event.inboxBefore && event.inboxAfter)
        // Content events never change the drop row.
        #expect(try f.store.resolve(drop.id) == drop)
    }

    @Test func contentEventsRideRetentionCleanup() throws {
        let f = try Fixture(retention: .days(1))
        let drop = try f.add()
        f.clock.advance(days: 2)
        try f.store.recordContentChange(drop.id)
        #expect(try f.store.events().map(\.type) == [.content])
    }

    @Test func commitObserverFiresOncePerCommitThatWroteEvents() throws {
        let f = try Fixture()
        let count = Locked(0)
        f.store.observeEventCommits { count.withLock { $0 += 1 } }
        let drop = try f.add(handoff: true)
        _ = try f.store.claim(drop.id, by: "a")
        expectError(3) { _ = try f.store.claim(drop.id, by: "b") }  // rolled back: no event
        _ = try f.store.edit(drop.id, EditRequest())                // no change: no event
        #expect(count.value == 2)
    }

    @Test func noContentEventForMissingOrUnknownDrop() throws {
        let f = try Fixture()
        let drop = try f.add()
        try fm.removeItem(at: f.store.path(of: drop))
        _ = try f.store.checkPresence(drop.id)
        let before = try f.store.latestSeq()
        try f.store.recordContentChange(drop.id)
        #expect(try f.store.latestSeq() == before)
        expectError(2) { try f.store.recordContentChange("zzzzzz") }
    }
}

struct FolderProtectionTests {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test(arguments: ["Desktop", "Desktop/AgentDrop", "Documents/a/b", "Downloads/x",
                      "Library/Mobile Documents/com~apple~CloudDocs/AgentDrop"])
    func protectedLocations(_ relative: String) {
        #expect(FolderProtection.isProtected(home.appendingPathComponent(relative), homeDir: home))
    }

    @Test(arguments: ["AgentDrop", "DesktopStuff", "code/Desktop", "Library/Application Support/x"])
    func unprotectedLocations(_ relative: String) {
        #expect(!FolderProtection.isProtected(home.appendingPathComponent(relative), homeDir: home))
    }

    @Test(arguments: ["desktop/AgentDrop", "DESKTOP", "Documents/../Downloads/x", "./Desktop/y"])
    func spellingVariantsAreStillProtected(_ relative: String) {
        #expect(FolderProtection.isProtected(home.appendingPathComponent(relative), homeDir: home))
    }

    @Test func aSymlinkIntoAProtectedFolderIsProtected() throws {
        let tmp = try TempDir()
        let home = tmp.url.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("dt"),
                                                   withDestinationURL: home.appendingPathComponent("Desktop"))
        #expect(FolderProtection.isProtected(home.appendingPathComponent("dt/AgentDrop"), homeDir: home))
        #expect(!FolderProtection.isProtected(home.appendingPathComponent("AgentDrop"), homeDir: home))
    }

    @Test func tempFolderOnTheBootVolumeIsNotProtected() throws {
        let tmp = try TempDir()
        #expect(!FolderProtection.isProtected(tmp.url.appendingPathComponent("not/yet/created"),
                                              homeDir: home))
    }

    @Test func needsConfirmationUntilConfirmed() throws {
        let tmp = try TempDir()
        let config = ConfigStore(configDir: tmp.url.appendingPathComponent("support"),
                                 homeDir: tmp.url.appendingPathComponent("home"))
        #expect(!config.folderNeedsConfirmation(try config.load()))

        let desktop = config.homeDir.appendingPathComponent("Desktop/AgentDrop", isDirectory: true)
        try config.setFolder(desktop)
        #expect(config.folderNeedsConfirmation(try config.load()))
        try config.setConfirmedFolder(desktop)
        #expect(!config.folderNeedsConfirmation(try config.load()))
        try config.setFolder(config.homeDir.appendingPathComponent("Documents/Drops"))
        #expect(config.folderNeedsConfirmation(try config.load()))
    }

    @Test func setupCompleteRoundTripsAndKeepsOtherKeys() throws {
        let tmp = try TempDir()
        let config = ConfigStore(configDir: tmp.url.appendingPathComponent("support"),
                                 homeDir: tmp.url.appendingPathComponent("home"))
        try config.setRetention(.days(7))
        try config.setSetupComplete(true)
        let loaded = try config.load()
        #expect(loaded.setupComplete)
        #expect(loaded.eventRetentionDays == .days(7))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter 'ServerSupportTests|FolderProtectionTests'`
Expected: build error: `value of type 'DropStore' has no member 'latestSeq'` (and the other new names).

- [ ] **Step 3: Make the three Plan 1 helpers reachable**

In `Sources/AgentDropCore/DropStore+Query.swift`, change `private func refreshMissing(_ drop: Drop) throws -> Drop` to `func refreshMissing(_ drop: Drop) throws -> Drop`.

In `Sources/AgentDropCore/Config.swift`, change `private func readDict()` to `func readDict()` and `private func writeDict(` to `func writeDict(`.

In `Sources/AgentDropCore/EventLog.swift`, add this initializer to `StoredEvent`, above `init(row:)`:

```swift
    init(seq: Int64, type: EventType, dropID: String, at: Date, data: String, inboxBefore: Bool,
         inboxAfter: Bool, projectBefore: String?, projectAfter: String?) {
        self.seq = seq
        self.type = type
        self.dropID = dropID
        self.at = at
        self.data = data
        self.inboxBefore = inboxBefore
        self.inboxAfter = inboxAfter
        self.projectBefore = projectBefore
        self.projectAfter = projectAfter
    }
```

- [ ] **Step 4: Implement**

`Sources/AgentDropCore/DropStore+Watch.swift` (create, complete file):

```swift
import Foundation
import GRDB

/// Store APIs for the server's event stream and folder watcher (spec §5).
extension DropStore {
    /// The highest event `seq` written so far, or 0 for an empty log.
    public func latestSeq() throws -> Int64 {
        try read { db in try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM event") ?? 0 }
    }

    /// The drop registered under exactly this filename. Records store the on-disk
    /// spelling, which is also what FSEvents reports.
    public func drop(filename: String) throws -> Drop? {
        try read { db in
            try Self.fetchDrops(db, sql: "SELECT * FROM drops WHERE filename = ?", arguments: [filename]).first
        }
    }

    /// Spec §3.2 for one drop: re-checks its entry and records `missing` or
    /// `metadata {missing: false}` when that changed.
    public func checkPresence(_ id: String) throws -> Drop {
        guard let drop = try read({ db in try Self.fetchDrop(db, id: id) }) else {
            throw AgentDropError.notFound("No drop matches '\(id)'")
        }
        return try refreshMissing(drop)
    }

    /// Spec §5.1 `content`: the drop's file or folder contents changed. Written only by the
    /// server's folder watcher. Leaves the drop row untouched; skipped for a missing drop.
    public func recordContentChange(_ id: String) throws {
        let now = self.now()
        try mutate { db in
            guard let drop = try Self.fetchDrop(db, id: id) else {
                throw AgentDropError.notFound("No drop matches '\(id)'")
            }
            guard !drop.missing else { return }
            try EventLog.append(db, type: .content, dropID: id, dataJSON: "{}",
                                before: drop, after: drop, at: now, retention: retention)
        }
    }
}

extension DropStore {
    /// Calls `handler` after every committed transaction on this store instance that wrote
    /// event rows. The server uses it to deliver in-process writes immediately; writes from
    /// other processes reach it through FSEvents on `.agentdrop/` instead.
    public func observeEventCommits(_ handler: @escaping @Sendable () -> Void) {
        pool.add(transactionObserver: EventCommitObserver(handler: handler), extent: .databaseLifetime)
    }
}

private final class EventCommitObserver: TransactionObserver, @unchecked Sendable {
    // Touched only on the store's writer queue, one transaction at a time.
    private var wroteEvents = false
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        if case .insert(let table) = eventKind { return table == "event" }
        return false
    }

    func databaseDidChange(with event: DatabaseEvent) { wroteEvents = true }

    func databaseDidCommit(_ db: Database) {
        guard wroteEvents else { return }
        wroteEvents = false
        handler()
    }

    func databaseDidRollback(_ db: Database) { wroteEvents = false }
}
```

`Sources/AgentDropCore/FolderProtection.swift` (create, complete file):

```swift
import Foundation

/// Spec §3 "Protected-folder confirmation": locations where macOS asks before an app
/// reads them, plus removable and network volumes.
public enum FolderProtection {
    public static func isProtected(_ folder: URL, homeDir: URL) -> Bool {
        // Compare real paths, case-insensitively: `~/desktop` and a symlink to ~/Desktop
        // reach the same protected folder on a default (case-insensitive) APFS volume.
        let path = canonical(folder)
        let home = canonical(homeDir)
        let protectedRoots = ["desktop", "documents", "downloads", "library/mobile documents"]
            .map { home + "/" + $0 }
        if protectedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        return isOnRemovableOrNetworkVolume(folder.standardizedFileURL)
    }

    /// realpath(3) of the nearest existing ancestor plus the rest, lowercased.
    static func canonical(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var base = existing.path
        if let resolved = realpath(existing.path, nil) {
            base = String(cString: resolved)
            free(resolved)
        }
        let joined = ([base == "/" ? "" : base] + rest).joined(separator: "/")
        return (joined.isEmpty ? "/" : joined).lowercased()
    }

    /// The folder may not exist yet, so ask about its nearest existing ancestor.
    private static func isOnRemovableOrNetworkVolume(_ folder: URL) -> Bool {
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.volumeIsLocal == false || values.volumeIsRemovable == true || values.volumeIsEjectable == true
    }
}

extension ConfigStore {
    /// True when the configured folder is protected and hasn't been confirmed in the app.
    /// Until then the app's server and watcher stay off and `drop watch` exits 1.
    public func folderNeedsConfirmation(_ config: AgentDropConfig) -> Bool {
        let folder = folderURL(config).standardizedFileURL
        guard FolderProtection.isProtected(folder, homeDir: homeDir) else { return false }
        return config.confirmedFolder.map { URL(fileURLWithPath: $0).standardizedFileURL.path } != folder.path
    }

    /// Written by the app when first-run setup finishes (spec §2).
    public func setSetupComplete(_ complete: Bool) throws {
        var dict = try readDict()
        dict["setupComplete"] = complete
        try writeDict(dict)
    }

    /// Written by the app when the user confirms a protected folder (spec §3).
    public func setConfirmedFolder(_ url: URL?) throws {
        var dict = try readDict()
        dict["confirmedFolder"] = url?.standardizedFileURL.path
        try writeDict(dict)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test`
Expected: all tests pass (Plan 1's plus the 11 new ones).

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentDropCore Tests/AgentDropCoreTests/ServerSupportTests.swift
git commit -m "feat(core): event cursor, filename lookup, presence check, content events, folder protection"
```

---

### Task 2: `AgentDropServer` target, Swift 6.2 CI, `server.json`, and the wire types

**Files:**
- Modify: `Package.swift`, `.github/workflows/ci.yml`
- Create: `Sources/AgentDropServer/ServerInfo.swift`, `Sources/AgentDropServer/Wire.swift`
- Test: `Tests/AgentDropServerTests/Support.swift`, `Tests/AgentDropServerTests/WireTests.swift`

**Interfaces:**
- Consumes: Task 1's `StoredEvent` initializer; Plan 1's `Date.iso`, `EventType`.
- Produces:
  - `ServerInfo` (`.running(port:token:pid:)`, `.noPort(pid:)`, `isProcessAlive(_:)`, `newToken()`)
  - `ServerInfoFile(configDir:)` with `read() -> ServerInfo?`, `write(_:) throws`, `remove()`
  - `JSONValue`, `EventMessage(storeID:event:)` with `jsonString()` and `cursor`
  - `EventCursor(storeID:seq:)` with `init?(lastEventID:)` and `id`
  - `EventFilter` (`.all`, `.drop(id)`, `.inbox(project:)`) with `matches(_:)`
  - `SSE.frame/comment/resetReason/resetData`, `SSEEvent`, `SSEParser` (`feed(byte:)`, `feed(line:)`, `lastEventID`)
  - Test support: `ScratchDir`, `StoredEventFixture.make(...)`, `Locked<Value>`, `eventually(timeout:_:)`

- [ ] **Step 1: Add the target and dependencies**

In `Package.swift`, add the product, the two packages, the target and its test target:

```swift
    products: [
        .library(name: "AgentDropCore", targets: ["AgentDropCore"]),
        .library(name: "AgentDropServer", targets: ["AgentDropServer"]),
        .executable(name: "drop", targets: ["drop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.1.0"),
    ],
```

```swift
        .target(
            name: "AgentDropServer",
            dependencies: [
                "AgentDropCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                // Hummingbird imports ServiceContextModule but only gets it transitively;
                // without this, packages that depend on AgentDropServer fail to build it.
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ]
        ),
```

```swift
        .testTarget(name: "AgentDropServerTests", dependencies: ["AgentDropServer", "AgentDropCore"]),
```

In `.github/workflows/ci.yml`, change `runs-on: macos-15` to `runs-on: macos-26`. `macos-15` ships Swift 6.1, and Hummingbird's current dependencies need 6.2. (Pinning Hummingbird 2.26 doesn't help: swift-log, swift-crypto and swift-async-algorithms resolve to 6.2-only versions anyway.)

- [ ] **Step 2: Write the failing tests**

`Tests/AgentDropServerTests/Support.swift` (create, complete file):

```swift
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

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func withLock(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return try await condition()
}
```

`Tests/AgentDropServerTests/WireTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

struct ServerInfoTests {
    @Test func runningAndNoPortShapes() throws {
        let running = String(decoding: try ServerInfo.running(port: 47390, token: "t", pid: 42).encoded(), as: UTF8.self)
        #expect(running == #"{"pid":42,"port":47390,"status":"running","token":"t"}"#)
        let noPort = String(decoding: try ServerInfo.noPort(pid: 42).encoded(), as: UTF8.self)
        #expect(noPort == #"{"pid":42,"status":"no-port"}"#)
    }

    @Test func writeIsPrivateAndAtomicAndRemovable() throws {
        let tmp = try ScratchDir()
        let file = ServerInfoFile(configDir: tmp.url.appendingPathComponent("support"))
        #expect(file.read() == nil)
        try file.write(.running(port: 1, token: "a", pid: 7))
        try file.write(.running(port: 2, token: "b", pid: 7))
        #expect(file.read() == .running(port: 2, token: "b", pid: 7))
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.url.deletingLastPathComponent().path)
        #expect(leftovers == ["server.json"])
        file.remove()
        #expect(file.read() == nil)
    }

    /// Review M4: the temp file must be private from the moment it exists, under any umask.
    @Test func tempFileIsCreatedPrivate() throws {
        let tmp = try ScratchDir()
        let target = tmp.url.appendingPathComponent("t")
        let old = umask(0)
        defer { umask(old) }
        try ServerInfoFile.writePrivately(Data("x".utf8), to: target)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(throws: (any Error).self) { try ServerInfoFile.writePrivately(Data("y".utf8), to: target) }
    }

    @Test func unreadableFileReadsAsAbsent() throws {
        let tmp = try ScratchDir()
        let file = ServerInfoFile(configDir: tmp.url)
        try Data("not json".utf8).write(to: file.url)
        #expect(file.read() == nil)
    }

    @Test func processLiveness() {
        #expect(ServerInfo.isProcessAlive(getpid()))
        #expect(!ServerInfo.isProcessAlive(0))
        #expect(!ServerInfo.isProcessAlive(Int32.max))
    }

    @Test func tokensAreLongAndFresh() {
        let a = ServerInfo.newToken(), b = ServerInfo.newToken()
        #expect(a.count == 64)
        #expect(a != b)
    }
}

struct SSETests {
    @Test func frameFormat() {
        #expect(SSE.frame(id: "s:3", event: "status", data: #"{"a":1}"#) == "id: s:3\nevent: status\ndata: {\"a\":1}\n\n")
        #expect(SSE.comment("keepalive") == ": keepalive\n\n")
    }

    @Test func parserHandlesCommentsCRLFAndMultipleFrames() {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        let text = ": connected\n\nid: s:1\r\nevent: created\ndata: {}\n\nid: s:2\nevent: status\ndata: {\"x\":\ndata: 1}\n\n"
        for byte in Array(text.utf8) {
            if let event = parser.feed(byte: byte) { events.append(event) }
        }
        #expect(events == [SSEEvent(id: "s:1", event: "created", data: "{}"),
                           SSEEvent(id: "s:2", event: "status", data: "{\"x\":\n1}")])
    }

    @Test func idOnlyFramesMoveTheCursorWithoutAnEvent() {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for byte in Array(": connected\n\nid: s:4\n\n".utf8) {
            if let event = parser.feed(byte: byte) { events.append(event) }
        }
        #expect(events.isEmpty)
        #expect(parser.lastEventID == "s:4")
        for byte in Array("id: s:5\nevent: created\ndata: {}\n\n".utf8) { _ = parser.feed(byte: byte) }
        #expect(parser.lastEventID == "s:5")
    }

    @Test func eventMessageEmbedsDataAsJSON() throws {
        let stored = StoredEventFixture.make(seq: 9, type: .status, data: #"{"from":"open","to":"claimed"}"#)
        let message = EventMessage(storeID: "st", event: stored)
        #expect(message.jsonString() ==
            #"{"at":"2025-10-09T08:53:20Z","data":{"from":"open","to":"claimed"},"dropId":"abcdef","seq":9,"storeId":"st","type":"status"}"#)
        let decoded = try JSONDecoder().decode(EventMessage.self, from: Data(message.jsonString().utf8))
        #expect(decoded == message)
    }
}

struct EventCursorTests {
    @Test func parsesStoreAndSeq() {
        #expect(EventCursor(lastEventID: "abc123:42") == EventCursor(storeID: "abc123", seq: 42))
        #expect(EventCursor(lastEventID: "a:b:7") == EventCursor(storeID: "a:b", seq: 7))
    }

    @Test(arguments: ["", "abc", ":4", "abc:", "abc:-1", "abc:x", "abc:1.5"])
    func rejectsMalformed(_ raw: String) {
        #expect(EventCursor(lastEventID: raw) == nil)
    }

    @Test func idString() {
        #expect(EventCursor(storeID: "s", seq: 3).id == "s:3")
    }
}

struct EventFilterTests {
    typealias E = StoredEventFixture

    @Test func allAndDrop() {
        let e = E.make(dropID: "aaaaaa")
        #expect(EventFilter.all.matches(e))
        #expect(EventFilter.drop("aaaaaa").matches(e))
        #expect(!EventFilter.drop("bbbbbb").matches(e))
    }

    @Test func inboxDeliversArrivalsOnly() {
        let inbox = EventFilter.inbox(project: nil)
        #expect(inbox.matches(E.make(inboxBefore: false, inboxAfter: true)))
        #expect(!inbox.matches(E.make(inboxBefore: true, inboxAfter: true)))   // still there
        #expect(!inbox.matches(E.make(inboxBefore: true, inboxAfter: false)))  // departure
        #expect(!inbox.matches(E.make(inboxBefore: false, inboxAfter: false)))
    }

    @Test func projectScopedInboxCountsAProjectMoveAsAnArrival() {
        let scoped = EventFilter.inbox(project: "app")
        #expect(scoped.matches(E.make(inboxBefore: false, inboxAfter: true, projectAfter: "app")))
        #expect(!scoped.matches(E.make(inboxBefore: false, inboxAfter: true, projectAfter: "other")))
        #expect(!scoped.matches(E.make(inboxBefore: false, inboxAfter: true, projectAfter: nil)))
        // In the global Inbox already, but it just moved into "app": an arrival for "app".
        #expect(scoped.matches(E.make(inboxBefore: true, inboxAfter: true, projectBefore: "other", projectAfter: "app")))
        #expect(!scoped.matches(E.make(inboxBefore: true, inboxAfter: true, projectBefore: "app", projectAfter: "app")))
    }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --filter 'ServerInfoTests|SSETests|EventCursorTests|EventFilterTests'`
Expected: build error: `cannot find 'ServerInfo' in scope`.

- [ ] **Step 4: Implement**

`Sources/AgentDropServer/ServerInfo.swift` (create, complete file):

```swift
import Foundation

/// `server.json` (spec §5.2): written by the app, read by `drop watch`.
public struct ServerInfo: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running
        case noPort = "no-port"
    }

    public var status: Status
    public var port: Int?
    public var token: String?
    public var pid: Int32

    public static func running(port: Int, token: String, pid: Int32) -> ServerInfo {
        ServerInfo(status: .running, port: port, token: token, pid: pid)
    }

    public static func noPort(pid: Int32) -> ServerInfo {
        ServerInfo(status: .noPort, port: nil, token: nil, pid: pid)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// A live process, including one owned by another user (EPERM).
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// 32 random bytes as hex. A new one for every server start.
    public static func newToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
    }
}

/// Reads and writes `<configDir>/server.json` with permissions 0600.
public struct ServerInfoFile: Sendable {
    public let url: URL

    public init(configDir: URL) {
        url = configDir.appendingPathComponent("server.json")
    }

    /// `nil` when the file is absent or unreadable: the app is treated as not running.
    public func read() -> ServerInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ServerInfo.self, from: data)
    }

    /// Written to a private temp file, then renamed over the old one, so readers never
    /// see a partial file and the token is never readable by other users.
    public func write(_ info: ServerInfo) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".server.json.\(UUID().uuidString)")
        try Self.writePrivately(try info.encoded(), to: temp)
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Creates `target` with mode 0600 from the first instant (O_CREAT|O_EXCL), so the
    /// token is never readable by others, not even between create and chmod.
    static func writePrivately(_ data: Data, to target: URL) throws {
        let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        fchmod(fd, 0o600) // exact mode even under an unusual umask
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
```

`Sources/AgentDropServer/Wire.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation

/// Any JSON value. Used to embed an event's stored `data` object in a message.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v):
            if v == v.rounded(), abs(v) < 1e15 { try c.encode(Int64(v)) } else { try c.encode(v) }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// The `data:` payload of every event frame (spec §5.3).
public struct EventMessage: Codable, Equatable, Sendable {
    public var storeId: String
    public var seq: Int64
    public var type: String
    public var dropId: String
    public var at: String
    public var data: JSONValue

    public init(storeID: String, event: StoredEvent) {
        storeId = storeID
        seq = event.seq
        type = event.type.rawValue
        dropId = event.dropID
        at = event.at.iso
        data = (try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8))) ?? .object([:])
    }

    public var cursor: EventCursor { EventCursor(storeID: storeId, seq: seq) }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}

/// `Last-Event-ID` / SSE `id:` value: `<storeId>:<seq>` (spec §5.3).
public struct EventCursor: Equatable, Sendable {
    public var storeID: String
    public var seq: Int64

    public init(storeID: String, seq: Int64) {
        self.storeID = storeID
        self.seq = seq
    }

    public init?(lastEventID: String) {
        guard let colon = lastEventID.lastIndex(of: ":") else { return nil }
        let store = String(lastEventID[..<colon])
        let digits = lastEventID[lastEventID.index(after: colon)...]
        guard !store.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let seq = Int64(digits) else { return nil }
        self.init(storeID: store, seq: seq)
    }

    public var id: String { "\(storeID):\(seq)" }
}

/// Which events a stream delivers (spec §5.3 `GET /events`).
public enum EventFilter: Equatable, Sendable {
    case all
    case drop(String)
    /// Arrivals only: events after which the drop is in the Inbox (scoped to `project`
    /// when given) and before which it was not.
    case inbox(project: String?)

    public func matches(_ event: StoredEvent) -> Bool {
        switch self {
        case .all:
            return true
        case .drop(let id):
            return event.dropID == id
        case .inbox(let project):
            let inScopeAfter = event.inboxAfter && (project == nil || event.projectAfter == project)
            let inScopeBefore = event.inboxBefore && (project == nil || event.projectBefore == project)
            return inScopeAfter && !inScopeBefore
        }
    }
}

/// Server-sent events framing (https://html.spec.whatwg.org/multipage/server-sent-events.html).
public enum SSE {
    /// `data` must not contain newlines (our payloads are single-line JSON).
    public static func frame(id: String?, event: String, data: String) -> String {
        var text = ""
        if let id { text += "id: \(id)\n" }
        return text + "event: \(event)\ndata: \(data)\n\n"
    }

    public static func comment(_ text: String) -> String { ": \(text)\n\n" }

    public static let resetReason = "drop folder changed"
    public static let resetData = #"{"reason":"drop folder changed"}"#
}

public struct SSEEvent: Equatable, Sendable {
    public var id: String?
    public var event: String
    public var data: String

    public init(id: String?, event: String, data: String) {
        self.id = id
        self.event = event
        self.data = data
    }
}

/// SSE parser. Feed raw bytes with `feed(byte:)`, or whole lines (including empty ones,
/// which end a frame) with `feed(line:)`. Lines are split on the LF byte; a trailing CR is
/// dropped. (Splitting a Swift `String` on "\n" would not work: "\r\n" is one Character.)
public struct SSEParser: Sendable {
    private var id: String?
    private var event: String?
    private var data: [String] = []
    private var lineBuffer: [UInt8] = []
    /// The last `id:` seen at the end of any frame, including id-only frames that dispatch
    /// no event (as an EventSource does). Send it back as `Last-Event-ID` on reconnect.
    public private(set) var lastEventID: String?

    public init() {}

    public mutating func feed(byte: UInt8) -> SSEEvent? {
        guard byte == 0x0A else {
            lineBuffer.append(byte)
            return nil
        }
        let line = String(decoding: lineBuffer, as: UTF8.self)
        lineBuffer.removeAll(keepingCapacity: true)
        return feed(line: line)
    }

    public mutating func feed(line raw: String) -> SSEEvent? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            defer { id = nil; event = nil; data = [] }
            if let id { lastEventID = id }
            guard !data.isEmpty || event != nil else { return nil }
            return SSEEvent(id: id, event: event ?? "message", data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            let rest = line[line.index(after: colon)...]
            value = rest.hasPrefix(" ") ? rest.dropFirst() : rest
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "id": id = String(value)
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}
```

The parser works on bytes on purpose: `URLSession`'s `bytes.lines` drops the blank lines that end SSE frames, and splitting a Swift `String` on `"\n"` never splits `"\r\n"`, which is a single `Character`.

- [ ] **Step 5: Run the tests**

Run: `swift test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved .github/workflows/ci.yml Sources/AgentDropServer Tests/AgentDropServerTests
git commit -m "feat(server): server.json, event messages, SSE framing and parsing, cursors, inbox filters"
```

---

### Task 3: `EventHub`: replay, live delivery, filters, `reset`, cursor frames, heartbeats

**Files:**
- Create: `Sources/AgentDropServer/EventHub.swift`
- Test: `Tests/AgentDropServerTests/HubSupport.swift`, `Tests/AgentDropServerTests/EventHubTests.swift`

**Interfaces:**
- Consumes: Task 1 (`latestSeq`), Task 2 (`EventMessage`, `EventCursor`, `EventFilter`); Plan 1 `DropStore.events(afterSeq:)`.
- Produces: `actor EventHub` with `init(store:) throws`, `storeID`, `subscribe(_ EventFilter, resumeFrom: EventCursor?) throws -> AsyncStream<Frame>`, `poke()`, `startHeartbeat(every:)`, `close()`, `subscriberCount`; `EventHub.Frame` = `.event(EventMessage)` | `.cursor(EventCursor)` | `.reset(EventCursor)` | `.heartbeat`.
- Test support: `StoreFixture`, `collect(_:count:timeout:includeCursor:)`, `Frame.message`.

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropServerTests/HubSupport.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

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

/// Reads up to `count` frames, giving up after `timeout`. Skips the opening `.cursor`
/// frame of fresh subscriptions unless `includeCursor`.
func collect(_ stream: AsyncStream<EventHub.Frame>, count: Int, timeout: Duration = .seconds(5),
             includeCursor: Bool = false) async -> [EventHub.Frame] {
    await withTaskGroup(of: [EventHub.Frame]?.self) { group in
        group.addTask {
            var frames: [EventHub.Frame] = []
            for await frame in stream {
                if case .cursor = frame, !includeCursor { continue }
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
```

`Tests/AgentDropServerTests/EventHubTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

struct EventHubTests {
    @Test func deliversNewEventsLiveAfterPoke() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        let stream = try await hub.subscribe(.all, resumeFrom: nil)
        let drop = try f.add(handoff: true)
        _ = try f.store.claim(drop.id, by: "b")
        await hub.poke()
        let frames = await collect(stream, count: 2)
        #expect(frames.compactMap(\.message).map(\.type) == ["created", "status"])
        #expect(frames.first?.message?.storeId == f.store.storeID)
        #expect(frames.last?.message?.data["to"]?.stringValue == "claimed")
    }

    @Test func liveOnlyWithoutCursorReplayWithCursor() async throws {
        let f = try StoreFixture()
        let a = try f.add("a.md")
        let b = try f.add("b.md")
        let hub = try EventHub(store: f.store)

        let fresh = try await hub.subscribe(.all, resumeFrom: nil)
        let resumed = try await hub.subscribe(.all, resumeFrom: EventCursor(storeID: f.store.storeID, seq: 1))
        _ = try f.store.setArchived(a.id, true)
        await hub.poke()

        #expect(await collect(fresh, count: 1).compactMap(\.message).map(\.type) == ["archived"])
        let replayed = await collect(resumed, count: 2).compactMap(\.message)
        #expect(replayed.map(\.dropId) == [b.id, a.id])
        #expect(replayed.map(\.seq) == [2, 3])
    }

    @Test func foreignStoreCursorGetsResetThenLiveOnly() async throws {
        let f = try StoreFixture()
        try f.add("a.md")
        let hub = try EventHub(store: f.store)
        let stream = try await hub.subscribe(.all, resumeFrom: EventCursor(storeID: "otherstore", seq: 0))
        try f.add("b.md")
        await hub.poke()
        let frames = await collect(stream, count: 2)
        #expect(frames.first == .reset(EventCursor(storeID: f.store.storeID, seq: 1)))
        #expect(frames.last?.message?.seq == 2)
    }

    @Test func subscribingWithoutCursorSkipsEverythingAlreadyWritten() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        try f.add("a.md")   // written after the hub started, never poked
        let stream = try await hub.subscribe(.all, resumeFrom: nil)
        try f.add("b.md")
        await hub.poke()
        #expect(await collect(stream, count: 1).compactMap(\.message).map(\.seq) == [2])
    }

    @Test func freshSubscriptionsOpenWithTheirStartingCursor() async throws {
        let f = try StoreFixture()
        try f.add("a.md")
        let hub = try EventHub(store: f.store)
        let fresh = try await hub.subscribe(.all, resumeFrom: nil)
        #expect(await collect(fresh, count: 1, includeCursor: true) == [.cursor(EventCursor(storeID: f.store.storeID, seq: 1))])
        let resumed = try await hub.subscribe(.all, resumeFrom: EventCursor(storeID: f.store.storeID, seq: 1))
        try f.add("b.md")
        await hub.poke()
        #expect(await collect(resumed, count: 1, includeCursor: true).first?.message?.seq == 2)
    }

    @Test func cursorAheadOfTheLogNeverDuplicates() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        try f.add("a.md")   // seq 1, not yet poked
        let stream = try await hub.subscribe(.all, resumeFrom: EventCursor(storeID: f.store.storeID, seq: 1))
        try f.add("b.md")   // seq 2
        await hub.poke()
        #expect(await collect(stream, count: 1).compactMap(\.message).map(\.seq) == [2])
        #expect(await collect(stream, count: 1, timeout: .milliseconds(200)).isEmpty)
    }

    @Test func filtersApplyToReplayAndLive() async throws {
        let f = try StoreFixture()
        let handoff = try f.add("h.md", project: "app", handoff: true)
        try f.add("n.md", project: "app")
        let hub = try EventHub(store: f.store)
        let inbox = try await hub.subscribe(.inbox(project: "app"), resumeFrom: EventCursor(storeID: f.store.storeID, seq: 0))
        let one = try await hub.subscribe(.drop(handoff.id), resumeFrom: EventCursor(storeID: f.store.storeID, seq: 0))
        _ = try f.store.claim(handoff.id, by: "x")      // departure: not an inbox arrival
        _ = try f.store.release(handoff.id)             // arrival again
        await hub.poke()

        let arrivals = await collect(inbox, count: 2).compactMap(\.message)
        #expect(arrivals.map(\.type) == ["created", "status"])
        #expect(arrivals.last?.data["to"]?.stringValue == "open")
        #expect(await collect(one, count: 3).compactMap(\.message).map(\.type) == ["created", "status", "status"])
    }

    /// Review Focus: a burst of writes with pokes racing them arrives complete, in order, once.
    @Test func burstArrivesInOrderWithoutGapsOrDuplicates() async throws {
        let f = try StoreFixture()
        let drop = try f.add(handoff: true)
        let hub = try EventHub(store: f.store)
        let stream = try await hub.subscribe(.all, resumeFrom: EventCursor(storeID: f.store.storeID, seq: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<25 {
                    _ = try f.store.claim(drop.id, by: "a")
                    _ = try f.store.release(drop.id)
                }
            }
            group.addTask {
                for _ in 0..<40 {
                    await hub.poke()
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            try await group.waitForAll()
        }
        await hub.poke()
        let seqs = await collect(stream, count: 51).compactMap(\.message).map(\.seq)
        #expect(seqs == Array(1...51))
    }

    @Test func heartbeatsReachSubscribers() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        await hub.startHeartbeat(every: .milliseconds(50))
        let stream = try await hub.subscribe(.all, resumeFrom: nil)
        #expect(await collect(stream, count: 2) == [.heartbeat, .heartbeat])
        await hub.close()
    }

    @Test func closeEndsStreamsAndRefusesNewOnes() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        let stream = try await hub.subscribe(.all, resumeFrom: nil)
        await hub.close()
        #expect(await collect(stream, count: 1).isEmpty)
        let late = try await hub.subscribe(.all, resumeFrom: nil)
        #expect(await collect(late, count: 1).isEmpty)
    }

    @Test func abandonedSubscriptionsAreDropped() async throws {
        let f = try StoreFixture()
        let hub = try EventHub(store: f.store)
        let task = Task {
            let stream = try await hub.subscribe(.all, resumeFrom: nil)
            for await _ in stream {}
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await hub.subscriberCount == 1)
        task.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await hub.subscriberCount == 0)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter EventHubTests`
Expected: build error: `cannot find type 'EventHub' in scope`.

- [ ] **Step 3: Implement**

`Sources/AgentDropServer/EventHub.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation

/// Fans the store's event log out to SSE subscribers (spec §5.3).
///
/// The store is the source of truth: `poke()` reads every row after the last one it saw
/// and delivers each to the subscribers whose filter matches. Anything that writes to the
/// store (the CLI in another process, the content watcher, a lazy missing check) is
/// picked up on the next poke, which the folder watcher triggers on every store change.
public actor EventHub {
    public enum Frame: Equatable, Sendable {
        case event(EventMessage)
        /// First frame of a fresh (cursor-less) subscription: where "live" starts. Sent as an
        /// id-only SSE frame, so every client has a `Last-Event-ID` to resume with, and gets
        /// `reset` after a folder switch even if no event arrived before it.
        case cursor(EventCursor)
        /// The client's `Last-Event-ID` came from another store. Carries the cursor to resume from.
        case reset(EventCursor)
        case heartbeat
    }

    private struct Subscriber {
        let filter: EventFilter
        /// Only events with a larger seq go to this subscriber.
        let after: Int64
        let continuation: AsyncStream<Frame>.Continuation
    }

    public nonisolated let storeID: String
    private let store: DropStore
    private var lastSeq: Int64
    private var subscribers: [UUID: Subscriber] = [:]
    private var heartbeatTask: Task<Void, Never>?
    private var closed = false

    public init(store: DropStore) throws {
        self.store = store
        storeID = store.storeID
        lastSeq = try store.latestSeq()
    }

    public var subscriberCount: Int { subscribers.count }

    /// Without a cursor: live events only. With a cursor from this store: every surviving
    /// matching event after it, then live. With a cursor from another store: one `reset`,
    /// then live.
    public func subscribe(_ filter: EventFilter, resumeFrom cursor: EventCursor?) throws -> AsyncStream<Frame> {
        let (stream, continuation) = AsyncStream<Frame>.makeStream(bufferingPolicy: .unbounded)
        guard !closed else {
            continuation.finish()
            return stream
        }
        // Catch up first, so "live" means "written after this call", not "after the last poke".
        poke()
        var after = lastSeq
        if cursor == nil {
            continuation.yield(.cursor(EventCursor(storeID: storeID, seq: lastSeq)))
        }
        if let cursor {
            if cursor.storeID != storeID {
                continuation.yield(.reset(EventCursor(storeID: storeID, seq: lastSeq)))
            } else {
                for event in try store.events(afterSeq: cursor.seq) where event.seq <= lastSeq && filter.matches(event) {
                    continuation.yield(.event(EventMessage(storeID: storeID, event: event)))
                }
                after = max(cursor.seq, lastSeq)
            }
        }
        let id = UUID()
        subscribers[id] = Subscriber(filter: filter, after: after, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    /// Delivers every event written since the last poke. Cheap when nothing changed.
    public func poke() {
        guard !closed, let events = try? store.events(afterSeq: lastSeq), !events.isEmpty else { return }
        for event in events {
            let message = EventMessage(storeID: storeID, event: event)
            for subscriber in subscribers.values where event.seq > subscriber.after && subscriber.filter.matches(event) {
                subscriber.continuation.yield(.event(message))
            }
        }
        lastSeq = events.last!.seq
    }

    /// Keeps idle connections alive and lets the server notice clients that went away.
    /// Each tick also pokes: the safety net for writers FSEvents can't see (a store
    /// connection that stays open only touches its WAL file, which reports nothing until
    /// it closes). It's the keepalive timer that already runs, not an extra poll.
    public func startHeartbeat(every interval: Duration) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.broadcastHeartbeat()
            }
        }
    }

    /// Ends every stream. Called before the HTTP server stops, so shutdown never waits on
    /// an open SSE response.
    public func close() {
        closed = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for subscriber in subscribers.values { subscriber.continuation.finish() }
        subscribers.removeAll()
    }

    private func broadcastHeartbeat() {
        poke()
        for subscriber in subscribers.values { subscriber.continuation.yield(.heartbeat) }
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }
}
```

Two rules make delivery exact. `subscribe` pokes first, so "live" means "written after this call", not "after the last poke". And each subscriber remembers the seq it starts after, so a cursor ahead of the hub never gets duplicates.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter EventHubTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentDropServer/EventHub.swift Tests/AgentDropServerTests
git commit -m "feat(server): event hub with replay, live delivery, filters, reset, heartbeats"
```

---

### Task 4: HTTP API, access checks, port fallback, and the client

**Files:**
- Create: `Sources/AgentDropServer/HTTPServer.swift`, `Sources/AgentDropServer/HTTPAPI.swift`, `Sources/AgentDropServer/AgentDropClient.swift`
- Test: `Tests/AgentDropServerTests/HTTPSupport.swift`, `Tests/AgentDropServerTests/HTTPTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3; Plan 1 `DropStore.list/resolve/json/path(of:)`, `ListFilter`, `AgentDropError`.
- Produces:
  - `HTTPServer.start(store:hub:token:portBase:attempts:) async throws -> HTTPServer` (throws `HTTPServer.PortsExhausted`), with `port`, `token`, `stop() async`
  - `FolderListing` (`id`, `entries: [Entry(path, type, size?, target?)]`)
  - `AgentDropClient(port:token:)` with `dropPath(_:)`, `request(...)`, `get(_:query:) async throws -> (Data, Int)`, `events(query:lastEventID:onCursor:) async throws -> AsyncThrowingStream<SSEEvent, Error>` (throws `HTTPFailure` for non-200)
- Test support: `ServerFixture`, `randomPortBase()`, `rawHTTP(port:_:) async throws -> String`, `first(_:timeout:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropServerTests/HTTPSupport.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

/// A real HTTP server on 127.0.0.1 over a scratch store.
struct ServerFixture {
    let store: StoreFixture
    let hub: EventHub
    let server: HTTPServer
    var client: AgentDropClient { AgentDropClient(port: server.port, token: server.token) }

    init(store: StoreFixture? = nil) async throws {
        let store = try store ?? StoreFixture()
        self.store = store
        hub = try EventHub(store: store.store)
        server = try await HTTPServer.start(store: store.store, hub: hub, token: ServerInfo.newToken(),
                                            portBase: randomPortBase(), attempts: 10)
    }
}

/// Parallel tests each start in a different range; collisions just fall through to the next port.
func randomPortBase() -> Int { Int.random(in: 20_000...59_000) }

/// Sends raw bytes, so tests can control headers URLSession would rewrite (e.g. `Host`).
/// The blocking socket calls run on a GCD thread: blocking a Swift concurrency thread
/// would starve the server under test on small CI machines.
func rawHTTP(port: Int, _ request: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        rawHTTPQueue.async {
            continuation.resume(with: Result { try blockingRawHTTP(port: port, request) })
        }
    }
}

/// Its own concurrent queue: `DispatchQueue.global()` has about one thread per core, and
/// other tests may be blocking all of them.
private let rawHTTPQueue = DispatchQueue(label: "tests.rawHTTP", attributes: .concurrent)

private func blockingRawHTTP(port: Int, _ request: String) throws -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    precondition(fd >= 0)
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
    let bytes = Array(request.utf8)
    _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, bytes.count, 0) }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { break }
        response.append(contentsOf: buffer[0..<n])
    }
    return String(decoding: response, as: UTF8.self)
}

/// The first event of a stream, or nil if it ends or nothing arrives in time.
func first(_ events: AsyncThrowingStream<SSEEvent, Error>, timeout: Duration = .seconds(5)) async throws -> SSEEvent? {
    try await withThrowingTaskGroup(of: SSEEvent?.self) { group in
        group.addTask {
            for try await event in events { return event }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

`Tests/AgentDropServerTests/HTTPTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

struct HTTPAccessTests {
    @Test func missingOrWrongTokenIs401() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let wrong = AgentDropClient(port: s.server.port, token: "nope")
        let (body, status) = try await wrong.get("/drops")
        #expect(status == 401)
        #expect(String(decoding: body, as: UTF8.self) == #"{"error":"missing or invalid token","status":401}"#)
        let noAuth = try await rawHTTP(port: s.server.port, "GET /drops HTTP/1.1\r\nHost: 127.0.0.1:\(s.server.port)\r\nConnection: close\r\n\r\n")
        #expect(noAuth.hasPrefix("HTTP/1.1 401"))
    }

    @Test(arguments: ["evil.example", "127.0.0.1", "127.0.0.1:1", "localhost.evil.example"])
    func foreignHostIs403EvenWithTheToken(_ host: String) async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let response = try await rawHTTP(port: s.server.port,
            "GET /drops HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(s.server.token)\r\nConnection: close\r\n\r\n")
        #expect(response.hasPrefix("HTTP/1.1 403"))
        #expect(response.contains(#""status":403"#))
    }

    @Test func localhostAndLoopbackHostsAreAllowed() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        for host in ["127.0.0.1:\(s.server.port)", "localhost:\(s.server.port)"] {
            let response = try await rawHTTP(port: s.server.port,
                "GET /drops HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(s.server.token)\r\nConnection: close\r\n\r\n")
            #expect(response.hasPrefix("HTTP/1.1 200"), "\(host)")
        }
    }

    /// Review L4: a second Host header must not slip through behind a valid first one.
    @Test func duplicateHostHeaderIs403() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let response = try await rawHTTP(port: s.server.port,
            "GET /drops HTTP/1.1\r\nHost: 127.0.0.1:\(s.server.port)\r\nHost: evil.example\r\nAuthorization: Bearer \(s.server.token)\r\nConnection: close\r\n\r\n")
        #expect(response.hasPrefix("HTTP/1.1 403"))
    }

    @Test func checksCoverUnknownRoutesAndEvents() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let port = s.server.port
        for path in ["/nope", "/events"] {
            let noToken = try await rawHTTP(port: port, "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n")
            #expect(noToken.hasPrefix("HTTP/1.1 401"), "\(path)")
            let foreign = try await rawHTTP(port: port,
                "GET \(path) HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(s.server.token)\r\nConnection: close\r\n\r\n")
            #expect(foreign.hasPrefix("HTTP/1.1 403"), "\(path)")
        }
    }

    @Test func unknownRouteIsJSON404() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let (body, status) = try await s.client.get("/nope")
        #expect(status == 404)
        #expect(String(decoding: body, as: UTF8.self).contains(#""status":404"#))
    }
}

struct HTTPDropsTests {
    @Test func listUsesListDefaultsAndFilters() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let a = try s.store.add("a.md", project: "app", handoff: true)
        let b = try s.store.add("b.md", project: "web")
        let c = try s.store.add("c.md", project: "app")
        _ = try s.store.store.setArchived(c.id, true)
        _ = try s.store.store.edit(b.id, EditRequest(addTags: ["PR", "x y"]))

        func ids(_ query: [String: String]) async throws -> [String] {
            let (body, status) = try await s.client.get("/drops", query: query.map { URLQueryItem(name: $0.key, value: $0.value) })
            #expect(status == 200)
            return try JSONDecoder().decode([[String: JSONValue]].self, from: body).compactMap { $0["id"]?.stringValue }
        }
        #expect(try await ids([:]) == [b.id, a.id])
        #expect(try await ids(["all": ""]) == [c.id, b.id, a.id])
        #expect(try await ids(["project": "app"]) == [a.id])
        #expect(try await ids(["tag": "x y"]) == [b.id])
        #expect(try await ids(["handoffs": "true", "status": "open"]) == [a.id])
        #expect(try await ids(["limit": "1"]) == [b.id])
        #expect(try await ids(["from-under": "tester"]) == [b.id, a.id])
        #expect(try await ids(["unread": "", "all": "true"]) == [b.id, a.id])
    }

    @Test(arguments: [["status": "maybe"], ["limit": "0"], ["limit": "x"], ["handoffs": "yes"], ["projct": "app"]])
    func badQueriesAre400(_ query: [String: String]) async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let (body, status) = try await s.client.get("/drops", query: query.map { URLQueryItem(name: $0.key, value: $0.value) })
        #expect(status == 400)
        #expect(String(decoding: body, as: UTF8.self).contains(#""status":400"#))
    }

    @Test func repeatedTagsMustAllMatch() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let both = try s.store.add("both.md")
        let one = try s.store.add("one.md")
        _ = try s.store.store.edit(both.id, EditRequest(addTags: ["a", "b"]))
        _ = try s.store.store.edit(one.id, EditRequest(addTags: ["a"]))
        let (body, _) = try await s.client.get("/drops", query: [URLQueryItem(name: "tag", value: "a"), URLQueryItem(name: "tag", value: "b")])
        let ids = try JSONDecoder().decode([[String: JSONValue]].self, from: body).compactMap { $0["id"]?.stringValue }
        #expect(ids == [both.id])
    }

    /// Review Focus: filenames with spaces, accents and emoji resolve through the URL path.
    @Test(arguments: ["Q3 plan — draft ✅.md", "a%b#c?.md", "café.md"])
    func showByIdOrEncodedFilename(_ name: String) async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let drop = try s.store.add(name)
        for ref in [drop.id, drop.filename] {
            let (body, status) = try await s.client.get(AgentDropClient.dropPath(ref))
            #expect(status == 200, "\(ref)")
            let json = try JSONDecoder().decode([String: JSONValue].self, from: body)
            #expect(json["id"]?.stringValue == drop.id)
            #expect(json["filename"]?.stringValue == drop.filename)
        }
        let (_, missing) = try await s.client.get(AgentDropClient.dropPath("zzzzzz"))
        #expect(missing == 404)
    }

    @Test func showNoticesAMissingFileAndStreamsTheEvent() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let drop = try s.store.add("gone.md")
        let stream = try await s.hub.subscribe(.drop(drop.id), resumeFrom: nil)
        try FileManager.default.removeItem(at: s.store.store.path(of: drop))
        let (body, _) = try await s.client.get(AgentDropClient.dropPath(drop.id))
        #expect(try JSONDecoder().decode([String: JSONValue].self, from: body)["missing"] == .bool(true))
        #expect(await collect(stream, count: 1).first?.message?.type == "missing")
    }

    @Test func fileContentIsByteExact() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x0A, 0x0D])
        let source = s.store.dir.url.appendingPathComponent("img.png")
        try bytes.write(to: source)
        let drop = try s.store.store.add(AddRequest(source: .path(source), from: "t"))
        let (body, status) = try await s.client.get(AgentDropClient.dropPath(drop.id) + "/content")
        #expect(status == 200)
        #expect(body == bytes)

        try FileManager.default.removeItem(at: s.store.store.path(of: drop))
        #expect(try await s.client.get(AgentDropClient.dropPath(drop.id) + "/content").1 == 404)
    }

    @Test func folderContentIsAListingThatNeverFollowsLinks() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let fm = FileManager.default
        let bundle = s.store.dir.url.appendingPathComponent("bundle", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("# B\n".utf8).write(to: bundle.appendingPathComponent("README.md"))
        try Data("x".utf8).write(to: bundle.appendingPathComponent("sub/x.txt"))
        try fm.createSymbolicLink(atPath: bundle.appendingPathComponent("link").path, withDestinationPath: "/etc")
        let drop = try s.store.store.add(AddRequest(source: .path(bundle), from: "t"))

        let (body, status) = try await s.client.get(AgentDropClient.dropPath(drop.id) + "/content")
        #expect(status == 200)
        let listing = try JSONDecoder().decode(FolderListing.self, from: body)
        #expect(listing.id == drop.id)
        #expect(listing.entries == [
            .init(path: "README.md", type: "file", size: 4, target: nil),
            .init(path: "link", type: "symlink", size: nil, target: "/etc"),
            .init(path: "sub", type: "directory", size: nil, target: nil),
            .init(path: "sub/x.txt", type: "file", size: 1, target: nil),
        ])
    }
}

struct HTTPEventsTests {
    @Test func streamsFramesWithStoreScopedIDs() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let events = try await s.client.events()
        let drop = try s.store.add(handoff: true)
        await s.hub.poke()
        let frame = try #require(try await first(events))
        #expect(frame.event == "created")
        #expect(frame.id == "\(s.store.store.storeID):1")
        let message = try JSONDecoder().decode(EventMessage.self, from: Data(frame.data.utf8))
        #expect(message.dropId == drop.id)
        #expect(message.data["kind"]?.stringValue == "handoff")
    }

    @Test func resumesFromLastEventIDAndResetsAcrossStores() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        try s.store.add("a.md")
        try s.store.add("b.md")
        await s.hub.poke()
        let resumed = try await s.client.events(lastEventID: "\(s.store.store.storeID):1")
        #expect(try await first(resumed)?.id == "\(s.store.store.storeID):2")

        let foreign = try await s.client.events(lastEventID: "someotherstore:9")
        let reset = try #require(try await first(foreign))
        #expect(reset.event == "reset")
        #expect(reset.data == #"{"reason":"drop folder changed"}"#)
        #expect(reset.id == "\(s.store.store.storeID):2")
    }

    @Test func dropAndInboxFilters() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let note = try s.store.add("n.md", project: "app")
        let byFilename = try await s.client.events(query: [URLQueryItem(name: "drop", value: note.filename)])
        let inbox = try await s.client.events(query: [URLQueryItem(name: "inbox", value: ""), URLQueryItem(name: "project", value: "app")])
        _ = try s.store.store.edit(note.id, EditRequest(kind: .handoff))
        await s.hub.poke()
        #expect(try await first(byFilename)?.event == "metadata")
        #expect(try await first(inbox)?.event == "metadata")
    }

    /// Review M3: a client resuming within the same store can still follow a drop whose
    /// record was removed while it was away, and receives the `removed` event.
    @Test func removedDropCanBeResumedWithinTheSameStore() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let drop = try s.store.add("gone.md")
        try FileManager.default.removeItem(at: s.store.store.path(of: drop))
        _ = try s.store.store.checkPresence(drop.id)
        try s.store.store.removeRecord(drop.id)
        let query = [URLQueryItem(name: "drop", value: drop.id)]
        let resumed = try await s.client.events(query: query, lastEventID: "\(s.store.store.storeID):1")
        #expect(try await first(resumed)?.event == "missing")
        do {
            _ = try await s.client.events(query: query)
            Issue.record("expected 404 without a cursor")
        } catch let failure as AgentDropClient.HTTPFailure {
            #expect(failure.status == 404)
        }
        do {
            _ = try await s.client.events(query: query, lastEventID: "otherstore:1")
            Issue.record("expected 404 for another store's cursor")
        } catch let failure as AgentDropClient.HTTPFailure {
            #expect(failure.status == 404)
        }
    }

    @Test func badEventRequests() async throws {
        let s = try await ServerFixture()
        defer { Task { await s.server.stop() } }
        let drop = try s.store.add()
        func status(_ query: [URLQueryItem], lastEventID: String? = nil) async throws -> Int {
            do {
                _ = try await s.client.events(query: query, lastEventID: lastEventID)
                return 200
            } catch let error as AgentDropClient.HTTPFailure {
                return error.status
            }
        }
        #expect(try await status([URLQueryItem(name: "drop", value: "zzzzzz")]) == 404)
        #expect(try await status([URLQueryItem(name: "drop", value: drop.id), URLQueryItem(name: "inbox", value: "")]) == 400)
        #expect(try await status([URLQueryItem(name: "project", value: "app")]) == 400)
        #expect(try await status([URLQueryItem(name: "dorp", value: drop.id)]) == 400)
        #expect(try await status([], lastEventID: "garbage") == 400)
    }

    /// Review Focus: stopping the server with a client still connected must not hang.
    @Test func stopEndsOpenStreamsPromptly() async throws {
        let s = try await ServerFixture()
        let events = try await s.client.events()
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await s.server.stop() }
        #expect(elapsed < .seconds(2))
        #expect(try await first(events, timeout: .seconds(2)) == nil)
    }
}

struct HTTPPortTests {
    @Test func fallsThroughTakenPortsAndReportsExhaustion() async throws {
        let store = try StoreFixture()
        let hub = try EventHub(store: store.store)
        let base = randomPortBase()
        let first = try await HTTPServer.start(store: store.store, hub: hub, token: "t", portBase: base, attempts: 2)
        let second = try await HTTPServer.start(store: store.store, hub: hub, token: "t", portBase: first.port, attempts: 2)
        #expect(second.port == first.port + 1)
        await #expect(throws: HTTPServer.PortsExhausted.self) {
            _ = try await HTTPServer.start(store: store.store, hub: hub, token: "t", portBase: first.port, attempts: 2)
        }
        await second.stop()
        await first.stop()
    }
}
```

`rawHTTP` exists because `URLSession` won't let a client set `Host`. Its blocking socket calls run on a GCD thread: on CI's 3-core runner, blocking Swift's concurrency threads starved the server under test, and unrelated tests timed out.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter HTTP`
Expected: build error: `cannot find 'HTTPServer' in scope`.

- [ ] **Step 3: Implement**

`Sources/AgentDropServer/HTTPServer.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

/// The local HTTP + SSE server (spec §5.2, §5.3): 127.0.0.1 only, bearer token, `Host` allowlist.
public final class HTTPServer: Sendable {
    public struct PortsExhausted: Error, Equatable {
        public let range: ClosedRange<Int>
    }

    public let port: Int
    public let token: String
    private let hub: EventHub
    private let running: Running

    private struct Running: Sendable {
        let group: ServiceGroup
        let task: Task<Void, Error>
    }

    private init(port: Int, token: String, hub: EventHub, running: Running) {
        self.port = port
        self.token = token
        self.hub = hub
        self.running = running
    }

    /// Binds the first free port in `portBase ..< portBase + attempts` (spec: the default
    /// port plus the next 9).
    public static func start(store: DropStore, hub: EventHub, token: String, portBase: Int,
                             attempts: Int) async throws -> HTTPServer {
        for port in portBase..<(portBase + attempts) {
            let router = HTTPAPI.router(store: store, hub: hub, token: token, port: port)
            if let running = await bind(router, port: port) {
                return HTTPServer(port: port, token: token, hub: hub, running: running)
            }
        }
        throw PortsExhausted(range: portBase...(portBase + attempts - 1))
    }

    /// Ends every open event stream first (a streaming response would otherwise keep
    /// shutdown waiting), then shuts the server down gracefully. If that takes more than
    /// 2 s (a stuck connection), the server task is cancelled.
    public func stop() async {
        await hub.close()
        await running.group.triggerGracefulShutdown()
        let task = running.task
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = try? await task.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        if !finished {
            task.cancel()
            _ = try? await task.value
        }
    }

    /// The running server's task, or nil if the port couldn't be bound. The first value
    /// on `outcome` decides: `true` once the server listens, `false` if `run()` ended first.
    private static func bind(_ router: Router<BasicRequestContext>, port: Int) async -> Running? {
        let (outcome, continuation) = AsyncStream<Bool>.makeStream()
        var logger = Logger(label: "AgentDropServer")
        logger.logLevel = .warning
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: nil, reuseAddress: false),
            onServerRunning: { _ in continuation.yield(true) },
            logger: logger)
        // Our own group (no signal handling), so stop() can shut down gracefully.
        let group = ServiceGroup(configuration: .init(services: [app], logger: logger))
        let task = Task {
            defer {
                continuation.yield(false)
                continuation.finish()
            }
            try await group.run()
        }
        var iterator = outcome.makeAsyncIterator()
        return await iterator.next() == true ? Running(group: group, task: task) : nil
    }
}
```

`Sources/AgentDropServer/HTTPAPI.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation
import Hummingbird
import HummingbirdCore

/// Routes and request checks for the local server (spec §5.3).
enum HTTPAPI {
    static func router(store: DropStore, hub: EventHub, token: String, port: Int) -> Router<BasicRequestContext> {
        let router = Router()
        // Outermost first: errors become JSON, then Host and token are checked, for every
        // request including unknown routes.
        router.add(middleware: ErrorMiddleware())
        router.add(middleware: AccessMiddleware(token: token, port: port))

        router.get("/drops") { request, _ -> Response in
            let filter = try listFilter(request)
            return json(try store.list(filter).map(store.json))
        }

        router.get("/drops/{id}") { _, context -> Response in
            let drop = try store.resolve(try pathID(context))
            await hub.poke() // resolve may have recorded a missing-file event
            return json(store.json(drop))
        }

        router.get("/drops/{id}/content") { _, context -> Response in
            let drop = try store.resolve(try pathID(context))
            await hub.poke()
            guard !drop.missing else { throw AgentDropError.notFound("The file for \(drop.id) is missing") }
            let url = store.path(of: drop)
            if drop.isFolder { return json(try FolderListing(id: drop.id, folder: url)) }
            return Response(status: .ok, headers: [.contentType: contentType(for: url)],
                            body: .init(byteBuffer: ByteBuffer(bytes: try readRegularFile(url, id: drop.id))))
        }

        router.get("/events") { request, _ -> Response in
            var cursor: EventCursor?
            if let raw = request.headers.first(where: { $0.name.canonicalName == "last-event-id" })?.value {
                guard let parsed = EventCursor(lastEventID: raw) else {
                    throw APIError(.badRequest, "Last-Event-ID must look like <storeId>:<seq>")
                }
                cursor = parsed
            }
            let filter = try eventFilter(request, store: store, resumingWithin: cursor?.storeID == hub.storeID)
            let frames = try await hub.subscribe(filter, resumeFrom: cursor)
            return Response(
                status: .ok,
                headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
                body: ResponseBody { writer in
                    try await writer.write(ByteBuffer(string: SSE.comment("connected")))
                    for await frame in frames {
                        try await writer.write(ByteBuffer(string: encode(frame)))
                    }
                    try await writer.finish(nil)
                })
        }
        return router
    }

    static func encode(_ frame: EventHub.Frame) -> String {
        switch frame {
        case .event(let message):
            SSE.frame(id: message.cursor.id, event: message.type, data: message.jsonString())
        case .cursor(let cursor):
            "id: \(cursor.id)\n\n"
        case .reset(let cursor):
            SSE.frame(id: cursor.id, event: "reset", data: SSE.resetData)
        case .heartbeat:
            SSE.comment("keepalive")
        }
    }

    // MARK: - Query parsing

    /// `drop list` filters as query parameters, with the same defaults and rules.
    static func listFilter(_ request: Request) throws -> ListFilter {
        let query = request.uri.queryParameters
        try rejectUnknown(query, allowed: ["project", "tag", "from", "from-under", "handoffs", "status", "unread",
                                           "limit", "all"])
        var filter = ListFilter()
        filter.project = query["project"].map(String.init)
        filter.tags = query[values: "tag"].map(String.init)
        filter.from = query["from"].map(String.init)
        filter.fromUnder = query["from-under"].map(String.init)
        filter.handoffsOnly = try flag(query, "handoffs")
        filter.unreadOnly = try flag(query, "unread")
        filter.includeArchived = try flag(query, "all")
        if let raw = query["status"] {
            guard let status = HandoffStatus(rawValue: String(raw)) else {
                throw APIError(.badRequest, "status must be open, claimed, or done")
            }
            filter.status = status
        }
        if let raw = query["limit"] {
            guard let limit = Int(raw), limit >= 1 else { throw APIError(.badRequest, "limit must be at least 1") }
            filter.limit = limit
        }
        return filter
    }

    /// `resumingWithin`: the client sent a cursor from this store. Then a well-formed id
    /// with no record (removed while the client was away) is still accepted, so the
    /// replay can deliver its `removed` event.
    static func eventFilter(_ request: Request, store: DropStore, resumingWithin: Bool = false) throws -> EventFilter {
        let query = request.uri.queryParameters
        try rejectUnknown(query, allowed: ["drop", "inbox", "project"])
        let inbox = try flag(query, "inbox")
        let project = query["project"].map(String.init)
        if let ref = query["drop"] {
            guard !inbox else { throw APIError(.badRequest, "use either drop or inbox, not both") }
            guard project == nil else { throw APIError(.badRequest, "project only applies to inbox") }
            do {
                return .drop(try store.resolve(String(ref)).id)
            } catch let error as AgentDropError where error.exitCode == 2 && resumingWithin
                && DropID.isWellFormed(String(ref)) {
                return .drop(String(ref))
            }
        }
        if inbox { return .inbox(project: project) }
        guard project == nil else { throw APIError(.badRequest, "project only applies to inbox") }
        return .all
    }

    /// A typo like `projct` must not silently widen the result.
    private static func rejectUnknown(_ query: FlatDictionary<Substring, Substring>, allowed: Set<String>) throws {
        for (key, _) in query where !allowed.contains(String(key)) {
            throw APIError(.badRequest, "unknown query parameter '\(key)'")
        }
    }

    /// Present with no value or `true` → true; `false` or absent → false.
    private static func flag(_ query: FlatDictionary<Substring, Substring>, _ name: String) throws -> Bool {
        guard let value = query[Substring(name)] else { return false }
        switch value {
        case "", "true": return true
        case "false": return false
        default: throw APIError(.badRequest, "\(name) must be true or false")
        }
    }

    /// Path parameters arrive percent-encoded (`my%20plan.md`).
    private static func pathID(_ context: BasicRequestContext) throws -> String {
        guard let raw = context.parameters.get("id"), let id = raw.removingPercentEncoding else {
            throw APIError(.badRequest, "invalid drop reference")
        }
        return id
    }

    /// Reads a drop's file without following a link: the entry could be swapped for a
    /// symlink after `resolve` checked it.
    private static func readRegularFile(_ url: URL, id: String) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AgentDropError.notFound("The file for \(id) is missing") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw AgentDropError.notFound("The file for \(id) is missing")
        }
        return try handle.readToEnd() ?? Data()
    }

    // MARK: - Responses

    static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": "text/markdown; charset=utf-8"
        case "txt", "log": "text/plain; charset=utf-8"
        case "json": "application/json"
        case "html", "htm": "text/html; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}

/// `{"error": "<message>", "status": <HTTP status>}` (spec §5.3).
struct APIError: Error {
    let status: HTTPResponse.Status
    let message: String

    init(_ status: HTTPResponse.Status, _ message: String) {
        self.status = status
        self.message = message
    }

    var response: Response {
        struct Body: Encodable {
            let error: String
            let status: Int
        }
        return HTTPAPI.json(Body(error: message, status: status.code), status: status)
    }
}

struct ErrorMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as APIError {
            return error.response
        } catch let error as AgentDropError {
            switch error {
            case .notFound(let m): return APIError(.notFound, m).response
            case .invalid(let m) where m == "store busy, retry": return APIError(.serviceUnavailable, m).response
            case .invalid(let m): return APIError(.badRequest, m).response
            case .conflict(let m): return APIError(.conflict, m).response
            }
        } catch let error as HTTPError {
            return APIError(error.status, error.body ?? error.status.reasonPhrase).response
        } catch {
            return APIError(.internalServerError, "\(error)").response
        }
    }
}

/// Spec §5.2: `Host` must be `127.0.0.1:<port>` or `localhost:<port>` (403), and every
/// request needs `Authorization: Bearer <token>` (401). A web page can reach localhost,
/// but it can't send a matching `Host` through a browser or know the token.
struct AccessMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let token: String
    let port: Int

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let allowed = ["127.0.0.1:\(port)", "localhost:\(port)"]
        // The first Host header becomes `authority`; any further one stays a header field.
        let extraHost = request.headers.contains { $0.name.canonicalName == "host" }
        guard let host = request.head.authority, allowed.contains(host.lowercased()), !extraHost else {
            throw APIError(.forbidden, "Host not allowed")
        }
        guard request.headers[.authorization] == "Bearer \(token)" else {
            throw APIError(.unauthorized, "missing or invalid token")
        }
        return try await next(request, context)
    }
}

/// `GET /drops/:id/content` for a folder drop. Links are listed with their target text,
/// never followed (spec §3).
public struct FolderListing: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var type: String
        public var size: Int64?
        public var target: String?
    }

    public var id: String
    public var entries: [Entry]

    init(id: String, folder: URL) throws {
        self.id = id
        var entries: [Entry] = []
        try Self.walk(folder, prefix: "", into: &entries)
        self.entries = entries
    }

    private static func walk(_ directory: URL, prefix: String, into entries: inout [Entry]) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
            let url = directory.appendingPathComponent(name)
            let path = prefix + name
            let attributes = try fm.attributesOfItem(atPath: url.path) // does not follow links
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?:
                entries.append(Entry(path: path, type: "directory", size: nil, target: nil))
                try walk(url, prefix: path + "/", into: &entries)
            case .typeRegular?:
                entries.append(Entry(path: path, type: "file", size: (attributes[.size] as? NSNumber)?.int64Value,
                                     target: nil))
            case .typeSymbolicLink?:
                entries.append(Entry(path: path, type: "symlink", size: nil,
                                     target: try? fm.destinationOfSymbolicLink(atPath: url.path)))
            default:
                entries.append(Entry(path: path, type: "other", size: nil, target: nil))
            }
        }
    }
}
```

`Sources/AgentDropServer/AgentDropClient.swift` (create, complete file):

```swift
import Foundation

/// A small client for the local server. Used by `drop watch` and the tests.
public struct AgentDropClient: Sendable {
    public struct HTTPFailure: Error, Equatable {
        public let status: Int
        public let message: String
    }

    public let port: Int
    public let token: String

    public init(port: Int, token: String) {
        self.port = port
        self.token = token
    }

    /// `/drops/<ref>` with `ref` percent-encoded as one path segment.
    public static func dropPath(_ ref: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        return "/drops/" + (ref.addingPercentEncoding(withAllowedCharacters: allowed) ?? ref)
    }

    public func request(_ path: String, query: [URLQueryItem] = [], lastEventID: String? = nil,
                        timeout: TimeInterval = 60) -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.percentEncodedPath = path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // An idle timeout, not a total one: heartbeats keep event streams under it.
        request.timeoutInterval = timeout
        return request
    }

    /// Body and HTTP status.
    public func get(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 60) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request(path, query: query, timeout: timeout))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Opens `GET /events`. Throws `HTTPFailure` for a non-200 answer. The stream ends
    /// when the server closes the connection.
    /// `onCursor` receives every new last-event id, including those of id-only frames.
    public func events(query: [URLQueryItem] = [], lastEventID: String? = nil,
                       onCursor: @escaping @Sendable (String) -> Void = { _ in }) async throws
        -> AsyncThrowingStream<SSEEvent, Error>
    {
        let (bytes, response) = try await URLSession.shared.bytes(
            for: request("/events", query: query, lastEventID: lastEventID))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            let message = (try? JSONDecoder().decode([String: JSONValue].self, from: body))?["error"]?.stringValue
            throw HTTPFailure(status: status, message: message ?? String(decoding: body, as: UTF8.self))
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    var cursor = lastEventID
                    for try await byte in bytes {
                        let event = parser.feed(byte: byte)
                        if let id = parser.lastEventID, id != cursor {
                            cursor = id
                            onCursor(id)
                        }
                        if let event { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

Notes:
- Hummingbird gives `Host` as `request.head.authority` and does **not** percent-decode path parameters, so `pathID` decodes them.
- `Router` wraps its not-found responder in the middleware chain, so unknown routes also get the `Host`/token checks and JSON errors.
- `bind` decides from the first value on `outcome`: `true` from `onServerRunning`, or `false` when `run()` ends because the port was taken.
- `stop()` closes the hub first. An open SSE response would otherwise keep graceful shutdown waiting.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter HTTP`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentDropServer Tests/AgentDropServerTests
git commit -m "feat(server): HTTP API with token and Host checks, JSON errors, drops, content, SSE events, port fallback"
```

---

### Task 5: Folder watcher (FSEvents) and content watcher

**Files:**
- Create: `Sources/AgentDropServer/FolderWatcher.swift`, `Sources/AgentDropServer/ContentWatcher.swift`
- Test: `Tests/AgentDropServerTests/WatcherTests.swift`

**Interfaces:**
- Consumes: Task 1 (`drop(filename:)`, `checkPresence`, `recordContentChange`); Plan 1 `list`, `path(of:)`.
- Produces:
  - `FolderWatcher(folder:latency:handler:)` with `start() throws`, `stop()`, `Change` = `.store` | `.entry(String)` | `.rescan`, `static classify(path:root:)`, `static realPath(_:)`
  - `actor ContentWatcher(store:debounce:onChange:)` with `baselineNewDrops()`, `entryChanged(_:)`, `rescan()`, `cancelPending()`, `baseline(for:)` (tests)

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropServerTests/WatcherTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

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
        #expect(await eventually { await watcher.baseline(for: drop.id) != nil })
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
        #expect(await eventually { changes.value == 2 })
        #expect(try Self.types(f) == [.created, .missing, .metadata])

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

    /// Found under CI-like load: the file vanished between the presence check and the
    /// fingerprint. That must become `missing`, never a bogus `content` event.
    @Test func entryVanishingMidCheckIsMissingNotContent() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md", "1")
        let url = f.store.path(of: drop)
        let watcher = ContentWatcher(store: f.store, debounce: .milliseconds(10), onChange: {},
                                     beforeFingerprint: { try? FileManager.default.removeItem(at: url) })
        await watcher.baselineNewDrops()
        await watcher.entryChanged("a.md")
        #expect(await eventually { (try? Self.types(f)) == [.created, .missing] })
        try await Task.sleep(for: .milliseconds(100))
        #expect(try Self.types(f) == [.created, .missing])
    }

    /// A change arriving while the same entry is still being settled is settled again
    /// afterwards, never in parallel (the older result must not win).
    @Test func overlappingSettlesForOneEntryRunInOrder() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md", "1")
        let url = f.store.path(of: drop)
        let gate = Locked(true)
        let watcherBox = Locked<ContentWatcher?>(nil)
        let watcher = ContentWatcher(store: f.store, debounce: .milliseconds(5), onChange: {},
                                     beforeFingerprint: {
            // The first settle edits the file and reports another change while it's running.
            var first = false
            gate.withLock { first = $0; $0 = false }
            guard first else { return }
            try? Data("22".utf8).write(to: url)
            await watcherBox.value?.entryChanged("a.md")
            try? await Task.sleep(for: .milliseconds(50))
        })
        watcherBox.withLock { $0 = watcher }
        await watcher.baselineNewDrops()
        await watcher.entryChanged("a.md")
        #expect(await eventually { (try? Self.types(f)) == [.created, .content] })
        try await Task.sleep(for: .milliseconds(150))
        #expect(try Self.types(f) == [.created, .content])
    }

    @Test func stoppedWatcherIgnoresLateChanges() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md", "1")
        let (watcher, _) = make(f)
        await watcher.baselineNewDrops()
        try fm.removeItem(at: f.store.path(of: drop))
        await watcher.stop()
        await watcher.entryChanged("a.md")
        try await Task.sleep(for: .milliseconds(200))
        #expect(try Self.types(f) == [.created])
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter 'FolderWatcherTests|ContentWatcherTests'`
Expected: build error: `cannot find 'FolderWatcher' in scope`.

- [ ] **Step 3: Implement**

`Sources/AgentDropServer/FolderWatcher.swift` (create, complete file):

```swift
import CoreServices
import Foundation

/// FSEvents on the drop folder, reduced to what the server cares about: which top-level
/// entry changed, or that the store (`.agentdrop/`) changed.
public final class FolderWatcher: @unchecked Sendable {
    public enum Change: Equatable, Sendable {
        /// Something under `.agentdrop/` changed: new event rows may be waiting.
        case store
        /// A top-level entry (or anything inside it) changed.
        case entry(String)
        /// FSEvents dropped detail; check everything.
        case rescan
    }

    private let root: String
    private let latency: TimeInterval
    private let handler: @Sendable ([Change]) -> Void
    private let queue = DispatchQueue(label: "AgentDrop.FolderWatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(folder: URL, latency: TimeInterval = 0.05, handler: @escaping @Sendable ([Change]) -> Void) {
        root = Self.realPath(folder)
        self.latency = latency
        self.handler = handler
    }

    // No deinit cleanup: start() retains self until stop(), so a started watcher can't be
    // deallocated. Call stop() when done.

    public func start() throws {
        try lock.withLock {
            guard stream == nil else { return }
            // The stream holds a strong reference until stop(), so the watcher can never be
            // deallocated (and run stop() from its own queue) while callbacks may arrive.
            let retained = Unmanaged.passRetained(self)
            var context = FSEventStreamContext(version: 0, info: retained.toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, Self.callback, &context, [root] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else {
                retained.release()
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root])
            }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                retained.release()
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root])
            }
            stream = created
        }
    }

    /// After this returns, the handler is never called again.
    public func stop() {
        let stopping: FSEventStreamRef? = lock.withLock {
            defer { stream = nil }
            return stream
        }
        guard let stopping else { return }
        FSEventStreamStop(stopping)
        FSEventStreamInvalidate(stopping)
        queue.sync {} // drain a callback that's already running
        FSEventStreamRelease(stopping)
        Unmanaged.passUnretained(self).release() // balances passRetained in start()
    }

    static func classify(path: String, root: String) -> Change? {
        guard path.hasPrefix(root + "/") else { return nil }
        guard let first = path.dropFirst(root.count + 1).split(separator: "/").first else { return nil }
        if first == ".agentdrop" { return .store }
        if first.hasPrefix(".") { return nil }
        return .entry(String(first))
    }

    /// FSEvents reports real paths (`/private/var/...`). `URL.resolvingSymlinksInPath()`
    /// would strip `/private` again, so use realpath(3).
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard lock.withLock({ stream != nil }) else { return }
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        var changes: [Change] = []
        for (path, flag) in zip(paths, flags) {
            let change = flag & rescanFlags != 0 ? .rescan : Self.classify(path: path, root: root)
            if let change, !changes.contains(change) { changes.append(change) }
        }
        if !changes.isEmpty { handler(changes) }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        watcher.deliver(paths: array, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
    }
}
```

`Sources/AgentDropServer/ContentWatcher.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation

/// Turns folder changes into `content` events (spec §5.1), debounced per entry.
///
/// A drop's contents count as changed only when its fingerprint (size, modification time
/// and file identity of everything inside, ignoring dot-files and folders' own timestamps)
/// differs from the last one seen. A drop seen for the first time just gets a baseline,
/// so `drop add` never produces a `content` event. The same pass notices deleted and
/// returning entries and records them through `checkPresence` (spec §3.2).
public actor ContentWatcher {
    private let store: DropStore
    private let debounce: Duration
    private let onChange: @Sendable () async -> Void
    private var fingerprints: [String: Int] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    private var stopped = false
    /// Entries being settled right now, and those that changed again meanwhile. Settles
    /// suspend (fingerprinting), so two for one entry could otherwise overlap and the
    /// older one could overwrite the newer fingerprint.
    private var settling: Set<String> = []
    private var settleAgain: Set<String> = []
    private let beforeFingerprint: @Sendable () async -> Void

    /// `onChange` runs after this watcher wrote one or more events. `beforeFingerprint` is
    /// a test hook.
    public init(store: DropStore, debounce: Duration = .milliseconds(300),
                onChange: @escaping @Sendable () async -> Void,
                beforeFingerprint: @escaping @Sendable () async -> Void = {}) {
        self.store = store
        self.debounce = debounce
        self.onChange = onChange
        self.beforeFingerprint = beforeFingerprint
    }

    /// Records a baseline for every present drop that has none yet. Run at start and on
    /// every store change, so drops registered without a file change (in place) get one.
    public func baselineNewDrops() {
        guard let drops = try? allDrops() else { return }
        for drop in drops where fingerprints[drop.id] == nil && !drop.missing {
            fingerprints[drop.id] = Self.fingerprint(of: store.path(of: drop), isFolder: drop.isFolder)
        }
    }

    /// Something changed in the top-level entry `name`. Settles after `debounce` of quiet.
    public func entryChanged(_ name: String) {
        guard !stopped else { return }
        pending[name]?.cancel()
        pending[name] = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.settle(name)
        }
    }

    /// FSEvents lost detail: treat every drop as possibly changed.
    public func rescan() {
        guard let drops = try? allDrops() else { return }
        for drop in drops { entryChanged(drop.filename) }
    }

    /// The recorded fingerprint, if any. For tests.
    func baseline(for id: String) -> Int? { fingerprints[id] }

    /// The service is stopping: drop unsettled work and ignore changes that still arrive
    /// from FSEvents callbacks already in flight.
    public func stop() {
        stopped = true
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    private func settle(_ name: String) async {
        pending[name] = nil
        guard !settling.contains(name) else {
            settleAgain.insert(name)
            return
        }
        settling.insert(name)
        await settleExclusively(name)
        settling.remove(name)
        if settleAgain.remove(name) != nil { entryChanged(name) }
    }

    private func settleExclusively(_ name: String) async {
        guard !stopped, let drop = try? store.drop(filename: name) else { return }
        var wrote = false
        do {
            let checked = try store.checkPresence(drop.id)
            wrote = checked.missing != drop.missing
            if checked.missing {
                fingerprints[drop.id] = nil
            } else {
                await beforeFingerprint()
                guard let current = await Self.fingerprintOffPool(of: store.path(of: checked),
                                                                   isFolder: checked.isFolder) else {
                    // The entry vanished (or changed kind) after the presence check: record
                    // that instead, never a content change.
                    guard !stopped else { return }
                    let rechecked = try store.checkPresence(drop.id)
                    if rechecked.missing { fingerprints[drop.id] = nil }
                    wrote = wrote || rechecked.missing != checked.missing
                    if wrote { await onChange() }
                    return
                }
                guard !stopped else { return }
                let previous = fingerprints.updateValue(current, forKey: drop.id)
                // A return is reported by its `metadata {missing: false}` event; a first
                // sighting only sets the baseline.
                if !drop.missing, let previous, previous != current {
                    try store.recordContentChange(drop.id)
                    wrote = true
                }
            }
        } catch {
            // e.g. "store busy": skip this round; the next change to the entry retries.
        }
        if wrote { await onChange() }
    }

    private func allDrops() throws -> [Drop] {
        var filter = ListFilter()
        filter.includeArchived = true
        filter.limit = nil
        return try store.list(filter)
    }

    /// A private serial queue: unlike `DispatchQueue.global()`, whose threads are capped at
    /// about one per core and can all be blocked by other work, it always gets a thread.
    private static let fingerprintQueue = DispatchQueue(label: "AgentDrop.ContentWatcher.fingerprint")

    /// A folder drop can be a large tree; walk it off the shared concurrency pool.
    static func fingerprintOffPool(of url: URL, isFolder: Bool) async -> Int? {
        await withCheckedContinuation { continuation in
            fingerprintQueue.async {
                continuation.resume(returning: fingerprint(of: url, isFolder: isFolder))
            }
        }
    }

    /// nil when the entry itself is absent or not the expected kind (links never count).
    static func fingerprint(of url: URL, isFolder: Bool) -> Int? {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        guard type == (isFolder ? .typeDirectory : .typeRegular) else { return nil }
        var hasher = Hasher()
        if isFolder {
            walk(url, prefix: "", into: &hasher)
        } else {
            combine(url, relative: "", into: &hasher)
        }
        return hasher.finalize()
    }

    private static func walk(_ directory: URL, prefix: String, into hasher: inout Hasher) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        for name in names {
            let url = directory.appendingPathComponent(name)
            let isDirectory = combine(url, relative: prefix + name, into: &hasher)
            if isDirectory { walk(url, prefix: prefix + name + "/", into: &hasher) }
        }
    }

    /// Returns true for a real directory (links are never followed).
    @discardableResult
    private static func combine(_ url: URL, relative: String, into hasher: inout Hasher) -> Bool {
        hasher.combine(relative)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            hasher.combine("absent")
            return false
        }
        let type = attributes[.type] as? FileAttributeType
        hasher.combine(type?.rawValue)
        if type == .typeDirectory { return true } // its own mtime changes with Finder's .DS_Store
        hasher.combine((attributes[.size] as? NSNumber)?.int64Value)
        hasher.combine((attributes[.modificationDate] as? Date)?.timeIntervalSince1970)
        hasher.combine((attributes[.systemFileNumber] as? NSNumber)?.int64Value)
        if type == .typeSymbolicLink {
            hasher.combine(try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        }
        return false
    }
}
```

`realPath` uses `realpath(3)` because `URL.resolvingSymlinksInPath()` strips the `/private` prefix that FSEvents reports.

- [ ] **Step 4: Run the tests five times**

Run: `for i in 1 2 3 4 5; do swift test --filter 'FolderWatcherTests|ContentWatcherTests'; done`
Expected: all pass every time. These tests depend on timing, so wait for state with `eventually`; never just sleep and hope.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentDropServer Tests/AgentDropServerTests/WatcherTests.swift
git commit -m "feat(server): FSEvents folder watcher and debounced content watcher with fingerprints"
```

---

### Task 6: `AgentDropService`: what the app hosts

**Files:**
- Create: `Sources/AgentDropServer/AgentDropService.swift`
- Test: `Tests/AgentDropServerTests/ServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: `ServiceMessages.setupIncomplete`, `ServiceMessages.confirmFolder`; `actor AgentDropService(config:options:)` with `Options` (`portBase`, `portAttempts`, `debounce`, `heartbeat`, `pid`), `State` (`.stopped`, `.running(port:)`, `.noPort`), `start() async throws -> State`, `retryPort() async -> State`, `stop() async`, `state`, `clientCount`.

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropServerTests/ServiceTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

/// A config in a scratch home, with setup finished and the folder outside protected places.
struct ServiceFixture {
    let dir: ScratchDir
    let config: ConfigStore
    var folder: URL { dir.url.appendingPathComponent("AgentDrop", isDirectory: true) }
    var infoFile: ServerInfoFile { ServerInfoFile(configDir: config.configDir) }

    init(setupComplete: Bool = true) throws {
        dir = try ScratchDir()
        config = ConfigStore(configDir: dir.url.appendingPathComponent("support", isDirectory: true),
                             homeDir: dir.url.appendingPathComponent("home", isDirectory: true))
        try config.setFolder(dir.url.appendingPathComponent("AgentDrop", isDirectory: true))
        if setupComplete { try config.setSetupComplete(true) }
    }

    func service(portBase: Int = randomPortBase(), attempts: Int = 10) -> AgentDropService {
        var options = AgentDropService.Options()
        options.portBase = portBase
        options.portAttempts = attempts
        options.debounce = .milliseconds(50)
        return AgentDropService(config: config, options: options)
    }

    /// Another process's view of the store, like the CLI.
    func cliStore() throws -> DropStore { try DropStore.open(folder: folder, retention: .default) }

    func client() throws -> AgentDropClient {
        let info = try #require(infoFile.read())
        return AgentDropClient(port: try #require(info.port), token: try #require(info.token))
    }
}

/// True when nothing listens on the port any more.
func isRefused(port: Int) async throws -> Bool {
    do {
        _ = try await AgentDropClient(port: port, token: "x").get("/drops", timeout: 2)
        return false
    } catch {
        return true
    }
}

func addFile(_ store: DropStore, _ name: String, _ text: String = "# T\n", in dir: URL,
             handoff: Bool = false, project: String? = nil) throws -> Drop {
    let source = dir.appendingPathComponent("src-\(UUID().uuidString)/\(name)")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: source)
    return try store.add(AddRequest(source: .path(source), project: project, from: "cli", handoff: handoff))
}

struct ServiceGateTests {
    @Test func refusesToStartBeforeSetupAndTouchesNothing() async throws {
        let f = try ServiceFixture(setupComplete: false)
        let service = f.service()
        await #expect(throws: AgentDropError.invalid(ServiceMessages.setupIncomplete)) { try await service.start() }
        #expect(!FileManager.default.fileExists(atPath: f.folder.path))
        #expect(f.infoFile.read() == nil)
    }

    @Test func refusesAnUnconfirmedProtectedFolder() async throws {
        let f = try ServiceFixture()
        let desktop = f.config.homeDir.appendingPathComponent("Desktop/AgentDrop", isDirectory: true)
        try f.config.setFolder(desktop)
        let service = f.service()
        await #expect(throws: AgentDropError.invalid(ServiceMessages.confirmFolder)) { try await service.start() }
        #expect(!FileManager.default.fileExists(atPath: desktop.path))

        try f.config.setConfirmedFolder(desktop)
        #expect(try await service.start() != .stopped)
        await service.stop()
    }
}

struct ServiceRunTests {
    @Test func startWritesPrivateServerInfoAndStopRemovesIt() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        guard case .running(let port) = try await service.start() else { Issue.record("not running"); return }
        let info = try #require(f.infoFile.read())
        #expect(info.status == .running)
        #expect(info.port == port)
        #expect(info.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(info.token?.count == 64)
        let mode = try FileManager.default.attributesOfItem(atPath: f.infoFile.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(try await f.client().get("/drops").1 == 200)

        await service.stop()
        #expect(f.infoFile.read() == nil)
        #expect(await service.state == .stopped)
    }

    @Test func eachStartGetsANewToken() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        let first = f.infoFile.read()?.token
        await service.stop()
        _ = try await service.start()
        #expect(f.infoFile.read()?.token != first)
        await service.stop()
    }

    @Test func stopLeavesAnotherInstancesServerInfoAlone() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        try f.infoFile.write(.running(port: 1, token: "other", pid: 1))
        await service.stop()
        #expect(f.infoFile.read()?.token == "other")
    }

    /// The CLI writes from another process; FSEvents on `.agentdrop/` must deliver it live.
    @Test func writesFromAnotherStoreStreamLive() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let events = try await f.client().events(query: [URLQueryItem(name: "inbox", value: "")])
        let drop = try addFile(try f.cliStore(), "handoff.md", in: f.dir.url, handoff: true)
        let frame = try #require(try await first(events))
        #expect(frame.event == "created")
        #expect(frame.data.contains(drop.id))
    }

    @Test func editingADropFileStreamsOneContentEvent() async throws {
        let f = try ServiceFixture()
        let cli = try f.cliStore()
        let drop = try addFile(cli, "notes.md", "one", in: f.dir.url)
        let service = f.service()
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let events = try await f.client().events(query: [URLQueryItem(name: "drop", value: drop.id)])
        for text in ["two", "three!", "four!!"] {
            try Data(text.utf8).write(to: cli.path(of: drop))
        }
        let frame = try #require(try await first(events))
        #expect(frame.event == "content")
        #expect(try cli.events().filter { $0.type == .content }.count == 1)
    }

    @Test func deletingADropFileStreamsMissing() async throws {
        let f = try ServiceFixture()
        let cli = try f.cliStore()
        let drop = try addFile(cli, "gone.md", in: f.dir.url)
        let service = f.service()
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let events = try await f.client().events(query: [URLQueryItem(name: "drop", value: drop.id)])
        try FileManager.default.removeItem(at: cli.path(of: drop))
        #expect(try await first(events)?.event == "missing")
    }

    @Test func noPortStillWatchesContentAndRetryRecovers() async throws {
        let f = try ServiceFixture()
        let blocker = try ServiceFixture()
        let base = randomPortBase()
        let holder = blocker.service(portBase: base, attempts: 1)
        guard case .running(let taken) = try await holder.start() else { Issue.record("blocker"); return }

        let cli = try f.cliStore()
        let drop = try addFile(cli, "a.md", "1", in: f.dir.url)
        let service = f.service(portBase: taken, attempts: 1)
        #expect(try await service.start() == .noPort)
        #expect(f.infoFile.read() == .noPort(pid: ProcessInfo.processInfo.processIdentifier))

        try Data("22".utf8).write(to: cli.path(of: drop))
        #expect(await eventually { (try? cli.events().last?.type) == .content })

        #expect(await service.retryPort() == .noPort)
        await holder.stop()
        #expect(await service.retryPort() == .running(port: taken))
        #expect(f.infoFile.read()?.status == .running)
        // Clients catch up on what happened while there was no server.
        let events = try await f.client().events(lastEventID: "\(cli.storeID):1")
        #expect(try await first(events)?.event == "content")
        await service.stop()
    }

    @Test func switchingFoldersMeansResetForOldCursors() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        let oldStore = try f.cliStore()
        _ = try addFile(oldStore, "old.md", in: f.dir.url)
        await service.stop()

        try f.config.setFolder(f.dir.url.appendingPathComponent("Other", isDirectory: true))
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let events = try await f.client().events(lastEventID: "\(oldStore.storeID):1")
        let frame = try #require(try await first(events))
        #expect(frame.event == "reset")
        #expect(frame.data == SSE.resetData)
    }

    /// Review M1: overlapping calls run one at a time; nothing is left running after stop.
    @Test func overlappingStartsShareOneServerAndStopWins() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        async let a = service.start()
        async let b = service.start()
        let (first, second) = try await (a, b)
        #expect(first == second)
        guard case .running(let port) = first else { Issue.record("not running"); return }
        await service.stop()
        #expect(try await isRefused(port: port))

        // Whichever of these reaches the service first, the result is consistent: the
        // reported state, server.json and the listening port always agree.
        for _ in 0..<5 {
            let starting = Task { try await service.start() }
            await service.stop()
            let started = try await starting.value
            guard case .running(let port2) = started else { Issue.record("not running"); return }
            switch await service.state {
            case .stopped:
                #expect(f.infoFile.read() == nil)
                #expect(try await isRefused(port: port2))
            case .running(let port3):
                #expect(f.infoFile.read()?.port == port3)
                await service.stop()
                #expect(try await isRefused(port: port3))
            case .noPort:
                Issue.record("unexpected no-port")
            }
        }
    }

    /// Review M2: the app writes through the service's own store, whose connection stays
    /// open, so FSEvents never fires for it. Its commits must still stream at once.
    @Test func writesThroughTheServicesOwnStoreStreamLive() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let store = try #require(await service.store)
        let drop = try addFile(store, "h.md", in: f.dir.url, handoff: true)
        _ = try store.claim(drop.id, by: "x")
        let events = try await f.client().events(query: [URLQueryItem(name: "inbox", value: "")])
        _ = try store.release(drop.id)
        #expect(try await first(events, timeout: .seconds(2))?.event == "status")
    }

    /// Review M2: another long-lived writer is caught by the keepalive tick at the latest.
    @Test func aLongLivedExternalWriterIsCaughtByTheKeepaliveTick() async throws {
        let f = try ServiceFixture()
        var options = AgentDropService.Options()
        options.portBase = randomPortBase()
        options.heartbeat = .milliseconds(300)
        let service = AgentDropService(config: f.config, options: options)
        _ = try await service.start()
        defer { Task { await service.stop() } }
        let external = try f.cliStore()      // stays open for the whole test
        let drop = try addFile(external, "h.md", in: f.dir.url, handoff: true)
        _ = try external.claim(drop.id, by: "x")
        try await Task.sleep(for: .milliseconds(400))
        let events = try await f.client().events(query: [URLQueryItem(name: "inbox", value: "")])
        _ = try external.release(drop.id)
        #expect(try await first(events, timeout: .seconds(3))?.event == "status")
        withExtendedLifetime(external) {}
    }

    @Test func stopWithAConnectedClientIsPrompt() async throws {
        let f = try ServiceFixture()
        let service = f.service()
        _ = try await service.start()
        let events = try await f.client().events()
        #expect(await eventually { await service.clientCount == 1 })
        let elapsed = await ContinuousClock().measure { await service.stop() }
        #expect(elapsed < .seconds(2))
        #expect(try await first(events, timeout: .seconds(2)) == nil)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter Service`
Expected: build error: `cannot find 'AgentDropService' in scope`.

- [ ] **Step 3: Implement**

`Sources/AgentDropServer/AgentDropService.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation

/// User-facing reasons shared by the service and `drop watch` (spec §3, §4 Watching).
public enum ServiceMessages {
    public static let setupIncomplete =
        "Agent Drop hasn't been set up yet. Open the Agent Drop app once to finish setup."
    public static let confirmFolder = "Confirm the new drop folder in Agent Drop"
}

/// What the app hosts (spec §5.2): the content watcher and the HTTP server for the
/// configured folder, plus `server.json`. One instance per folder; a folder switch is
/// `stop()` then `start()`, which gives the new store's events a new `storeId`.
public actor AgentDropService {
    public struct Options: Sendable {
        /// nil: `serverPort` from config.json, else 47390.
        public var portBase: Int?
        /// The default port plus the next 9.
        public var portAttempts = 10
        public var debounce: Duration = .milliseconds(300)
        public var heartbeat: Duration = .seconds(15)
        public var pid: Int32 = ProcessInfo.processInfo.processIdentifier

        public init() {}
    }

    public enum State: Equatable, Sendable {
        case stopped
        case running(port: Int)
        /// The content watcher runs; no port in the range could be bound.
        case noPort
    }

    public private(set) var state: State = .stopped
    private let config: ConfigStore
    private let options: Options
    private var hub: EventHub?
    private var content: ContentWatcher?
    private var watcher: FolderWatcher?
    private var server: HTTPServer?
    private var portBase = AgentDropConfig.defaultServerPort
    /// The last queued operation. start/stop/retryPort run one at a time, in call order:
    /// each suspends on its way, and an overlapping call must not see a half-started state.
    private var lastOperation: Task<Void, Never>?

    /// The running store. In-process writers (the app) should write through it: its
    /// commits reach event-stream clients at once.
    public private(set) var store: DropStore?

    public init(config: ConfigStore, options: Options = Options()) {
        self.config = config
        self.options = options
    }

    private var infoFile: ServerInfoFile { ServerInfoFile(configDir: config.configDir) }

    /// Connected event-stream clients.
    public var clientCount: Int {
        get async { await hub?.subscriberCount ?? 0 }
    }

    /// Refuses (touching nothing) until setup is complete and any protected folder is
    /// confirmed. Otherwise starts the content watcher, then the server.
    @discardableResult
    public func start() async throws -> State {
        try await serially { try await $0.performStart() }
    }

    /// The app's **Retry** button after `noPort`.
    @discardableResult
    public func retryPort() async -> State {
        (try? await serially { service -> State in
            guard await service.state == .noPort else { return await service.state }
            return (try? await service.bindServer()) ?? .noPort
        }) ?? state
    }

    /// Stops everything and removes `server.json` if this instance wrote it.
    public func stop() async {
        _ = try? await serially { await $0.performStop() }
    }

    private func serially<T: Sendable>(_ operation: @escaping @Sendable (AgentDropService) async throws -> T)
        async throws -> T
    {
        let previous = lastOperation
        let task = Task<T, Error> {
            await previous?.value
            return try await operation(self)
        }
        lastOperation = Task { _ = try? await task.value }
        return try await task.value
    }

    private func performStart() async throws -> State {
        guard state == .stopped else { return state }
        let settings = try config.load()
        guard settings.setupComplete else { throw AgentDropError.invalid(ServiceMessages.setupIncomplete) }
        guard !config.folderNeedsConfirmation(settings) else {
            throw AgentDropError.invalid(ServiceMessages.confirmFolder)
        }
        portBase = options.portBase ?? settings.serverPort ?? AgentDropConfig.defaultServerPort

        let folder = config.folderURL(settings)
        let store = try DropStore.open(folder: folder, retention: settings.eventRetentionDays)
        let hub = try EventHub(store: store)
        store.observeEventCommits { Task { await hub.poke() } }
        await hub.startHeartbeat(every: options.heartbeat)
        let content = ContentWatcher(store: store, debounce: options.debounce, onChange: { await hub.poke() })
        await content.baselineNewDrops()
        let watcher = FolderWatcher(folder: folder) { changes in
            Task {
                for change in changes {
                    switch change {
                    case .store:
                        await hub.poke()
                        await content.baselineNewDrops()
                    case .entry(let name):
                        await content.entryChanged(name)
                    case .rescan:
                        await hub.poke()
                        await content.rescan()
                    }
                }
            }
        }
        self.store = store
        self.hub = hub
        self.content = content
        self.watcher = watcher
        do {
            try watcher.start()
            return try await bindServer()
        } catch {
            await performStop()
            if let error = error as? AgentDropError { throw error }
            throw AgentDropError.invalid("Can't start serving \(folder.path): \(error.localizedDescription)")
        }
    }

    private func performStop() async {
        await server?.stop()
        await hub?.close()
        watcher?.stop()
        await content?.stop()
        if infoFile.read()?.pid == options.pid { infoFile.remove() }
        server = nil
        hub = nil
        content = nil
        watcher = nil
        store = nil
        state = .stopped
    }

    private func bindServer() async throws -> State {
        guard let store, let hub else { return state }
        let token = ServerInfo.newToken()
        do {
            let server = try await HTTPServer.start(store: store, hub: hub, token: token, portBase: portBase,
                                                    attempts: options.portAttempts)
            self.server = server
            try infoFile.write(.running(port: server.port, token: token, pid: options.pid))
            state = .running(port: server.port)
        } catch is HTTPServer.PortsExhausted {
            try infoFile.write(.noPort(pid: options.pid))
            state = .noPort
        }
        return state
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test`
Expected: all pass. Run the full suite three times: these tests run in parallel with everything else.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentDropServer/AgentDropService.swift Tests/AgentDropServerTests/ServiceTests.swift
git commit -m "feat(server): AgentDropService with setup and folder gates, server.json, no-port retry, clean stop"
```

---

### Task 7: Terminal-safe human output

**Files:**
- Modify: `Sources/DropCLI/Output.swift`, `Sources/DropCLI/DropCLI.swift` (one line)
- Test: `Tests/dropCLITests/TerminalSafetyTests.swift`

**Interfaces:**
- Produces: `Output.terminalSafe(_ text: String, keepNewlines: Bool = false) -> String`, used by every human-readable line, including `drop watch` (Task 8).

- [ ] **Step 1: Write the failing tests**

`Tests/dropCLITests/TerminalSafetyTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import DropCLI

/// Human-readable output must never pass terminal control sequences through: titles come
/// from file contents, so a dropped file could otherwise drive the reader's terminal.
struct TerminalSafetyTests {
    static let evil = "Evil \u{1B}]0;pwned\u{07}\u{1B}[2J\u{9B}31m\tnext\r\nline"

    func hasControls(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 || $0.value == 0x9B || $0.value == 0x0D }
    }

    @Test func sanitizer() {
        #expect(Output.terminalSafe("a\tb\nc\r\nd") == "a b c  d")
        #expect(Output.terminalSafe("x\u{1B}[31my\u{7F}\u{9B}") == "x\u{FFFD}[31my\u{FFFD}\u{FFFD}")
        #expect(Output.terminalSafe("one\ntwo\u{1B}", keepNewlines: true) == "one\ntwo\u{FFFD}")
        #expect(Output.terminalSafe("Q3 plan — draft ✅") == "Q3 plan — draft ✅")
    }

    @Test func listAndShowAreSafeButJSONIsExact() throws {
        let env = try TestEnv()
        try env.file("evil.md", "# \(Self.evil)\n")
        let id = env.run("add", "evil.md", "--from", "a", "-m", "first\nsecond\u{1B}[1m").trimmedOut

        let list = env.run("list")
        #expect(!hasControls(list.out))
        #expect(list.out.split(separator: "\n").count == 1)
        #expect(list.out.split(separator: "\t").count == 6)

        let show = env.run("show", id)
        #expect(!hasControls(show.out))
        #expect(show.out.contains("first\nsecond"))

        let json = env.run("show", id, "--json")
        #expect((json.json["title"] as? String)?.contains("\u{1B}]0;pwned") == true)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter TerminalSafetyTests`
Expected: build error: `type 'Output' has no member 'terminalSafe'`.

- [ ] **Step 3: Implement**

`Sources/DropCLI/Output.swift` (replace, complete file):

```swift
import AgentDropCore
import Foundation

enum Output {
    static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }

    static func emit(_ line: String) { CLIContext.current.stdout.line(line) }
    static func emitJSON<T: Encodable>(_ value: T) { emit(jsonString(value)) }

    /// For human-readable output only (JSON escapes these itself). Titles come from file
    /// contents, so control characters must never reach the terminal: tab, CR and LF become
    /// spaces (LF is kept with `keepNewlines`), every other C0/C1 control and DEL becomes U+FFFD.
    static func terminalSafe(_ text: String, keepNewlines: Bool = false) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A where keepNewlines: scalars.append(scalar)
            case 0x09, 0x0A, 0x0D: scalars.append(" ")
            case 0x00..<0x20, 0x7F...0x9F: scalars.append("\u{FFFD}")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// One tab-separated line: id, state, title, project, from, created[, flags].
    static func line(for drop: Drop) -> String {
        let state = drop.status.map { "handoff:\($0.rawValue)" } ?? "note"
        var fields = [drop.id, state, drop.title, drop.project ?? "-", drop.from, drop.createdAt.iso]
        if drop.archived { fields.append("[archived]") }
        if drop.missing { fields.append("[missing]") }
        return fields.map { terminalSafe($0) }.joined(separator: "\t")
    }

    static func details(for drop: Drop, path: String) -> String {
        var rows: [(String, String)] = [("id", drop.id), ("title", drop.title), ("path", path)]
        rows.append(("kind", drop.status.map { "handoff (\($0.rawValue))" } ?? "note"))
        if let by = drop.claimedBy { rows.append(("claimed by", by)) }
        if let note = drop.statusNote { rows.append(("status note", note)) }
        rows.append(("from", drop.from))
        rows.append(("project", drop.project ?? "-"))
        rows.append(("tags", drop.tags.isEmpty ? "-" : drop.tags.joined(separator: ", ")))
        if let description = drop.description { rows.append(("description", description)) }
        rows.append(("created", drop.createdAt.iso))
        rows.append(("updated", drop.updatedAt.iso))
        rows.append(("folder drop", drop.isFolder ? "yes" : "no"))
        rows.append(("archived", drop.archived ? "yes" : "no"))
        rows.append(("missing", drop.missing ? "yes" : "no"))
        return rows.map { label, value in
            "\(label):".padding(toLength: 13, withPad: " ", startingAt: 0)
                + terminalSafe(value, keepNewlines: label == "description")
        }
            .joined(separator: "\n")
    }

    /// Mutating commands: JSON object, or the one-line summary.
    static func printDrop(_ drop: Drop, store: DropStore, json: Bool) {
        if json { emitJSON(store.json(drop)) } else { emit(line(for: drop)) }
    }

    static func printDrops(_ drops: [Drop], store: DropStore, json: Bool) {
        if json {
            emitJSON(drops.map(store.json))
        } else {
            drops.forEach { emit(line(for: $0)) }
        }
    }
}
```

In `Sources/DropCLI/DropCLI.swift`'s `report`, change the human branch to `context.stderr.line("drop: \(Output.terminalSafe(message))")`.

`drop cat`, `drop path` and `drop where` stay byte-exact: scripts consume their output (`cat "$(drop path id)"`).

- [ ] **Step 4: Run the tests**

Run: `swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/DropCLI Tests/dropCLITests/TerminalSafetyTests.swift
git commit -m "fix(cli): strip terminal control characters from human-readable output"
```

---

### Task 8: `drop watch`

**Files:**
- Modify: `Package.swift` (`DropCLI` and `dropCLITests` depend on `AgentDropServer`), `Sources/DropCLI/CLIContext.swift`, `Sources/DropCLI/DropCLI.swift`, `Sources/drop/main.swift`, `Tests/dropCLITests/TestEnv.swift`
- Create: `Sources/DropCLI/Commands/WatchCommand.swift`
- Test: `Tests/dropCLITests/WatchCommandTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 4, 6, 7.
- Produces: `CLIContext.launchApp`, `.isProcessAlive`, `.serverWait`, `CLIContext.appBundleID = "io.github.mrbenj.AgentDrop"`; `DropCLI.runAsync(_:context:) async -> Int32`; `TestEnv.runAsync(_:out:)`.

- [ ] **Step 1: Add the dependencies**

In `Package.swift`, add `"AgentDropServer"` to the `DropCLI` target's dependencies, and to `dropCLITests`:

```swift
        .testTarget(name: "dropCLITests", dependencies: ["DropCLI", "AgentDropCore", "AgentDropServer"]),
```

- [ ] **Step 2: Write the failing tests**

`Tests/dropCLITests/TestEnv.swift` (replace, complete file):

```swift
import Foundation
@testable import AgentDropCore
@testable import DropCLI

/// Each test gets its own home, config dir, drop folder and cwd. No real paths are touched.
final class TestEnv: @unchecked Sendable {
    let root: URL
    let config: ConfigStore
    let cwd: URL
    var stdin = Data()
    var codeExecutable: URL?
    var useRealProcess = false
    /// `drop watch` hooks. By default launching fails, so a test must opt in.
    var launchApp: @Sendable () throws -> Void = { throw AgentDropError.invalid("no app in tests") }
    var isProcessAlive: @Sendable (Int32) -> Bool = { pid in pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }
    var serverWait: Duration = .seconds(3)
    let clock = Date(timeIntervalSince1970: 1_760_208_240)
    private let lock = NSLock()
    private var _processCalls: [(URL, [String])] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropcli-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        cwd = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        config = ConfigStore(
            configDir: home.appendingPathComponent("Library/Application Support/AgentDrop", isDirectory: true),
            homeDir: home)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var home: URL { config.homeDir }
    var dropFolder: URL { home.appendingPathComponent("AgentDrop", isDirectory: true) }
    var processCalls: [(URL, [String])] { lock.withLock { _processCalls } }

    struct Result {
        let code: Int32
        let out: String
        let err: String
        let outData: Data
        var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: outData)) as? [String: Any]) ?? [:] }
        var jsonArray: [[String: Any]] { ((try? JSONSerialization.jsonObject(with: outData)) as? [[String: Any]]) ?? [] }
        var trimmedOut: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func makeContext(out: OutputSink, err: OutputSink) -> CLIContext {
        let stdin = self.stdin, clock = self.clock, code = self.codeExecutable
        let useRealProcess = self.useRealProcess
        return CLIContext(
            config: config, cwd: cwd, now: { clock }, readStdin: { stdin },
            stdout: out, stderr: err,
            findExecutable: { $0 == "code" ? code : nil },
            runProcess: { [weak self] executable, args in
                if useRealProcess { return try CLIContext.live().runProcess(executable, args) }
                self?.lock.withLock { self?._processCalls.append((executable, args)) }
                return 0
            },
            launchApp: launchApp, isProcessAlive: isProcessAlive, serverWait: serverWait)
    }

    @discardableResult
    func run(_ arguments: String...) -> Result {
        let out = OutputSink(), err = OutputSink()
        let status = DropCLI.run(arguments, context: makeContext(out: out, err: err))
        return Result(code: status, out: out.text, err: err.text, outData: out.data)
    }

    /// For `drop watch`. `out` can be read while the command is still running.
    func runAsync(_ arguments: [String], out: OutputSink = OutputSink()) async -> Result {
        let err = OutputSink()
        let status = await DropCLI.runAsync(arguments, context: makeContext(out: out, err: err))
        return Result(code: status, out: out.text, err: err.text, outData: out.data)
    }

    @discardableResult
    func file(_ relative: String, _ contents: String) throws -> URL {
        try data(relative, Data(contents.utf8))
    }

    @discardableResult
    func data(_ relative: String, _ data: Data) throws -> URL {
        let url = cwd.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}
```

`Tests/dropCLITests/WatchCommandTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer
@testable import DropCLI

/// `drop watch` end-to-end against an in-process AgentDropService (spec §8).
struct WatchCommandTests {
    func ready(_ env: TestEnv) throws {
        try env.config.setSetupComplete(true)
    }

    func service(_ env: TestEnv) -> AgentDropService {
        var options = AgentDropService.Options()
        options.portBase = Int.random(in: 20_000...59_000)
        options.debounce = .milliseconds(50)
        return AgentDropService(config: env.config, options: options)
    }

    func waitFor(_ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    func handoff(_ env: TestEnv, _ name: String = "task.md", project: String = "p") -> String {
        env.stdin = Data("# Do the thing".utf8)
        return env.run("add", "-", "--name", name, "--from", "agent-a", "--project", project, "--handoff").trimmedOut
    }

    // MARK: - Gates and arguments

    @Test func beforeSetupExits1WithTheSpecMessage() async throws {
        let env = try TestEnv()
        let r = await env.runAsync(["watch", "--inbox"])
        #expect(r.code == 1)
        #expect(r.err == "drop: \(ServiceMessages.setupIncomplete)\n")
    }

    @Test func unconfirmedProtectedFolderExits1() async throws {
        let env = try TestEnv()
        try ready(env)
        try env.config.setFolder(env.home.appendingPathComponent("Desktop/AgentDrop"))
        let r = await env.runAsync(["watch", "--inbox", "--json"])
        #expect(r.code == 1)
        #expect(r.json["error"] as? String == ServiceMessages.confirmFolder)
    }

    @Test(arguments: [["watch"], ["watch", "abcdef", "--inbox"], ["watch", "abcdef", "--project", "p"]])
    func needsExactlyOneTarget(_ arguments: [String]) async throws {
        let env = try TestEnv()
        try ready(env)
        #expect(await env.runAsync(arguments).code == 1)
    }

    @Test func syncRunnerRefusesWatch() throws {
        let env = try TestEnv()
        #expect(env.run("watch", "--inbox").code == 1)
    }

    // MARK: - Finding the app

    @Test func noPortExits1WithoutLaunching() async throws {
        let env = try TestEnv()
        try ready(env)
        try ServerInfoFile(configDir: env.config.configDir).write(.noPort(pid: getpid()))
        let launches = Locked(0)
        env.launchApp = { launches.withLock { $0 += 1 } }
        let r = await env.runAsync(["watch", "--inbox"])
        #expect(r.code == 1)
        #expect(r.err.contains("no port was free"))
        #expect(launches.value == 0)
    }

    @Test func launchesTheAppWhenServerInfoIsMissingOrStale() async throws {
        for stale in [false, true] {
            let env = try TestEnv()
            try ready(env)
            if stale { try ServerInfoFile(configDir: env.config.configDir).write(.running(port: 1, token: "x", pid: Int32.max)) }
            let service = service(env)
            let launches = Locked(0)
            env.launchApp = {
                launches.withLock { $0 += 1 }
                Task { try await service.start() }
            }
            let out = OutputSink()
            let watch = Task { await env.runAsync(["watch", "--inbox", "--once", "--json"], out: out) }
            #expect(await waitFor { await service.clientCount == 1 }, "stale: \(stale)")
            let id = handoff(env)
            let r = await watch.value
            #expect(r.code == 0)
            #expect(launches.value == 1)
            #expect(r.json["dropId"] as? String == id)
            #expect(r.json["type"] as? String == "created")
            await service.stop()
        }
    }

    @Test func launchFailureOrSilenceExits1() async throws {
        let env = try TestEnv()
        try ready(env)
        env.launchApp = { throw AgentDropError.invalid("Couldn't launch Agent Drop. Is AgentDrop.app installed?") }
        let failed = await env.runAsync(["watch", "--inbox"])
        #expect(failed.code == 1)
        #expect(failed.err.contains("Is AgentDrop.app installed?"))

        env.launchApp = {}
        env.serverWait = .milliseconds(300)
        let silent = await env.runAsync(["watch", "--inbox"])
        #expect(silent.code == 1)
        #expect(silent.err.contains("didn't start its server"))
    }

    // MARK: - Watching

    @Test func unknownIdExits2() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        defer { Task { await service.stop() } }
        let r = await env.runAsync(["watch", "zzzzzz", "--json"])
        #expect(r.code == 2)
        #expect(r.json["code"] as? Int == 2)
    }

    @Test func watchOneDropByFilenamePrintsHumanLinesAndEndsOnMissing() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        defer { Task { await service.stop() } }
        let id = handoff(env, "my task.md")
        let out = OutputSink()
        let watch = Task { await env.runAsync(["watch", "my task.md"], out: out) }
        #expect(await waitFor { await service.clientCount == 1 })

        #expect(env.run("claim", id, "--by", "djleague/autodev/AutoDev DJ-1 [ef0]").code == 0)
        #expect(await waitFor { out.text.contains("open → claimed by djleague/autodev/AutoDev DJ-1 [ef0]") })
        try FileManager.default.removeItem(at: env.dropFolder.appendingPathComponent("my task.md"))

        let r = await watch.value
        #expect(r.code == 0)
        let lines = r.out.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        #expect(lines.map { $0[1] } == ["status", "missing"])
        #expect(lines.allSatisfy { $0[2] == id && $0.count == 4 })
        #expect(lines.last?[3] == "file is missing")
    }

    @Test func inboxWatchDeliversArrivalsOnlyForItsProject() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        defer { Task { await service.stop() } }
        let out = OutputSink()
        let watch = Task { await env.runAsync(["watch", "--inbox", "--project", "p", "--json"], out: out) }
        #expect(await waitFor { await service.clientCount == 1 })

        let other = handoff(env, "other.md", project: "q")
        let mine = handoff(env, "mine.md", project: "p")
        _ = env.run("claim", mine, "--by", "x")     // departure: not delivered
        _ = env.run("release", mine)                 // arrival again
        #expect(await waitFor { out.text.split(separator: "\n").count == 2 })
        watch.cancel()
        _ = await watch.value

        // Cancelling the command makes it print one error object; keep only events.
        let lines = out.text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["type"] != nil }
        #expect(lines.map { $0["type"] as? String } == ["created", "status"])
        #expect(lines.allSatisfy { $0["dropId"] as? String == mine })
        #expect(!out.text.contains(other))
    }

    /// Spec §5.3: a folder switch restarts the server; `--inbox` prints `reset` and goes on
    /// with the new folder, a watch on one drop exits 2.
    @Test func folderSwitchResetsInboxWatchesAndEndsDropWatches() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        let id = handoff(env, "old.md")
        let inboxOut = OutputSink()
        let inbox = Task { await env.runAsync(["watch", "--inbox", "--json"], out: inboxOut) }
        let dropWatch = Task { await env.runAsync(["watch", id, "--json"]) }
        #expect(await waitFor { await service.clientCount == 2 })

        await service.stop()
        #expect(env.run("config", "set-folder", env.root.appendingPathComponent("Second").path).code == 0)
        try await service.start()

        let ended = await dropWatch.value
        #expect(ended.code == 2)
        #expect(ended.json["error"] as? String == "drop folder changed; \(id) is not in the current folder")

        #expect(await waitFor { inboxOut.text.contains(#""type":"reset""#) })
        #expect(await waitFor { await service.clientCount == 1 })
        let fresh = handoff(env, "new.md")
        #expect(await waitFor { inboxOut.text.contains(fresh) })
        inbox.cancel()
        _ = await inbox.value
        let types = inboxOut.text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["type"] as? String
        }
        #expect(types == ["reset", "created"])
        await service.stop()
    }

    @Test func appQuittingEndsTheWatchWithExit1() async throws {
        let env = try TestEnv()
        try ready(env)
        env.serverWait = .milliseconds(500)
        let service = service(env)
        try await service.start()
        let watch = Task { await env.runAsync(["watch", "--inbox"]) }
        #expect(await waitFor { await service.clientCount == 1 })
        await service.stop()
        let r = await watch.value
        #expect(r.code == 1)
        #expect(r.err.contains("Lost the connection to Agent Drop"))
    }

    /// Review M3: the drop was deleted and its record removed while the server was down.
    /// Same folder, so the watch replays `missing` and ends with exit 0, not "folder changed".
    @Test func dropRemovedWhileDisconnectedReplaysAndExits0() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        let id = handoff(env, "gone.md")
        let out = OutputSink()
        let watch = Task { await env.runAsync(["watch", id, "--json"], out: out) }
        #expect(await waitFor { await service.clientCount == 1 })
        await service.stop()

        let store = try DropStore.open(folder: env.dropFolder, retention: .default)
        try FileManager.default.removeItem(at: env.dropFolder.appendingPathComponent("gone.md"))
        _ = try store.checkPresence(id)
        try store.removeRecord(id)
        try await service.start()

        let r = await watch.value
        #expect(r.code == 0)
        let types = r.out.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["type"] as? String
        }
        #expect(types == ["missing"])
        await service.stop()
    }

    @Test func eventsWhileReconnectingAreReplayed() async throws {
        let env = try TestEnv()
        try ready(env)
        let service = service(env)
        try await service.start()
        let id = handoff(env)
        let out = OutputSink()
        let watch = Task { await env.runAsync(["watch", id, "--json"], out: out) }
        #expect(await waitFor { await service.clientCount == 1 })
        _ = env.run("claim", id, "--by", "a")
        #expect(await waitFor { out.text.contains(#""to":"claimed""#) })

        await service.stop()
        _ = env.run("release", id)           // written while no server runs
        try await service.start()
        #expect(await waitFor { out.text.contains(#""to":"open""#) })
        _ = env.run("archive", id)
        #expect(await waitFor { out.text.contains(#""type":"archived""#) })
        watch.cancel()
        _ = await watch.value
        await service.stop()
    }

    /// Human lines never carry terminal control characters (titles come from file contents).
    @Test func watchLinesAreSafe() async throws {
        let env = try TestEnv()
        try env.config.setSetupComplete(true)
        var options = AgentDropService.Options()
        options.portBase = Int.random(in: 20_000...59_000)
        let service = AgentDropService(config: env.config, options: options)
        try await service.start()
        defer { Task { await service.stop() } }
        let out = OutputSink()
        let watch = Task { await env.runAsync(["watch", "--inbox", "--once"], out: out) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await service.clientCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try env.file("evil.md", "# \(TerminalSafetyTests.evil)\n")
        #expect(env.run("add", "evil.md", "--from", "a", "--handoff").code == 0)
        let r = await watch.value
        #expect(r.code == 0)
        #expect(!TerminalSafetyTests().hasControls(r.out))
        #expect(r.out.split(separator: "\n").count == 1)
        #expect(r.out.split(separator: "\t").count == 4)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func withLock(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --filter WatchCommandTests`
Expected: build error: `extra arguments 'launchApp', 'isProcessAlive', 'serverWait' in call` and `type 'DropCLI' has no member 'runAsync'`.

- [ ] **Step 4: Implement**

`Sources/DropCLI/CLIContext.swift` (replace, complete file):

```swift
import AgentDropCore
import AgentDropServer
import Foundation

/// Buffered (tests) or pass-through (live) output.
public final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let handle: FileHandle?

    public init(handle: FileHandle? = nil) {
        self.handle = handle
    }

    public func write(_ data: Data) {
        lock.withLock {
            if let handle { handle.write(data) } else { buffer.append(data) }
        }
    }

    public func write(_ string: String) { write(Data(string.utf8)) }
    public func line(_ string: String) { write(string + "\n") }
    public var data: Data { lock.withLock { buffer } }
    public var text: String { String(decoding: data, as: UTF8.self) }
}

/// Everything a command touches outside its own arguments. Tests inject all of it (spec §8).
public struct CLIContext: Sendable {
    public var config: ConfigStore
    public var cwd: URL
    public var now: @Sendable () -> Date
    public var readStdin: @Sendable () -> Data
    public var stdout: OutputSink
    public var stderr: OutputSink
    public var findExecutable: @Sendable (String) -> URL?
    public var runProcess: @Sendable (URL, [String]) throws -> Int32
    /// `drop watch`: start AgentDrop.app without opening its window (spec §4 Watching).
    public var launchApp: @Sendable () throws -> Void
    public var isProcessAlive: @Sendable (Int32) -> Bool
    /// How long `drop watch` waits for the app's server (spec: 10 s).
    public var serverWait: Duration

    public init(config: ConfigStore, cwd: URL, now: @escaping @Sendable () -> Date,
                readStdin: @escaping @Sendable () -> Data, stdout: OutputSink, stderr: OutputSink,
                findExecutable: @escaping @Sendable (String) -> URL?,
                runProcess: @escaping @Sendable (URL, [String]) throws -> Int32,
                launchApp: @escaping @Sendable () throws -> Void = {
                    throw AgentDropError.invalid("Launching Agent Drop isn't available here")
                },
                isProcessAlive: @escaping @Sendable (Int32) -> Bool = ServerInfo.isProcessAlive,
                serverWait: Duration = .seconds(10)) {
        self.config = config
        self.cwd = cwd
        self.now = now
        self.readStdin = readStdin
        self.stdout = stdout
        self.stderr = stderr
        self.findExecutable = findExecutable
        self.runProcess = runProcess
        self.launchApp = launchApp
        self.isProcessAlive = isProcessAlive
        self.serverWait = serverWait
    }

    /// AgentDrop.app's bundle identifier (Plan 3 builds the app with it).
    public static let appBundleID = "io.github.mrbenj.AgentDrop"

    @TaskLocal public static var current: CLIContext = .live()

    public static func live() -> CLIContext {
        let runProcess: @Sendable (URL, [String]) throws -> Int32 = { executable, arguments in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // Drain both streams together before waiting, so even verbose children
            // cannot fill a pipe or bypass the CLI's JSON/error output policy.
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let detail = String(decoding: diagnostics, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw AgentDropError.invalid("`\(executable.lastPathComponent)` exited with status \(process.terminationStatus)"
                    + (detail.isEmpty ? "" : ": \(detail)"))
            }
            return process.terminationStatus
        }
        return CLIContext(
            config: .live(),
            cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            now: { Date() },
            readStdin: { FileHandle.standardInput.readDataToEndOfFile() },
            stdout: OutputSink(handle: .standardOutput),
            stderr: OutputSink(handle: .standardError),
            findExecutable: { name in
                let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
                for directory in path.split(separator: ":") {
                    let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
                    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                }
                return nil
            },
            runProcess: runProcess,
            launchApp: {
                // -g: don't bring it to the front. `--windowless` tells the app not to open its
                // window (spec §4 Watching); the menu bar icon still appears.
                do {
                    _ = try runProcess(URL(fileURLWithPath: "/usr/bin/open"),
                                       ["-g", "-b", appBundleID, "--args", "--windowless"])
                } catch let error as AgentDropError {
                    throw AgentDropError.invalid("Couldn't launch Agent Drop. Is AgentDrop.app installed? (\(error.message))")
                }
            })
    }

    /// `~`, relative-to-cwd, and trailing-slash handling for user-supplied paths.
    public func resolvePath(_ raw: String) -> URL {
        var path = raw
        if path == "~" {
            path = config.homeDir.path
        } else if path.hasPrefix("~/") {
            path = config.homeDir.path + String(path.dropFirst(1))
        }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : cwd.appendingPathComponent(path)
        return url.standardizedFileURL
    }

    /// Opens the store in the configured folder, creating the folder if needed (spec §7).
    public func openStore() throws -> DropStore {
        let settings = try config.load()
        let folder = config.folderURL(settings)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw AgentDropError.invalid("Can't create the drop folder at \(folder.path): \(error.localizedDescription)")
        }
        return try DropStore.open(folder: folder, retention: settings.eventRetentionDays, now: now)
    }
}
```

`Sources/DropCLI/DropCLI.swift` (replace, complete file):

```swift
import AgentDropCore
import ArgumentParser
import Foundation

public enum DropCLI {
    /// Parses and runs one invocation; returns the process exit code (spec §4 Global rules).
    /// Synchronous commands only (`drop watch` needs `runAsync`).
    public static func run(_ arguments: [String], context: CLIContext) -> Int32 {
        let wantsJSON = arguments.contains("--json")
        return CLIContext.$current.withValue(context) {
            do {
                var command = try DropCommand.parseAsRoot(arguments)
                guard !(command is AsyncParsableCommand) else {
                    throw AgentDropError.invalid("\(arguments.first ?? "this command") needs DropCLI.runAsync")
                }
                try command.run()
                return 0
            } catch {
                return handle(error, json: wantsJSON, context: context)
            }
        }
    }

    /// What `main.swift` calls: runs every command, including `drop watch`.
    public static func runAsync(_ arguments: [String], context: CLIContext) async -> Int32 {
        let wantsJSON = arguments.contains("--json")
        return await CLIContext.$current.withValue(context) {
            do {
                var command = try DropCommand.parseAsRoot(arguments)
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
                return 0
            } catch {
                return handle(error, json: wantsJSON, context: context)
            }
        }
    }

    private static func handle(_ error: Error, json: Bool, context: CLIContext) -> Int32 {
        if let error = error as? AgentDropError {
            report(error.message, code: error.exitCode, json: json, context: context)
            return error.exitCode
        }
        if DropCommand.exitCode(for: error) == .success {
            context.stdout.line(DropCommand.fullMessage(for: error))
            return 0
        }
        report(DropCommand.fullMessage(for: error), code: 1, json: json, context: context)
        return 1
    }

    private struct ErrorJSON: Encodable {
        let error: String
        let code: Int32
    }

    private static func report(_ message: String, code: Int32, json: Bool, context: CLIContext) {
        if json {
            context.stdout.line(Output.jsonString(ErrorJSON(error: message, code: code)))
        } else {
            context.stderr.line("drop: \(Output.terminalSafe(message))")
        }
    }
}

struct DropCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drop",
        abstract: "Agent Drop: a shared drop folder with context, for humans and coding agents.",
        version: "0.1.0",
        subcommands: [Add.self, Edit.self, Archive.self, ListCommand.self, Show.self, Cat.self, PathCommand.self,
                      Latest.self, Inbox.self, Claim.self, Release.self, Done.self, Reopen.self, Code.self,
                      Watch.self, Where.self, Config.self, AgentInstructions.self]
    )
}

struct JSONOption: ParsableArguments {
    @Flag(name: .long, help: "Machine-readable JSON output.")
    var json = false
}
```

`Sources/drop/main.swift` (replace, complete file):

```swift
import DropCLI
import Foundation

exit(await DropCLI.runAsync(Array(CommandLine.arguments.dropFirst()), context: .live()))
```

`Sources/DropCLI/Commands/WatchCommand.swift` (create, complete file):

```swift
import AgentDropCore
import AgentDropServer
import ArgumentParser
import Foundation

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Stream changes to one drop, or handoffs arriving in the Inbox (uses the Agent Drop app).")
    @Argument(help: "Id or exact filename.") var id: String?
    @Flag(help: "Watch handoffs entering the Inbox instead of one drop.") var inbox = false
    @Option(help: "With --inbox: only this project.") var project: String?
    @Flag(help: "Exit after the first event.") var once = false
    @OptionGroup var output: JSONOption

    func run() async throws {
        let target: WatchSession.Target
        switch (id, inbox) {
        case (let id?, false):
            guard project == nil else { throw AgentDropError.invalid("--project only applies with --inbox") }
            target = .drop(id)
        case (nil, true):
            target = .inbox(project: project)
        default:
            throw AgentDropError.invalid("Pass a drop id, or --inbox (not both)")
        }
        try await WatchSession(context: CLIContext.current, target: target, once: once, json: output.json).run()
    }
}

/// Spec §4 Watching and §5.3: find or launch the app's server, then print events until
/// interrupted, `--once`, or (for one drop) a `missing` or `removed` event.
struct WatchSession {
    enum Target {
        case drop(String)
        case inbox(project: String?)
    }

    private enum Outcome {
        case finished
        case disconnected
    }

    let context: CLIContext
    let target: Target
    let once: Bool
    let json: Bool

    func run() async throws {
        let settings = try context.config.load()
        guard settings.setupComplete else { throw AgentDropError.invalid(ServiceMessages.setupIncomplete) }
        if context.config.folderNeedsConfirmation(settings) {
            throw AgentDropError.invalid(ServiceMessages.confirmFolder)
        }
        var client = try await connect(launchIfNeeded: true)
        var dropID: String?
        if case .drop(let ref) = target { dropID = try await lookUp(ref, client: client, afterFolderChange: false) }
        let cursor = CursorBox()
        while true {
            switch try await stream(client: client, dropID: dropID, cursor: cursor) {
            case .finished:
                return
            case .disconnected:
                // The app quit, restarted its server, or switched folders. Keep the cursor:
                // the same store replays what we missed (even for a drop removed meanwhile);
                // a new store sends `reset`.
                try await Task.sleep(for: .milliseconds(200))
                client = try await connect(launchIfNeeded: false)
            }
        }
    }

    // MARK: - Connecting

    /// Reads `server.json`. A missing file or a dead `pid` means the app isn't running: the
    /// first connect launches it; a reconnect only waits for it to come back.
    private func connect(launchIfNeeded: Bool) async throws -> AgentDropClient {
        let file = ServerInfoFile(configDir: context.config.configDir)
        var launched = false
        if launchIfNeeded, liveInfo(file) == nil {
            try context.launchApp()
            launched = true
        }
        let deadline = ContinuousClock.now + context.serverWait
        while true {
            if let info = liveInfo(file) {
                if info.status == .noPort {
                    throw AgentDropError.invalid(
                        "Agent Drop is running without its local server: no port was free. Click Retry in Agent Drop.")
                }
                if let port = info.port, let token = info.token {
                    let client = AgentDropClient(port: port, token: token)
                    let remaining = deadline - ContinuousClock.now
                    let timeout = min(2, max(0.2, Double(remaining.components.seconds)))
                    let probe = try? await client.get("/drops", query: [URLQueryItem(name: "limit", value: "1")],
                                                      timeout: timeout)
                    if probe?.1 == 200 { return client }
                }
            }
            guard ContinuousClock.now < deadline else {
                let seconds = context.serverWait.components.seconds
                if launched { throw AgentDropError.invalid("Agent Drop didn't start its server within \(seconds) s") }
                if launchIfNeeded { throw AgentDropError.invalid("Agent Drop's server isn't answering") }
                throw AgentDropError.invalid("Lost the connection to Agent Drop (it quit or its server stopped)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func liveInfo(_ file: ServerInfoFile) -> ServerInfo? {
        guard let info = file.read(), context.isProcessAlive(info.pid) else { return nil }
        return info
    }

    /// The drop's id, from its id or exact filename. Exit 2 if the server doesn't have it.
    private func lookUp(_ ref: String, client: AgentDropClient, afterFolderChange: Bool) async throws -> String {
        let (body, status): (Data, Int)
        do {
            (body, status) = try await client.get(AgentDropClient.dropPath(ref))
        } catch {
            throw AgentDropError.invalid("Couldn't reach Agent Drop: \(error.localizedDescription)")
        }
        let json = try? JSONDecoder().decode([String: JSONValue].self, from: body)
        switch status {
        case 200:
            guard let id = json?["id"]?.stringValue else { throw AgentDropError.invalid("Unexpected answer from Agent Drop") }
            return id
        case 404:
            throw AgentDropError.notFound(afterFolderChange
                ? "drop folder changed; \(ref) is not in the current folder"
                : "No drop matches '\(ref)'")
        default:
            throw AgentDropError.invalid(json?["error"]?.stringValue ?? "Agent Drop answered HTTP \(status)")
        }
    }

    // MARK: - Streaming

    private func stream(client: AgentDropClient, dropID: String?, cursor: CursorBox) async throws -> Outcome {
        let query: [URLQueryItem]
        switch target {
        case .drop: query = [URLQueryItem(name: "drop", value: dropID)]
        case .inbox(let project):
            query = [URLQueryItem(name: "inbox", value: "")] + (project.map { [URLQueryItem(name: "project", value: $0)] } ?? [])
        }
        let events: AsyncThrowingStream<SSEEvent, Error>
        do {
            events = try await client.events(query: query, lastEventID: cursor.value, onCursor: { cursor.value = $0 })
        } catch let failure as AgentDropClient.HTTPFailure {
            switch failure.status {
            case 404 where dropID != nil:
                // With a cursor from this store the server still accepts a removed drop,
                // so a 404 here means the folder changed.
                throw AgentDropError.notFound(cursor.value == nil
                    ? "No drop matches '\(dropID!)'"
                    : "drop folder changed; \(dropID!) is not in the current folder")
            case 401, 503:
                return .disconnected // token rotated by a restart, or store busy: reconnect
            default:
                throw AgentDropError.invalid(failure.message)
            }
        } catch {
            return .disconnected
        }
        do {
            for try await event in events {
                if event.event == "reset" {
                    print(reset: event)
                    if let dropID { _ = try await lookUp(dropID, client: client, afterFolderChange: true) }
                    continue
                }
                print(event: event)
                if once { return .finished }
                if dropID != nil, event.event == "missing" || event.event == "removed" { return .finished }
            }
        } catch let error as AgentDropError {
            throw error
        } catch {
            // The connection dropped; reconnect.
        }
        return .disconnected
    }

    /// The stream's last event id, kept across reconnects.
    private final class CursorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    // MARK: - Output

    private func print(event: SSEEvent) {
        if json {
            context.stdout.line(event.data)
            return
        }
        guard let message = try? JSONDecoder().decode(EventMessage.self, from: Data(event.data.utf8)) else {
            context.stdout.line(Output.terminalSafe(event.data))
            return
        }
        context.stdout.line([message.at, message.type, message.dropId, Self.summary(message)]
            .map { Output.terminalSafe($0) }.joined(separator: "\t"))
    }

    private func print(reset event: SSEEvent) {
        if json {
            context.stdout.line(#"{"data":\#(event.data),"type":"reset"}"#)
        } else {
            context.stdout.line(["-", "reset", "-", SSE.resetReason].joined(separator: "\t"))
        }
    }

    /// One readable phrase per event type (spec §5.1 table).
    static func summary(_ message: EventMessage) -> String {
        let data = message.data
        switch message.type {
        case "created":
            return data["title"]?.stringValue ?? "created"
        case "content":
            return "contents changed"
        case "metadata":
            if case .object(let fields) = data { return "changed " + fields.keys.sorted().joined(separator: ", ") }
            return "metadata changed"
        case "status":
            var text = "\(data["from"]?.stringValue ?? "?") → \(data["to"]?.stringValue ?? "?")"
            if data["to"]?.stringValue == "claimed", let by = data["claimedBy"]?.stringValue { text += " by \(by)" }
            if data["to"]?.stringValue == "done", let note = data["statusNote"]?.stringValue { text += ": \(note)" }
            return text
        case "archived":
            return data["archived"] == .bool(true) ? "archived" : "unarchived"
        case "missing":
            return "file is missing"
        case "read":
            return "viewed in the app"
        case "removed":
            return "record removed"
        default:
            return message.type
        }
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test`
Expected: all pass. Run the full suite three times.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/DropCLI Sources/drop Tests/dropCLITests
git commit -m "feat(cli): drop watch with app launch, server.json checks, reconnect, folder-switch reset"
```

---

### Task 9: `agentdrop-devhost`, real-binary smoke test, docs

**Files:**
- Create: `Sources/AgentDropServer/TemporarySetup.swift`, `Sources/agentdrop-devhost/main.swift`
- Modify: `Package.swift` (dev host target), `.github/workflows/ci.yml`, `Scripts/smoke.sh`, `README.md`, the spec (§4 Watching, §5.1, §5.3 notes)
- Test: `Tests/AgentDropServerTests/TemporarySetupTests.swift`; the smoke test on CI

**Interfaces:**
- Consumes: Task 6 (`AgentDropService`), Task 1 (`setSetupComplete`, `setConfirmedFolder`, `folderNeedsConfirmation`).
- Produces: `TemporarySetup.apply(to:) throws -> TemporarySetup` with `changedAnything` and `restore()`; the `agentdrop-devhost` executable.

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropServerTests/TemporarySetupTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

struct TemporarySetupTests {
    func config() throws -> (ScratchDir, ConfigStore) {
        let dir = try ScratchDir()
        return (dir, ConfigStore(configDir: dir.url.appendingPathComponent("support"),
                                 homeDir: dir.url.appendingPathComponent("home")))
    }

    @Test func nothingToDoWhenAlreadySetUp() throws {
        let (_, config) = try config()
        try config.setSetupComplete(true)
        let before = try Data(contentsOf: config.configFile)
        let setup = try TemporarySetup.apply(to: config)
        #expect(!setup.changedAnything)
        setup.restore()
        #expect(try Data(contentsOf: config.configFile) == before)
    }

    @Test func setsAndRestoresSetupAndProtectedFolderConfirmation() throws {
        let (_, config) = try config()
        let desktop = config.homeDir.appendingPathComponent("Desktop/AgentDrop", isDirectory: true)
        try config.setFolder(desktop)
        try config.setRetention(.days(9))

        let setup = try TemporarySetup.apply(to: config)
        #expect(setup.changedAnything)
        var during = try config.load()
        #expect(during.setupComplete)
        #expect(!config.folderNeedsConfirmation(during))

        setup.restore()
        during = try config.load()
        #expect(!during.setupComplete)
        #expect(during.confirmedFolder == nil)
        #expect(config.folderNeedsConfirmation(during))
        #expect(during.eventRetentionDays == .days(9))
    }

    @Test func restoreLeavesNoTraceWhenThereWasNoConfig() throws {
        let (_, config) = try config()
        let setup = try TemporarySetup.apply(to: config)
        #expect(try config.load().setupComplete)
        setup.restore()
        #expect(!FileManager.default.fileExists(atPath: config.configFile.path))
    }

    @Test func restoreRemovesOnlyTheKeysItAddedAndKeepsLaterChanges() throws {
        let (_, config) = try config()
        try config.setRetention(.days(3))
        let setup = try TemporarySetup.apply(to: config)
        try config.setRetention(.forever)  // changed while the dev host ran
        setup.restore()
        let text = try String(contentsOf: config.configFile, encoding: .utf8)
        #expect(!text.contains("setupComplete"))
        #expect(try config.load().eventRetentionDays == .forever)
    }

    @Test func restoreKeepsAPreviouslyConfirmedOtherFolder() throws {
        let (_, config) = try config()
        let old = config.homeDir.appendingPathComponent("Documents/Old")
        try config.setConfirmedFolder(old)
        try config.setFolder(config.homeDir.appendingPathComponent("Desktop/New"))
        try config.setSetupComplete(true)
        let setup = try TemporarySetup.apply(to: config)
        setup.restore()
        #expect(try config.load().confirmedFolder == old.path)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter TemporarySetupTests`
Expected: build error: `cannot find 'TemporarySetup' in scope`.

- [ ] **Step 3: Implement**

`Sources/AgentDropServer/TemporarySetup.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation

/// For `agentdrop-devhost` only, until the app exists (Plan 3): marks setup complete and
/// confirms a protected folder for as long as the dev host runs, then puts both keys back
/// exactly as they were (absent keys are removed; a config.json that didn't exist is
/// deleted again), so the app's real first-run setup still happens later.
public struct TemporarySetup: Sendable {
    private enum Original: Sendable, Equatable {
        case absent
        case value(String) // JSON text of the original value
    }

    let config: ConfigStore
    private let fileExisted: Bool
    private let originals: [String: Original]

    public var changedAnything: Bool { !originals.isEmpty }

    public static func apply(to config: ConfigStore) throws -> TemporarySetup {
        let settings = try config.load()
        let fileExisted = FileManager.default.fileExists(atPath: config.configFile.path)
        let dict = try readDict(config)
        var originals: [String: Original] = [:]
        func remember(_ key: String) {
            originals[key] = dict[key].flatMap(encode).map(Original.value) ?? .absent
        }
        do {
            if !settings.setupComplete {
                remember("setupComplete")
                try config.setSetupComplete(true)
            }
            if config.folderNeedsConfirmation(settings) {
                remember("confirmedFolder")
                try config.setConfirmedFolder(config.folderURL(settings))
            }
        } catch {
            // Undo whatever part already landed before reporting the failure.
            TemporarySetup(config: config, fileExisted: fileExisted, originals: originals).restore()
            throw error
        }
        return TemporarySetup(config: config, fileExisted: fileExisted, originals: originals)
    }

    public func restore() {
        guard !originals.isEmpty, var dict = try? Self.readDict(config) else { return }
        for (key, original) in originals {
            switch original {
            case .absent: dict[key] = nil
            case .value(let json): dict[key] = Self.decode(json)
            }
        }
        if dict.isEmpty && !fileExisted {
            try? FileManager.default.removeItem(at: config.configFile)
            return
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? data.write(to: config.configFile, options: .atomic)
    }

    private static func readDict(_ config: ConfigStore) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: config.configFile) else { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func encode(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private static func decode(_ json: String) -> Any? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [Any])?.first
    }
}
```

`Sources/agentdrop-devhost/main.swift` (create, complete file):

```swift
// A stand-in for AgentDrop.app until Plan 3 builds it: hosts the same AgentDropService
// (content watcher + local server + server.json) in the foreground, so `drop watch` and
// other clients can be tried today. Not shipped; run it with `swift run agentdrop-devhost`.
import AgentDropCore
import AgentDropServer
import Foundation

let usage = """
    usage: swift run agentdrop-devhost [--temporary-setup]

    Serves the drop folder from config.json the way the app will, until Ctrl-C.

    --temporary-setup  The app's first-run setup hasn't happened yet (it can't: the app is
                       Plan 3). This marks setup complete, and confirms a protected drop
                       folder, only while the dev host runs. Both values are put back on exit.
    """

let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}
let unknown = arguments.subtracting(["--temporary-setup"])
guard unknown.isEmpty else {
    FileHandle.standardError.write(Data("agentdrop-devhost: unknown option \(unknown.sorted().joined(separator: " "))\n\(usage)\n".utf8))
    exit(1)
}

let config = ConfigStore.live()
var temporarySetup: TemporarySetup?
let service = AgentDropService(config: config)

@MainActor func fail(_ message: String) -> Never {
    temporarySetup?.restore()
    FileHandle.standardError.write(Data("agentdrop-devhost: \(message)\n".utf8))
    exit(1)
}

// Installed before anything changes, so even an early Ctrl-C puts config.json back.
// Handlers run on the main queue: top-level code is main-actor isolated in Swift 6, and
// touching `service` / `temporarySetup` from another queue traps at runtime.
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        Task { @MainActor in
            await service.stop()
            temporarySetup?.restore()
            print("\nagentdrop-devhost: stopped.")
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}

if arguments.contains("--temporary-setup") {
    do {
        temporarySetup = try TemporarySetup.apply(to: config)
    } catch {
        fail("couldn't update config.json: \(error.localizedDescription)")
    }
}

let state: AgentDropService.State
do {
    state = try await service.start()
} catch let error as AgentDropError {
    if error.message == ServiceMessages.setupIncomplete || error.message == ServiceMessages.confirmFolder {
        fail("\(error.message)\n(pass --temporary-setup to run before the app exists)")
    }
    fail(error.message)
} catch {
    fail(error.localizedDescription)
}

let folder = config.folderURL((try? config.load()) ?? AgentDropConfig()).path
switch state {
case .running(let port):
    print("agentdrop-devhost: serving \(folder) on 127.0.0.1:\(port), pid \(getpid()). Ctrl-C to stop.")
case .noPort:
    print("agentdrop-devhost: watching \(folder), but no port was free (server.json says no-port). Ctrl-C to stop.")
case .stopped:
    fail("the service didn't start")
}
if temporarySetup?.changedAnything == true {
    print("agentdrop-devhost: setup is marked complete only while this runs.")
}

while true {
    try await Task.sleep(for: .seconds(3600))
}
```

The final `Package.swift`, including the dev host target:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDrop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentDropCore", targets: ["AgentDropCore"]),
        .library(name: "AgentDropServer", targets: ["AgentDropServer"]),
        .executable(name: "drop", targets: ["drop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "AgentDropCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "AgentDropServer",
            dependencies: [
                "AgentDropCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                // Hummingbird imports ServiceContextModule but only gets it transitively;
                // without this, packages that depend on AgentDropServer fail to build it.
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ]
        ),
        .target(
            name: "DropCLI",
            dependencies: [
                "AgentDropCore",
                "AgentDropServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "drop", dependencies: ["DropCLI"]),
        // Development stand-in for AgentDrop.app until Plan 3. Not a shipped product.
        .executableTarget(name: "agentdrop-devhost", dependencies: ["AgentDropServer", "AgentDropCore"]),
        .testTarget(
            name: "AgentDropCoreTests",
            dependencies: ["AgentDropCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "AgentDropServerTests", dependencies: ["AgentDropServer", "AgentDropCore"]),
        .testTarget(name: "dropCLITests", dependencies: ["DropCLI", "AgentDropCore", "AgentDropServer"]),
    ]
)
```

- [ ] **Step 4: Smoke test and CI**

`.github/workflows/ci.yml` (replace, complete file):

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - run: swift --version
      - run: swift test
      - run: swift build -c release --product drop
      - run: swift build -c release --product agentdrop-devhost
      - name: Real-binary smoke test (ephemeral runner only)
        run: Scripts/smoke.sh .build/release/drop .build/release/agentdrop-devhost
```

`Scripts/smoke.sh` (replace, complete file):

```bash
#!/usr/bin/env bash
# Real-binary smoke test (spec §8). It uses the REAL default paths
# (~/AgentDrop and ~/Library/Application Support/AgentDrop), so it only runs on
# ephemeral GitHub Actions machines, never on a developer's Mac.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "smoke.sh: skipped (runs only on GitHub Actions because it uses the real default paths)"
  exit 0
fi

DROP="${1:?usage: Scripts/smoke.sh <path-to-drop-binary> <path-to-agentdrop-devhost>}"
DEVHOST="${2:?usage: Scripts/smoke.sh <path-to-drop-binary> <path-to-agentdrop-devhost>}"
support="$HOME/Library/Application Support/AgentDrop"
work="${RUNNER_TEMP:?}/agentdrop-smoke"
mkdir -p "$work"

[[ "$("$DROP" where)" == "$HOME/AgentDrop" ]]

printf '# Smoke plan\n' > "$work/smoke plan.md"
id=$("$DROP" add "$work/smoke plan.md" --from "ci/smoke [1]" --project smoke --handoff)
[[ "$("$DROP" cat "$id")" == "# Smoke plan" ]]
"$DROP" inbox --project smoke --json | grep -q "\"id\":\"$id\""

"$DROP" claim "$id" --by "ci/a"
set +e
"$DROP" claim "$id" --by "ci/b"
code=$?
set -e
[[ "$code" -eq 3 ]]

"$DROP" done "$id" --note "smoke ok" >/dev/null
[[ -z "$("$DROP" inbox --project smoke)" ]]
[[ -f "$HOME/AgentDrop/.agentdrop/index.sqlite" ]]

# drop watch (Plan 2). Before setup it refuses with the spec's message.
set +e
out=$("$DROP" watch --inbox 2>&1)
code=$?
set -e
[[ "$code" -eq 1 && "$out" == *"hasn't been set up yet"* ]]

# The dev host stands in for the app: same service, real server.json, real FSEvents.
"$DEVHOST" --temporary-setup > "$work/devhost.log" 2>&1 &
host=$!
for _ in $(seq 1 100); do [[ -f "$support/server.json" ]] && break; sleep 0.1; done
grep -q '"status":"running"' "$support/server.json"

"$DROP" watch --inbox --project smoke2 --once --json > "$work/watch.out" &
watcher=$!
# The watcher may not be subscribed yet, so keep adding handoffs until it sees one and
# exits (--once). Every handoff is an arrival; at most 20 tries.
ids=()
for n in $(seq 1 20); do
  printf '# Second %s\n' "$n" > "$work/second-$n.md"
  ids+=("$("$DROP" add "$work/second-$n.md" --from "ci/smoke" --project smoke2 --handoff)")
  sleep 1
  kill -0 "$watcher" 2>/dev/null || break
done
kill "$watcher" 2>/dev/null && { echo "drop watch never saw an arrival"; exit 1; }
wait "$watcher"
seen=$(sed -n 's/.*"dropId":"\([a-z0-9]*\)".*/\1/p' "$work/watch.out")
[[ " ${ids[*]} " == *" $seen "* ]]
grep -q '"type":"created"' "$work/watch.out"

kill -INT "$host"
wait "$host"
[[ ! -f "$support/server.json" ]]
# --temporary-setup put config.json back exactly (it didn't exist before).
[[ ! -f "$support/config.json" ]]
echo "smoke: ok"
```

The smoke test is the only place the compiled `drop` and the dev host meet. It runs on GitHub's throwaway runner, against the real default paths.

- [ ] **Step 5: Docs**

Update `README.md` (status, Swift 6.2 requirement, "Watching for changes", `server.json` under "What Agent Drop stores and deletes"). Add the implementation decisions to the spec: §4 Watching (bundle id, `--windowless`, reconnect, `--once` and `reset`, output format), §5.1 (`content` fingerprints, missing/return), §5.3 (cursor frame, keepalive, strict queries, decoded path ids, folder listing, 503/500).

- [ ] **Step 6: Run everything**

Run: `swift test && swift build -c release --product drop && swift build -c release --product agentdrop-devhost && Scripts/smoke.sh .build/release/drop .build/release/agentdrop-devhost`
Expected: all tests pass, both builds succeed, and the smoke test prints `skipped` locally. On GitHub Actions it prints `smoke: ok`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: agentdrop-devhost stand-in, real-binary watch smoke test, README and spec notes for Plan 2"
```


## Self-review notes

- **Spec coverage.** §5.2 table: the content watcher runs whenever the service runs, including `no-port` (Task 6 `noPortStillWatchesContentAndRetryRecovers`), and the server runs only with a bound port. §5.3: all six endpoint forms are tested in Task 4. `reset` and resume are tested in Tasks 3, 4, 6 and 8. §7: the port-exhausted path is tested in Tasks 4 and 6, 401/403 in Task 4. §8: server tests use in-process servers on temp stores, and `drop watch` end-to-end tests live in `dropCLITests`.
- **Deliberately left to Plan 3:** the app's setup flow, Settings, re-reading `config.json` changes while running (a folder switch is `stop()` then `start()` on the service), and launch-at-login.
- **Decisions recorded in the spec during implementation** (§4 Watching and §5): the app's bundle id and `--windowless`; reconnect waits and never relaunches; `--once` ignores `reset`; the human line format; the fingerprint rule for `content`; the missing/return events from the watcher; the id-only cursor frame; 15 s keepalives; strict query parameters; percent-decoded path ids; the folder listing shape; 503/500.
- **Found while building:**
  1. Hummingbird doesn't percent-decode path parameters.
  2. `URLSession`'s `lines` drops the blank lines that end SSE frames, and a Swift `String` treats `"\r\n"` as one character. That's why the parser works on bytes.
  3. `URL.resolvingSymlinksInPath()` strips `/private`, so the watcher uses `realpath(3)`.
  4. Blocking socket calls on Swift's concurrency threads starved the server on CI's 3-core runner.
  5. Human-readable output could carry terminal escape sequences from file headings.
  6. `DispatchQueue.global()` has about one thread per core; when other work blocks them, queued work waits for seconds. The server's off-pool work uses private queues instead.
  7. Two checks of the same entry could overlap and the older one could overwrite the newer fingerprint. They're now exclusive per entry.
  8. A file could vanish between the presence check and the fingerprint, which used to look like a content change.
  9. Hummingbird imports `ServiceContextModule` but gets it only transitively, so packages depending on this one (the Plan 3 app) failed to build until it's declared explicitly.
  10. Top-level code is main-actor isolated in Swift 6, so the dev host's signal handlers must run on the main queue (a background queue trapped on Ctrl-C).

  Each has a test, or a CI check for the build and smoke items.
- **Independent review (fresh reviewer, whole branch), all addressed:**
  - **M1:** overlapping `start`/`stop`/`retryPort` leaked a server. They now run one at a time.
  - **M2:** writes through a store connection that stays open never streamed. Fixed with commit observation for the service's own store plus a check on each keepalive tick.
  - **M3:** a reconnecting `drop watch <id>` exited 2 instead of replaying `removed`. The server now accepts a removed id within the same store.
  - **M4:** the `server.json` temp file was briefly 0644. It's now created 0600 with `O_EXCL`.
  - **M5:** the protected-folder check missed case variants and symlinks. It now compares real paths, case-folded.
  - **L1–L4:** the reconnect probe now uses a short timeout bounded by the deadline; reconnects back off and 401/503 retry; files are read with `O_NOFOLLOW`; a duplicate `Host` is rejected.
  - **Also fixed:** a race in the smoke test, the dev host restoring config on every failure, and graceful shutdown (no error log on stop).
  - **Not changed:** route handlers still make short synchronous SQLite calls (bounded by the 5 s busy timeout), and file bodies load into memory. Both are fine at v1's scale. Streaming large files is a Plan 3 candidate if the app previews big files through the server.
