# AgentDrop.app + `drop open` Implementation Plan (Plan 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build AgentDrop.app (menu bar extra, main window, first-run setup, rendered previews, Settings) hosting the Plan 2 service, plus `drop open <id>`. The human then sees and acts on drops, and `drop watch` has a real app to launch.

**Architecture:** The app is two new targets in the existing Swift package:
- `AgentDropApp`: a library with everything testable without a window. That's the lifecycle model, the library model, forms, the notifier, Markdown rendering and the preview rules.
- `AgentDrop`: an executable with the SwiftUI/AppKit views.

`Scripts/build-app.sh` wraps the executable into `AgentDrop.app` with `App/Info.plist`, which holds the bundle id and the `agentdrop://` scheme. The app hosts `AgentDropService`, writes through its store off the main thread, and reloads on a new `onChange` hook. It follows `config.json` with the existing `FolderWatcher`.

**Tech Stack:**
- Swift 6.2, tools-version 6.0, Swift 6 language mode, Swift Testing.
- SwiftUI + AppKit on macOS 14 (`MenuBarExtra`, Observation, `openSettings`).
- WebKit (`WKWebView`, `WKURLSchemeHandler`), Quick Look (`QLPreviewView`), UserNotifications, ServiceManagement (`SMAppService`).
- swift-cmark (GFM), plus GRDB and Hummingbird through the existing targets.

**Spec:** `docs/superpowers/specs/2026-10-11-agent-drop-design.md`: §2 (first-run setup, nothing touched before it), §3 and §3.2 (folder, protected-folder confirmation, reconciliation), §4 (`drop open`, Watching), §5.1–§5.2, §6 (the app), §7, §8, §9. Plans 1 and 2 are merged on `main`; this plan builds on their code: `AgentDropService`, `ConfigStore`, `FolderProtection`, `FolderWatcher`, `FolderListing`, `ServiceMessages`.

## Global Constraints

- macOS 14 minimum (`platforms: [.macOS(.v14)]`). swift-tools-version stays `6.0`. Swift 6 language mode: strict concurrency, no warnings.
- Bundle identifier `io.github.mrbenj.AgentDrop` everywhere: `AppIdentity.bundleID`, `CLIContext.appBundleID`, `App/Info.plist`.
- `drop watch` launches the app with `open -g -b io.github.mrbenj.AgentDrop --args --windowless`. A `--windowless` launch opens no window, and the menu bar icon still appears. Any launch before setup shows the setup window (spec §2).
- **Before setup is complete the app does not touch the drop folder at all:** no reconciliation, no folder creation, no FSEvents on it, no rendering, no server. It reads only `config.json` (spec §2).
- No environment-variable or argument path overrides (spec §3, §8). Tests inject `ConfigStore(configDir:homeDir:)` with temp directories and never touch `~/AgentDrop` or `~/Library/Application Support/AgentDrop`. Agents must not launch the built app; it reads and writes the real config. The human does that in Task 12.
- `--from`, `--project` and tags are never guessed or pre-filled (spec §4.1).
- App writes go through the running service's store (`library.store` is `service.store`), off the main thread via `StoreQueue`, and use the same `AgentDropCore` operations as the CLI (spec §4.2). Humans don't claim from the app.
- Never block Swift concurrency threads with long work. Use private `DispatchQueue`s, never `DispatchQueue.global()`.
- Links are never followed when listing, rendering or previewing (spec §3). Rendered Markdown never runs JavaScript (spec §6).
- Unread is `Drop.isUnread` and the Inbox is `Drop.isInInbox` (spec §4 Terms). Don't redefine them.
- `swift test` stays fast (about 3 s) and never needs a window server.

## Review Focus

1. **The macOS access prompt appears before setup has explained it.** For `~/Desktop/AgentDrop`, setup shows the explanation and only **Finish Setup** touches the folder. The app asks `FolderProtection.isProtected` while setup is open, so Task 1 makes it check the path as written before any filesystem call. Whether macOS actually waits is a manual check (checklist "First run").
2. **A burst of CLI writes**, such as an agent adding 60 drops in a loop, must leave the window current without a pile-up of reloads. Change signals collapse into one pending reload (Task 8 `aBurstOfCLIWritesConverges`).
3. **`drop open` launching the app:** the link can arrive before `launch()` finishes, and the drop must still be shown once serving (Task 8 `aLinkThatArrivesWhileLaunchingIsShownOnceServing`).
4. **A half-written or hand-broken `config.json` while running** must not stop serving the current folder. The app says what's wrong and picks up the fixed file (Task 8 `aBrokenConfigWhileRunningKeepsServingAndSaysSo`).
5. **Names and text from outside Swift's assumptions:**
   - A Finder filename in decomposed Unicode (`Café` as NFD) registers in place and leaves no phantom unregistered entry (Task 6 `aDecomposedUnicodeNameRegistersInPlace`).
   - A legacy-encoded text file goes to Quick Look, not garbled text (Task 9 `legacyEncodedTextGoesToQuickLookNotGarbledText`).

## Decisions this plan makes

Spec §6 was marked "draft — to be refined". These choices fill it in, and Task 12 writes them into the spec:

- **No Xcode project (spec §9 said there would be one).** SwiftPM builds the app, and `Scripts/build-app.sh` makes the bundle (Task 4 says why).
- **The main window is an AppKit `NSWindow` hosting SwiftUI.** The only SwiftUI scenes are `MenuBarExtra` and `Settings`, because on macOS 14 a SwiftUI window scene opens at launch and `--windowless` must not (Task 11).
- **Links in rendered Markdown:**
  - `http`, `https` and `mailto` links open in the browser.
  - A link to a file in the drop folder reveals it in Finder instead of opening it, so a click can't run a script an agent left there.
  - Images may come from the drop folder, `data:` and `https:`. Raw HTML and scripts never run.
- **Copy:** for a folder drop, the copy button gives `drop path <id>`, because `drop cat` can't print a folder.
- **Notifications:**
  - Only drops created while the app runs are announced, never older ones.
  - Drops the human registered in the app are never announced.
  - More than 3 at once become one summary.
- **App-only settings (Hide Dock icon, Notify) live in UserDefaults.** Settings the CLI also reads stay in `config.json`.
- **The edit form can't clear a description or project.** That matches `drop edit`; clearing was deferred in Plan 1. Emptying a field is refused with a message.
- **A retention change applies to the open store directly** (`DropStore.setRetention`), with no server restart. A folder, confirmation or port change restarts the service.
- **Out of scope:** an app icon (the generic icon is used), notarization (a spec non-goal), and streaming large files from the server.
- **Known limit:** if the whole drop folder is deleted while the app runs, the app keeps its open (now unlinked) store until the folder changes or the app restarts.

## File structure

```
App/Info.plist                         bundle id, agentdrop:// scheme, folder usage strings
Scripts/build-app.sh                   swift build + wrap into .build/AgentDrop.app, ad-hoc sign
Sources/AgentDropCore/DropStore+Folder.swift     unregistered entries, reconcile
Sources/AgentDropServer/AppLink.swift            agentdrop://drop/<id>
Sources/DropCLI/Commands/OpenCommand.swift       drop open
Sources/AgentDropApp/                  testable app layer (no views)
  AppModel.swift                       lifecycle: setup, confirm, service, config.json, links
  AppSettings.swift, LoginItem.swift   UserDefaults prefs; SMAppService
  LibraryModel.swift (+Actions)        drops, entries, sidebar, search, selection, actions
  Sidebar.swift, Forms.swift           sidebar items, identity trees; edit/register forms
  NewDropNotifier.swift                created events → notices
  StoreQueue.swift                     off-main store calls
  DropFormatting.swift                 menu lines, labels, retention choices
  CodeLocator.swift, LaunchOptions.swift, AppIdentity.swift
  Preview/                             MarkdownRenderer, PreviewKind, PreviewResources, FolderTree, LinkPolicy
Sources/AgentDrop/                     the app executable
  AgentDropMain.swift                  MenuBarExtra + Settings scenes
  Shell/                               AppDelegate, MainWindowController, RootView (setup/confirm/error), menu, Settings, notifications
  Library/                             LibraryView, SidebarView, DropListView, DetailView, Sheets
  Preview/                             FilePreview (+ text, Quick Look, folder), MarkdownView (+ scheme handler)
Tests/AgentDropAppTests/               models against temp stores and temp config dirs
docs/manual-test-checklist.md          spec §8's manual UI checklist
```

---

### Task 1: Core: unregistered entries, reconciliation, live retention, path-first folder protection

**Files:**
- Create: `Sources/AgentDropCore/DropStore+Folder.swift`
- Modify: `Sources/AgentDropCore/Store.swift` (retention becomes settable), `Sources/AgentDropCore/FolderProtection.swift` (check the path as written before the disk)
- Test: `Tests/AgentDropCoreTests/FolderReconcileTests.swift`

**Interfaces:**
- Consumes (Plans 1–2): `DropStore.read`, `fetchDrop`, `refreshMissing(_:)` (internal), `FolderProtection.canonical`.
- Produces:
  - `public struct UnregisteredEntry: Equatable, Sendable, Identifiable { name: String; isFolder: Bool; modifiedAt: Date?; id: String }`
  - `DropStore.unregisteredEntries() throws -> [UnregisteredEntry]` (newest first)
  - `@discardableResult DropStore.reconcile() throws -> [Drop]` (the drops whose missing state changed)
  - `DropStore.setRetention(_ retention: Retention)`; `DropStore.retention` is now `public var` (get)

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropCoreTests/FolderReconcileTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore

/// Spec §3.2 as the app sees it: unregistered entries and reconciliation on launch.
struct FolderReconcileTests {
    let fm = FileManager.default

    @Test func unregisteredListsOnlyUnclaimedTopLevelFilesAndFolders() throws {
        let f = try Fixture()
        try f.add("plan.md")
        try Data("x".utf8).write(to: f.folder.appendingPathComponent("loose.md"))
        try fm.createDirectory(at: f.folder.appendingPathComponent("bundle/inner"), withIntermediateDirectories: true)
        try Data("y".utf8).write(to: f.folder.appendingPathComponent("bundle/inner/a.txt"))
        try Data().write(to: f.folder.appendingPathComponent(".hidden"))
        try fm.createSymbolicLink(at: f.folder.appendingPathComponent("link.md"),
                                  withDestinationURL: f.folder.appendingPathComponent("plan.md"))

        let entries = try f.store.unregisteredEntries()
        #expect(Set(entries.map(\.name)) == ["loose.md", "bundle"])
        #expect(entries.first { $0.name == "bundle" }?.isFolder == true)
        #expect(entries.first { $0.name == "loose.md" }?.isFolder == false)
    }

    @Test func aCaseAliasOfARegisteredNameIsStillUnregistered() throws {
        let f = try Fixture()
        let drop = try f.add("Plan.md")
        // The record's file is gone and a name differing only in case appeared: that is not
        // the drop returning (spec §3.2), so it shows as unregistered.
        try fm.removeItem(at: f.store.path(of: drop))
        try Data("x".utf8).write(to: f.folder.appendingPathComponent("plan.md"))
        #expect(try f.store.unregisteredEntries().map(\.name) == ["plan.md"])
    }

    @Test func emptyFolderHasNoUnregisteredEntries() throws {
        let f = try Fixture()
        #expect(try f.store.unregisteredEntries().isEmpty)
    }

    @Test func reconcileMarksMissingAndReturnedDropsIncludingArchived() throws {
        let f = try Fixture()
        let kept = try f.add("kept.md")
        let gone = try f.add("gone.md")
        let archived = try f.add("old.md")
        _ = try f.store.setArchived(archived.id, true)
        try fm.removeItem(at: f.store.path(of: gone))
        try fm.removeItem(at: f.store.path(of: archived))

        let changed = try f.store.reconcile()
        #expect(Set(changed.map(\.id)) == [gone.id, archived.id])
        #expect(try f.store.resolve(kept.id).missing == false)
        #expect(changed.allSatisfy { $0.missing })

        try Data("back".utf8).write(to: f.store.path(of: gone))
        #expect(try f.store.reconcile().map(\.id) == [gone.id])
        #expect(try f.store.events().last?.data == #"{"missing":false}"#)
        #expect(try f.store.reconcile().isEmpty) // nothing changed: no events
    }

    @Test func setRetentionAppliesToTheNextWrite() throws {
        let f = try Fixture(retention: .forever)
        let drop = try f.add()
        f.clock.advance(days: 10)
        try f.store.recordContentChange(drop.id)
        #expect(try f.store.events().count == 2) // forever: nothing trimmed

        f.store.setRetention(.days(5))
        #expect(f.store.retention == .days(5))
        try f.store.recordContentChange(drop.id)
        #expect(try f.store.events().map(\.type) == [.content, .content])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter FolderReconcileTests`
Expected: build error: `value of type 'DropStore' has no member 'unregisteredEntries'` (also `reconcile`, `setRetention`).

- [ ] **Step 3: Make retention settable**

In `Sources/AgentDropCore/Store.swift`, replace:

```swift
    let pool: DatabasePool
    let retention: Retention
```

with:

```swift
    let pool: DatabasePool
    private let retentionSetting: RetentionSetting
    /// Event-log retention applied by every write (spec §5.1). The app changes it live.
    public var retention: Retention { retentionSetting.value }
```

In `Sources/AgentDropCore/Store.swift` (in the private `init`), replace:

```swift
        self.retention = retention
```

with:

```swift
        self.retentionSetting = RetentionSetting(retention)
```

In `Sources/AgentDropCore/Store.swift`, replace:

```swift
    /// Runs `body` in an IMMEDIATE transaction
```

with:

```swift
    /// Settings → Event history changed while the app holds this store open: the next
    /// write uses the new value. Other processes read `config.json` on their own.
    public func setRetention(_ retention: Retention) {
        retentionSetting.value = retention
    }

    /// Runs `body` in an IMMEDIATE transaction
```

In `Sources/AgentDropCore/Store.swift`, replace:

```swift
extension Drop {
    init(row
```

with:

```swift
private final class RetentionSetting: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Retention
    init(_ value: Retention) { _value = value }
    var value: Retention {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

extension Drop {
    init(row
```

Every `retention: retention` argument in the store's extensions keeps compiling: it now reads the computed property.

- [ ] **Step 4: Add unregistered entries and reconciliation**

`Sources/AgentDropCore/DropStore+Folder.swift` (create, complete file):

```swift
import Foundation
import GRDB

/// A top-level entry of the drop folder with no record (spec §3.2 "unregistered").
public struct UnregisteredEntry: Equatable, Sendable, Identifiable {
    public var name: String
    public var isFolder: Bool
    public var modifiedAt: Date?
    public var id: String { name }

    public init(name: String, isFolder: Bool, modifiedAt: Date?) {
        self.name = name
        self.isFolder = isFolder
        self.modifiedAt = modifiedAt
    }
}

/// Folder reconciliation for the app (spec §3.2).
extension DropStore {
    /// Regular files and directories at the top level that no record claims. Dot-entries,
    /// symlinks and anything else (sockets, devices) are never drops. Names are compared
    /// byte for byte, like `resolve`: `plan.md` is unregistered even if `Plan.md` has a record.
    public func unregisteredEntries() throws -> [UnregisteredEntry] {
        let registered = try read { db in
            Set(try String.fetchAll(db, sql: "SELECT filename FROM drops").map { Array($0.utf8) })
        }
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: folder.path)
        return names.compactMap { name -> UnregisteredEntry? in
            guard !name.hasPrefix("."), !registered.contains(Array(name.utf8)),
                  let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            else { return nil }
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory else { return nil }
            return UnregisteredEntry(name: name, isFolder: type == .typeDirectory,
                                     modifiedAt: attributes[.modificationDate] as? Date)
        }
        .sorted { ($0.modifiedAt ?? .distantPast, $1.name) > ($1.modifiedAt ?? .distantPast, $0.name) }
    }

    /// Re-checks every record against the folder (archived ones too), recording `missing`
    /// or a return exactly as `checkPresence` does. The app runs it on launch and after a
    /// folder switch; it returns the drops whose state changed.
    @discardableResult
    public func reconcile() throws -> [Drop] {
        let ids = try read { db in try String.fetchAll(db, sql: "SELECT id FROM drops ORDER BY rowid") }
        var changed: [Drop] = []
        for id in ids {
            guard let before = try read({ db in try Self.fetchDrop(db, id: id) }) else { continue }
            let after = try refreshMissing(before)
            if after.missing != before.missing { changed.append(after) }
        }
        return changed
    }
}
```

- [ ] **Step 5: Check the path as written before touching the disk**

The app's setup screen asks `isProtected` before setup has explained the macOS prompt. Stat-ing inside `~/Desktop` can itself trigger that prompt, so the lexical check comes first and, for the usual spelling, no filesystem call happens.

In `Sources/AgentDropCore/FolderProtection.swift`, replace:

```swift
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
```

with:

```swift
    public static func isProtected(_ folder: URL, homeDir: URL) -> Bool {
        // The path as written first, without touching the disk: looking inside a protected
        // folder (even a stat) can make macOS ask for access, and the app must explain
        // that prompt before it appears (spec §2). The app's setup screen asks this.
        if isUnderProtectedRoot(folder.standardizedFileURL.path.lowercased(),
                                home: homeDir.standardizedFileURL.path.lowercased()) { return true }
        // Then real paths, case-insensitively: `~/desktop` and a symlink to ~/Desktop
        // reach the same protected folder on a default (case-insensitive) APFS volume.
        if isUnderProtectedRoot(canonical(folder), home: canonical(homeDir)) { return true }
        return isOnRemovableOrNetworkVolume(folder.standardizedFileURL)
    }

    private static func isUnderProtectedRoot(_ path: String, home: String) -> Bool {
        ["desktop", "documents", "downloads", "library/mobile documents"]
            .map { home + "/" + $0 }
            .contains { path == $0 || path.hasPrefix($0 + "/") }
    }
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter 'FolderReconcileTests|FolderProtectionTests|ServerSupportTests'`
Expected: all pass. Then `swift test`: everything passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/AgentDropCore Tests/AgentDropCoreTests/FolderReconcileTests.swift
git commit -m "feat(core): unregistered entries, reconcile, live retention, path-first protection check"
```

---

### Task 2: Service hooks for the app: `onChange`, reconcile on start, public folder listing

**Files:**
- Modify: `Sources/AgentDropServer/AgentDropService.swift`, `Sources/AgentDropServer/HTTPAPI.swift` (`FolderListing.init` becomes public)
- Test: `Tests/AgentDropServerTests/ServiceAppHookTests.swift`

**Interfaces:**
- Consumes: Task 1 `DropStore.reconcile()`; Plan 2 `AgentDropService`, `FolderWatcher`, `ServiceFixture`, `addFile`, `randomPortBase`, `Locked`, `eventually` (test support in `Tests/AgentDropServerTests`).
- Produces:
  - `AgentDropService.Options.onChange: @Sendable () -> Void` (default `{}`), called on any thread after a store commit that wrote events, and on every FolderWatcher batch (CLI writes, entries added/removed).
  - `AgentDropService.start()` reconciles every record (spec §3.2 "reconciles on launch") before serving.
  - `public init(id: String, folder: URL) throws` on `FolderListing`.

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropServerTests/ServiceAppHookTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

/// What the app relies on from the service: change notifications and
/// reconciliation on start.
struct ServiceAppHookTests {
    func service(_ f: ServiceFixture, onChange: @escaping @Sendable () -> Void) -> AgentDropService {
        var options = AgentDropService.Options()
        options.portBase = randomPortBase()
        options.debounce = .milliseconds(50)
        options.onChange = onChange
        return AgentDropService(config: f.config, options: options)
    }

    @Test func onChangeFiresForInProcessWritesCLIWritesAndNewEntries() async throws {
        let f = try ServiceFixture()
        let count = Locked(0)
        let service = service(f) { count.withLock { $0 += 1 } }
        try await service.start()
        defer { Task { await service.stop() } }
        let store = try #require(await service.store)

        func expectChange(_ change: () throws -> Void) async throws {
            let seen = count.value
            try change()
            #expect(await eventually { count.value > seen })
        }
        try await expectChange { _ = try addFile(store, "a.md", in: f.dir.url) }
        try await expectChange { _ = try addFile(try f.cliStore(), "b.md", in: f.dir.url) }
        try await expectChange { try Data("x".utf8).write(to: f.folder.appendingPathComponent("loose.txt")) }
    }

    @Test func startReconcilesMissingDrops() async throws {
        let f = try ServiceFixture()
        let cli = try f.cliStore()
        let drop = try addFile(cli, "gone.md", in: f.dir.url)
        try FileManager.default.removeItem(at: cli.path(of: drop))

        let service = service(f) {}
        try await service.start()
        defer { Task { await service.stop() } }
        let store = try #require(await service.store)
        let row = try #require(try store.list({ var l = ListFilter(); l.includeArchived = true; return l }()).first)
        #expect(row.missing)
        #expect(try store.events().last?.type == .missing)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter ServiceAppHookTests`
Expected: build error: `value of type 'AgentDropService.Options' has no member 'onChange'`.

- [ ] **Step 3: Add the hook and reconcile on start**

In `Sources/AgentDropServer/AgentDropService.swift`, replace:

```swift
        public var pid: Int32 = ProcessInfo.processInfo.processIdentifier
```

with:

```swift
        public var pid: Int32 = ProcessInfo.processInfo.processIdentifier
        /// Called (on no particular thread) whenever the folder or the store may have
        /// changed: a commit, a CLI write, an entry added or removed. The app reloads on it.
        public var onChange: @Sendable () -> Void = {}
```

In `Sources/AgentDropServer/AgentDropService.swift` (in `performStart`), replace:

```swift
        let store = try DropStore.open(folder: folder, retention: settings.eventRetentionDays)
        let hub = try EventHub(store: store)
        store.observeEventCommits { Task { await hub.poke() } }
```

with:

```swift
        let store = try DropStore.open(folder: folder, retention: settings.eventRetentionDays)
        // Spec §3.2: reconcile on launch. A busy store is skipped; the next change to an
        // entry re-checks that drop anyway.
        _ = try? store.reconcile()
        let hub = try EventHub(store: store)
        let onChange = options.onChange
        store.observeEventCommits {
            Task { await hub.poke() }
            onChange()
        }
```

In `Sources/AgentDropServer/AgentDropService.swift`, replace:

```swift
        let watcher = FolderWatcher(folder: folder) { changes in
            Task {
```

with:

```swift
        let watcher = FolderWatcher(folder: folder) { changes in
            onChange()
            Task {
```

- [ ] **Step 4: Make the folder listing usable from the app**

In `Sources/AgentDropServer/HTTPAPI.swift`, replace:

```swift
    init(id: String, folder: URL) throws {
        self.id = id
```

with:

```swift
    /// Also used by the app's file tree.
    public init(id: String, folder: URL) throws {
        self.id = id
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter 'ServiceAppHookTests|Service'`
Expected: all pass. Then `swift test`: everything passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentDropServer Tests/AgentDropServerTests/ServiceAppHookTests.swift
git commit -m "feat(server): onChange hook and reconcile on start for the app"
```

---

### Task 3: `drop open <id>` and `AppLink`

**Files:**
- Create: `Sources/AgentDropServer/AppLink.swift`, `Sources/DropCLI/Commands/OpenCommand.swift`
- Modify: `Sources/DropCLI/DropCLI.swift` (register the subcommand), `Tests/dropCLITests/TestEnv.swift` (a fake `runProcess` failure)
- Test: `Tests/dropCLITests/OpenCommandTests.swift`

**Interfaces:**
- Consumes: `CLIContext.current`, `openStore()`, `runProcess`, `CLIContext.appBundleID`, `Output.emitJSON`, `DropStore.resolve`, `DropID.isWellFormed`.
- Produces:
  - `public enum AppLink { static let scheme = "agentdrop"; static func url(forDrop id: String) -> URL; static func dropID(from url: URL) -> String? }` in `AgentDropServer` (shared by the CLI and the app).
  - `drop open <id|filename> [--json]` → runs `/usr/bin/open -b io.github.mrbenj.AgentDrop agentdrop://drop/<id>`; exit 2 for an unknown id; `--json` prints `{"opened": "agentdrop://drop/<id>"}`.
  - `TestEnv.processError: AgentDropError?`

- [ ] **Step 1: Let tests make the fake `runProcess` fail**

In `Tests/dropCLITests/TestEnv.swift`, replace:

```swift
    var useRealProcess = false
```

with:

```swift
    var useRealProcess = false
    /// When set, the fake `runProcess` records the call and then throws this.
    var processError: AgentDropError?
```

In `Tests/dropCLITests/TestEnv.swift`, replace:

```swift
        let useRealProcess = self.useRealProcess
```

with:

```swift
        let useRealProcess = self.useRealProcess, processError = self.processError
```

In `Tests/dropCLITests/TestEnv.swift`, replace:

```swift
                self?.lock.withLock { self?._processCalls.append((executable, args)) }
                return 0
```

with:

```swift
                self?.lock.withLock { self?._processCalls.append((executable, args)) }
                if let processError { throw processError }
                return 0
```

- [ ] **Step 2: Write the failing tests**

`Tests/dropCLITests/OpenCommandTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer
@testable import DropCLI

/// Spec §4 `drop open`.
struct OpenCommandTests {
    @Test func opensTheDropLinkInTheAppByBundleID() throws {
        let env = try TestEnv()
        try env.file("plan.md", "# Plan")
        let id = env.run("add", "plan.md", "--from", "a").trimmedOut
        #expect(env.run("open", "plan.md").code == 0) // a filename resolves to the id
        let call = try #require(env.processCalls.first)
        #expect(call.0.path == "/usr/bin/open")
        #expect(call.1 == ["-b", "io.github.mrbenj.AgentDrop", "agentdrop://drop/\(id)"])
        #expect(env.run("open", id, "--json").json["opened"] as? String == "agentdrop://drop/\(id)")
    }

    @Test func unknownIdIsExit2AndOpensNothing() throws {
        let env = try TestEnv()
        let r = env.run("open", "zzzzzz")
        #expect(r.code == 2)
        #expect(env.processCalls.isEmpty)
    }

    @Test func appNotInstalledIsExit1WithAHint() throws {
        let env = try TestEnv()
        try env.file("plan.md", "# Plan")
        let id = env.run("add", "plan.md", "--from", "a").trimmedOut
        env.processError = .invalid("`open` exited with status 1: Unable to find application")
        let r = env.run("open", id, "--json")
        #expect(r.code == 1)
        let message = r.json["error"] as? String ?? ""
        #expect(message.contains("Is AgentDrop.app installed?") && message.contains("Unable to find application"))
    }
}

struct AppLinkTests {
    @Test func roundTrips() {
        let url = AppLink.url(forDrop: "k7f2qa")
        #expect(url.absoluteString == "agentdrop://drop/k7f2qa")
        #expect(AppLink.dropID(from: url) == "k7f2qa")
    }

    @Test(arguments: ["agentdrop://drop/", "agentdrop://drop/k7f2qa/extra", "agentdrop://other/k7f2qa",
                      "https://drop/k7f2qa", "agentdrop://drop/NOTANID", "agentdrop://drop/k7f2q0"])
    func rejectsAnythingElse(_ raw: String) throws {
        #expect(AppLink.dropID(from: try #require(URL(string: raw))) == nil)
    }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --filter 'OpenCommandTests|AppLinkTests'`
Expected: build error: `cannot find 'AppLink' in scope`.

- [ ] **Step 4: Add the link type**

`Sources/AgentDropServer/AppLink.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation

/// `agentdrop://drop/<id>` (spec §4 `drop open`): how `drop open` and notifications ask
/// AgentDrop.app to show a drop.
public enum AppLink {
    public static let scheme = "agentdrop"

    public static func url(forDrop id: String) -> URL {
        URL(string: "\(scheme)://drop/\(id)")!
    }

    /// The drop id in an `agentdrop://drop/<id>` URL; nil for anything else.
    public static func dropID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "drop" else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 1, DropID.isWellFormed(String(parts[0])) else { return nil }
        return String(parts[0])
    }
}
```

- [ ] **Step 5: Add the command**

`Sources/DropCLI/Commands/OpenCommand.swift` (create, complete file):

```swift
import AgentDropCore
import AgentDropServer
import ArgumentParser
import Foundation

/// Spec §4 `drop open`: the app shows the drop's rendered view, launching if needed.
struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Show the drop in the Agent Drop app.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let context = CLIContext.current
        let drop = try context.openStore().resolve(id)
        let link = AppLink.url(forDrop: drop.id)
        do {
            // By bundle id, like `drop watch`, so a stray copy of the app can't take the link.
            _ = try context.runProcess(URL(fileURLWithPath: "/usr/bin/open"),
                                       ["-b", CLIContext.appBundleID, link.absoluteString])
        } catch let error as AgentDropError {
            throw AgentDropError.invalid("Couldn't open Agent Drop. Is AgentDrop.app installed? (\(error.message))")
        }
        if output.json { Output.emitJSON(["opened": link.absoluteString]) }
    }
}
```

In `Sources/DropCLI/DropCLI.swift`, replace:

```swift
Reopen.self, Code.self,
```

with:

```swift
Reopen.self, Open.self, Code.self,
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter 'OpenCommandTests|AppLinkTests'`
Expected: all pass. Then `swift test`: everything passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/AgentDropServer/AppLink.swift Sources/DropCLI Tests/dropCLITests
git commit -m "feat(cli): drop open, AppLink"
```

---

### Task 4: App package skeleton: targets, Info.plist, `build-app.sh`, CI

**Files:**
- Modify: `Package.swift`, `Package.resolved` (generated), `.github/workflows/ci.yml`
- Create: `App/Info.plist`, `Scripts/build-app.sh`, `Sources/AgentDropApp/LaunchOptions.swift`, `Sources/AgentDropApp/AppIdentity.swift`, `Sources/AgentDrop/AgentDropMain.swift` (a placeholder Task 11 replaces)
- Test: `Tests/AgentDropAppTests/LaunchOptionsTests.swift`

**Interfaces:**
- Consumes: `CLIContext.appBundleID`, `AppLink.scheme` (Task 3).
- Produces:
  - Targets `AgentDropApp` (library: models, rendering; depends on Core, Server, swift-cmark's `cmark-gfm` + `cmark-gfm-extensions`), `AgentDrop` (executable: views), `AgentDropAppTests`; product `.executable(name: "AgentDrop")`.
  - `public struct LaunchOptions { var windowless: Bool; init(arguments: [String]) }`
  - `public enum AppIdentity { static let bundleID: String; static var isBundled: Bool }`
  - `Scripts/build-app.sh [debug|release]` → `.build/AgentDrop.app` (ad-hoc signed).

- [ ] **Step 1: Why SwiftPM and not an Xcode project**

Spec §9 said `App/` would hold an Xcode project. This plan builds the app from the same Swift package instead, and Task 12 records that in the spec:
- A hand-written `project.pbxproj` can't be reviewed, and every later task would have to edit it.
- The app's models then test with the same `swift test` as everything else, and CI needs no `xcodebuild`.
- `App/` keeps only `Info.plist`; `Scripts/build-app.sh` copies the `AgentDrop` executable and that plist into a bundle.

swift-cmark has no semver tags (only `swift-x.y-RELEASE`), so it is pinned to a commit on its `gfm` branch. That is fine for a root package.

- [ ] **Step 2: Write the failing test**

`Tests/AgentDropAppTests/LaunchOptionsTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropServer
@testable import DropCLI

struct LaunchOptionsTests {
    @Test func windowlessOnlyWhenPassed() {
        #expect(LaunchOptions(arguments: ["/x/AgentDrop", "--windowless"]).windowless)
        #expect(!LaunchOptions(arguments: ["/x/AgentDrop"]).windowless)
        // argv[0] is the executable path, never an option.
        #expect(!LaunchOptions(arguments: ["--windowless"]).windowless)
    }

    @Test func bundleIdentityMatchesTheCLIAndInfoPlist() throws {
        #expect(AppIdentity.bundleID == CLIContext.appBundleID)
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == AppIdentity.bundleID)
        #expect(plist["CFBundleExecutable"] as? String == "AgentDrop")
        let schemes = (plist["CFBundleURLTypes"] as? [[String: Any]])?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes == [AppLink.scheme])
    }
}
```

- [ ] **Step 3: Update the package**

`Package.swift` (modify, complete file):

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
        // The macOS app's executable; Scripts/build-app.sh wraps it into AgentDrop.app.
        .executable(name: "AgentDrop", targets: ["AgentDrop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.1.0"),
        // GFM Markdown → HTML for the app's rendered view. swift-cmark has no semver tags
        // (only swift-x.y-RELEASE), so it is pinned to a commit on its `gfm` branch.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", revision: "56146aeeecbfb7ea54504ac6453ac4cbc0faffe7"),
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
        // Everything in the app that can be tested without a window: models, rendering,
        // settings. The SwiftUI views live in the AgentDrop executable target.
        .target(
            name: "AgentDropApp",
            dependencies: [
                "AgentDropCore",
                "AgentDropServer",
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        .executableTarget(name: "AgentDrop", dependencies: ["AgentDropApp", "AgentDropCore", "AgentDropServer"]),
        // Windowless development stand-in for AgentDrop.app. Not a shipped product.
        .executableTarget(name: "agentdrop-devhost", dependencies: ["AgentDropServer", "AgentDropCore"]),
        .testTarget(
            name: "AgentDropCoreTests",
            dependencies: ["AgentDropCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "AgentDropServerTests", dependencies: ["AgentDropServer", "AgentDropCore"]),
        .testTarget(name: "dropCLITests", dependencies: ["DropCLI", "AgentDropCore", "AgentDropServer"]),
        .testTarget(name: "AgentDropAppTests", dependencies: ["AgentDropApp", "AgentDropCore", "AgentDropServer", "DropCLI"]),
    ]
)
```

Then `swift package resolve`; it adds swift-cmark to `Package.resolved`.

- [ ] **Step 4: Run the test to see it fail**

Run: `swift test --filter LaunchOptionsTests`
Expected: error: the `AgentDropApp` / `AgentDrop` targets have no sources (or `cannot find 'LaunchOptions' in scope`).

- [ ] **Step 5: Add the app library's first types**

`Sources/AgentDropApp/LaunchOptions.swift` (create, complete file):

```swift
import Foundation

/// How the app was started (spec §4 Watching): `drop watch` launches it with
/// `--windowless`, which skips opening the main window. Setup still shows its window.
public struct LaunchOptions: Equatable, Sendable {
    public var windowless: Bool

    public init(arguments: [String]) {
        windowless = arguments.dropFirst().contains("--windowless")
    }
}
```

`Sources/AgentDropApp/AppIdentity.swift` (create, complete file):

```swift
import Foundation

public enum AppIdentity {
    /// Must match CFBundleIdentifier in App/Info.plist and `CLIContext.appBundleID`.
    public static let bundleID = "io.github.mrbenj.AgentDrop"

    /// True when running from AgentDrop.app. `swift run AgentDrop` is unbundled, and
    /// notifications and the login item need a bundle.
    public static var isBundled: Bool { Bundle.main.bundleIdentifier == bundleID }
}
```

- [ ] **Step 6: Add a placeholder app entry point**

`Sources/AgentDrop/AgentDropMain.swift` (create; Task 11 replaces it):

```swift
import AgentDropApp
import SwiftUI

@main
struct AgentDropMain: App {
    var body: some Scene {
        MenuBarExtra("Agent Drop", systemImage: "tray.and.arrow.down") {
            Button("Quit Agent Drop") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
```

- [ ] **Step 7: Add the bundle files**

`App/Info.plist` (create, complete file):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Agent Drop</string>
	<key>CFBundleExecutable</key>
	<string>AgentDrop</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.mrbenj.AgentDrop</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Agent Drop</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>io.github.mrbenj.AgentDrop.drop</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>agentdrop</string>
			</array>
		</dict>
	</array>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSDesktopFolderUsageDescription</key>
	<string>Your drop folder is on the Desktop. Agent Drop reads it to show your drops.</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>Your drop folder is in Documents. Agent Drop reads it to show your drops.</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>Your drop folder is in Downloads. Agent Drop reads it to show your drops.</string>
	<key>NSRemovableVolumesUsageDescription</key>
	<string>Your drop folder is on a removable drive. Agent Drop reads it to show your drops.</string>
	<key>NSNetworkVolumesUsageDescription</key>
	<string>Your drop folder is on a network drive. Agent Drop reads it to show your drops.</string>
</dict>
</plist>
```

`Scripts/build-app.sh` (create, complete file):

```bash
#!/bin/bash
# Builds AgentDrop.app from the AgentDrop executable: .build/AgentDrop.app.
# Usage: Scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration" --product AgentDrop
bin="$(swift build -c "$configuration" --show-bin-path)"
app=".build/AgentDrop.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/AgentDrop" "$app/Contents/MacOS/AgentDrop"
cp App/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
# Ad-hoc signature: not notarized (spec §1 non-goals), but a signed bundle is what
# notifications and the login item expect.
codesign --force --sign - "$app"
echo "$app"
```

Make it executable: `chmod +x Scripts/build-app.sh`.

- [ ] **Step 8: Build the app in CI**

`.github/workflows/ci.yml` (modify, complete file):

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
      - name: Build AgentDrop.app
        run: Scripts/build-app.sh release
      - name: Real-binary smoke test (ephemeral runner only)
        run: Scripts/smoke.sh .build/release/drop .build/release/agentdrop-devhost
```

- [ ] **Step 9: Run the tests and build the bundle**

Run: `swift test --filter LaunchOptionsTests && Scripts/build-app.sh debug`
Expected: tests pass; the script prints `.build/AgentDrop.app`. `plutil -p .build/AgentDrop.app/Contents/Info.plist` shows the bundle id, and `codesign --verify .build/AgentDrop.app` prints nothing. Don't launch it on a machine whose real Agent Drop setup matters: from Task 8 on, launching reads and writes the real config.

- [ ] **Step 10: Commit**

```bash
git add Package.swift Package.resolved .github/workflows/ci.yml App Scripts/build-app.sh Sources/AgentDropApp Sources/AgentDrop Tests/AgentDropAppTests
git commit -m "feat(app): package skeleton, Info.plist, build-app.sh"
```

---

### Task 5: `LibraryModel`: loading, sidebar filters, identity trees, search, counts, selection

**Files:**
- Create: `Sources/AgentDropApp/StoreQueue.swift`, `Sources/AgentDropApp/Sidebar.swift`, `Sources/AgentDropApp/LibraryModel.swift`
- Test: `Tests/AgentDropAppTests/Support.swift`, `Tests/AgentDropAppTests/LibraryModelTests.swift`

**Interfaces:**
- Consumes: Task 1 `unregisteredEntries()`, `UnregisteredEntry`; Core `list(_:)` with `includeArchived`/`limit: nil`, `markRead(_:)`, `Drop.isUnread`, `Drop.isInInbox`, `Validation.isUnder`.
- Produces (all `@MainActor` where a class):
  - `enum StoreQueue { static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T }` (internal): every app store call goes through it.
  - `public enum SidebarItem: Hashable { allDrops, inbox, handoffs, unregistered, archived, project(String), tag(String), from(String); func includes(_ drop: Drop) -> Bool }`
  - `public struct IdentityNode { path, name, count, children: [IdentityNode]? }`, `IdentityTree.build(_ values: [String]) -> [IdentityNode]`, `public struct HandoffGroup { status, drops }`
  - `@Observable public final class LibraryModel` with `enum Selection { drop(String), entry(String) }`; state `store`, `drops`, `unregistered`, `loadError`, `sidebar`, `search`, `selection`, `alert`, `revision`; `registeredInApp: Set<String>` (`public internal(set)`); `afterReload: (@MainActor (DropStore) async -> Void)?`
  - methods `attach(_:) async`, `detach()`, `reload() async`, `drop(_:)`, `reveal(_:) async -> Bool` (discardable), `matchesSearch(_:)`, `static func message(_ error: Error) -> String` (internal)
  - derived `selectedDrop`, `selectedEntry`, `visibleDrops`, `visibleEntries`, `handoffGroups`, `unreadCount`, `inboxDrops`, `inboxCount`, `unregisteredCount`, `recentDrops`, `projectTree`, `fromTree`, `tags`
  - Test support: `Scratch`, `StoreFixture` (`add`, `loose`), `eventually` (main actor), `PortBlocker`.

- [ ] **Step 1: Add the test support**

`Tests/AgentDropAppTests/Support.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore

final class Scratch: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdrop-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A store in a scratch folder, with helpers that write the way the CLI does.
struct StoreFixture {
    let scratch: Scratch
    let store: DropStore
    var folder: URL { store.folder }

    init() throws {
        scratch = try Scratch()
        store = try DropStore.open(folder: scratch.url.appendingPathComponent("AgentDrop", isDirectory: true),
                                   retention: .default)
    }

    @discardableResult
    func add(_ name: String, _ contents: String = "# Title\n", from: String = "agent", project: String? = nil,
             tags: [String] = [], handoff: Bool = false, description: String? = nil) throws -> Drop {
        let source = scratch.url.appendingPathComponent("src-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: source)
        return try store.add(AddRequest(source: .path(source), description: description, project: project, tags: tags,
                                        from: from, handoff: handoff))
    }

    /// A top-level entry with no record.
    func loose(_ name: String) throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try await condition()
}

/// Holds a loopback port open, so the service finds it taken.
final class PortBlocker: @unchecked Sendable {
    private var fd: Int32

    init(port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
    }

    func release() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    deinit { release() }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/AgentDropAppTests/LibraryModelTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore

@MainActor
struct LibraryModelTests {
    @Test func loadsDropsAndUnregisteredEntriesWithCounts() async throws {
        let f = try StoreFixture()
        try f.add("note.md")
        let handoff = try f.add("task.md", handoff: true)
        let archived = try f.add("old.md")
        _ = try f.store.setArchived(archived.id, true)
        try f.loose("loose.txt")

        let library = LibraryModel()
        await library.attach(f.store)
        #expect(library.drops.count == 3)
        #expect(library.unregistered.map(\.name) == ["loose.txt"])
        #expect(library.unreadCount == 2) // archived drops are never unread
        #expect(library.inboxDrops.map(\.id) == [handoff.id])
        #expect(library.unregisteredCount == 1)
        #expect(!library.recentDrops.contains { $0.id == archived.id })
    }

    @Test func sidebarItemsFilterLikeTheCLI() async throws {
        let f = try StoreFixture()
        let a = try f.add("a.md", from: "djleague/build-x", project: "courses-app", tags: ["spec"])
        let b = try f.add("b.md", from: "djleague2", project: "courses-app/web", handoff: true)
        let c = try f.add("c.md", from: "djleague/autodev/AutoDev DJ-1 [ef0]", project: "other")
        let gone = try f.add("d.md", from: "djleague", handoff: true)
        try FileManager.default.removeItem(at: f.store.path(of: gone))
        _ = try f.store.resolve(gone.id) // the CLI notices it missing
        let archived = try f.add("e.md", tags: ["spec"])
        _ = try f.store.setArchived(archived.id, true)

        let library = LibraryModel()
        await library.attach(f.store)
        func ids(_ item: SidebarItem) -> Set<String> {
            library.sidebar = item
            return Set(library.visibleDrops.map(\.id))
        }
        #expect(ids(.allDrops) == [a.id, b.id, c.id, gone.id])
        #expect(ids(.inbox) == [b.id]) // a missing handoff is not in the Inbox
        #expect(ids(.handoffs) == [b.id, gone.id])
        #expect(ids(.archived) == [archived.id])
        #expect(ids(.from("djleague")) == [a.id, c.id, gone.id]) // not djleague2
        #expect(ids(.project("courses-app")) == [a.id, b.id])
        #expect(ids(.tag("spec")) == [a.id]) // archived excluded
        #expect(ids(.unregistered).isEmpty)
    }

    @Test func searchMatchesTitleDescriptionAndFilename() async throws {
        let f = try StoreFixture()
        let byTitle = try f.add("one.md", "# Auth refactor\n")
        let byDescription = try f.add("two.md", description: "Moves sessions to cookies")
        let byFilename = try f.add("cookie-notes.txt", "plain")
        try f.add("other.md")
        try f.loose("COOKIE.png")

        let library = LibraryModel()
        await library.attach(f.store)
        library.search = "  cookie "
        #expect(Set(library.visibleDrops.map(\.id)) == [byDescription.id, byFilename.id])
        library.search = "AUTH"
        #expect(library.visibleDrops.map(\.id) == [byTitle.id])
        library.sidebar = .unregistered
        library.search = "cookie"
        #expect(library.visibleEntries.map(\.name) == ["COOKIE.png"])
    }

    @Test func handoffGroupsAreOrderedOpenClaimedDone() async throws {
        let f = try StoreFixture()
        let open = try f.add("o.md", handoff: true)
        let claimed = try f.add("c.md", handoff: true)
        let done = try f.add("d.md", handoff: true)
        _ = try f.store.claim(claimed.id, by: "x")
        _ = try f.store.done(done.id, note: nil)

        let library = LibraryModel()
        await library.attach(f.store)
        library.sidebar = .handoffs
        #expect(library.handoffGroups.map(\.status) == [.open, .claimed, .done])
        #expect(library.handoffGroups.map { $0.drops.map(\.id) } == [[open.id], [claimed.id], [done.id]])
    }

    @Test func selectingAnUnreadDropMarksItReadOnce() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md")
        let library = LibraryModel()
        await library.attach(f.store)
        library.selection = .drop(drop.id)
        #expect(await eventually { library.drop(drop.id)?.readAt != nil })
        #expect(library.unreadCount == 0)

        library.selection = nil
        library.selection = .drop(drop.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try f.store.events().filter { $0.type == .read }.count == 1)
    }

    @Test func selectingAnEntryMarksNothing() async throws {
        let f = try StoreFixture()
        try f.loose("loose.md")
        let library = LibraryModel()
        await library.attach(f.store)
        library.selection = .entry("loose.md")
        #expect(library.selectedEntry?.name == "loose.md")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try f.store.events().allSatisfy { $0.type == .created })
    }

    @Test func revealSwitchesToAViewThatShowsTheDrop() async throws {
        let f = try StoreFixture()
        let archived = try f.add("old.md")
        _ = try f.store.setArchived(archived.id, true)
        let library = LibraryModel()
        await library.attach(f.store)
        library.sidebar = .inbox
        library.search = "nothing matches this"

        #expect(await library.reveal(archived.id))
        #expect(library.sidebar == .archived && library.search.isEmpty)
        #expect(library.selection == .drop(archived.id))

        // A drop created after the last reload is found by reloading.
        let fresh = try f.add("new.md")
        #expect(await library.reveal(fresh.id))
        #expect(library.sidebar == .allDrops)

        #expect(await library.reveal("zzzzzz") == false)
        #expect(library.alert?.contains("zzzzzz") == true)
    }

    @Test func reloadDropsASelectionThatNoLongerExists() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md")
        try f.loose("loose.md")
        let library = LibraryModel()
        await library.attach(f.store)
        library.selection = .entry("loose.md")
        try FileManager.default.removeItem(at: f.folder.appendingPathComponent("loose.md"))
        await library.reload()
        #expect(library.selection == nil)

        library.selection = .drop(drop.id)
        try FileManager.default.removeItem(at: f.store.path(of: drop))
        _ = try f.store.checkPresence(drop.id)
        try f.store.removeRecord(drop.id)
        await library.reload()
        #expect(library.selection == nil)
    }

    @Test func everyReloadBumpsTheRevision() async throws {
        let f = try StoreFixture()
        let library = LibraryModel()
        await library.attach(f.store)
        let first = library.revision
        await library.reload()
        #expect(library.revision == first + 1)
    }

    @Test func detachClearsEverything() async throws {
        let f = try StoreFixture()
        try f.add("a.md")
        let library = LibraryModel()
        await library.attach(f.store)
        library.sidebar = .archived
        library.detach()
        #expect(library.store == nil && library.drops.isEmpty && library.sidebar == .allDrops)
        await library.reload() // no store: nothing happens
        #expect(library.drops.isEmpty)
    }
}

struct IdentityTreeTests {
    @Test func flatValuesStayFlat() {
        let nodes = IdentityTree.build(["codex", "claude", "codex"])
        #expect(nodes.map(\.name) == ["claude", "codex"])
        #expect(nodes.map(\.count) == [1, 2])
        #expect(nodes.allSatisfy { $0.children == nil })
    }

    @Test func slashValuesBecomeATreeWhosePathsArePrefixes() {
        let nodes = IdentityTree.build(["djleague/build-x", "djleague/autodev/AutoDev DJ-1 [ef0]", "djleague", "pi"])
        #expect(nodes.map(\.path) == ["djleague", "pi"])
        let djleague = nodes[0]
        #expect(djleague.count == 3)
        #expect(djleague.children?.map(\.path) == ["djleague/autodev", "djleague/build-x"])
        #expect(djleague.children?[0].children?.map(\.path) == ["djleague/autodev/AutoDev DJ-1 [ef0]"])
        #expect(djleague.children?[1].children == nil)
    }

    @Test func emptyLevelsKeepExactPrefixes() {
        let nodes = IdentityTree.build(["a//b", "a/"])
        #expect(nodes.map(\.path) == ["a"])
        #expect(nodes[0].children?.map(\.path) == ["a/"])
        #expect(nodes[0].children?[0].children?.map(\.path) == ["a//b"])
        #expect(nodes[0].children?[0].count == 2)
    }

    @Test func treeFilterMatchesTheSidebarFilter() {
        let values = ["djleague/build-x", "djleague2", "djleague"]
        let node = IdentityTree.build(values).first { $0.path == "djleague" }!
        #expect(values.filter { Validation.isUnder($0, prefix: node.path) }.count == node.count)
    }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --filter 'LibraryModelTests|IdentityTreeTests'`
Expected: build error: `cannot find 'LibraryModel' in scope`.

- [ ] **Step 4: Add the store queue**

`Sources/AgentDropApp/StoreQueue.swift` (create, complete file):

```swift
import Foundation

/// Store calls from the app run here, never on the main thread: a write can wait up to
/// 5 s for another process's lock (spec §3), and the UI must not freeze meanwhile. A
/// private serial queue, not `DispatchQueue.global()`, so it always gets a thread.
enum StoreQueue {
    private static let queue = DispatchQueue(label: "AgentDrop.app.store")

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
```

- [ ] **Step 5: Add the sidebar types**

`Sources/AgentDropApp/Sidebar.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation

/// The main window's sidebar (spec §6 Main window).
public enum SidebarItem: Hashable, Sendable {
    case allDrops
    case inbox
    case handoffs
    case unregistered
    case archived
    /// A project, or a project level when values contain `/` (matches the level and beneath).
    case project(String)
    case tag(String)
    /// A `from` identity or level, like `drop list --from-under`.
    case from(String)

    /// Whether the drop belongs in this view. `.unregistered` lists entries, not drops.
    public func includes(_ drop: Drop) -> Bool {
        switch self {
        case .allDrops: !drop.archived
        case .inbox: drop.isInInbox
        case .handoffs: drop.kind == .handoff && !drop.archived
        case .unregistered: false
        case .archived: drop.archived
        case .project(let prefix): !drop.archived && drop.project.map { Validation.isUnder($0, prefix: prefix) } == true
        case .tag(let tag): !drop.archived && drop.tags.contains(tag)
        case .from(let prefix): !drop.archived && Validation.isUnder(drop.from, prefix: prefix)
        }
    }
}

/// One level of a `/`-separated identity (spec §4.1), for the Projects and From lists.
public struct IdentityNode: Identifiable, Hashable, Sendable {
    /// The full value up to this level, e.g. `djleague/autodev`. Used as the filter prefix.
    public var path: String
    /// This level's own name, e.g. `autodev`. May be empty for values like `a//b`.
    public var name: String
    /// Values at this level or beneath it.
    public var count: Int
    /// nil for a leaf, so SwiftUI's `OutlineGroup` shows no disclosure triangle.
    public var children: [IdentityNode]?
    public var id: String { path }
}

public enum IdentityTree {
    /// Values without `/` come out as a flat list; values with `/` as a tree. Each value
    /// counts once at every level above it. Levels are split exactly at `/`, so a node's
    /// path is always a real prefix of the values beneath it.
    public static func build(_ values: [String]) -> [IdentityNode] {
        nodes(values.map { ($0, $0.split(separator: "/", omittingEmptySubsequences: false).map(String.init)) }, depth: 0)
    }

    private static func nodes(_ items: [(value: String, parts: [String])], depth: Int) -> [IdentityNode] {
        var groups: [String: [(value: String, parts: [String])]] = [:]
        for item in items { groups[item.parts[depth], default: []].append(item) }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let group = groups[name]!
            let deeper = group.filter { $0.parts.count > depth + 1 }
            return IdentityNode(path: group[0].parts[0...depth].joined(separator: "/"), name: name, count: group.count,
                                children: deeper.isEmpty ? nil : nodes(deeper, depth: depth + 1))
        }
    }
}

/// The Handoffs view groups by status (spec §6).
public struct HandoffGroup: Identifiable, Equatable, Sendable {
    public var status: HandoffStatus
    public var drops: [Drop]
    public var id: HandoffStatus { status }
}
```

- [ ] **Step 6: Add the model**

`Sources/AgentDropApp/LibraryModel.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation
import Observation

/// Everything the main window and the menu bar show, read from the running store.
@MainActor @Observable
public final class LibraryModel {
    public enum Selection: Hashable, Sendable {
        case drop(String)
        /// An unregistered entry, by name.
        case entry(String)
    }

    public private(set) var store: DropStore?
    /// Every drop, archived ones included, newest first.
    public private(set) var drops: [Drop] = []
    public private(set) var unregistered: [UnregisteredEntry] = []
    /// The last reload failed (e.g. "store busy, retry"); the previous contents stay.
    public private(set) var loadError: String?
    public var sidebar: SidebarItem = .allDrops
    public var search = ""
    public var selection: Selection? {
        didSet { if selection != oldValue { selectionChanged() } }
    }
    /// An action failed; the window shows it as an alert.
    public var alert: String?
    /// Bumped by every reload that applied. Previews reload their file when it changes,
    /// since a content change doesn't change the drop's metadata.
    public private(set) var revision = 0

    /// Drops the human registered in this window: they never trigger a "new drop" notification.
    @ObservationIgnored public internal(set) var registeredInApp: Set<String> = []
    /// Runs after every reload that applied, with the store it read (new-drop notifications).
    @ObservationIgnored public var afterReload: (@MainActor (DropStore) async -> Void)?
    /// Bumped on attach/detach so a reload from the previous folder never lands.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextTicket = 0
    @ObservationIgnored private var appliedTicket = 0

    public init() {}

    // MARK: Loading

    public func attach(_ store: DropStore) async {
        reset()
        self.store = store
        await reload()
    }

    public func detach() {
        reset()
    }

    private func reset() {
        generation += 1
        store = nil
        drops = []
        unregistered = []
        loadError = nil
        selection = nil
        sidebar = .allDrops
        search = ""
    }

    public func reload() async {
        guard let store else { return }
        let generation = self.generation
        nextTicket += 1
        let ticket = nextTicket
        do {
            let snapshot = try await StoreQueue.run { try Snapshot.load(store) }
            // Reloads can overlap; never let an older snapshot overwrite a newer one.
            guard generation == self.generation, ticket > appliedTicket else { return }
            appliedTicket = ticket
            revision += 1
            drops = snapshot.drops
            unregistered = snapshot.unregistered
            loadError = nil
            dropStaleSelection()
            await afterReload?(store)
        } catch {
            guard generation == self.generation else { return }
            loadError = Self.message(error)
        }
    }

    private struct Snapshot: Sendable {
        var drops: [Drop]
        var unregistered: [UnregisteredEntry]

        static func load(_ store: DropStore) throws -> Snapshot {
            var filter = ListFilter()
            filter.includeArchived = true
            filter.limit = nil
            return Snapshot(drops: try store.list(filter), unregistered: try store.unregisteredEntries())
        }
    }

    private func dropStaleSelection() {
        switch selection {
        case .drop(let id) where drop(id) == nil: selection = nil
        case .entry(let name) where !unregistered.contains(where: { $0.name == name }): selection = nil
        default: break
        }
    }

    // MARK: What the views show

    public func drop(_ id: String) -> Drop? { drops.first { $0.id == id } }

    public var selectedDrop: Drop? {
        if case .drop(let id) = selection { return drop(id) }
        return nil
    }

    public var selectedEntry: UnregisteredEntry? {
        if case .entry(let name) = selection { return unregistered.first { $0.name == name } }
        return nil
    }

    /// The list column for the current sidebar item and search.
    public var visibleDrops: [Drop] { drops.filter { sidebar.includes($0) && matchesSearch($0) } }

    public var visibleEntries: [UnregisteredEntry] {
        guard case .unregistered = sidebar else { return [] }
        let query = trimmedSearch
        return query.isEmpty ? unregistered : unregistered.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Open, then claimed, then done; empty groups left out.
    public var handoffGroups: [HandoffGroup] {
        let handoffs = visibleDrops
        return HandoffStatus.allCases.compactMap { status in
            let group = handoffs.filter { $0.status == status }
            return group.isEmpty ? nil : HandoffGroup(status: status, drops: group)
        }
    }

    /// Spec §4 Terms "Unread": the menu bar badge.
    public var unreadCount: Int { drops.count { $0.isUnread } }
    public var inboxDrops: [Drop] { drops.filter { $0.isInInbox } }
    public var inboxCount: Int { inboxDrops.count }
    public var unregisteredCount: Int { unregistered.count }
    /// The menu bar's list: the 10 most recent drops that aren't archived.
    public var recentDrops: [Drop] { Array(drops.lazy.filter { !$0.archived }.prefix(10)) }

    public var projectTree: [IdentityNode] { IdentityTree.build(activeDrops.compactMap(\.project)) }
    public var fromTree: [IdentityNode] { IdentityTree.build(activeDrops.map(\.from)) }
    public var tags: [String] {
        Set(activeDrops.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var activeDrops: [Drop] { drops.filter { !$0.archived } }
    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Spec §6: search filters title, description and filename.
    public func matchesSearch(_ drop: Drop) -> Bool {
        let query = trimmedSearch
        guard !query.isEmpty else { return true }
        return drop.title.localizedCaseInsensitiveContains(query)
            || (drop.description?.localizedCaseInsensitiveContains(query) ?? false)
            || drop.filename.localizedCaseInsensitiveContains(query)
    }

    // MARK: Navigation

    /// Shows the drop: from a deep link, the menu, or a notification. Switches to a view
    /// that contains it when the current one doesn't. False (with an alert) if no drop in
    /// the current folder has that id.
    @discardableResult
    public func reveal(_ id: String) async -> Bool {
        if drop(id) == nil { await reload() }
        guard let drop = drop(id) else {
            alert = "No drop matches '\(id)' in the current drop folder."
            return false
        }
        if !sidebar.includes(drop) || !matchesSearch(drop) {
            sidebar = drop.archived ? .archived : .allDrops
            search = ""
        }
        selection = .drop(id)
        return true
    }

    /// Spec §6: viewing a drop in the detail pane sets `read_at` (first view only).
    private func selectionChanged() {
        guard let drop = selectedDrop, drop.readAt == nil, let store else { return }
        let id = drop.id
        Task {
            do {
                _ = try await StoreQueue.run { try store.markRead(id) }
                await reload()
            } catch {
                alert = Self.message(error)
            }
        }
    }

    static func message(_ error: Error) -> String {
        (error as? AgentDropError)?.message ?? error.localizedDescription
    }
}
```

- [ ] **Step 7: Run the tests**

Run: `swift test --filter 'LibraryModelTests|IdentityTreeTests'`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/AgentDropApp Tests/AgentDropAppTests
git commit -m "feat(app): LibraryModel, sidebar filters, identity trees"
```

---

### Task 6: Detail-pane actions and the edit/register forms

**Files:**
- Create: `Sources/AgentDropApp/Forms.swift`, `Sources/AgentDropApp/LibraryModel+Actions.swift`
- Test: `Tests/AgentDropAppTests/ActionTests.swift`

**Interfaces:**
- Consumes: Task 5 `LibraryModel` (`store`, `drop(_:)`, `reload()`, `alert`, `selection`, `registeredInApp`, `message(_:)`), `StoreQueue`; Core `release`, `done`, `reopen`, `setArchived`, `removeRecord`, `edit(_:_:)`, `EditRequest`, `add(_:)`, `AddRequest`.
- Produces:
  - `public struct MetadataForm { title, description, project, tags, kind; init(_ drop:); static func canChangeKind(_:) -> Bool; func request(for:) throws -> EditRequest? }`
  - `public struct RegisterForm { title, description, from, project, tags, handoff; func request(for: UnregisteredEntry, in: URL) throws -> AddRequest }`
  - `public enum TagList { static func normalized(_:) -> [String] }`
  - `LibraryModel.release(_:)`, `markDone(_:note:)`, `reopen(_:)`, `setArchived(_:_:)`, `removeRecord(_:)` (async; failures set `alert`), `edit(_:_:) async -> String?`, `register(_:_:) async -> String?` (return the error for the sheet; nil on success).

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropAppTests/ActionTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore

@MainActor
struct ActionTests {
    func attached(_ f: StoreFixture) async -> LibraryModel {
        let library = LibraryModel()
        await library.attach(f.store)
        return library
    }

    @Test func handoffButtonsUseTheCoreTransitions() async throws {
        let f = try StoreFixture()
        let drop = try f.add("t.md", handoff: true)
        _ = try f.store.claim(drop.id, by: "codex")
        let library = await attached(f)

        await library.release(drop.id)
        #expect(library.drop(drop.id)?.status == .open && library.drop(drop.id)?.claimedBy == nil)
        await library.markDone(drop.id, note: "  shipped in PR #42 ")
        #expect(library.drop(drop.id)?.status == .done && library.drop(drop.id)?.statusNote == "shipped in PR #42")
        await library.reopen(drop.id)
        #expect(library.drop(drop.id)?.status == .open && library.drop(drop.id)?.statusNote == nil)
        await library.markDone(drop.id, note: "   ")
        #expect(library.drop(drop.id)?.statusNote == nil)
        #expect(library.alert == nil)
    }

    @Test func aConflictBecomesAnAlertAndShowsTheCurrentState() async throws {
        let f = try StoreFixture()
        let drop = try f.add("t.md", handoff: true)
        let library = await attached(f)
        _ = try f.store.claim(drop.id, by: "codex") // another agent, after the window loaded
        await library.reopen(drop.id)
        #expect(library.alert?.contains("claimed by codex") == true)
        #expect(library.drop(drop.id)?.status == .claimed)
    }

    @Test func archiveAndRemoveRecord() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md")
        let library = await attached(f)
        await library.setArchived(drop.id, true)
        #expect(library.drop(drop.id)?.archived == true)
        await library.setArchived(drop.id, false)
        #expect(library.drop(drop.id)?.archived == false)

        await library.removeRecord(drop.id) // file still there: refused
        #expect(library.alert?.contains("still has its file") == true)
        library.alert = nil
        try FileManager.default.removeItem(at: f.store.path(of: drop))
        await library.removeRecord(drop.id)
        #expect(library.alert == nil && library.drop(drop.id) == nil)
    }

    @Test func editAppliesOnlyWhatChanged() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md", project: "p", tags: ["x", "y"])
        let library = await attached(f)
        var form = MetadataForm(try #require(library.drop(drop.id)))
        form.title = "  New title "
        form.tags = ["y", "z", "z", " "]
        form.kind = .handoff
        #expect(await library.edit(drop.id, form) == nil)
        let edited = try #require(library.drop(drop.id))
        #expect(edited.title == "New title" && edited.tags == ["y", "z"])
        #expect(edited.kind == .handoff && edited.status == .open && edited.project == "p")
        #expect(try f.store.events().filter { $0.type == .metadata }.count == 1)

        // Nothing changed: no write, no event.
        #expect(await library.edit(drop.id, MetadataForm(edited)) == nil)
        #expect(try f.store.events().filter { $0.type == .metadata }.count == 1)
    }

    @Test func editErrorsStayInTheSheet() async throws {
        let f = try StoreFixture()
        let drop = try f.add("a.md", project: "p", handoff: true)
        _ = try f.store.claim(drop.id, by: "codex")
        let library = await attached(f)
        var form = MetadataForm(try #require(library.drop(drop.id)))
        form.project = ""
        #expect(await library.edit(drop.id, form)?.contains("can't clear the project") == true)
        form = MetadataForm(try #require(library.drop(drop.id)))
        form.kind = .note
        #expect(await library.edit(drop.id, form)?.contains("Release or reopen") == true)
        form = MetadataForm(try #require(library.drop(drop.id)))
        form.project = "bad\nvalue"
        #expect(await library.edit(drop.id, form) != nil) // the store's identity rules apply
        #expect(library.alert == nil)
    }

    @Test func registerAddsTheEntryInPlaceAndSelectsIt() async throws {
        let f = try StoreFixture()
        try f.loose("notes.md")
        let library = await attached(f)
        let entry = try #require(library.unregistered.first)

        var form = RegisterForm()
        #expect(await library.register(entry, form)?.contains("From") == true) // never filled in
        form.from = " ben "
        form.project = "agent-drop"
        form.tags = ["spec"]
        form.handoff = true
        #expect(await library.register(entry, form) == nil)
        let drop = try #require(library.selectedDrop)
        #expect(drop.filename == "notes.md" && drop.from == "ben" && drop.project == "agent-drop")
        #expect(drop.kind == .handoff && drop.tags == ["spec"])
        #expect(library.unregistered.isEmpty)
        #expect(library.registeredInApp == [drop.id])
        #expect(FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("notes.md").path))
    }

    @Test func aDecomposedUnicodeNameRegistersInPlace() async throws {
        let f = try StoreFixture()
        let decomposed = "Cafe\u{301} notes.md" // as Finder may write it (NFD)
        try f.loose(decomposed)
        let library = await attached(f)
        let entry = try #require(library.unregistered.first)
        var form = RegisterForm()
        form.from = "ben"
        #expect(await library.register(entry, form) == nil)
        #expect(library.unregistered.isEmpty)
        #expect(library.selectedDrop.map { Array($0.filename.utf8) } == Array(entry.name.utf8))
        #expect(try f.store.unregisteredEntries().isEmpty)
    }

    @Test func registeringAFolderEntryKeepsItAFolderDrop() async throws {
        let f = try StoreFixture()
        try FileManager.default.createDirectory(at: f.folder.appendingPathComponent("bundle"), withIntermediateDirectories: true)
        try Data("# Bundle\n".utf8).write(to: f.folder.appendingPathComponent("bundle/README.md"))
        let library = await attached(f)
        var form = RegisterForm()
        form.from = "ben"
        #expect(await library.register(try #require(library.unregistered.first), form) == nil)
        #expect(library.selectedDrop?.isFolder == true && library.selectedDrop?.title == "Bundle")
    }
}

struct FormTests {
    func drop(status: HandoffStatus?) -> Drop {
        Drop(id: "abcdef", filename: "a.md", isFolder: false, title: "T", description: nil, project: nil, tags: [],
             from: "x", createdAt: Date(), updatedAt: Date(), readAt: nil, kind: status == nil ? .note : .handoff,
             status: status, claimedBy: nil, statusNote: nil, archived: false, missing: false)
    }

    @Test func kindIsEditableOnlyForNotesAndOpenHandoffs() {
        #expect(MetadataForm.canChangeKind(drop(status: nil)))
        #expect(MetadataForm.canChangeKind(drop(status: .open)))
        #expect(!MetadataForm.canChangeKind(drop(status: .claimed)))
        #expect(!MetadataForm.canChangeKind(drop(status: .done)))
    }

    @Test func emptyTitleIsRejectedAndEmptyOptionalFieldsAreFineWhenAlreadyEmpty() throws {
        var form = MetadataForm(drop(status: nil))
        #expect(try form.request(for: drop(status: nil)) == nil)
        form.title = "  "
        #expect(throws: AgentDropError.self) { try form.request(for: drop(status: nil)) }
    }

    @Test func tagListTrimsAndDeduplicatesExactly() {
        #expect(TagList.normalized([" PR", "pr", "PR", "", "  "]) == ["PR", "pr"])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter 'ActionTests|FormTests'`
Expected: build error: `cannot find 'MetadataForm' in scope`.

- [ ] **Step 3: Add the forms**

`Sources/AgentDropApp/Forms.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation

/// The detail pane's **Edit metadata** sheet (spec §6). Empty fields are not "clear":
/// like `drop edit`, the store can't clear a description or project yet.
public struct MetadataForm: Equatable, Sendable {
    public var title: String
    public var description: String
    public var project: String
    public var tags: [String]
    public var kind: DropKind

    public init(_ drop: Drop) {
        title = drop.title
        description = drop.description ?? ""
        project = drop.project ?? ""
        tags = drop.tags
        kind = drop.kind
    }

    /// Spec §4.2 "Changing kind": the picker is disabled while a handoff is claimed or done.
    public static func canChangeKind(_ drop: Drop) -> Bool {
        drop.status != .claimed && drop.status != .done
    }

    /// The edit to apply, or nil when nothing changed.
    public func request(for drop: Drop) throws -> EditRequest? {
        var request = EditRequest()
        let title = Self.trim(self.title)
        guard !title.isEmpty else { throw AgentDropError.invalid("The title can't be empty.") }
        if title != drop.title { request.title = title }
        request.description = try Self.changed(description, from: drop.description, field: "description")
        request.project = try Self.changed(project, from: drop.project, field: "project")
        let tags = TagList.normalized(self.tags)
        request.addTags = tags.filter { !drop.tags.contains($0) }
        request.removeTags = drop.tags.filter { !tags.contains($0) }
        if kind != drop.kind {
            guard Self.canChangeKind(drop) else {
                throw AgentDropError.conflict("Release or reopen this handoff before changing its kind.")
            }
            request.kind = kind
        }
        let unchanged = request.title == nil && request.description == nil && request.project == nil
            && request.addTags.isEmpty && request.removeTags.isEmpty && request.kind == nil
        return unchanged ? nil : request
    }

    private static func changed(_ raw: String, from current: String?, field: String) throws -> String? {
        let value = trim(raw)
        if value.isEmpty {
            guard current == nil else {
                throw AgentDropError.invalid("Agent Drop can't clear the \(field) yet; change the text instead.")
            }
            return nil
        }
        return value == current ? nil : value
    }

    static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The **Register** form for an unregistered entry (spec §3.2): registers it in place,
/// exactly like `drop add <path-in-folder>`. `from` is required and never filled in.
public struct RegisterForm: Equatable, Sendable {
    public var title = ""
    public var description = ""
    public var from = ""
    public var project = ""
    public var tags: [String] = []
    public var handoff = false

    public init() {}

    public func request(for entry: UnregisteredEntry, in folder: URL) throws -> AddRequest {
        let from = MetadataForm.trim(self.from)
        guard !from.isEmpty else {
            throw AgentDropError.invalid("“From” is required: who or what made this file.")
        }
        func optional(_ value: String) -> String? {
            let trimmed = MetadataForm.trim(value)
            return trimmed.isEmpty ? nil : trimmed
        }
        return AddRequest(source: .path(folder.appendingPathComponent(entry.name, isDirectory: entry.isFolder)),
                          title: optional(title), description: optional(description), project: optional(project),
                          tags: TagList.normalized(tags), from: from, handoff: handoff)
    }
}

/// Tags as typed into a form: trimmed, empty ones dropped, duplicates removed (exact
/// match, like the store: `PR` and `pr` are different tags).
public enum TagList {
    public static func normalized(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.map(MetadataForm.trim).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
```

- [ ] **Step 4: Add the actions**

`Sources/AgentDropApp/LibraryModel+Actions.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation

/// The detail pane's actions (spec §6). Each calls the same `AgentDropCore` operation as
/// the CLI, through the app's store, then reloads. Failures become `alert`, except the
/// two forms, which return their error so the sheet can stay open and show it.
extension LibraryModel {
    public func release(_ id: String) async { await perform { _ = try $0.release(id) } }

    public func markDone(_ id: String, note: String?) async {
        let note = note.map(MetadataForm.trim).flatMap { $0.isEmpty ? nil : $0 }
        await perform { _ = try $0.done(id, note: note) }
    }

    public func reopen(_ id: String) async { await perform { _ = try $0.reopen(id) } }

    public func setArchived(_ id: String, _ archived: Bool) async {
        await perform { _ = try $0.setArchived(id, archived) }
    }

    /// Spec §3.2 "Remove record", offered only for missing drops.
    public func removeRecord(_ id: String) async { await perform { try $0.removeRecord(id) } }

    /// nil on success (or when nothing changed), else the message to show in the sheet.
    public func edit(_ id: String, _ form: MetadataForm) async -> String? {
        guard let drop = drop(id) else { return "This drop no longer exists." }
        do {
            guard let request = try form.request(for: drop) else { return nil }
            try await write { _ = try $0.edit(id, request) }
            return nil
        } catch {
            return Self.message(error)
        }
    }

    /// Registers the entry in place and selects the new drop. nil on success.
    public func register(_ entry: UnregisteredEntry, _ form: RegisterForm) async -> String? {
        guard let store else { return "Agent Drop isn't serving a folder right now." }
        do {
            let request = try form.request(for: entry, in: store.folder)
            let drop = try await StoreQueue.run { try store.add(request) }
            registeredInApp.insert(drop.id)
            await reload()
            selection = .drop(drop.id)
            return nil
        } catch {
            return Self.message(error)
        }
    }

    private func perform(_ body: @escaping @Sendable (DropStore) throws -> Void) async {
        do {
            try await write(body)
        } catch {
            alert = Self.message(error)
        }
    }

    private func write(_ body: @escaping @Sendable (DropStore) throws -> Void) async throws {
        guard let store else { throw AgentDropError.invalid("Agent Drop isn't serving a folder right now.") }
        do {
            try await StoreQueue.run { try body(store) }
        } catch {
            await reload() // e.g. a conflict: show the state that caused it
            throw error
        }
        await reload()
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter 'ActionTests|FormTests'`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentDropApp Tests/AgentDropAppTests/ActionTests.swift
git commit -m "feat(app): detail-pane actions and metadata/register forms"
```

---

### Task 7: New-drop notifications (logic)

**Files:**
- Create: `Sources/AgentDropApp/NewDropNotifier.swift`
- Test: `Tests/AgentDropAppTests/NotifierTests.swift`

**Interfaces:**
- Consumes: Task 5 `LibraryModel.drop(_:)`, `registeredInApp`, `StoreQueue`; Core `latestSeq()`, `events(afterSeq:)`.
- Produces:
  - `public struct NewDropNotice: Equatable { title, body, dropID: String? }`
  - `@MainActor public protocol NoticePosting: AnyObject { func post(_ notices: [NewDropNotice]) }`
  - `@MainActor public final class NewDropNotifier { init(); func check(_ store: DropStore, library: LibraryModel, enabled: Bool) async -> [NewDropNotice] }`
  - Test support: `RecordingPoster` (in `NotifierTests.swift`, used by Task 8).

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropAppTests/NotifierTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore

@MainActor
final class RecordingPoster: NoticePosting {
    var posted: [NewDropNotice] = []
    func post(_ notices: [NewDropNotice]) { posted += notices }
}

@MainActor
struct NotifierTests {
    @Test func announcesOnlyDropsCreatedAfterTheFirstCheck() async throws {
        let f = try StoreFixture()
        try f.add("before.md")
        let library = LibraryModel()
        await library.attach(f.store)
        let notifier = NewDropNotifier()
        #expect(await notifier.check(f.store, library: library, enabled: true).isEmpty) // baseline

        let drop = try f.add("new.md", "# New plan\n", from: "codex", project: "app", handoff: true,
                             description: "Implement it")
        await library.reload()
        let notices = await notifier.check(f.store, library: library, enabled: true)
        #expect(notices == [NewDropNotice(title: "New plan", body: "Handoff from codex · app\nImplement it",
                                          dropID: drop.id)])
        #expect(await notifier.check(f.store, library: library, enabled: true).isEmpty) // once only
    }

    @Test func disabledStillAdvancesSoTurningItOnDoesntReplayOldDrops() async throws {
        let f = try StoreFixture()
        let library = LibraryModel()
        await library.attach(f.store)
        let notifier = NewDropNotifier()
        _ = await notifier.check(f.store, library: library, enabled: false)
        try f.add("a.md")
        await library.reload()
        #expect(await notifier.check(f.store, library: library, enabled: false).isEmpty)
        #expect(await notifier.check(f.store, library: library, enabled: true).isEmpty)
    }

    @Test func manyAtOnceBecomeOneSummary() async throws {
        let f = try StoreFixture()
        let library = LibraryModel()
        await library.attach(f.store)
        let notifier = NewDropNotifier()
        _ = await notifier.check(f.store, library: library, enabled: true)
        for i in 1...4 { try f.add("n\(i).md", "# N\(i)\n") }
        await library.reload()
        let notices = await notifier.check(f.store, library: library, enabled: true)
        #expect(notices.count == 1)
        #expect(notices.first?.title == "4 new drops" && notices.first?.dropID == nil)
    }

    @Test func skipsDropsRegisteredInTheAppArchivedOrMissing() async throws {
        let f = try StoreFixture()
        try f.loose("mine.md")
        let library = LibraryModel()
        await library.attach(f.store)
        let notifier = NewDropNotifier()
        _ = await notifier.check(f.store, library: library, enabled: true)

        var form = RegisterForm()
        form.from = "ben"
        #expect(await library.register(try #require(library.unregistered.first), form) == nil)
        let archived = try f.add("arch.md")
        _ = try f.store.setArchived(archived.id, true)
        await library.reload()
        #expect(await notifier.check(f.store, library: library, enabled: true).isEmpty)
    }

    @Test func aNewStoreStartsFromItsCurrentEnd() async throws {
        let first = try StoreFixture()
        let second = try StoreFixture()
        try second.add("old-in-other-folder.md")
        let library = LibraryModel()
        await library.attach(first.store)
        let notifier = NewDropNotifier()
        _ = await notifier.check(first.store, library: library, enabled: true)
        await library.attach(second.store) // folder switch
        #expect(await notifier.check(second.store, library: library, enabled: true).isEmpty)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter NotifierTests`
Expected: build error: `cannot find type 'NoticePosting' in scope`.

- [ ] **Step 3: Add the notifier**

`Sources/AgentDropApp/NewDropNotifier.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation

/// One notification to show (spec §6 "Notify on new drops"). Clicking it opens `dropID`,
/// or just the window for a summary.
public struct NewDropNotice: Equatable, Sendable {
    public var title: String
    public var body: String
    public var dropID: String?
}

/// Shows notices. The app's implementation uses UserNotifications; tests record them.
@MainActor
public protocol NoticePosting: AnyObject {
    func post(_ notices: [NewDropNotice])
}

/// Turns `created` events into notices. It reads the event log, not the list, so a drop
/// that arrives and is archived between two reloads is still seen once, and nothing that
/// existed before the app started is ever announced.
@MainActor
public final class NewDropNotifier {
    /// Above this many new drops at once, one summary instead of a notice each.
    static let summaryThreshold = 3
    private weak var store: DropStore?
    private var lastSeq: Int64 = 0
    private var checking = false
    private var checkAgain = false

    public init() {}

    /// Notices for drops created since the last check. The first check for a store (app
    /// start, folder switch) only records where its log ends.
    public func check(_ store: DropStore, library: LibraryModel, enabled: Bool) async -> [NewDropNotice] {
        guard !checking else {
            checkAgain = true
            return []
        }
        checking = true
        defer { checking = false }
        var notices: [NewDropNotice] = []
        repeat {
            checkAgain = false
            notices += await checkOnce(store, library: library, enabled: enabled)
        } while checkAgain
        return notices
    }

    private func checkOnce(_ store: DropStore, library: LibraryModel, enabled: Bool) async -> [NewDropNotice] {
        guard self.store === store else {
            self.store = store
            lastSeq = (try? await StoreQueue.run { try store.latestSeq() }) ?? 0
            return []
        }
        let after = lastSeq
        guard let events = try? await StoreQueue.run({ try store.events(afterSeq: after) }),
              let last = events.last else { return [] }
        lastSeq = last.seq
        guard enabled else { return [] }
        let drops = events.filter { $0.type == .created }
            .compactMap { library.drop($0.dropID) }
            .filter { !$0.archived && !$0.missing && !library.registeredInApp.contains($0.id) }
        return Self.notices(for: drops)
    }

    static func notices(for drops: [Drop]) -> [NewDropNotice] {
        guard drops.count <= summaryThreshold else {
            let titles = drops.prefix(summaryThreshold).map(\.title).joined(separator: ", ")
            return [NewDropNotice(title: "\(drops.count) new drops", body: titles + ", …", dropID: nil)]
        }
        return drops.map { drop in
            let source = [drop.kind == .handoff ? "Handoff from \(drop.from)" : "From \(drop.from)", drop.project]
                .compactMap { $0 }.joined(separator: " · ")
            let body = [source, drop.description].compactMap { $0 }.joined(separator: "\n")
            return NewDropNotice(title: drop.title, body: body, dropID: drop.id)
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter NotifierTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentDropApp/NewDropNotifier.swift Tests/AgentDropAppTests/NotifierTests.swift
git commit -m "feat(app): new-drop notifier"
```

---

### Task 8: `AppModel`: setup, folder confirmation, hosting the service, following config.json

**Files:**
- Create: `Sources/AgentDropApp/AppSettings.swift`, `Sources/AgentDropApp/LoginItem.swift`, `Sources/AgentDropApp/AppModel.swift`
- Test: `Tests/AgentDropAppTests/AppModelTests.swift`

**Interfaces:**
- Consumes: Tasks 1–7: `AgentDropService(config:options:)` + `Options.onChange`, `service.start/stop/retryPort/store`, `FolderWatcher` (on the config dir), `ConfigStore.load/setFolder/setConfirmedFolder/setSetupComplete/setRetention/folderNeedsConfirmation/folderURL`, `FolderProtection.isProtected`, `DropStore.setRetention`, `AppLink.dropID(from:)`, `LibraryModel`, `NewDropNotifier`, `NoticePosting`.
- Produces:
  - `@Observable public final class AppSettings { notifyOnNewDrops (default true), hideDockIcon; init(defaults: UserDefaults = .standard) }`
  - `public protocol LoginItemControlling: Sendable { var isEnabled: Bool { get }; func setEnabled(_:) throws }`, `SystemLoginItem` (SMAppService.mainApp)
  - `@Observable public final class AppModel`:
    - `enum Phase { starting, setup, confirmFolder, running, storeError(String) }`, `enum Banner { noPort, invalidRetention }`
    - state: `phase`, `config`, `serverState`, `library`, `settings`, `configStore`, `launchAtLogin` (setup's choice, default true), `folderError`, `loginItemError`, `pendingDropID`, `showWindow: @MainActor () -> Void`
    - derived: `folder`, `folderIsProtected`, `banners`, `menuStatus`, `launchesAtLogin`
    - `init(configStore:loginItem:settings:poster:serviceOptions:)`
    - `launch()`, `shutdown()`, `completeSetup()`, `confirmFolder()`, `chooseFolder(_:)`, `setRetention(_:)`, `retryPort()`, `retryStore()`, `configDidChange()`, `open(dropID:)`, `open(_ url:)` (all `async`), `setLaunchesAtLogin(_:)`
  - Test support: `FakeLoginItem`, `AppFixture` (scratch home + config dir, `model(poster:)`, `finishedSetup(folder:)`, `stopAll()`).

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropAppTests/AppModelTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore
@testable import AgentDropServer

final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [Bool] = []
    var failure: AgentDropError?
    var calls: [Bool] { lock.withLock { _calls } }
    var isEnabled: Bool { calls.last ?? false }
    func setEnabled(_ enabled: Bool) throws {
        if let failure { throw failure }
        lock.withLock { _calls.append(enabled) }
    }
}

/// A scratch home with its own config.json. Nothing here touches real paths.
@MainActor
final class AppFixture {
    let scratch: Scratch
    let config: ConfigStore
    let loginItem = FakeLoginItem()
    let defaults: UserDefaults
    private(set) var models: [AppModel] = []

    init() throws {
        scratch = try Scratch()
        config = ConfigStore(configDir: scratch.url.appendingPathComponent("support", isDirectory: true),
                             homeDir: scratch.url.appendingPathComponent("home", isDirectory: true))
        let suite = "agentdrop-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    var defaultFolder: URL { config.defaultFolder }
    var desktopFolder: URL { config.homeDir.appendingPathComponent("Desktop/AgentDrop", isDirectory: true) }
    var infoFile: ServerInfoFile { ServerInfoFile(configDir: config.configDir) }

    func model(poster: NoticePosting? = nil) -> AppModel {
        var options = AgentDropService.Options()
        options.portBase = Int.random(in: 20_000...59_000)
        options.debounce = .milliseconds(50)
        let model = AppModel(configStore: config, loginItem: loginItem, settings: AppSettings(defaults: defaults),
                             poster: poster, serviceOptions: options)
        models.append(model)
        return model
    }

    /// Setup already finished in an earlier run.
    func finishedSetup(folder: URL? = nil) throws {
        if let folder { try config.setFolder(folder) }
        try config.setSetupComplete(true)
    }

    func stopAll() async {
        for model in models { await model.shutdown() }
    }
}

@MainActor
struct AppModelSetupTests {
    @Test func beforeSetupNothingButConfigIsTouched() async throws {
        let f = try AppFixture()
        let model = f.model()
        await model.launch()
        #expect(model.phase == .setup)
        #expect(!FileManager.default.fileExists(atPath: f.defaultFolder.path))
        #expect(f.infoFile.read() == nil)
        #expect(model.menuStatus == "Finish setting up Agent Drop…")
        await f.stopAll()
    }

    @Test func finishingSetupCreatesTheFolderStartsServingAndSetsTheLoginItem() async throws {
        let f = try AppFixture()
        let model = f.model()
        await model.launch()
        #expect(model.launchAtLogin) // Yes is pre-selected
        await model.completeSetup()
        #expect(model.phase == .running)
        #expect(try f.config.load().setupComplete)
        #expect(try f.config.load().confirmedFolder == nil) // the default folder isn't protected
        #expect(FileManager.default.fileExists(atPath: f.defaultFolder.path))
        #expect(f.loginItem.calls == [true])
        #expect(f.infoFile.read()?.status == .running)
        #expect(model.library.store?.folder.path == f.defaultFolder.path)
        await f.stopAll()
        #expect(f.infoFile.read() == nil) // removed on clean quit
    }

    @Test func declinedLoginItemAndALoginItemFailureStillFinishSetup() async throws {
        let f = try AppFixture()
        let model = f.model()
        await model.launch()
        model.launchAtLogin = false
        f.loginItem.failure = .invalid("not allowed")
        await model.completeSetup()
        #expect(model.phase == .running)
        #expect(model.loginItemError?.contains("not allowed") == true)
        await f.stopAll()
    }

    @Test func aProtectedFolderIsConfirmedByFinishingSetup() async throws {
        let f = try AppFixture()
        try f.config.setFolder(f.desktopFolder) // e.g. `drop config set-folder` before setup
        let model = f.model()
        await model.launch()
        #expect(model.folderIsProtected)
        #expect(!FileManager.default.fileExists(atPath: f.desktopFolder.path))
        await model.completeSetup()
        #expect(model.phase == .running)
        #expect(try f.config.load().confirmedFolder == f.desktopFolder.standardizedFileURL.path)
        await f.stopAll()
    }

    @Test func aFolderThatCantBeCreatedKeepsSetupOpen() async throws {
        let f = try AppFixture()
        let blocker = f.scratch.url.appendingPathComponent("file")
        try Data().write(to: blocker)
        try f.config.setFolder(blocker.appendingPathComponent("AgentDrop"))
        let model = f.model()
        await model.launch()
        await model.completeSetup()
        #expect(model.phase == .setup)
        #expect(model.folderError?.contains("can't use") == true)
        #expect(try f.config.load().setupComplete == false)
        await f.stopAll()
    }

    @Test func choosingAFolderDuringSetupOnlyRecordsIt() async throws {
        let f = try AppFixture()
        let model = f.model()
        await model.launch()
        let chosen = f.scratch.url.appendingPathComponent("Chosen", isDirectory: true)
        await model.chooseFolder(chosen)
        #expect(model.phase == .setup && model.folder.path == chosen.path)
        #expect(!FileManager.default.fileExists(atPath: chosen.path))
        await f.stopAll()
    }
}

@MainActor
struct AppModelFolderTests {
    @Test func anUnconfirmedProtectedFolderWaitsForConfirmation() async throws {
        let f = try AppFixture()
        try f.finishedSetup(folder: f.desktopFolder)
        let model = f.model()
        await model.launch()
        #expect(model.phase == .confirmFolder)
        #expect(model.menuStatus == "Drop folder changed — confirm")
        #expect(!FileManager.default.fileExists(atPath: f.desktopFolder.path))
        #expect(f.infoFile.read() == nil)

        await model.confirmFolder()
        #expect(model.phase == .running)
        #expect(try f.config.load().confirmedFolder == f.desktopFolder.standardizedFileURL.path)
        await f.stopAll()
    }

    @Test func theCLISwitchingToAnUnprotectedFolderAppliesImmediately() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        let firstToken = f.infoFile.read()?.token
        let other = f.scratch.url.appendingPathComponent("Other", isDirectory: true)
        try f.config.setFolder(other) // `drop config set-folder`, seen through the config watcher
        #expect(await eventually { model.library.store?.folder.path == other.path })
        #expect(model.phase == .running)
        #expect(await eventually { f.infoFile.read()?.token != firstToken })
        await f.stopAll()
    }

    @Test func theCLISwitchingToAProtectedFolderStopsTheServer() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        try f.config.setFolder(f.desktopFolder)
        await model.configDidChange()
        #expect(model.phase == .confirmFolder)
        #expect(model.library.store == nil)
        #expect(f.infoFile.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: f.desktopFolder.path))
        await f.stopAll()
    }

    @Test func choosingAProtectedFolderInTheAppNeedsNoConfirmation() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        await model.chooseFolder(f.desktopFolder)
        #expect(model.phase == .running)
        #expect(model.library.store?.folder.path == f.desktopFolder.path)
        await f.stopAll()
    }

    @Test func retentionChangesApplyWithoutARestart() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        let token = f.infoFile.read()?.token
        await model.setRetention(.forever)
        #expect(model.library.store?.retention == .forever)
        #expect(f.infoFile.read()?.token == token)
        await f.stopAll()
    }

    @Test func invalidRetentionShowsABanner() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        var dict = try JSONSerialization.jsonObject(with: Data(contentsOf: f.config.configFile)) as! [String: Any]
        dict["eventRetentionDays"] = "lots"
        try JSONSerialization.data(withJSONObject: dict).write(to: f.config.configFile)
        let model = f.model()
        await model.launch()
        #expect(model.banners == [.invalidRetention])
        await f.stopAll()
    }

    @Test func aStoreThatCantOpenIsAnError() async throws {
        let f = try AppFixture()
        let blocker = f.scratch.url.appendingPathComponent("file")
        try Data().write(to: blocker)
        try f.finishedSetup(folder: blocker)
        let model = f.model()
        await model.launch()
        guard case .storeError = model.phase else {
            Issue.record("expected storeError, got \(model.phase)")
            return
        }
        #expect(model.menuStatus == "Can't open the drop store")

        // Fixed outside the app (the file moved away): Try Again recovers.
        try FileManager.default.removeItem(at: blocker)
        await model.retryStore()
        #expect(model.phase == .running)
        await f.stopAll()
    }

    @Test func launchAtLoginSettingReportsFailures() async throws {
        let f = try AppFixture()
        let model = f.model()
        model.setLaunchesAtLogin(true)
        #expect(model.launchesAtLogin && model.loginItemError == nil)
        f.loginItem.failure = .invalid("needs approval")
        model.setLaunchesAtLogin(false)
        #expect(model.launchesAtLogin && model.loginItemError?.contains("needs approval") == true)
        await f.stopAll()
    }

    @Test func noFreePortShowsTheRetryBanner() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        var options = AgentDropService.Options()
        let base = Int.random(in: 20_000...59_000)
        options.portBase = base
        options.portAttempts = 1
        let blocker = try PortBlocker(port: base)
        let model = AppModel(configStore: f.config, loginItem: f.loginItem, settings: AppSettings(defaults: f.defaults),
                             serviceOptions: options)
        await model.launch()
        #expect(model.phase == .running && model.banners == [.noPort])
        blocker.release()
        await model.retryPort()
        #expect(model.banners.isEmpty)
        await model.shutdown()
    }
}

@MainActor
struct AppModelLinkTests {
    @Test func aLinkBeforeSetupIsShownWhenSetupCompletes() async throws {
        let f = try AppFixture()
        // The CLI works before setup: an agent dropped something and ran `drop open`.
        let store = try DropStore.open(folder: f.defaultFolder, retention: .default)
        let source = f.scratch.url.appendingPathComponent("plan.md")
        try Data("# Plan".utf8).write(to: source)
        let drop = try store.add(AddRequest(source: .path(source), from: "agent"))

        let model = f.model()
        var windows = 0
        model.showWindow = { windows += 1 }
        await model.launch()
        await model.open(AppLink.url(forDrop: drop.id))
        #expect(model.pendingDropID == drop.id && windows == 1)
        await model.completeSetup()
        #expect(model.library.selection == .drop(drop.id))
        #expect(model.pendingDropID == nil)
        await f.stopAll()
    }

    @Test func badLinksAndUnknownIdsAlert() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        await model.open(URL(string: "agentdrop://elsewhere")!)
        #expect(model.library.alert?.contains("can't open") == true)
        model.library.alert = nil
        await model.open(dropID: "zzzzzz")
        #expect(model.library.alert?.contains("zzzzzz") == true)
        await f.stopAll()
    }

    @Test func aLinkThatArrivesWhileLaunchingIsShownOnceServing() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let store = try DropStore.open(folder: f.defaultFolder, retention: .default)
        let source = f.scratch.url.appendingPathComponent("plan.md")
        try Data("# Plan".utf8).write(to: source)
        let drop = try store.add(AddRequest(source: .path(source), from: "agent"))

        let model = f.model()
        await model.open(dropID: drop.id) // `drop open` launched the app: the link beats launch()
        #expect(model.phase == .starting && model.pendingDropID == drop.id)
        await model.launch()
        #expect(model.library.selection == .drop(drop.id))
        await f.stopAll()
    }

    @Test func aBurstOfCLIWritesConverges() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        let cli = try DropStore.open(folder: f.defaultFolder, retention: .default)
        for i in 0..<60 {
            let source = f.scratch.url.appendingPathComponent("burst/\(i).md")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# \(i)".utf8).write(to: source)
            _ = try cli.add(AddRequest(source: .path(source), from: "agent"))
        }
        #expect(await eventually { model.library.drops.count == 60 })
        await f.stopAll()
    }

    @Test func aBrokenConfigWhileRunningKeepsServingAndSaysSo() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        let good = try Data(contentsOf: f.config.configFile)
        try Data("{ half-written".utf8).write(to: f.config.configFile)
        await model.configDidChange()
        #expect(model.phase == .running && model.library.store != nil)
        #expect(model.library.alert?.contains("config.json") == true)

        model.library.alert = nil
        try good.write(to: f.config.configFile)
        await model.configDidChange()
        #expect(model.phase == .running && model.library.alert == nil)
        await f.stopAll()
    }

    @Test func changesFromTheCLIReachTheLibrary() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let model = f.model()
        await model.launch()
        let cli = try DropStore.open(folder: f.defaultFolder, retention: .default)
        let source = f.scratch.url.appendingPathComponent("x.md")
        try Data("# X".utf8).write(to: source)
        let drop = try cli.add(AddRequest(source: .path(source), from: "agent"))
        #expect(await eventually { model.library.drop(drop.id) != nil })
        try Data("y".utf8).write(to: f.defaultFolder.appendingPathComponent("loose.txt"))
        #expect(await eventually { model.library.unregistered.map(\.name) == ["loose.txt"] })
        await f.stopAll()
    }
}

@MainActor
struct AppModelNotificationTests {
    @Test func theAppPostsForCLIDropsWhileRunning() async throws {
        let f = try AppFixture()
        try f.finishedSetup()
        let poster = RecordingPoster()
        let model = f.model(poster: poster)
        await model.launch()
        let cli = try DropStore.open(folder: f.defaultFolder, retention: .default)
        let source = f.scratch.url.appendingPathComponent("x.md")
        try Data("# From the CLI".utf8).write(to: source)
        _ = try cli.add(AddRequest(source: .path(source), from: "agent"))
        #expect(await eventually { poster.posted.map(\.title) == ["From the CLI"] })

        model.settings.notifyOnNewDrops = false
        let second = f.scratch.url.appendingPathComponent("y.md")
        try Data("# Quiet".utf8).write(to: second)
        _ = try cli.add(AddRequest(source: .path(second), from: "agent"))
        #expect(await eventually { model.library.drops.count == 2 })
        #expect(poster.posted.count == 1)
        await model.shutdown()
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter AppModel`
Expected: build error: `cannot find type 'LoginItemControlling' in scope`.

- [ ] **Step 3: Add the app's own settings**

`Sources/AgentDropApp/AppSettings.swift` (create, complete file):

```swift
import Foundation
import Observation

/// The app's own preferences (spec §6), kept in UserDefaults. Shared settings (folder,
/// retention, port) live in config.json instead, because the CLI reads them too.
@MainActor @Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Spec §6 "Notify on new drops", default on.
    public var notifyOnNewDrops: Bool {
        didSet { defaults.set(notifyOnNewDrops, forKey: Keys.notify) }
    }

    /// Spec §6 "Hide Dock icon": accessory activation policy, menu bar only.
    public var hideDockIcon: Bool {
        didSet { defaults.set(hideDockIcon, forKey: Keys.hideDock) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notifyOnNewDrops = defaults.object(forKey: Keys.notify) as? Bool ?? true
        hideDockIcon = defaults.bool(forKey: Keys.hideDock)
    }

    private enum Keys {
        static let notify = "notifyOnNewDrops"
        static let hideDock = "hideDockIcon"
    }
}
```

- [ ] **Step 4: Add the login item**

`Sources/AgentDropApp/LoginItem.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation
import ServiceManagement

/// Spec §6 "Launch at login". A protocol so tests never register the test runner.
public protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public struct SystemLoginItem: LoginItemControlling {
    public init() {}

    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public func setEnabled(_ enabled: Bool) throws {
        guard AppIdentity.isBundled else {
            throw AgentDropError.invalid("Launch at login needs AgentDrop.app; it isn't available under `swift run`.")
        }
        let service = SMAppService.mainApp
        if enabled, service.status != .enabled {
            try service.register()
        } else if !enabled, service.status == .enabled {
            try service.unregister()
        }
    }
}
```

- [ ] **Step 5: Add the model**

How it fits together:
- Every lifecycle call runs through `serially`, one at a time.
- `launch()` reads config.json only. If setup is done it calls `applyFolder()`: that either waits in `.confirmFolder` or starts the service and attaches the library.
- `configDidChange()` compares folder, needs-confirmation and port with what was applied, and restarts only when one of them changed. A retention change goes straight to the open store.
- The service's `onChange` feeds a `bufferingNewest(1)` stream, so a burst of changes collapses into one pending reload.

`Sources/AgentDropApp/AppModel.swift` (create, complete file):

```swift
import AgentDropCore
import AgentDropServer
import Foundation
import Observation

/// The app's lifecycle (spec §2, §3, §5.2, §6): first-run setup, protected-folder
/// confirmation, hosting the service for the configured folder, and following
/// config.json when the CLI changes it.
@MainActor @Observable
public final class AppModel {
    public enum Phase: Equatable, Sendable {
        case starting
        /// First-run setup (spec §2). Nothing in the drop folder is touched yet.
        case setup
        /// The configured folder is protected and wasn't confirmed in the app (spec §3).
        /// The server and content watcher are off.
        case confirmFolder
        case running
        /// The store couldn't be opened (spec §7). The message says why.
        case storeError(String)
    }

    public enum Banner: Hashable, Identifiable, Sendable {
        /// No port in the range was free (spec §5.2): **Retry**.
        case noPort
        /// config.json holds an invalid retention value, treated as 30 (spec §5.1).
        case invalidRetention
        public var id: Self { self }
    }

    public private(set) var phase: Phase = .starting
    public private(set) var config = AgentDropConfig()
    public private(set) var serverState: AgentDropService.State = .stopped
    public let library: LibraryModel
    public let settings: AppSettings
    public let configStore: ConfigStore
    /// Setup's question "Start Agent Drop at login?"; Yes is pre-selected (spec §6).
    public var launchAtLogin = true
    /// Finishing setup or confirming a folder failed (e.g. macOS denied access).
    public var folderError: String?
    /// Launch at login couldn't be changed. Setup still completes.
    public var loginItemError: String?
    /// A `drop open` link that arrived before the drops could be shown (spec §2).
    public private(set) var pendingDropID: String?
    /// Set by the app delegate: brings up the main window.
    @ObservationIgnored public var showWindow: @MainActor () -> Void = {}

    @ObservationIgnored let loginItem: LoginItemControlling
    @ObservationIgnored private let notifier = NewDropNotifier()
    @ObservationIgnored private let service: AgentDropService
    @ObservationIgnored private let changes: AsyncStream<Void>.Continuation
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var configWatcher: FolderWatcher?
    /// The folder settings the service last started (or refused to start) with.
    @ObservationIgnored private var applied: Applied?
    @ObservationIgnored private var lastOperation: Task<Void, Never>?

    private struct Applied: Equatable {
        var folder: String
        var needsConfirmation: Bool
        var port: Int?
    }

    public init(configStore: ConfigStore, loginItem: LoginItemControlling, settings: AppSettings,
                poster: NoticePosting? = nil, serviceOptions: AgentDropService.Options = .init()) {
        self.configStore = configStore
        self.loginItem = loginItem
        self.settings = settings
        library = LibraryModel()
        // Bursts of changes collapse into one pending reload.
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = continuation
        var options = serviceOptions
        options.onChange = { continuation.yield() }
        service = AgentDropService(config: configStore, options: options)
        let library = self.library
        library.afterReload = { [notifier, weak library, weak poster] store in
            guard let library else { return }
            let notices = await notifier.check(store, library: library, enabled: settings.notifyOnNewDrops)
            if !notices.isEmpty { poster?.post(notices) }
        }
        changeTask = Task { @MainActor in
            for await _ in stream { await library.reload() }
        }
    }

    public var folder: URL { configStore.folderURL(config) }
    public var folderIsProtected: Bool { FolderProtection.isProtected(folder, homeDir: configStore.homeDir) }

    public var banners: [Banner] {
        var banners: [Banner] = []
        if serverState == .noPort { banners.append(.noPort) }
        if config.retentionWasInvalid { banners.append(.invalidRetention) }
        return banners
    }

    /// The menu bar's status line, when the app needs the human.
    public var menuStatus: String? {
        switch phase {
        case .setup: "Finish setting up Agent Drop…"
        case .confirmFolder: "Drop folder changed — confirm"
        case .storeError: "Can't open the drop store"
        case .starting, .running: nil
        }
    }

    // MARK: Lifecycle

    /// Reads config.json and starts serving if setup is done and the folder is confirmed.
    /// Before setup it touches nothing but config.json (spec §2).
    public func launch() async {
        await serially { model in
            model.watchConfig()
            model.loadConfig()
            if model.config.setupComplete {
                await model.applyFolder()
            } else {
                model.phase = .setup
            }
        }
    }

    /// Stops the service (removing server.json) before the app quits.
    public func shutdown() async {
        await serially { model in
            model.configWatcher?.stop()
            model.configWatcher = nil
            await model.service.stop()
            model.serverState = .stopped
            model.changeTask?.cancel()
            model.changes.finish()
        }
    }

    /// Setup's **Finish** button: the folder is touched for the first time here, so a
    /// protected folder's macOS prompt appears now, after setup explained it.
    public func completeSetup() async {
        await serially { model in
            guard model.phase == .setup else { return }
            model.folderError = nil
            model.loadConfig()
            let folder = model.folder
            do {
                try Self.touch(folder)
                if model.folderIsProtected { try model.configStore.setConfirmedFolder(folder) }
                try model.configStore.setSetupComplete(true)
            } catch {
                model.folderError = Self.folderMessage(folder, error)
                return
            }
            do {
                try model.loginItem.setEnabled(model.launchAtLogin)
            } catch {
                model.loginItemError = "Couldn't change Launch at login: \(LibraryModel.message(error))"
            }
            model.loadConfig()
            await model.applyFolder()
        }
    }

    /// The confirmation screen's **Use this folder** (spec §3).
    public func confirmFolder() async {
        await serially { model in
            guard model.phase == .confirmFolder else { return }
            model.folderError = nil
            model.loadConfig()
            let folder = model.folder
            do {
                try Self.touch(folder)
                try model.configStore.setConfirmedFolder(folder)
            } catch {
                model.folderError = Self.folderMessage(folder, error)
                return
            }
            model.loadConfig()
            await model.applyFolder()
        }
    }

    /// A folder picked in the app (setup, confirmation, Settings) counts as confirmed
    /// (spec §3). During setup it is only recorded; otherwise the app switches to it.
    public func chooseFolder(_ url: URL) async {
        do {
            try configStore.setFolder(url)
            try configStore.setConfirmedFolder(url)
        } catch {
            folderError = LibraryModel.message(error)
            return
        }
        await configDidChange()
    }

    /// Settings → Event history.
    public func setRetention(_ retention: Retention) async {
        do {
            try configStore.setRetention(retention)
        } catch {
            library.alert = LibraryModel.message(error)
            return
        }
        await configDidChange()
    }

    /// The store-error screen's **Try Again**.
    public func retryStore() async {
        await serially { model in
            guard case .storeError = model.phase else { return }
            model.loadConfig()
            await model.service.stop()
            await model.applyFolder()
        }
    }

    /// Settings → Launch at login.
    public var launchesAtLogin: Bool { loginItem.isEnabled }

    public func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change Launch at login: \(LibraryModel.message(error))"
        }
    }

    /// The **Retry** banner after `noPort`.
    public func retryPort() async {
        serverState = await service.retryPort()
    }

    /// config.json changed (the CLI, Settings, or an editor). A new folder, a change in
    /// whether it needs confirming, or a new port restarts the service; a new retention
    /// applies to the open store directly.
    public func configDidChange() async {
        await serially { model in
            model.loadConfig()
            guard model.phase != .setup, model.phase != .starting else { return }
            model.library.store?.setRetention(model.config.eventRetentionDays)
            guard model.appliedKey() != model.applied else { return }
            await model.service.stop()
            model.serverState = .stopped
            model.library.detach()
            await model.applyFolder()
        }
    }

    // MARK: Links

    /// `drop open`, a notification, or the menu: show the drop. Before the drops can be
    /// shown (setup, confirmation) it is remembered and shown once they can (spec §2).
    public func open(dropID: String) async {
        showWindow()
        guard phase == .running else {
            pendingDropID = dropID
            return
        }
        await library.reveal(dropID)
    }

    public func open(_ url: URL) async {
        guard let id = AppLink.dropID(from: url) else {
            showWindow()
            library.alert = "Agent Drop can't open \(url.absoluteString)."
            return
        }
        await open(dropID: id)
    }

    // MARK: Internals

    /// Start the service for the configured folder, or wait for confirmation.
    private func applyFolder() async {
        applied = appliedKey()
        if configStore.folderNeedsConfirmation(config) {
            phase = .confirmFolder
            return
        }
        do {
            serverState = try await service.start()
            guard let store = await service.store else {
                throw AgentDropError.invalid("The drop store didn't open.")
            }
            phase = .running
            await library.attach(store)
            if let id = pendingDropID {
                pendingDropID = nil
                await library.reveal(id)
            }
        } catch {
            serverState = .stopped
            phase = .storeError(LibraryModel.message(error))
        }
    }

    private func appliedKey() -> Applied {
        Applied(folder: folder.standardizedFileURL.path, needsConfirmation: configStore.folderNeedsConfirmation(config),
                port: config.serverPort)
    }

    private func loadConfig() {
        do {
            config = try configStore.load()
        } catch {
            library.alert = LibraryModel.message(error)
        }
    }

    private func watchConfig() {
        guard configWatcher == nil else { return }
        try? FileManager.default.createDirectory(at: configStore.configDir, withIntermediateDirectories: true)
        let watcher = FolderWatcher(folder: configStore.configDir) { [weak self] changes in
            guard changes.contains(.entry("config.json")) || changes.contains(.rescan) else { return }
            Task { @MainActor in await self?.configDidChange() }
        }
        do {
            try watcher.start()
            configWatcher = watcher
        } catch {
            library.alert = "Agent Drop can't watch \(configStore.configFile.path) for changes."
        }
    }

    /// Lifecycle operations run one at a time, in call order: each suspends, and one must
    /// never see another's half-applied state.
    private func serially(_ operation: @escaping @MainActor (AppModel) async -> Void) async {
        let previous = lastOperation
        let task = Task { @MainActor in
            await previous?.value
            await operation(self)
        }
        lastOperation = task
        await task.value
    }

    /// Creating and listing the folder is its first access: macOS asks now for a
    /// protected location, and a refusal surfaces as an error here.
    static func touch(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    private static func folderMessage(_ folder: URL, _ error: Error) -> String {
        "Agent Drop can't use \(folder.path): \(LibraryModel.message(error))"
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter AppModel`
Expected: all pass (they start real servers on random loopback ports, in temp dirs). Then `swift test`: everything passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/AgentDropApp Tests/AgentDropAppTests/AppModelTests.swift
git commit -m "feat(app): AppModel lifecycle, settings, login item"
```

---

### Task 9: Preview pipeline: Markdown, preview kinds, the drop-folder URL scheme, file tree, links, VS Code

**Files:**
- Create: `Sources/AgentDropApp/Preview/MarkdownRenderer.swift`, `Sources/AgentDropApp/Preview/PreviewKind.swift`, `Sources/AgentDropApp/Preview/PreviewResources.swift`, `Sources/AgentDropApp/Preview/FolderTree.swift`, `Sources/AgentDropApp/Preview/LinkPolicy.swift`, `Sources/AgentDropApp/CodeLocator.swift`
- Test: `Tests/AgentDropAppTests/PreviewTests.swift`

**Interfaces:**
- Consumes: swift-cmark (`cmark_gfm`, `cmark_gfm_extensions`), Task 2 `FolderListing(id:folder:)`.
- Produces:
  - `MarkdownRenderer.body(_:) -> String`, `MarkdownRenderer.page(_:) -> String` (full page, CSP with no scripts, light/dark CSS)
  - `public enum PreviewKind { markdown, text, quickLook, folder, symlink(target: String?), unavailable(String); static func of(_ url: URL) -> PreviewKind }`
  - `PreviewResources.scheme = "agentdrop-preview"`, `baseURL(forDocumentAt:) -> URL`, `file(for:root:) -> URL?`
  - `public struct FileNode { path, name, type, size, target, children }`, `FolderTree.load(_:) throws -> [FileNode]`, `FolderTree.defaultDocument(_:) -> FileNode?`
  - `public enum LinkAction { scrollInPage, openInBrowser(URL), revealInFinder(URL), ignore }`, `LinkPolicy.action(for:documentBase:root:)`
  - `CodeLocator.find(path:home:isExecutable:) -> URL?`, `CodeLocator.open(_:with:) throws`

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropAppTests/PreviewTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropApp

struct MarkdownRendererTests {
    @Test func rendersGitHubFlavoredMarkdown() {
        let html = MarkdownRenderer.body("# Plan\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n~~old~~ https://example.com\n")
        #expect(html.contains("<h1>Plan</h1>"))
        #expect(html.contains("<table>") && html.contains("<td>2</td>"))
        #expect(html.contains("type=\"checkbox\""))
        #expect(html.contains("<del>old</del>"))
        #expect(html.contains("<a href=\"https://example.com\">"))
    }

    @Test func rawHTMLAndScriptLinksNeverReachThePage() {
        let html = MarkdownRenderer.body("<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[x](javascript:alert(1))\n")
        #expect(!html.contains("<script"))
        #expect(!html.contains("onerror"))
        #expect(!html.contains("javascript:"))
    }

    @Test func thePageForbidsScriptsAndFollowsDarkMode() {
        let page = MarkdownRenderer.page("hi")
        #expect(page.contains("Content-Security-Policy"))
        #expect(page.contains("default-src 'none'"))
        #expect(!page.contains("script-src"))
        #expect(page.contains("prefers-color-scheme: dark"))
    }

    @Test func emptyAndNonASCIIInput() {
        #expect(MarkdownRenderer.body("").isEmpty)
        #expect(MarkdownRenderer.body("# Café 🚀").contains("Café 🚀"))
    }
}

struct PreviewKindTests {
    let scratch: Scratch
    init() throws { scratch = try Scratch() }

    func write(_ name: String, _ data: Data) throws -> URL {
        let url = scratch.url.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func classifiesByTypeExtensionAndContent() throws {
        #expect(PreviewKind.of(try write("a.md", Data("# x".utf8))) == .markdown)
        #expect(PreviewKind.of(try write("a.MARKDOWN", Data("# x".utf8))) == .markdown)
        #expect(PreviewKind.of(try write("a.swift", Data("let x = 1".utf8))) == .text)
        #expect(PreviewKind.of(try write("page.html", Data("<script>".utf8))) == .text) // never rendered
        #expect(PreviewKind.of(try write("NOTES", Data("plain words".utf8))) == .text)
        #expect(PreviewKind.of(try write("empty", Data())) == .text)
        #expect(PreviewKind.of(try write("a.png", Data([0x89, 0x50, 0x4E, 0x47, 0, 1]))) == .quickLook)
        #expect(PreviewKind.of(try write("big.md", Data(count: 2_000_001))) == .quickLook)
        #expect(PreviewKind.of(scratch.url) == .folder)
        #expect(PreviewKind.of(scratch.url.appendingPathComponent("nope")) == .unavailable("This file is no longer in the drop folder."))
    }

    @Test func legacyEncodedTextGoesToQuickLookNotGarbledText() throws {
        // "café" in Windows-1252: 0xE9 alone is not UTF-8.
        #expect(PreviewKind.of(try write("README", Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))) == .quickLook)
    }

    @Test func aLinkIsNeverFollowed() throws {
        _ = try write("real.md", Data("# x".utf8))
        let link = scratch.url.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real.md")
        #expect(PreviewKind.of(link) == .symlink(target: "real.md"))
    }

    @Test func aMultibyteCharacterCutAtTheSniffLimitIsStillText() throws {
        var data = Data(repeating: UInt8(ascii: "a"), count: 8191)
        data.append(contentsOf: Array("é".utf8)) // 2 bytes: the second falls past 8192
        #expect(PreviewKind.of(try write("cut", data)) == .text)
    }
}

struct PreviewResourcesTests {
    let scratch: Scratch
    var root: URL { scratch.url.appendingPathComponent("AgentDrop", isDirectory: true) }

    init() throws {
        scratch = try Scratch()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("bundle/img"), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: root.appendingPathComponent("bundle/img/a b.png"))
        try Data("top".utf8).write(to: root.appendingPathComponent("pic.png"))
        try fm.createDirectory(at: root.appendingPathComponent(".agentdrop"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: root.appendingPathComponent(".agentdrop/index.sqlite"))
        try Data("secret".utf8).write(to: scratch.url.appendingPathComponent("outside.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("bundle/escape.txt").path,
                                  withDestinationPath: "../../outside.txt")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("bundle/linkdir").path, withDestinationPath: "img")
    }

    func resolve(_ relative: String, from document: String) -> URL? {
        let url = URL(string: relative, relativeTo: PreviewResources.baseURL(forDocumentAt: document))!.absoluteURL
        return PreviewResources.file(for: url, root: root)
    }

    @Test func relativeReferencesResolveAgainstTheDocumentsDirectory() {
        #expect(resolve("img/a%20b.png", from: "bundle/README.md")?.path == root.appendingPathComponent("bundle/img/a b.png").path)
        #expect(resolve("pic.png", from: "plan.md")?.path == root.appendingPathComponent("pic.png").path)
        #expect(resolve("../pic.png", from: "bundle/README.md")?.path == root.appendingPathComponent("pic.png").path)
    }

    @Test func nothingOutsideTheFolderNoDotEntriesNoLinks() {
        #expect(resolve("../../outside.txt", from: "bundle/README.md") == nil) // clamped to root/outside.txt: absent
        #expect(resolve("%2E%2E/outside.txt", from: "plan.md") == nil)
        #expect(resolve(".agentdrop/index.sqlite", from: "plan.md") == nil)
        #expect(resolve("escape.txt", from: "bundle/README.md") == nil)
        #expect(resolve("linkdir/a%20b.png", from: "bundle/README.md") == nil)
        #expect(resolve("img", from: "bundle/README.md") == nil) // a directory is not a file
        #expect(PreviewResources.file(for: URL(string: "file:///etc/hosts")!, root: root) == nil)
    }

    @Test func baseURLEncodesAwkwardNames() {
        let base = PreviewResources.baseURL(forDocumentAt: "my bundle #1/docs/README.md")
        #expect(base.absoluteString == "agentdrop-preview://root/my%20bundle%20%231/docs/")
        #expect(PreviewResources.baseURL(forDocumentAt: "plan.md").absoluteString == "agentdrop-preview://root/")
    }
}

struct FolderTreeTests {
    @Test func buildsANestedTreeAndHidesDotEntries() throws {
        let scratch = try Scratch()
        let fm = FileManager.default
        let folder = scratch.url.appendingPathComponent("bundle")
        try fm.createDirectory(at: folder.appendingPathComponent("docs/deep"), withIntermediateDirectories: true)
        try Data("# R".utf8).write(to: folder.appendingPathComponent("README.md"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("docs/deep/x.txt"))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try fm.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("config").path,
                                  withDestinationPath: "../shared/config.json")

        let nodes = try FolderTree.load(folder)
        #expect(nodes.map(\.name) == ["README.md", "config", "docs"])
        #expect(nodes[1].type == "symlink" && nodes[1].target == "../shared/config.json" && nodes[1].children == nil)
        #expect(nodes[2].children?.first?.children?.first?.path == "docs/deep/x.txt")
        #expect(FolderTree.defaultDocument(nodes)?.path == "README.md")
    }

    @Test func defaultDocumentFallsBackToTheFirstMarkdownFile() {
        func file(_ name: String) -> FileNode { FileNode(path: name, name: name, type: "file", size: 1, target: nil, children: nil) }
        #expect(FolderTree.defaultDocument([file("b.md"), file("a.md"), file("c.txt")])?.name == "a.md")
        #expect(FolderTree.defaultDocument([file("readme.md"), file("a.md")])?.name == "readme.md")
        #expect(FolderTree.defaultDocument([file("c.txt")]) == nil)
    }
}

struct CodeLocatorTests {
    @Test func searchesPathThenCommonInstallLocations() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(CodeLocator.find(path: "/a:/b", home: home) { $0 == "/b/code" }?.path == "/b/code")
        #expect(CodeLocator.find(path: "/usr/bin:/bin", home: home) { $0 == "/opt/homebrew/bin/code" }?.path
                == "/opt/homebrew/bin/code")
        let bundled = "/Users/someone/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        #expect(CodeLocator.find(path: nil, home: home) { $0 == bundled }?.path == bundled)
        #expect(CodeLocator.find(path: "/usr/bin", home: home) { _ in false } == nil)
    }
}

struct LinkPolicyTests {
    @Test func linksOpenInTheBrowserFilesAreRevealedAnchorsScroll() throws {
        let scratch = try Scratch()
        try Data("x".utf8).write(to: scratch.url.appendingPathComponent("other.md"))
        let base = PreviewResources.baseURL(forDocumentAt: "plan.md")
        func action(_ href: String) -> LinkAction {
            LinkPolicy.action(for: URL(string: href, relativeTo: base)!.absoluteURL, documentBase: base, root: scratch.url)
        }
        #expect(action("https://example.com/a") == .openInBrowser(URL(string: "https://example.com/a")!))
        #expect(action("mailto:me@example.com") == .openInBrowser(URL(string: "mailto:me@example.com")!))
        #expect(action("#usage") == .scrollInPage)
        #expect(action("other.md") == .revealInFinder(scratch.url.appendingPathComponent("other.md")))
        #expect(action("missing.md") == .ignore)
        #expect(action("file:///etc/hosts") == .ignore)
        #expect(action("javascript:alert(1)") == .ignore)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter 'MarkdownRendererTests|PreviewKindTests|PreviewResourcesTests|FolderTreeTests|LinkPolicyTests|CodeLocatorTests'`
Expected: build error: `cannot find 'MarkdownRenderer' in scope`.

- [ ] **Step 3: Add the renderer**

cmark's default (safe) mode replaces raw HTML with `<!-- raw HTML omitted -->` and blanks `javascript:` links. Never pass `CMARK_OPT_UNSAFE`.

`Sources/AgentDropApp/Preview/MarkdownRenderer.swift` (create, complete file):

```swift
import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Spec §6 Rendering: GFM via swift-cmark → HTML. Raw HTML in the Markdown is never
/// passed through (cmark's safe mode replaces it with a comment and blanks
/// `javascript:` links), and the page's Content-Security-Policy allows no scripts, so
/// nothing in a drop can run code even before the web view's own JavaScript switch.
public enum MarkdownRenderer {
    private static let extensions = ["table", "strikethrough", "autolink", "tasklist", "tagfilter"]

    /// The HTML fragment for `markdown`.
    public static func body(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_DEFAULT | CMARK_OPT_FOOTNOTES
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in extensions {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        markdown.utf8CString.withUnsafeBufferPointer { buffer in
            cmark_parser_feed(parser, buffer.baseAddress, buffer.count - 1) // without the NUL
        }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else {
            return ""
        }
        defer { free(html) }
        return String(cString: html)
    }

    /// A complete page: the fragment, the bundled stylesheet (light and dark), and a
    /// policy that only allows images from the drop folder, `data:` and `https:`.
    public static func page(_ markdown: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(PreviewResources.scheme): data: https:; media-src \(PreviewResources.scheme):; style-src 'unsafe-inline'">
        <meta name="color-scheme" content="light dark">
        <style>\(MarkdownStyle.css)</style>
        </head>
        <body>
        <article class="markdown-body">
        \(body(markdown))
        </article>
        </body>
        </html>
        """
    }
}

enum MarkdownStyle {
    static let css = """
        :root { color-scheme: light dark; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --code-bg: #f6f8fa; --link: #0969da; }
        @media (prefers-color-scheme: dark) {
          :root { --fg: #f0f6fc; --muted: #9198a1; --border: #3d444d; --code-bg: #151b23; --link: #4493f8; }
        }
        html { background: transparent; }
        body { margin: 0; padding: 24px 32px; color: var(--fg); font: 14px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; }
        .markdown-body { max-width: 860px; }
        h1, h2 { border-bottom: 1px solid var(--border); padding-bottom: .3em; }
        h1, h2, h3, h4 { margin: 1.4em 0 .6em; line-height: 1.25; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code, pre { font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code-bg); border-radius: 6px; }
        code { padding: .2em .4em; }
        pre { padding: 12px 16px; overflow: auto; }
        pre code { padding: 0; background: none; }
        blockquote { margin: 0; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
        table { border-collapse: collapse; display: block; overflow: auto; }
        th, td { border: 1px solid var(--border); padding: 6px 13px; }
        img { max-width: 100%; }
        hr { border: 0; border-top: 1px solid var(--border); }
        li > input[type=checkbox] { margin-right: .4em; }
        """
}
```

- [ ] **Step 4: Add preview classification**

`Sources/AgentDropApp/Preview/PreviewKind.swift` (create, complete file):

```swift
import Foundation

/// Which preview a file gets (spec §6 Rendering).
public enum PreviewKind: Equatable, Sendable {
    case markdown
    /// Plain text and code: a monospace text view.
    case text
    /// Images, PDFs and everything else: Quick Look.
    case quickLook
    case folder
    /// Links are listed with their target text and never followed (spec §3).
    case symlink(target: String?)
    case unavailable(String)

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    /// Shown as text even if the first bytes look odd. HTML is text here: never rendered.
    static let textExtensions: Set<String> = [
        "txt", "text", "log", "json", "jsonl", "yaml", "yml", "toml", "ini", "conf", "csv", "tsv", "xml", "html",
        "htm", "css", "js", "mjs", "ts", "tsx", "jsx", "swift", "py", "rb", "go", "rs", "java", "kt", "c", "h", "m",
        "mm", "cpp", "hpp", "sh", "zsh", "bash", "fish", "sql", "diff", "patch", "env", "gitignore",
    ]
    /// Larger files go to Quick Look instead of being loaded into a view.
    static let maxInlineBytes: Int64 = 2_000_000

    public static func of(_ url: URL) -> PreviewKind {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { // does not follow links
            return .unavailable("This file is no longer in the drop folder.")
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory?:
            return .folder
        case .typeSymbolicLink?:
            return .symlink(target: try? fm.destinationOfSymbolicLink(atPath: url.path))
        case .typeRegular?:
            break
        default:
            return .unavailable("Agent Drop doesn't preview this kind of item.")
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxInlineBytes else { return .quickLook }
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if textExtensions.contains(ext) { return .text }
        return looksLikeText(url) ? .text : .quickLook
    }

    /// No NUL bytes and valid UTF-8 in the first 8 KB (allowing a character cut off at the end).
    static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let limit = 8192
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return true }
        guard !data.contains(0) else { return false }
        let maxCut = data.count == limit ? 3 : 0
        return (0...maxCut).contains { String(data: data.dropLast($0), encoding: .utf8) != nil }
    }
}
```

- [ ] **Step 5: Add the drop-folder URL scheme**

`Sources/AgentDropApp/Preview/PreviewResources.swift` (create, complete file):

```swift
import Foundation

/// The rendered view's private URL scheme. A Markdown page is loaded with a base URL in
/// this scheme, so relative links and images resolve against the rendered file's own
/// directory (spec §6), and every request is answered from the drop folder only:
/// nothing above it, no dot-entries (`.agentdrop/`), and never through a symlink (§3).
public enum PreviewResources {
    public static let scheme = "agentdrop-preview"
    private static let host = "root"

    /// The base URL for a document at `relativePath` (relative to the drop folder).
    public static func baseURL(forDocumentAt relativePath: String) -> URL {
        let directories = relativePath.split(separator: "/").dropLast()
        let encoded = directories.map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "" }
        return URL(string: "\(scheme)://\(host)/" + encoded.map { $0 + "/" }.joined())!
    }

    /// The regular file a preview URL names inside `root`, or nil.
    public static func file(for url: URL, root: URL) -> URL? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != ".." && $0 != "." && !$0.hasPrefix(".") }) else { return nil }
        var current = root
        for (index, component) in components.enumerated() {
            current = current.appendingPathComponent(component)
            let type = (try? FileManager.default.attributesOfItem(atPath: current.path))?[.type] as? FileAttributeType
            let isLast = index == components.count - 1
            guard type == (isLast ? .typeRegular : .typeDirectory) else { return nil }
        }
        return current
    }
}
```

- [ ] **Step 6: Add the folder tree**

`Sources/AgentDropApp/Preview/FolderTree.swift` (create, complete file):

```swift
import AgentDropServer
import Foundation

/// One entry in a folder drop's file tree (spec §6 Rendering).
public struct FileNode: Identifiable, Hashable, Sendable {
    /// Relative to the folder drop, e.g. `docs/plan.md`.
    public var path: String
    public var name: String
    /// `file`, `directory`, `symlink` or `other`, as in the server's folder listing.
    public var type: String
    public var size: Int64?
    /// A link's target text; links are never followed.
    public var target: String?
    /// nil for anything but a directory.
    public var children: [FileNode]?
    public var id: String { path }
}

public enum FolderTree {
    /// The folder drop's contents as a tree, sorted by name. Dot-entries are hidden.
    public static func load(_ folder: URL) throws -> [FileNode] {
        nodes(try FolderListing(id: "", folder: folder))
    }

    static func nodes(_ listing: FolderListing) -> [FileNode] {
        let visible = listing.entries.filter { entry in
            !entry.path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        var byParent: [String: [FolderListing.Entry]] = [:]
        for entry in visible {
            let parent = entry.path.split(separator: "/").dropLast().joined(separator: "/")
            byParent[parent, default: []].append(entry)
        }
        func build(_ parent: String) -> [FileNode] {
            (byParent[parent] ?? []).map { entry in
                FileNode(path: entry.path, name: String(entry.path.split(separator: "/").last ?? ""),
                         type: entry.type, size: entry.size, target: entry.target,
                         children: entry.type == "directory" ? build(entry.path) : nil)
            }
        }
        return build("")
    }

    /// What a folder drop shows under its tree: `README.md`, else its first `.md`
    /// alphabetically, at the top level (the same file its title comes from).
    public static func defaultDocument(_ nodes: [FileNode]) -> FileNode? {
        let files = nodes.filter { $0.type == "file" }
        return files.first { $0.name.lowercased() == "readme.md" }
            ?? files.filter { $0.name.lowercased().hasSuffix(".md") }.sorted { $0.name < $1.name }.first
    }
}
```

- [ ] **Step 7: Add the link policy**

`Sources/AgentDropApp/Preview/LinkPolicy.swift` (create, complete file):

```swift
import Foundation

/// What clicking a link in the rendered view does (spec §6: links open in the default
/// browser). A link to a file in the drop folder reveals it in Finder rather than
/// opening it: opening could run a script or app an agent left there.
public enum LinkAction: Equatable, Sendable {
    /// A `#fragment` in the same document: scroll there.
    case scrollInPage
    case openInBrowser(URL)
    case revealInFinder(URL)
    case ignore
}

public enum LinkPolicy {
    public static func action(for url: URL, documentBase: URL, root: URL) -> LinkAction {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return .openInBrowser(url)
        case PreviewResources.scheme:
            if url.fragment != nil, sameDocument(url, documentBase) { return .scrollInPage }
            return PreviewResources.file(for: url, root: root).map(LinkAction.revealInFinder) ?? .ignore
        default:
            return .ignore
        }
    }

    /// Fragment links resolve against the base URL (the document's directory).
    private static func sameDocument(_ url: URL, _ base: URL) -> Bool {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.url?.absoluteString == base.absoluteString
    }
}
```

- [ ] **Step 8: Add the VS Code locator**

`Sources/AgentDropApp/CodeLocator.swift` (create, complete file):

```swift
import Foundation

/// Spec §6 **Open in VS Code**: `code <path>`. Apps started from Finder or at login get
/// a minimal PATH, so the usual install locations are checked too.
public enum CodeLocator {
    public static func find(path: String? = ProcessInfo.processInfo.environment["PATH"],
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        let directories = (path ?? "").split(separator: ":").map(String.init) + ["/usr/local/bin", "/opt/homebrew/bin"]
        let bundled = "Visual Studio Code.app/Contents/Resources/app/bin/code"
        let candidates = directories.map { $0 + "/code" }
            + ["/Applications/" + bundled, home.appendingPathComponent("Applications/" + bundled).path]
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// Starts `code` without waiting for it. A folder drop opens as a workspace.
    public static func open(_ item: URL, with code: URL) throws {
        let process = Process()
        process.executableURL = code
        process.arguments = [item.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
```

- [ ] **Step 9: Run the tests**

Run: `swift test --filter 'MarkdownRendererTests|PreviewKindTests|PreviewResourcesTests|FolderTreeTests|LinkPolicyTests|CodeLocatorTests'`
Expected: all pass.

- [ ] **Step 10: Commit**

```bash
git add Sources/AgentDropApp Tests/AgentDropAppTests/PreviewTests.swift
git commit -m "feat(app): preview pipeline, link policy, VS Code locator"
```

---

### Task 10: The library window: sidebar, list, detail pane, previews, sheets

**Files:**
- Create: `Sources/AgentDropApp/DropFormatting.swift`, `Sources/AgentDrop/Library/LibraryView.swift`, `Sources/AgentDrop/Library/SidebarView.swift`, `Sources/AgentDrop/Library/DropListView.swift`, `Sources/AgentDrop/Library/DetailView.swift`, `Sources/AgentDrop/Library/Sheets.swift`, `Sources/AgentDrop/Preview/FilePreview.swift`, `Sources/AgentDrop/Preview/MarkdownView.swift`
- Test: `Tests/AgentDropAppTests/FormattingTests.swift` (views are checked by building, and by hand in Task 12)

**Interfaces:**
- Consumes: Tasks 5–9 (`AppModel.banners/retryPort/library`, `LibraryModel` state and actions, `MetadataForm`, `RegisterForm`, `TagList`, `PreviewKind`, `PreviewResources`, `FolderTree`, `LinkPolicy`, `MarkdownRenderer`, `CodeLocator`).
- Produces:
  - `DropFormatting.menuLine(_:relativeTo:)`, `relativeTime(_:relativeTo:)`, `statusLabel(_:)`, `copyCommand(_:)`; `RetentionChoice` (`days7`, `days30`, `days90`, `forever`, `custom`; `init(_ Retention)`, `retention`, `label`, `note`)
  - Views: `LibraryView(model:)`, `BannerView`, `NoticeBar`, `SidebarView`, `DropListView`, `DropRow`, `StatusPill`, `DetailView`, `DropDetailView`, `EntryDetailView`, `MetadataGrid`, `OpenInCodeButton`, `Pasteboard`, `EditMetadataSheet`, `RegisterSheet`, `DoneSheet`, `SheetLayout`, `TagEditor`, `FilePreview`, `MarkdownView` + `PreviewSchemeHandler`, `TextFileView`, `QuickLookView`, `FolderPreview`.

- [ ] **Step 1: Write the failing formatting tests**

`Tests/AgentDropAppTests/FormattingTests.swift` (create, complete file):

```swift
import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore

struct FormattingTests {
    func drop(title: String = "Auth plan", project: String? = "courses-app", readAt: Date? = nil,
              isFolder: Bool = false) -> Drop {
        Drop(id: "k7f2qa", filename: "a.md", isFolder: isFolder, title: title, description: nil, project: project, tags: [],
             from: "djleague/build-x", createdAt: Date(timeIntervalSince1970: 1_000_000), updatedAt: Date(), readAt: readAt,
             kind: .note, status: nil, claimedBy: nil, statusNote: nil, archived: false, missing: false)
    }

    @Test func menuLineHasDotTitleProjectFromAndTime() {
        let now = Date(timeIntervalSince1970: 1_000_000 + 300)
        let time = DropFormatting.relativeTime(Date(timeIntervalSince1970: 1_000_000), relativeTo: now)
        #expect(DropFormatting.menuLine(drop(), relativeTo: now) == "● Auth plan — courses-app · djleague/build-x · " + time)
        #expect(!DropFormatting.menuLine(drop(project: nil, readAt: now), relativeTo: now).contains("●"))
        #expect(DropFormatting.menuLine(drop(project: nil), relativeTo: now).contains("Auth plan — djleague/build-x"))
    }

    @Test func longTitlesAreShortened() {
        let line = DropFormatting.menuLine(drop(title: String(repeating: "x", count: 100)))
        #expect(line.contains(String(repeating: "x", count: 59) + "…"))
    }

    @Test func copyCommandFitsTheKindOfDrop() {
        #expect(DropFormatting.copyCommand(drop()) == "drop cat k7f2qa")
        #expect(DropFormatting.copyCommand(drop(isFolder: true)) == "drop path k7f2qa")
    }

    @Test func retentionChoicesRoundTripAndKeepCLIValues() {
        for choice in RetentionChoice.allCases where choice != .custom {
            #expect(RetentionChoice(choice.retention!) == choice)
        }
        #expect(RetentionChoice(.days(14)) == .custom)
        #expect(RetentionChoice.custom.retention == nil)
        #expect(RetentionChoice.note.contains("Your drops and files are never deleted."))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter FormattingTests`
Expected: build error: `cannot find 'DropFormatting' in scope`.

- [ ] **Step 3: Add the formatting helpers**

`Sources/AgentDropApp/DropFormatting.swift` (create, complete file):

```swift
import AgentDropCore
import Foundation

/// Text the menu bar and lists show for a drop (spec §6).
public enum DropFormatting {
    /// One menu line: unread dot, title, project, from, relative time.
    public static func menuLine(_ drop: Drop, relativeTo now: Date = Date()) -> String {
        let title = drop.title.count > 60 ? drop.title.prefix(59) + "…" : drop.title
        let details = [drop.project, drop.from, relativeTime(drop.createdAt, relativeTo: now)]
            .compactMap { $0 }.joined(separator: " · ")
        return (drop.isUnread ? "● " : "") + title + " — " + details
    }

    public static func relativeTime(_ date: Date, relativeTo now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    public static func statusLabel(_ status: HandoffStatus) -> String {
        switch status {
        case .open: "Open"
        case .claimed: "Claimed"
        case .done: "Done"
        }
    }

    /// The **Copy** command for pasting into an agent. `drop cat` prints a file; for a
    /// folder drop the agent needs its path instead.
    public static func copyCommand(_ drop: Drop) -> String {
        drop.isFolder ? "drop path \(drop.id)" : "drop cat \(drop.id)"
    }
}

/// Settings → Event history (spec §5.1): presets plus **Custom…**, which keeps any value
/// set from the CLI displayed as-is.
public enum RetentionChoice: Hashable, CaseIterable, Sendable {
    case days7, days30, days90, forever, custom

    public init(_ retention: Retention) {
        switch retention {
        case .days(7): self = .days7
        case .days(30): self = .days30
        case .days(90): self = .days90
        case .forever: self = .forever
        case .days: self = .custom
        }
    }

    /// nil for `.custom`, whose days come from the text field.
    public var retention: Retention? {
        switch self {
        case .days7: .days(7)
        case .days30: .days(30)
        case .days90: .days(90)
        case .forever: .forever
        case .custom: nil
        }
    }

    public var label: String {
        switch self {
        case .days7: "7 days"
        case .days30: "30 days"
        case .days90: "90 days"
        case .forever: "Forever"
        case .custom: "Custom…"
        }
    }

    /// The disclosure note, verbatim from the spec.
    public static let note = "Old entries in the change log are deleted as new changes come in. Your drops and files are never deleted."
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter FormattingTests`
Expected: all pass. Relative times use the user's locale, which is why the test compares against `relativeTime` and not a literal.

- [ ] **Step 5: Add the window's frame and banners**

`Sources/AgentDrop/Library/LibraryView.swift` (create, complete file):

```swift
import AgentDropApp
import AgentDropCore
import SwiftUI

/// The main window once the folder is served (spec §6 Main window).
struct LibraryView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner, model: model)
            }
            if let error = model.library.loadError {
                NoticeBar(text: "Couldn't refresh: \(error)", systemImage: "exclamationmark.triangle")
            }
            NavigationSplitView {
                SidebarView(library: model.library)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } content: {
                DropListView(library: model.library)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 340)
            } detail: {
                DetailView(library: model.library)
            }
        }
    }
}

struct BannerView: View {
    let banner: AppModel.Banner
    let model: AppModel

    var body: some View {
        switch banner {
        case .noPort:
            NoticeBar(text: "No free port for the local server, so `drop watch` and other apps can't connect. Agent Drop still records changes; they catch up once connected.",
                      systemImage: "network.slash") {
                Button("Retry") { Task { await model.retryPort() } }
            }
        case .invalidRetention:
            NoticeBar(text: "config.json has an invalid eventRetentionDays value, so 30 days is used. Fix it in Settings → Event history.",
                      systemImage: "exclamationmark.triangle")
        }
    }
}

/// A one-line strip above the window's content.
struct NoticeBar<Accessory: View>: View {
    let text: String
    let systemImage: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

extension NoticeBar where Accessory == EmptyView {
    init(text: String, systemImage: String) {
        self.init(text: text, systemImage: systemImage) { EmptyView() }
    }
}
```

- [ ] **Step 6: Add the sidebar**

`Sources/AgentDrop/Library/SidebarView.swift` (create, complete file):

```swift
import AgentDropApp
import SwiftUI

/// Spec §6 sidebar: fixed views, then Projects, Tags and From as filter lists (trees when
/// values contain `/`).
struct SidebarView: View {
    @Bindable var library: LibraryModel

    private var selection: Binding<SidebarItem?> {
        Binding(get: { library.sidebar }, set: { library.sidebar = $0 ?? .allDrops })
    }

    var body: some View {
        List(selection: selection) {
            Label("All Drops", systemImage: "tray.full").tag(SidebarItem.allDrops)
            Label("Inbox", systemImage: "tray.and.arrow.down").badge(library.inboxCount).tag(SidebarItem.inbox)
            Label("Handoffs", systemImage: "arrow.left.arrow.right").tag(SidebarItem.handoffs)
            Label("Unregistered", systemImage: "questionmark.folder").badge(library.unregisteredCount)
                .tag(SidebarItem.unregistered)
            Label("Archived", systemImage: "archivebox").tag(SidebarItem.archived)

            if !library.projectTree.isEmpty {
                Section("Projects") {
                    OutlineGroup(library.projectTree, children: \.children) { node in
                        IdentityRow(node: node, systemImage: "folder").tag(SidebarItem.project(node.path))
                    }
                }
            }
            if !library.tags.isEmpty {
                Section("Tags") {
                    ForEach(library.tags, id: \.self) { tag in
                        Label(tag, systemImage: "tag").tag(SidebarItem.tag(tag))
                    }
                }
            }
            if !library.fromTree.isEmpty {
                Section("From") {
                    OutlineGroup(library.fromTree, children: \.children) { node in
                        IdentityRow(node: node, systemImage: "person").tag(SidebarItem.from(node.path))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct IdentityRow: View {
    let node: IdentityNode
    let systemImage: String

    var body: some View {
        Label(node.name.isEmpty ? "(empty)" : node.name, systemImage: systemImage)
            .badge(node.count)
            .help(node.path)
    }
}
```

- [ ] **Step 7: Add the list column**

`Sources/AgentDrop/Library/DropListView.swift` (create, complete file):

```swift
import AgentDropApp
import AgentDropCore
import SwiftUI

/// Spec §6 list column: title, project, from, tags, relative time, unread dot, status pill.
struct DropListView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        content
            .searchable(text: $library.search, placement: .toolbar, prompt: "Title, description, filename")
            .navigationTitle(title)
    }

    @ViewBuilder private var content: some View {
        switch library.sidebar {
        case .unregistered:
            List(selection: $library.selection) {
                ForEach(library.visibleEntries) { entry in
                    EntryRow(entry: entry).tag(LibraryModel.Selection.entry(entry.name))
                }
            }
            .overlay { if library.visibleEntries.isEmpty { empty("Nothing unregistered", "Every file in the drop folder has a record.") } }
        case .handoffs:
            List(selection: $library.selection) {
                ForEach(library.handoffGroups) { group in
                    Section(DropFormatting.statusLabel(group.status)) {
                        ForEach(group.drops, id: \.id) { drop in
                            DropRow(drop: drop).tag(LibraryModel.Selection.drop(drop.id))
                        }
                    }
                }
            }
            .overlay { if library.handoffGroups.isEmpty { empty("No handoffs", "Agents create them with drop add --handoff.") } }
        default:
            List(selection: $library.selection) {
                ForEach(library.visibleDrops, id: \.id) { drop in
                    DropRow(drop: drop).tag(LibraryModel.Selection.drop(drop.id))
                }
            }
            .overlay { if library.visibleDrops.isEmpty { empty("No drops", "Nothing here yet.") } }
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text(detail))
    }

    private var title: String {
        switch library.sidebar {
        case .allDrops: "All Drops"
        case .inbox: "Inbox"
        case .handoffs: "Handoffs"
        case .unregistered: "Unregistered"
        case .archived: "Archived"
        case .project(let path), .from(let path): path
        case .tag(let tag): "#\(tag)"
        }
    }
}

struct DropRow: View {
    let drop: Drop

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(drop.isUnread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(drop.title).fontWeight(drop.isUnread ? .semibold : .regular).lineLimit(1)
                    Spacer()
                    if let status = drop.status { StatusPill(status: status) }
                }
                Text([drop.project, drop.from].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    if !drop.tags.isEmpty {
                        Text(drop.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(DropFormatting.relativeTime(drop.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .opacity(drop.missing ? 0.5 : 1)
        .help(drop.missing ? "The file is no longer in the drop folder." : drop.filename)
    }
}

struct EntryRow: View {
    let entry: UnregisteredEntry

    var body: some View {
        Label(entry.name, systemImage: entry.isFolder ? "folder" : "doc")
    }
}

struct StatusPill: View {
    let status: HandoffStatus

    var body: some View {
        Text(DropFormatting.statusLabel(status))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .open: .blue
        case .claimed: .orange
        case .done: .green
        }
    }
}
```

- [ ] **Step 8: Add the detail pane**

Each detail view gets `.id(folder + id)`, so after a folder switch, or for another drop, its sheets and preview state start fresh.

`Sources/AgentDrop/Library/DetailView.swift` (create, complete file):

```swift
import AgentDropApp
import AgentDropCore
import AppKit
import SwiftUI

/// Spec §6 detail column: metadata header, action buttons, then the preview.
struct DetailView: View {
    let library: LibraryModel

    var body: some View {
        if let store = library.store, let drop = library.selectedDrop {
            DropDetailView(library: library, drop: drop, folder: store.folder)
                .id(store.folder.path + "/" + drop.id)
        } else if let store = library.store, let entry = library.selectedEntry {
            EntryDetailView(library: library, entry: entry, folder: store.folder)
                .id(store.folder.path + "/" + entry.name)
        } else {
            ContentUnavailableView("Select a drop", systemImage: "tray")
        }
    }
}

struct DropDetailView: View {
    let library: LibraryModel
    let drop: Drop
    let folder: URL
    @State private var editing = false
    @State private var finishing = false
    @State private var confirmingRemove = false

    private var url: URL { folder.appendingPathComponent(drop.filename, isDirectory: drop.isFolder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(drop.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if let status = drop.status { StatusPill(status: status) }
                    Spacer()
                }
                if drop.missing {
                    Label("The file is no longer in the drop folder.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let description = drop.description {
                    Text(description).textSelection(.enabled)
                }
                MetadataGrid(drop: drop)
                actions
            }
            .padding(16)
            Divider()
            if drop.missing {
                ContentUnavailableView("Missing", systemImage: "questionmark.folder",
                                       description: Text("“\(drop.filename)” was moved, renamed or deleted."))
            } else if drop.isFolder {
                FolderPreview(root: folder, folderName: drop.filename, revision: library.revision)
            } else {
                FilePreview(root: folder, relativePath: drop.filename, revision: library.revision)
            }
        }
        .sheet(isPresented: $editing) { EditMetadataSheet(library: library, drop: drop) }
        .sheet(isPresented: $finishing) { DoneSheet(library: library, drop: drop) }
        .confirmationDialog("Remove the record for “\(drop.title)”?", isPresented: $confirmingRemove) {
            Button("Remove Record", role: .destructive) { Task { await library.removeRecord(drop.id) } }
        } message: {
            Text("Only Agent Drop's record is removed. The file is already gone from the drop folder.")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            OpenInCodeButton(url: url, library: library).disabled(drop.missing)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .disabled(drop.missing)
            Menu("Copy") {
                Button("Copy Path") { Pasteboard.copy(url.path) }
                Button("Copy `\(DropFormatting.copyCommand(drop))`") { Pasteboard.copy(DropFormatting.copyCommand(drop)) }
            }
            .fixedSize()
            if drop.status == .claimed {
                Button("Release") { Task { await library.release(drop.id) } }
            }
            if drop.status == .open || drop.status == .claimed {
                Button("Mark Done…") { finishing = true }
            }
            if drop.status == .done {
                Button("Reopen") { Task { await library.reopen(drop.id) } }
            }
            Spacer()
            Menu {
                Button("Edit Metadata…") { editing = true }
                Button(drop.archived ? "Unarchive" : "Archive") {
                    Task { await library.setArchived(drop.id, !drop.archived) }
                }
                if drop.missing {
                    Divider()
                    Button("Remove Record…", role: .destructive) { confirmingRemove = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.small)
    }
}

struct MetadataGrid: View {
    let drop: Drop

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Project", drop.project)
            row("Tags", drop.tags.isEmpty ? nil : drop.tags.joined(separator: ", "))
            row("From", drop.from)
            row("Claimed by", drop.claimedBy)
            row("Note", drop.statusNote)
            row("File", drop.filename + (drop.isFolder ? "/" : ""))
            row("Created", drop.createdAt.formatted(date: .abbreviated, time: .shortened))
            row("Updated", drop.updatedAt.formatted(date: .abbreviated, time: .shortened))
            row("Read", drop.readAt?.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.callout)
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

struct EntryDetailView: View {
    let library: LibraryModel
    let entry: UnregisteredEntry
    let folder: URL
    @State private var registering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text("Unregistered: this \(entry.isFolder ? "folder" : "file") is in the drop folder but has no record. Register it here, or have an agent run `drop add \(entry.name)` from the drop folder.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Register…") { registering = true }.buttonStyle(.borderedProminent)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(entry.name)])
                    }
                }
                .controlSize(.small)
            }
            .padding(16)
            Divider()
            if entry.isFolder {
                FolderPreview(root: folder, folderName: entry.name, revision: library.revision)
            } else {
                FilePreview(root: folder, relativePath: entry.name, revision: library.revision)
            }
        }
        .sheet(isPresented: $registering) { RegisterSheet(library: library, entry: entry) }
    }
}

struct OpenInCodeButton: View {
    let url: URL
    let library: LibraryModel
    @State private var code = CodeLocator.find()

    var body: some View {
        Button("Open in VS Code") {
            guard let code else { return }
            do {
                try CodeLocator.open(url, with: code)
            } catch {
                library.alert = "Couldn't start VS Code: \(error.localizedDescription)"
            }
        }
        .disabled(code == nil)
        .help(code == nil
              ? "VS Code's `code` command wasn't found. In VS Code, run “Shell Command: Install 'code' command in PATH”."
              : "Open in VS Code")
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
```

- [ ] **Step 9: Add the sheets**

`Sources/AgentDrop/Library/Sheets.swift` (create, complete file):

```swift
import AgentDropApp
import AgentDropCore
import SwiftUI

/// Spec §6 **Edit metadata**. The kind picker is disabled while a handoff is claimed or done.
struct EditMetadataSheet: View {
    let library: LibraryModel
    let drop: Drop
    @State private var form: MetadataForm
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(library: LibraryModel, drop: Drop) {
        self.library = library
        self.drop = drop
        _form = State(initialValue: MetadataForm(drop))
    }

    var body: some View {
        SheetLayout(title: "Edit Metadata", error: error, confirm: "Save", busy: saving, onCancel: { dismiss() }) {
            saving = true
            error = await library.edit(drop.id, form)
            saving = false
            if error == nil { dismiss() }
        } content: {
            TextField("Title", text: $form.title)
            TextField("Description", text: $form.description, axis: .vertical).lineLimit(3...6)
            TextField("Project", text: $form.project)
            TagEditor(tags: $form.tags)
            Picker("Kind", selection: $form.kind) {
                Text("Note").tag(DropKind.note)
                Text("Handoff").tag(DropKind.handoff)
            }
            .disabled(!MetadataForm.canChangeKind(drop))
            .help(MetadataForm.canChangeKind(drop) ? "" : "Release or reopen this handoff before changing its kind.")
        }
    }
}

/// Spec §3.2 **Register**: title, description, from, project, tags, kind.
struct RegisterSheet: View {
    let library: LibraryModel
    let entry: UnregisteredEntry
    @State private var form = RegisterForm()
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetLayout(title: "Register “\(entry.name)”", error: error, confirm: "Register", busy: saving,
                    onCancel: { dismiss() }) {
            saving = true
            error = await library.register(entry, form)
            saving = false
            if error == nil { dismiss() }
        } content: {
            TextField("Title", text: $form.title, prompt: Text("From the first # heading, else the filename"))
            TextField("Description", text: $form.description, axis: .vertical).lineLimit(3...6)
            TextField("From", text: $form.from, prompt: Text("Required: who or what made this"))
            TextField("Project", text: $form.project)
            TagEditor(tags: $form.tags)
            Toggle("Handoff (appears in the Inbox for an agent to claim)", isOn: $form.handoff)
        }
    }
}

/// **Mark done** with an optional note (like `drop done --note`).
struct DoneSheet: View {
    let library: LibraryModel
    let drop: Drop
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetLayout(title: "Mark “\(drop.title)” Done", error: nil, confirm: "Mark Done", busy: false,
                    onCancel: { dismiss() }) {
            await library.markDone(drop.id, note: note)
            dismiss()
        } content: {
            TextField("Note", text: $note, prompt: Text("Optional, e.g. shipped in PR #42"))
        }
    }
}

struct SheetLayout<Content: View>: View {
    let title: String
    let error: String?
    let confirm: String
    let busy: Bool
    let onCancel: () -> Void
    let onConfirm: () async -> Void
    @ViewBuilder let content: Content

    init(title: String, error: String?, confirm: String, busy: Bool, onCancel: @escaping () -> Void,
         onConfirm: @escaping () async -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.error = error
        self.confirm = confirm
        self.busy = busy
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Form { content }
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirm) { Task { await onConfirm() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Tags as removable tokens plus a field to add one (tags may contain commas or spaces).
struct TagEditor: View {
    @Binding var tags: [String]
    @State private var newTag = ""

    var body: some View {
        LabeledContent("Tags") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag)
                        Button {
                            tags.removeAll { $0 == tag }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(tag)")
                    }
                }
                TextField("Add a tag", text: $newTag)
                    .onSubmit {
                        tags = TagList.normalized(tags + [newTag])
                        newTag = ""
                    }
            }
        }
    }
}
```

- [ ] **Step 10: Add the previews**

`FilePreview` reclassifies the file whenever the library's `revision` changes, because content changes don't touch the drop's metadata. `MarkdownView` reloads only when the text actually changed, so the scroll position survives an unrelated refresh.

`Sources/AgentDrop/Preview/FilePreview.swift` (create, complete file):

```swift
import AgentDropApp
import AppKit
import Quartz
import SwiftUI

/// Spec §6 Rendering for one file, `relativePath` inside the drop folder `root`.
struct FilePreview: View {
    let root: URL
    let relativePath: String
    /// The library's revision: a change re-reads the file (content events).
    let revision: Int
    @State private var kind: PreviewKind?

    private var url: URL { root.appendingPathComponent(relativePath) }

    var body: some View {
        Group {
            switch kind {
            case nil:
                Color.clear
            case .markdown?:
                MarkdownView(root: root, relativePath: relativePath, revision: revision)
            case .text?:
                TextFileView(url: url, revision: revision)
            case .quickLook?:
                QuickLookView(url: url, revision: revision)
            case .folder?:
                ContentUnavailableView("Folder", systemImage: "folder",
                                       description: Text("Select a file inside it to preview it."))
            case .symlink(let target)?:
                ContentUnavailableView("Link", systemImage: "link",
                                       description: Text("Points to \(target ?? "an unknown target"). Agent Drop never follows links."))
            case .unavailable(let message)?:
                ContentUnavailableView("No Preview", systemImage: "eye.slash", description: Text(message))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(relativePath)#\(revision)") { kind = PreviewKind.of(url) }
    }
}

/// Plain text and code: a read-only monospace text view (fast for large files).
struct TextFileView: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let text = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text { textView.string = text }
    }
}

/// Images, PDFs and everything else (spec §6). Only ever given regular files.
struct QuickLookView: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal)!
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
        } else {
            view.refreshPreviewItem()
        }
    }
}

/// Spec §6: a folder drop shows its file tree above the rendered README (or first `.md`).
/// Selecting a file in the tree previews it with the rules above.
struct FolderPreview: View {
    let root: URL
    let folderName: String
    let revision: Int
    @State private var nodes: [FileNode] = []
    @State private var selected: String?

    var body: some View {
        VSplitView {
            List(selection: $selected) {
                OutlineGroup(nodes, children: \.children) { node in
                    Label(node.type == "symlink" ? "\(node.name) → \(node.target ?? "?")" : node.name,
                          systemImage: icon(node))
                        .tag(node.path)
                }
            }
            .frame(minHeight: 100, idealHeight: 160)
            Group {
                if let selected {
                    FilePreview(root: root, relativePath: folderName + "/" + selected, revision: revision)
                } else {
                    ContentUnavailableView("No README", systemImage: "doc.text",
                                           description: Text("Select a file to preview it."))
                }
            }
            .frame(minHeight: 200)
        }
        .task(id: revision) {
            nodes = (try? FolderTree.load(root.appendingPathComponent(folderName, isDirectory: true))) ?? []
            if selected == nil { selected = FolderTree.defaultDocument(nodes)?.path }
        }
    }

    private func icon(_ node: FileNode) -> String {
        switch node.type {
        case "directory": "folder"
        case "symlink": "link"
        case "file": "doc"
        default: "questionmark.square"
        }
    }
}
```

`Sources/AgentDrop/Preview/MarkdownView.swift` (create, complete file):

```swift
import AgentDropApp
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Markdown rendered by `MarkdownRenderer` in a web view with JavaScript off. Pages load
/// with a base URL in the preview scheme; `PreviewSchemeHandler` answers from the drop
/// folder only.
struct MarkdownView: NSViewRepresentable {
    let root: URL
    let relativePath: String
    let revision: Int

    func makeCoordinator() -> Coordinator { Coordinator(root: root) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(PreviewSchemeHandler(root: root), forURLScheme: PreviewResources.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let markdown = (try? Data(contentsOf: root.appendingPathComponent(relativePath)))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let base = PreviewResources.baseURL(forDocumentAt: relativePath)
        // Reload only when the text changed, so a refresh doesn't lose the scroll position.
        let page = Coordinator.Loaded(base: base, markdown: markdown)
        guard context.coordinator.loaded != page else { return }
        context.coordinator.loaded = page
        webView.loadHTMLString(MarkdownRenderer.page(markdown), baseURL: base)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        struct Loaded: Equatable {
            var base: URL
            var markdown: String
        }

        let root: URL
        var loaded: Loaded?

        init(root: URL) { self.root = root }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url, let base = loaded?.base else {
                decisionHandler(.allow) // the page itself
                return
            }
            switch LinkPolicy.action(for: url, documentBase: base, root: root) {
            case .scrollInPage:
                decisionHandler(.allow)
            case .openInBrowser(let url):
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
            case .revealInFinder(let file):
                decisionHandler(.cancel)
                NSWorkspace.shared.activateFileViewerSelecting([file])
            case .ignore:
                decisionHandler(.cancel)
            }
        }
    }
}

/// Serves `agentdrop-preview:` requests (images, linked files) from the drop folder.
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL

    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = PreviewResources.file(for: url, root: root),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
```

- [ ] **Step 11: Build**

Run: `swift build --product AgentDrop`
Expected: builds with no errors and no warnings (the placeholder `AgentDropMain` doesn't use these views yet).

- [ ] **Step 12: Commit**

```bash
git add Sources/AgentDropApp/DropFormatting.swift Sources/AgentDrop Tests/AgentDropAppTests/FormattingTests.swift
git commit -m "feat(app): library window views and previews"
```

---

### Task 11: The app shell: delegate, window, setup and confirmation screens, menu bar, Settings, notifications

**Files:**
- Modify: `Sources/AgentDrop/AgentDropMain.swift` (replace the placeholder)
- Create: `Sources/AgentDrop/Shell/AppDelegate.swift`, `Sources/AgentDrop/Shell/MainWindowController.swift`, `Sources/AgentDrop/Shell/SystemNotifications.swift`, `Sources/AgentDrop/Shell/RootView.swift`, `Sources/AgentDrop/Shell/MenuBarContent.swift`, `Sources/AgentDrop/Shell/SettingsView.swift`

**Interfaces:**
- Consumes: everything above. `AppModel(configStore: .live(), loginItem: SystemLoginItem(), settings: AppSettings(), poster:)` is the only place real paths are used.
- Produces: the running app.
  - `AppDelegate`: registers the `kAEGetURL` handler in `applicationWillFinishLaunching`; after `launch()` it shows the window unless `--windowless` (setup always shows it); close doesn't quit; Dock reopen shows the window; quit stops the service first, which removes `server.json`.
  - `DockIcon.apply(hidden:)`, `FolderPicker.choose(startingAt:)`, `MainWindowController.show()`.

- [ ] **Step 1: Why the main window is AppKit**

On macOS 14, a SwiftUI `Window`/`WindowGroup` scene opens at launch, and `--windowless` (spec §4 Watching) must open no window. So the only SwiftUI scenes are `MenuBarExtra` and `Settings`, and the main window is an `NSWindow` hosting `RootView`, created once and shown on demand.

- [ ] **Step 2: Replace the entry point**

`Sources/AgentDrop/AgentDropMain.swift` (modify, complete file):

```swift
import AgentDropApp
import SwiftUI

@main
struct AgentDropMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Spec §6: the menu bar extra is always present while the app runs. The main
        // window is an AppKit window the delegate opens on demand, so `--windowless`
        // launches show no window at all.
        MenuBarExtra {
            MenuBarContent(model: delegate.model)
        } label: {
            MenuBarLabel(library: delegate.model.library)
        }
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}
```

- [ ] **Step 3: Add the delegate**

`Sources/AgentDrop/Shell/AppDelegate.swift` (create, complete file):

```swift
import AgentDropApp
import AgentDropCore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private let notifications = SystemNotifications()
    private let launchOptions = LaunchOptions(arguments: CommandLine.arguments)
    private lazy var mainWindow = MainWindowController(model: model)

    override init() {
        model = AppModel(configStore: .live(), loginItem: SystemLoginItem(), settings: AppSettings(),
                         poster: notifications)
        super.init()
        model.showWindow = { [weak self] in self?.showMainWindow() }
        notifications.onOpen = { [weak self] dropID in
            guard let self else { return }
            if let dropID {
                Task { await self.model.open(dropID: dropID) }
            } else {
                self.showMainWindow()
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `drop open` sends agentdrop://drop/<id> (spec §4); it can arrive before launch ends.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIcon.apply(hidden: model.settings.hideDockIcon)
        Task {
            await model.launch()
            // Setup always shows its window (spec §2), even for a windowless launch.
            if !launchOptions.windowless || model.phase == .setup { showMainWindow() }
        }
    }

    /// Clicking the Dock icon (or opening the app again) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// Spec §6: closing the window doesn't quit; the menu bar keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Stop the service first, so server.json is removed on a clean quit (spec §5.2).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        Task { await model.open(url) }
    }

    func showMainWindow() {
        mainWindow.show()
    }
}

/// Spec §6 "Hide Dock icon": accessory activation policy, menu bar only.
enum DockIcon {
    @MainActor static func apply(hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
    }
}
```

- [ ] **Step 4: Add the window**

`Sources/AgentDrop/Shell/MainWindowController.swift` (create, complete file):

```swift
import AgentDropApp
import AppKit
import SwiftUI

/// The main window, created once and reused: closing it only hides it (spec §6).
@MainActor
final class MainWindowController: NSWindowController {
    init(model: AppModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Agent Drop"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RootView(model: model))
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        window.setFrameAutosaveName("AgentDropMainWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 5: Add notifications**

Unbundled runs (`swift run AgentDrop`) must never touch `UNUserNotificationCenter`; it traps without a bundle.

`Sources/AgentDrop/Shell/SystemNotifications.swift` (create, complete file):

```swift
import AgentDropApp
import Foundation
import UserNotifications

/// Spec §6 "Notify on new drops" through UserNotifications. Clicking a notification opens
/// its drop. Unbundled runs (`swift run AgentDrop`) can't use the notification center, so
/// they post nothing.
@MainActor
final class SystemNotifications: NSObject, NoticePosting, UNUserNotificationCenterDelegate {
    var onOpen: (String?) -> Void = { _ in }
    private var askedForPermission = false

    override init() {
        super.init()
        if AppIdentity.isBundled { UNUserNotificationCenter.current().delegate = self }
    }

    func post(_ notices: [NewDropNotice]) {
        guard AppIdentity.isBundled else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            if !askedForPermission {
                askedForPermission = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            for notice in notices {
                let content = UNMutableNotificationContent()
                content.title = notice.title
                content.body = notice.body
                if let id = notice.dropID { content.userInfo = ["dropID": id] }
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let dropID = response.notification.request.content.userInfo["dropID"] as? String
        await MainActor.run { onOpen(dropID) }
    }

    /// Show banners even while the app is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
```

- [ ] **Step 6: Add the phase screens**

`Sources/AgentDrop/Shell/RootView.swift` (create, complete file):

```swift
import AgentDropApp
import AppKit
import SwiftUI

/// What the main window shows for each phase of the app (spec §2, §3, §7).
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .setup:
                SetupView(model: model)
            case .confirmFolder:
                ConfirmFolderView(model: model)
            case .running:
                LibraryView(model: model)
            case .storeError(let message):
                StoreErrorView(model: model, message: message)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .alert("Agent Drop", isPresented: alertShown) {
            Button("OK") { model.library.alert = nil }
        } message: {
            Text(model.library.alert ?? "")
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.library.alert != nil }, set: { if !$0 { model.library.alert = nil } })
    }
}

/// First-run setup (spec §2, §6): the folder, any macOS prompt explained before it
/// appears, and the launch-at-login question with Yes pre-selected.
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var finishing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Agent Drop").font(.largeTitle.weight(.semibold))
            Text("Agents drop files here with context: what each file is, why it exists, which project it's from, and whether a handoff has been picked up.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Drop folder") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.folder.path).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Change…") { pickFolder() }
                    }
                    if model.folderIsProtected {
                        ProtectedFolderNote()
                    }
                }
                .padding(6)
            }

            GroupBox("Start Agent Drop at login?") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Start Agent Drop at login?", selection: $model.launchAtLogin) {
                        Text("Yes").tag(true)
                        Text("No").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text("Agents and apps that watch for changes need it running. You can change this in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            if let error = model.folderError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(finishing ? "Setting up…" : "Finish Setup") {
                    finishing = true
                    Task {
                        await model.completeSetup()
                        finishing = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(finishing)
            }
        }
        .padding(32)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pickFolder() {
        guard let url = FolderPicker.choose(startingAt: model.folder) else { return }
        Task { await model.chooseFolder(url) }
    }
}

/// Spec §3 protected-folder confirmation, after the folder was changed outside the app.
struct ConfirmFolderView: View {
    @Bindable var model: AppModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Drop folder changed").font(.largeTitle.weight(.semibold))
            Text("The drop folder was changed outside Agent Drop to:")
            Text(model.folder.path).font(.body.monospaced()).textSelection(.enabled)
            ProtectedFolderNote()
            Text("Until you confirm, Agent Drop leaves this folder alone: its local server and change tracking are off, and `drop watch` can't connect.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.folderError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose Another Folder…") {
                    if let url = FolderPicker.choose(startingAt: model.folder) {
                        Task { await model.chooseFolder(url) }
                    }
                }
                Spacer()
                Button("Use This Folder") {
                    confirming = true
                    Task {
                        await model.confirmFolder()
                        confirming = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(confirming)
            }
        }
        .padding(32)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Explains the macOS prompt before it appears (spec §2).
struct ProtectedFolderNote: View {
    var body: some View {
        Label {
            Text("This folder is in a location macOS protects (Desktop, Documents, Downloads, iCloud Drive, or a removable or network drive). When you continue, macOS asks whether Agent Drop may access it. Agent Drop needs that to list and show your drops; it reads and writes only inside this folder.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.callout)
    }
}

/// Spec §7: the store can't be opened. Never deleted or repaired automatically.
struct StoreErrorView: View {
    let model: AppModel
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Agent Drop can't open its store", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).textSelection(.enabled)
        } actions: {
            Button("Reveal in Finder") {
                let store = model.folder.appendingPathComponent(".agentdrop", isDirectory: true)
                let target = FileManager.default.fileExists(atPath: store.path) ? store : model.folder
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
            Button("Try Again") { Task { await model.retryStore() } }
        }
    }
}

enum FolderPicker {
    @MainActor static func choose(startingAt folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.directoryURL = folder.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
```

- [ ] **Step 7: Add the menu bar**

`Sources/AgentDrop/Shell/MenuBarContent.swift` (create, complete file):

```swift
import AgentDropApp
import AgentDropCore
import SwiftUI

/// Spec §6 menu bar extra: icon with the unread count.
struct MenuBarLabel: View {
    let library: LibraryModel

    var body: some View {
        let count = library.unreadCount
        Image(systemName: count > 0 ? "tray.full" : "tray")
        if count > 0 { Text("\(count)") }
    }
}

/// The dropdown: the 10 most recent drops, the Inbox, then Open / Settings / Quit.
struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let status = model.menuStatus {
            Button(status) { model.showWindow() }
            Divider()
        }
        if model.phase == .running {
            Section("Recent") {
                if model.library.recentDrops.isEmpty {
                    Text("No drops yet")
                }
                ForEach(model.library.recentDrops, id: \.id) { drop in
                    Button(DropFormatting.menuLine(drop)) { Task { await model.open(dropID: drop.id) } }
                }
            }
            Section("Inbox") {
                if model.library.inboxDrops.isEmpty {
                    Text("No open handoffs")
                }
                ForEach(model.library.inboxDrops, id: \.id) { drop in
                    Button(DropFormatting.menuLine(drop)) { Task { await model.open(dropID: drop.id) } }
                }
            }
            Divider()
        }
        Button("Open Agent Drop") { model.showWindow() }
            .keyboardShortcut("o")
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Agent Drop") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
```

- [ ] **Step 8: Add Settings**

`Sources/AgentDrop/Shell/SettingsView.swift` (create, complete file):

```swift
import AgentDropApp
import AgentDropCore
import SwiftUI

/// Spec §6 settings and §5.1 Settings → Event history.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            EventHistorySettings(model: model)
                .tabItem { Label("Event history", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            LabeledContent("Drop folder") {
                HStack {
                    Text(model.folder.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Change…") {
                        if let url = FolderPicker.choose(startingAt: model.folder) {
                            Task { await model.chooseFolder(url) }
                        }
                    }
                }
            }
            LabeledContent("Local server") {
                HStack {
                    Text(serverText)
                    if model.serverState == .noPort {
                        Button("Retry") { Task { await model.retryPort() } }
                    }
                }
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != model.launchesAtLogin else { return }
                    model.setLaunchesAtLogin(enabled)
                    launchAtLogin = model.launchesAtLogin
                }
            if let error = model.loginItemError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Toggle("Hide Dock icon", isOn: Bindable(model.settings).hideDockIcon)
                .onChange(of: model.settings.hideDockIcon) { _, hidden in DockIcon.apply(hidden: hidden) }
            Toggle("Notify on new drops", isOn: Bindable(model.settings).notifyOnNewDrops)
        }
        .onAppear { launchAtLogin = model.launchesAtLogin }
    }

    private var serverText: String {
        switch model.serverState {
        case .running(let port): "Running on 127.0.0.1:\(port)"
        case .noPort: "No free port"
        case .stopped: "Off"
        }
    }
}

struct EventHistorySettings: View {
    let model: AppModel
    @State private var choice: RetentionChoice = .days30
    @State private var customDays = ""
    @State private var customError: String?

    var body: some View {
        Form {
            Picker("Keep change-log entries for", selection: $choice) {
                ForEach(RetentionChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .onChange(of: choice) { _, newChoice in
                guard let retention = newChoice.retention,
                      retention != model.config.eventRetentionDays || model.config.retentionWasInvalid else { return }
                Task { await model.setRetention(retention) }
            }
            if choice == .custom {
                HStack {
                    TextField("Days", text: $customDays).frame(width: 80)
                    Text("days")
                    Button("Apply") {
                        guard let retention = Retention(argument: customDays.trimmingCharacters(in: .whitespaces)),
                              retention != .forever else {
                            customError = "Enter a whole number of days, 1 or more."
                            return
                        }
                        customError = nil
                        Task { await model.setRetention(retention) }
                    }
                }
                if let customError { Text(customError).foregroundStyle(.red).font(.callout) }
            }
            if model.config.retentionWasInvalid {
                HStack {
                    Text("config.json has an invalid value, so 30 days is used until you choose one here.")
                        .foregroundStyle(.orange).font(.callout)
                    Button("Use 30 Days") { Task { await model.setRetention(.default) } }
                }
            }
            Text(RetentionChoice.note).font(.callout).foregroundStyle(.secondary)
        }
        .onAppear(perform: sync)
        .onChange(of: model.config.eventRetentionDays) { _, _ in sync() }
    }

    /// Shows whatever config.json holds, including a value set from the CLI.
    private func sync() {
        choice = RetentionChoice(model.config.eventRetentionDays)
        if case .days(let days) = model.config.eventRetentionDays { customDays = String(days) }
    }
}
```

- [ ] **Step 9: Build everything**

Run: `swift build --product AgentDrop && swift test && Scripts/build-app.sh release`
Expected: no errors or warnings; all tests pass; `.build/AgentDrop.app` is built. Launching it is Task 12's manual check, on a machine where the real setup may change.

- [ ] **Step 10: Commit**

```bash
git add Sources/AgentDrop
git commit -m "feat(app): shell: delegate, window, setup, menu bar, settings, notifications"
```

---

### Task 12: Docs, spec, manual checklist, and the human check

**Files:**
- Create: `docs/manual-test-checklist.md`
- Modify: `README.md`, `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, `Sources/agentdrop-devhost/main.swift`, `Sources/AgentDropServer/TemporarySetup.swift`, `Sources/AgentDropCore/DropStore+Edit.swift`, `Sources/DropCLI/CLIContext.swift` (comments and help text that said "until Plan 3")

**Interfaces:**
- Consumes: the finished app.
- Produces: user-facing install instructions, the spec updated to match what was built, and the checklist spec §8 asks for.

- [ ] **Step 1: Update the README**

In `README.md`, replace:

```markdown
**Status:** the `drop` CLI works today (Plan 1). The local server and `drop watch` are built
(Plan 2); the macOS app that hosts the server is next (Plan 3). Until then,
`agentdrop-devhost` stands in for the app (see below). See
[the design spec](docs/superpowers/specs/2026-10-11-agent-drop-design.md).
```

with:

```markdown
**Status:** v0.1: the `drop` CLI, the local server with `drop watch`, and AgentDrop.app
(menu bar + main window). Build from source; the app is not notarized yet. See
[the design spec](docs/superpowers/specs/2026-10-11-agent-drop-design.md).
```

In `README.md`, replace:

````markdown
```bash
git clone https://github.com/MrBenJ/agent-drop.git
cd agent-drop
swift build -c release --product drop
cp .build/release/drop /usr/local/bin/drop   # or anywhere on your PATH
```
````

with:

````markdown
```bash
git clone https://github.com/MrBenJ/agent-drop.git
cd agent-drop
swift build -c release --product drop
cp .build/release/drop /usr/local/bin/drop   # or anywhere on your PATH

Scripts/build-app.sh                          # builds .build/AgentDrop.app
cp -R .build/AgentDrop.app /Applications/
open /Applications/AgentDrop.app              # first launch: setup
```

The app is ad-hoc signed, not notarized. If macOS refuses to open it, right-click it in
Finder → **Open** once.

The first launch shows setup: it shows the drop folder (default `~/AgentDrop`) and asks
whether Agent Drop should start at login. Until setup is finished, the app doesn't touch
the drop folder. The CLI works without the app at any time.
````

In `README.md`, replace:

```markdown
Teach your agents with `drop agent-instructions >> CLAUDE.md` (or `AGENTS.md`).
```

with:

```markdown
Teach your agents with `drop agent-instructions >> CLAUDE.md` (or `AGENTS.md`).

`drop open <id>` shows a drop in the app (rendered Markdown, file previews, handoff
buttons). The menu bar icon counts unread drops.
```

In `README.md`, replace:

````markdown
It launches the app in the background if it isn't running. **Until the app exists**,
run the development stand-in in another terminal instead:

```bash
swift run agentdrop-devhost --temporary-setup
```

It serves your configured drop folder exactly as the app will (content watcher, local
server, `server.json`) until Ctrl-C. `--temporary-setup` marks the app's first-run setup
as done only while it runs, and puts `config.json` back exactly as it was on exit.
````

with:

```markdown
It launches the app in the background (no window, menu bar icon only) if it isn't
running, and needs the app's setup to be finished.

For development without the app, `swift run agentdrop-devhost --temporary-setup` serves
the configured folder the same way from a terminal until Ctrl-C. `--temporary-setup`
marks setup as done only while it runs and puts `config.json` back on exit. Don't run it
while the app is running.
```

- [ ] **Step 2: Record this plan's decisions in the spec**

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
One repo: a Swift package (`AgentDropCore`, `AgentDropServer`, `drop`) plus an Xcode
project for the app (§9).
```

with:

```markdown
One repo, one Swift package (`AgentDropCore`, `AgentDropServer`, `drop`, and the app's
`AgentDropApp` library and `AgentDrop` executable). `Scripts/build-app.sh` wraps the
executable into `AgentDrop.app` with `App/Info.plist` (§9). No Xcode project: the app
builds and its models test with `swift build` / `swift test`, like everything else.
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
| `AgentDrop.app` | SwiftUI app | UI only: main window + menu bar extra. Reads/writes through `AgentDropCore` and hosts an `AgentDropServer` instance. |
```

with:

```markdown
| `AgentDropApp` | Swift library | The app's testable layer: lifecycle (setup, folder confirmation, hosting the service), the library and menu models, forms, notifications logic, Markdown rendering and preview rules. No views. |
| `AgentDrop.app` | SwiftUI app (`AgentDrop` executable) | UI only: main window + menu bar extra. Reads/writes through `AgentDropCore` (via `AgentDropApp`) and hosts an `AgentDropServer` instance. |
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
[swift-cmark](https://github.com/swiftlang/swift-cmark) GFM (Markdown → HTML),
```

with:

```markdown
[swift-cmark](https://github.com/swiftlang/swift-cmark) GFM (Markdown → HTML; pinned to a
commit on its `gfm` branch, which has no semver tags),
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
## 6. The app (draft — to be refined)
```

with:

```markdown
## 6. The app
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
- Setting: **Notify on new drops** (via `UserNotifications`), default on. Clicking a
  notification opens that drop.
```

with:

```markdown
- Setting: **Notify on new drops** (via `UserNotifications`), default on. Clicking a
  notification opens that drop. Only drops created while the app runs are announced
  (never ones from before launch or from a previous folder), never drops the human
  registered in the app itself, and more than three at once become one summary.
- The app's own settings (Hide Dock icon, Notify) live in its UserDefaults. Settings the
  CLI also reads (folder, retention, port) stay in `config.json`.
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
- **Copy path** and **Copy `drop cat <id>`** (handy for pasting into an agent).
```

with:

```markdown
- **Copy path** and **Copy `drop cat <id>`** (handy for pasting into an agent; `drop path
  <id>` for a folder drop, which `drop cat` can't print).
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
- **Edit metadata**, **Archive**.
```

with:

```markdown
- **Edit metadata**, **Archive**. Like `drop edit`, the edit form can't clear a
  description or project yet; emptying one is refused with a message.
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
  Links open in the default browser. JavaScript in the rendered content is disabled.
```

with:

```markdown
  Links open in the default browser. JavaScript in the rendered content is disabled.
  Raw HTML in the Markdown is not rendered (cmark's safe mode), and the page's
  Content-Security-Policy allows no scripts; images may come from the drop folder,
  `data:` and `https:`. Relative references are served from the drop folder only (never
  above it, never `.agentdrop/` or other dot-entries, never through a symlink). A link to
  a file in the drop folder reveals it in Finder instead of opening it, so a click can't
  run a script an agent left there.
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
- Plain text / code files: monospace text view.
```

with:

```markdown
- Plain text / code files: monospace text view. HTML files are shown as text, never
  rendered. Files over 2 MB go to Quick Look.
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
- **App**: view models unit-tested against a temp store; UI verified manually against a
  checklist (menu bar count, notification, rendered view, VS Code open, unregistered
  register flow).
```

with:

```markdown
- **App**: view models unit-tested against a temp store; UI verified manually against
  `docs/manual-test-checklist.md` (menu bar count, notification, rendered view, VS Code
  open, unregistered register flow).
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
├── Package.swift                 # AgentDropCore, AgentDropServer, drop CLI
├── Sources/
│   ├── AgentDropCore/
│   ├── AgentDropServer/
│   └── drop/
```

with:

```markdown
├── Package.swift                 # AgentDropCore, AgentDropServer, drop CLI, the app
├── Sources/
│   ├── AgentDropCore/
│   ├── AgentDropServer/
│   ├── DropCLI/ + drop/
│   ├── AgentDropApp/             # the app's models, rendering, settings (tested)
│   └── AgentDrop/                # the app's SwiftUI/AppKit views
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
│   ├── AgentDropServerTests/
│   └── dropCLITests/        # incl. `drop watch` end-to-end against an in-process server
```

with:

```markdown
│   ├── AgentDropServerTests/
│   ├── dropCLITests/        # incl. `drop watch` end-to-end against an in-process server
│   └── AgentDropAppTests/   # app models against temp stores and a temp config dir
```

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, replace:

```markdown
├── App/                          # Xcode project for AgentDrop.app (depends on the package)
```

with:

```markdown
├── App/Info.plist                # AgentDrop.app's Info.plist (bundle id, agentdrop:// scheme)
├── Scripts/build-app.sh          # swift build + wrap the AgentDrop executable into AgentDrop.app
```

- [ ] **Step 3: Retire the "until Plan 3" wording**

In `Sources/agentdrop-devhost/main.swift`, replace:

```swift
// A stand-in for AgentDrop.app until Plan 3 builds it: hosts the same AgentDropService
// (content watcher + local server + server.json) in the foreground, so `drop watch` and
// other clients can be tried today. Not shipped; run it with `swift run agentdrop-devhost`.
```

with:

```swift
// A development stand-in for AgentDrop.app without a window: hosts the same
// AgentDropService (content watcher + local server + server.json) in the foreground, so
// `drop watch` and other clients can be tried from a terminal. Not shipped; run it with
// `swift run agentdrop-devhost`. Don't run it while the app is running: both would serve.
```

In `Sources/agentdrop-devhost/main.swift`, replace:

```swift
    Serves the drop folder from config.json the way the app will, until Ctrl-C.

    --temporary-setup  The app's first-run setup hasn't happened yet (it can't: the app is
                       Plan 3). This marks setup complete, and confirms a protected drop
                       folder, only while the dev host runs. Both values are put back on exit.
```

with:

```swift
    Serves the drop folder from config.json the way the app does, until Ctrl-C.

    --temporary-setup  For a machine where the app's first-run setup hasn't happened. This
                       marks setup complete, and confirms a protected drop folder, only
                       while the dev host runs. Both values are put back on exit.
```

In `Sources/agentdrop-devhost/main.swift`, replace:

```swift
(pass --temporary-setup to run before the app exists)
```

with:

```swift
(pass --temporary-setup to run without the app's setup)
```

In `Sources/AgentDropServer/TemporarySetup.swift`, replace:

```swift
/// For `agentdrop-devhost` only, until the app exists (Plan 3): marks setup complete and
```

with:

```swift
/// For `agentdrop-devhost` only, on a machine without the app's setup: marks setup complete and
```

In `Sources/AgentDropCore/DropStore+Edit.swift`, replace:

```swift
    /// Spec §5.1 `read`: first view in the app only. Used by Plan 3.
```

with:

```swift
    /// Spec §5.1 `read`: first view in the app only.
```

In `Sources/AgentDropCore/DropStore+Edit.swift`, replace:

```swift
    /// Spec §3.2 "Remove record": only for drops whose file is gone. Used by Plan 3.
```

with:

```swift
    /// Spec §3.2 "Remove record": only for drops whose file is gone.
```

In `Sources/DropCLI/CLIContext.swift`, replace:

```swift
    /// AgentDrop.app's bundle identifier (Plan 3 builds the app with it).
```

with:

```swift
    /// AgentDrop.app's bundle identifier (App/Info.plist).
```

- [ ] **Step 4: Add the manual checklist**

`docs/manual-test-checklist.md` (create, complete file):

```markdown
# AgentDrop.app manual test checklist

Spec §8: the app's models are unit-tested; its UI is checked by hand against this list.
Run it on a Mac where you don't mind the app's real setup, or on a fresh user account.
Build first: `Scripts/build-app.sh && cp -R .build/AgentDrop.app /Applications/`.

Reset to a first run: quit the app, then
`rm ~/Library/Application\ Support/AgentDrop/config.json` (this keeps your drops; it
only forgets setup and settings).

## First run (spec §2)
- [ ] `open /Applications/AgentDrop.app`: the setup window appears, shows `~/AgentDrop`,
      and "Start Agent Drop at login?" has **Yes** selected.
- [ ] Before finishing: `~/AgentDrop` was not created by the app, and
      `drop watch --inbox` exits 1 with "hasn't been set up yet".
- [ ] **Change…** to `~/Desktop/AgentDrop`: the protected-folder explanation appears.
      **Finish Setup**: macOS asks for Desktop access *after* the explanation.
- [ ] After setup: System Settings → General → Login Items lists Agent Drop.
- [ ] `drop open <id>` before setup (`drop add` works without the app): finishing setup
      then shows that drop.

## Menu bar (spec §6)
- [ ] The icon shows the unread count; `drop add x.md --from me` raises it within a second.
- [ ] The dropdown lists the 10 most recent drops (unread dot, title, project, from, time),
      then the Inbox, then Open Agent Drop / Settings… / Quit.
- [ ] Clicking a drop opens the window on it and clears its unread dot.
- [ ] Quit, then `ls ~/Library/Application\ Support/AgentDrop/`: no `server.json`.

## Window
- [ ] Closing the window leaves the menu bar icon; the Dock icon reopens the window.
- [ ] Sidebar: All Drops, Inbox (count), Handoffs (grouped open/claimed/done),
      Unregistered (count), Archived, Projects/Tags/From. A `--from a/b/c` value shows as a tree.
- [ ] Search filters by title, description and filename.
- [ ] A Markdown drop renders with tables, task lists and code blocks; dark mode follows
      the system; a relative image next to it shows; an `https://` link opens the browser;
      a `<script>` in the file does nothing.
- [ ] A `.swift` or `.txt` drop shows monospace text; an image or PDF shows Quick Look.
- [ ] A folder drop shows its tree above the rendered README; a symlink inside it shows
      as `name → target` and is never previewed.
- [ ] Open in VS Code opens the file (a folder drop opens as a workspace). With `code`
      not installed, the button is disabled with a tooltip.
- [ ] Reveal in Finder, Copy Path, Copy `drop cat <id>` (`drop path` for folders) work.
- [ ] Handoff buttons: Release on a claimed drop, Mark Done… with a note, Reopen.
      `drop show <id> --json` agrees after each.
- [ ] Edit Metadata: the Kind picker is disabled while claimed or done.
- [ ] Archive / Unarchive moves the drop between All Drops and Archived.
- [ ] Delete a drop's file in Finder: it greys out; **Remove Record…** removes it.
- [ ] Put a file in `~/AgentDrop` by hand: it appears under Unregistered; **Register…**
      requires From and registers it in place.

## Folder changes (spec §3)
- [ ] `drop config set-folder ~/Other`: the window switches to the new folder at once.
- [ ] `drop config set-folder ~/Documents/Drops`: the menu shows "Drop folder changed —
      confirm"; `drop watch --inbox` exits 1 ("Confirm the new drop folder…"); confirming
      in the window starts serving it.

## Watching (spec §4 Watching, §5)
- [ ] Quit the app. `drop watch --inbox`: the app starts with no window, menu bar icon only.
- [ ] `drop open <id>` with the app quit: it launches and shows that drop.
- [ ] Settings → General shows the server's port. Quit the app, occupy 47390–47399
      (`for p in $(seq 47390 47399); do nc -l 127.0.0.1 $p & done`), launch it: the window
      shows the no-port banner. `kill %1` (frees 47390), **Retry** recovers.

## Settings
- [ ] Hide Dock icon hides it immediately; the menu bar still opens the window.
- [ ] Notify on new drops: `drop add` from a terminal shows a notification; clicking it
      opens the drop. Off: no notification.
- [ ] Event history: presets and Custom… write `eventRetentionDays` (`drop config show`).
      `drop config set-retention 14` shows as Custom 14. The note about deletion is shown.
```

- [ ] **Step 5: Verify**

Run: `swift test && Scripts/build-app.sh release && grep -rn 'Plan 3' Sources Tests README.md`
Expected: all tests pass, the app builds, and grep finds nothing.

- [ ] **Step 6: Commit**

```bash
git add README.md docs Sources
git commit -m "docs: README for the app, manual checklist, spec records Plan 3 decisions"
```

- [ ] **Step 7: Hand off for the manual check**

The human (not an agent) runs `docs/manual-test-checklist.md` on a Mac where the app's real first-run setup may happen. Report any failing line as a bug against the task that owns it.

