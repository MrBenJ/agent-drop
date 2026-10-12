# Agent Drop — Plan 1: Core + `drop` CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `AgentDropCore` and a working `drop` CLI so agents can drop, find, read, and hand off files today, with no app running.

**Architecture:** A Swift package. `AgentDropCore` owns all domain logic: config, the SQLite store (GRDB), the event log, validation, folder operations, and handoff transitions. `DropCLI` is a thin swift-argument-parser layer over Core, kept in a library target so tests can run commands in-process with injected paths. The `drop` executable is a one-line `main.swift`. Every mutation writes exactly one event row in the same transaction. That keeps Plan 2 (server + `drop watch`) and Plan 3 (the app) additive.

**Tech Stack:** Swift 6 (tools 6.0, language mode 6), macOS 14+, GRDB.swift 7, swift-argument-parser 1.5, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-11-agent-drop-design.md`

**This plan covers:** spec §3 (storage, ids, lazy missing check), §4 (every CLI command **except** `drop watch` and `drop open`), §4.1, §4.2, §5.1 (event log + retention; `content` events are Plan 2), §7 (CLI rows), §8 (Core, CLI, event-log tests, real-binary smoke tests).
**Later plans:** Plan 2 = `AgentDropServer` + `drop watch` + `content` events. Plan 3 = `AgentDrop.app` + `drop open` + folder reconciliation of unregistered entries.
**Deviation from spec §9 layout (intentional):** an extra library target `Sources/DropCLI/` holds the commands, so `dropCLITests` can run them in-process (spec §8 "commands run in-process"). `Sources/drop/` contains only `main.swift`.

## Global Constraints

- Minimum macOS **14**; `// swift-tools-version: 6.0`.
- Dependencies for this plan: **GRDB.swift ≥ 7.0.0** and **swift-argument-parser ≥ 1.5.0**. No others.
- Config file: `~/Library/Application Support/AgentDrop/config.json`. Default drop folder: `~/AgentDrop`. **No environment-variable override of any path.** Tests inject paths through `ConfigStore(configDir:homeDir:)`.
- Store: `<drop folder>/.agentdrop/index.sqlite`, WAL mode, busy timeout **5 s**, schema version in `PRAGMA user_version`.
- The CLI **never guesses** `--from`, `--by`, or `--project`, and **never prompts**.
- Identity fields (`--from`, `--by`, `--project`) and tags: trimmed of leading/trailing spaces and tabs, non-empty, no newlines or control characters, **≤ 200 characters**, otherwise stored exactly as given and matched exactly. `/` is the only interpreted character (`--from-under`).
- Ids: **6 characters** from `abcdefghijkmnpqrstuvwxyz23456789` (32 symbols). Matched in full only (no prefix matching). An exact filename is accepted anywhere an id is.
- Exit codes: `0` ok · `1` error/bad input · `2` not found · `3` conflict.
- Errors: human mode → stderr as `drop: <message>`. With `--json` → stdout as `{"code":<exit>,"error":"<message>"}`, nothing on stderr.
- `--json` is accepted on every command. `drop cat` and `drop latest --cat` reject it with exit 1.
- Every mutation appends **exactly one** `event` row in the **same transaction**. Retention cleanup (`DELETE FROM event WHERE at < now − N days`) runs in every event-writing transaction unless retention is `"forever"`. Cleanup deletes only event rows.
- Agent Drop never deletes a user's files. The only exception: removing its own partial copy when `drop add` fails after copying.

## Review Focus

Five inputs or failure modes the spec implies but doesn't spell out, most likely to bite first. Each one has its test in the task that owns the code:

1. **Names with spaces, accents, and emoji** (`Q3 plan — draft ✅.md`) must round-trip through `add`, `cat <filename>`, and `path`. Test: Task 10, `unicodeAndSpacesRoundTrip`.
2. **Binary files** (e.g. a PNG) must come out of `drop cat` byte-for-byte unchanged, not re-encoded as text. Test: Task 10, `catWritesBinaryBytesUnchanged`.
3. **Two agents adding the same filename at the same moment** must both succeed with distinct names (`plan.md`, `plan-2.md`) and no lost file. Test: Task 5, `concurrentAddsOfSameNameBothSucceed`.
4. **`config set-folder` with a relative path, `~`, or spaces** must save an absolute path that `drop where` prints back. Test: Task 9, `setFolderResolvesRelativeTildeAndSpaces`.
5. **A file deleted behind Agent Drop's back:** `cat` exits 2, `show` reports `"missing": true`, and the drop leaves the Inbox. Test: Task 6, `deletedFileBecomesMissingAndLeavesInbox`.

---

## File Structure

```
Package.swift
.github/workflows/ci.yml
Scripts/smoke.sh
Sources/AgentDropCore/
  AgentDropError.swift      error type → exit code
  DropID.swift              id + storeId generation
  Validation.swift          identity/tag/name/text rules, --from-under, name suffixing
  Config.swift              Retention, AgentDropConfig, ConfigStore (config.json)
  Drop.swift                DropKind, HandoffStatus, Drop, DropJSON
  Store.swift               DropStore.open, schema/migrations, mutate/read helpers, row mapping
  EventLog.swift            EventType, StoredEvent, append + retention cleanup
  TitleExtractor.swift      default titles from Markdown headings
  DropStore+Add.swift       AddRequest, add (file/folder/stdin/in-place/move/collisions)
  DropStore+Query.swift     resolve (id/filename + lazy missing), ListFilter, list, inbox
  DropStore+Edit.swift      EditRequest, edit (incl. kind changes), archive, markRead, removeRecord
  DropStore+Transitions.swift claim, release, done, reopen
Sources/DropCLI/
  CLIContext.swift          injected context (config paths, cwd, clock, stdin, sinks, process)
  DropCLI.swift             runner (parse → run → exit code), root command, JSONOption
  Output.swift              human + JSON rendering
  Commands/ConfigCommands.swift   where, config set-folder|set-retention|show
  Commands/AddCommand.swift       add
  Commands/ReadCommands.swift     show, cat, path, list, latest, inbox
  Commands/EditCommands.swift     edit, archive
  Commands/HandoffCommands.swift  claim, release, done, reopen
  Commands/HumanCommands.swift    code, agent-instructions
Sources/drop/main.swift
Tests/AgentDropCoreTests/   Support.swift + one file per Core area
Tests/dropCLITests/         TestEnv.swift + one file per command group
```

---

### Task 1: Package scaffold, error type, ids, CI

**Files:**
- Create: `Package.swift`, `.gitignore`, `.github/workflows/ci.yml`
- Create: `Sources/AgentDropCore/AgentDropError.swift`, `Sources/AgentDropCore/DropID.swift`
- Test: `Tests/AgentDropCoreTests/DropIDTests.swift`

**Interfaces:**
- Produces: `AgentDropError` (`.invalid`/`.notFound`/`.conflict`, `exitCode: Int32`, `message: String`), `DropID.alphabet`, `DropID.generate() -> String`, `DropID.isWellFormed(_:) -> Bool`, `DropID.storeID() -> String`

- [ ] **Step 1: Create the package manifest and gitignore**

`Package.swift`:
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDrop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentDropCore", targets: ["AgentDropCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AgentDropCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "AgentDropCoreTests",
            dependencies: ["AgentDropCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
```

`.gitignore`:
```
.build/
.swiftpm/
*.xcodeproj/xcuserdata/
DerivedData/
.DS_Store
```

- [ ] **Step 2: Write the failing id tests**

`Tests/AgentDropCoreTests/DropIDTests.swift`:
```swift
import Testing
@testable import AgentDropCore

struct DropIDTests {
    @Test func alphabetHas32UnambiguousSymbols() {
        #expect(DropID.alphabet.count == 32)
        for banned: Character in ["o", "l", "0", "1"] {
            #expect(!DropID.alphabet.contains(banned))
        }
    }

    @Test func generatedIdsAreWellFormed() {
        for _ in 0..<1_000 {
            let id = DropID.generate()
            #expect(id.count == 6)
            #expect(DropID.isWellFormed(id))
        }
    }

    @Test func wellFormedRejectsWrongLengthAndCharacters() {
        #expect(!DropID.isWellFormed("k7f2q"))
        #expect(!DropID.isWellFormed("k7f2qaa"))
        #expect(!DropID.isWellFormed("k7f2qo"))
        #expect(!DropID.isWellFormed("plan.md"))
        #expect(DropID.isWellFormed("k7f2qa"))
    }

    @Test func storeIDIsTwelveCharacters() {
        let a = DropID.storeID(), b = DropID.storeID()
        #expect(a.count == 12)
        #expect(a != b)
    }

    @Test func errorExitCodes() {
        #expect(AgentDropError.invalid("x").exitCode == 1)
        #expect(AgentDropError.notFound("x").exitCode == 2)
        #expect(AgentDropError.conflict("x").exitCode == 3)
        #expect(AgentDropError.conflict("msg").message == "msg")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter DropIDTests`
Expected: compile failure: `cannot find 'DropID' in scope`.

- [ ] **Step 4: Implement**

`Sources/AgentDropCore/AgentDropError.swift`:
```swift
/// Every user-facing failure. The case decides the CLI exit code (spec §4 Global rules).
public enum AgentDropError: Error, Equatable, Sendable {
    case invalid(String)   // exit 1: bad input, wrong kind, unusable store
    case notFound(String)  // exit 2
    case conflict(String)  // exit 3: e.g. handoff already claimed

    public var exitCode: Int32 {
        switch self {
        case .invalid: 1
        case .notFound: 2
        case .conflict: 3
        }
    }

    public var message: String {
        switch self {
        case .invalid(let m), .notFound(let m), .conflict(let m): m
        }
    }
}
```

`Sources/AgentDropCore/DropID.swift`:
```swift
/// Short ids (spec §3.1): 6 chars from a 32-symbol alphabet with no 0/o or 1/l.
public enum DropID {
    public static let alphabet: [Character] = Array("abcdefghijkmnpqrstuvwxyz23456789")
    public static let length = 6

    public static func generate() -> String {
        random(length: length)
    }

    /// Random id for a store (spec §5.3 `storeId`).
    public static func storeID() -> String {
        random(length: 12)
    }

    public static func isWellFormed(_ value: String) -> Bool {
        value.count == length && value.allSatisfy { alphabet.contains($0) }
    }

    private static func random(length: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter DropIDTests`
Expected: all 5 tests pass.

- [ ] **Step 6: Add CI**

`.github/workflows/ci.yml`:
```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - run: swift --version
      - run: swift test
```

- [ ] **Step 7: Commit**

```bash
git add Package.swift .gitignore .github Sources Tests
git commit -m "feat(core): package scaffold, error type, short ids, CI"
```

---

### Task 2: Validation rules

**Files:**
- Create: `Sources/AgentDropCore/Validation.swift`
- Test: `Tests/AgentDropCoreTests/ValidationTests.swift`, `Tests/AgentDropCoreTests/Support.swift`

**Interfaces:**
- Consumes: `AgentDropError`
- Produces: `Validation.identity(_:field:) throws -> String`, `Validation.tag(_:) throws -> String`, `Validation.text(_:field:) throws -> String`, `Validation.dropName(_:) throws -> String`, `Validation.isUnder(_:prefix:) -> Bool`, `Validation.suffixed(_:n:isFolder:) -> String`, `Validation.unique(_:) -> [String]`; test helper `expectError(_:_:)`

- [ ] **Step 1: Write the shared test helper**

`Tests/AgentDropCoreTests/Support.swift`:
```swift
import Foundation
import Testing
@testable import AgentDropCore

/// Asserts `body` throws an AgentDropError with the given exit code; returns its message.
@discardableResult
func expectError(_ exitCode: Int32, _ body: () throws -> Void,
                 sourceLocation: SourceLocation = #_sourceLocation) -> String? {
    do {
        try body()
        Issue.record("expected AgentDropError(\(exitCode)), nothing was thrown", sourceLocation: sourceLocation)
    } catch let error as AgentDropError {
        #expect(error.exitCode == exitCode, "message: \(error.message)", sourceLocation: sourceLocation)
        return error.message
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
    return nil
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/AgentDropCoreTests/ValidationTests.swift`:
```swift
import Testing
@testable import AgentDropCore

struct ValidationTests {
    @Test func identityKeepsSlashesSpacesBrackets() throws {
        let v = try Validation.identity("  djleague/autodev/AutoDev DJ-1234 [ef013ae]\t", field: "--from")
        #expect(v == "djleague/autodev/AutoDev DJ-1234 [ef013ae]")
    }

    @Test func identityRejectsEmptyNewlinesControlAndLong() {
        expectError(1) { _ = try Validation.identity("   ", field: "--from") }
        expectError(1) { _ = try Validation.identity("a\nb", field: "--from") }
        expectError(1) { _ = try Validation.identity("a\u{0007}b", field: "--from") }
        expectError(1) { _ = try Validation.identity(String(repeating: "x", count: 201), field: "--from") }
        #expect((try? Validation.identity(String(repeating: "x", count: 200), field: "--from")) != nil)
    }

    @Test func tagsKeepCase() throws {
        #expect(try Validation.tag(" PR ") == "PR")
        #expect(try Validation.tag("pr") == "pr")
    }

    @Test func dropNameRule() throws {
        #expect(try Validation.dropName("plan.md") == "plan.md")
        #expect(try Validation.dropName("Q3 plan — draft ✅.md") == "Q3 plan — draft ✅.md")
        for bad in ["", ".", "..", ".notes.md", "a/b.md"] {
            expectError(1) { _ = try Validation.dropName(bad) }
        }
    }

    @Test func fromUnderMatchesWholeLevelsOnly() {
        #expect(Validation.isUnder("djleague", prefix: "djleague"))
        #expect(Validation.isUnder("djleague/autodev/tab", prefix: "djleague"))
        #expect(!Validation.isUnder("djleague2", prefix: "djleague"))
        #expect(!Validation.isUnder("dj", prefix: "djleague"))
    }

    @Test func suffixing() {
        #expect(Validation.suffixed("plan.md", n: 2, isFolder: false) == "plan-2.md")
        #expect(Validation.suffixed("archive.tar.gz", n: 3, isFolder: false) == "archive.tar-3.gz")
        #expect(Validation.suffixed("README", n: 2, isFolder: false) == "README-2")
        #expect(Validation.suffixed("bundle.v2", n: 2, isFolder: true) == "bundle.v2-2")
    }

    @Test func textTrimsAndRejectsEmpty() throws {
        #expect(try Validation.text("  Why\nthis exists \n", field: "--desc") == "Why\nthis exists")
        expectError(1) { _ = try Validation.text(" \n ", field: "--title") }
    }

    @Test func uniqueKeepsFirstOccurrenceOrder() {
        #expect(Validation.unique(["b", "a", "b", "c", "a"]) == ["b", "a", "c"])
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter ValidationTests`
Expected: compile failure: `cannot find 'Validation' in scope`.

- [ ] **Step 4: Implement**

`Sources/AgentDropCore/Validation.swift`:
```swift
import Foundation

/// Input rules shared by the CLI and the app (spec §4, §4.1).
public enum Validation {
    public static let maxIdentityLength = 200

    /// §4.1: trimmed (spaces/tabs), non-empty, no newlines or control characters, ≤ 200 chars.
    /// Nothing else is interpreted.
    public static func identity(_ raw: String, field: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            throw AgentDropError.invalid("\(field) must not be empty")
        }
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard !value.unicodeScalars.contains(where: { forbidden.contains($0) }) else {
            throw AgentDropError.invalid("\(field) must not contain newlines or control characters")
        }
        guard value.count <= maxIdentityLength else {
            throw AgentDropError.invalid("\(field) must be at most \(maxIdentityLength) characters")
        }
        return value
    }

    /// Tags follow the identity rules and keep their case (spec §3 data model).
    public static func tag(_ raw: String) throws -> String {
        try identity(raw, field: "tag")
    }

    /// Free text (title, description, status note): trimmed, non-empty, newlines allowed.
    public static func text(_ raw: String, field: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw AgentDropError.invalid("\(field) must not be empty")
        }
        return value
    }

    /// Name rule (spec §4 `drop add`): the resulting top-level name must not be empty,
    /// start with ".", contain "/", or be "." / "..".
    public static func dropName(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), !name.contains("/") else {
            throw AgentDropError.invalid(
                "'\(name)' can't be a drop name (it must not be empty, start with '.', or contain '/'); pass --name <visible-name>"
            )
        }
        return name
    }

    /// `--from-under` (spec §4.1): the prefix itself and whole levels beneath it.
    public static func isUnder(_ value: String, prefix: String) -> Bool {
        value == prefix || value.hasPrefix(prefix + "/")
    }

    /// Collision suffix: `plan.md` → `plan-2.md`; folders and extensionless names get `-n` appended.
    public static func suffixed(_ name: String, n: Int, isFolder: Bool) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        if isFolder || ext.isEmpty { return "\(name)-\(n)" }
        return "\(ns.deletingPathExtension)-\(n).\(ext)"
    }

    /// Removes duplicates, keeping the first occurrence's order.
    public static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ValidationTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentDropCore/Validation.swift Tests/AgentDropCoreTests
git commit -m "feat(core): identity, tag, name and text validation"
```

---

### Task 3: Config (`config.json`)

**Files:**
- Create: `Sources/AgentDropCore/Config.swift`
- Test: `Tests/AgentDropCoreTests/ConfigTests.swift`

**Interfaces:**
- Consumes: `AgentDropError`
- Produces:
  - `enum Retention: Equatable, Sendable { case days(Int), forever }`, `Retention.default` (= `.days(30)`), `Retention(argument:)`, `Retention.displayValue: String`
  - `struct AgentDropConfig` with fields `folder: String?`, `eventRetentionDays: Retention`, `retentionWasInvalid: Bool`, `serverPort: Int?`, `setupComplete: Bool`, `confirmedFolder: String?`, plus `static let defaultServerPort = 47390`
  - `struct ConfigStore: Sendable` with `init(configDir:homeDir:)`, `static func live()`, `configFile`, `defaultFolder`, `load() throws -> AgentDropConfig`, `folderURL(_:) -> URL`, `setFolder(_ url: URL) throws`, `setRetention(_:) throws`

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropCoreTests/ConfigTests.swift`:
```swift
import Foundation
import Testing
@testable import AgentDropCore

struct ConfigTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdrop-config-\(UUID().uuidString)", isDirectory: true)
    var store: ConfigStore {
        ConfigStore(configDir: root.appendingPathComponent("support", isDirectory: true),
                    homeDir: root.appendingPathComponent("home", isDirectory: true))
    }

    @Test func defaultsWhenFileAbsent() throws {
        let c = try store.load()
        #expect(c.folder == nil)
        #expect(c.eventRetentionDays == .days(30))
        #expect(!c.retentionWasInvalid)
        #expect(!c.setupComplete)
        #expect(store.folderURL(c).path == root.appendingPathComponent("home/AgentDrop").path)
    }

    @Test func setFolderAndRetentionRoundTrip() throws {
        let target = root.appendingPathComponent("Desk top/Agent Drop", isDirectory: true)
        try store.setFolder(target)
        try store.setRetention(.forever)
        let c = try store.load()
        #expect(store.folderURL(c).path == target.path)
        #expect(c.eventRetentionDays == .forever)
        try store.setRetention(.days(14))
        #expect(try store.load().eventRetentionDays == .days(14))
    }

    @Test func preservesUnknownKeysWrittenByTheApp() throws {
        try FileManager.default.createDirectory(at: store.configDir, withIntermediateDirectories: true)
        try Data(#"{"setupComplete": true, "futureKey": "keep me"}"#.utf8).write(to: store.configFile)
        try store.setRetention(.days(7))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.configFile)) as! [String: Any]
        #expect(raw["futureKey"] as? String == "keep me")
        #expect(raw["setupComplete"] as? Bool == true)
        #expect(try store.load().setupComplete)
    }

    @Test(arguments: [#"0"#, #"-3"#, #"14.5"#, #""weekly""#, #"null"#])
    func invalidRetentionFallsBackTo30(_ raw: String) throws {
        try FileManager.default.createDirectory(at: store.configDir, withIntermediateDirectories: true)
        try Data(#"{"eventRetentionDays": \#(raw)}"#.utf8).write(to: store.configFile)
        let c = try store.load()
        #expect(c.eventRetentionDays == .days(30))
        #expect(c.retentionWasInvalid)
    }

    @Test func corruptConfigIsAnError() throws {
        try FileManager.default.createDirectory(at: store.configDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.configFile)
        expectError(1) { _ = try store.load() }
    }

    @Test func retentionArgumentParsing() {
        #expect(Retention(argument: "forever") == .forever)
        #expect(Retention(argument: "1") == .days(1))
        #expect(Retention(argument: "0") == nil)
        #expect(Retention(argument: "-1") == nil)
        #expect(Retention(argument: "7.5") == nil)
        #expect(Retention(argument: "week") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigTests`
Expected: compile failure: `cannot find 'ConfigStore' in scope`.

- [ ] **Step 3: Implement**

`Sources/AgentDropCore/Config.swift`:
```swift
import Foundation

/// Event-log retention (spec §5.1): a whole number of days ≥ 1, or forever.
public enum Retention: Equatable, Sendable {
    case days(Int)
    case forever

    public static let `default` = Retention.days(30)

    /// Parses CLI input: "forever" or a whole number ≥ 1.
    public init?(argument: String) {
        if argument == "forever" {
            self = .forever
        } else if let days = Int(argument), days >= 1 {
            self = .days(days)
        } else {
            return nil
        }
    }

    public var displayValue: String {
        switch self {
        case .forever: "forever"
        case .days(let n): "\(n) days"
        }
    }
}

public struct AgentDropConfig: Equatable, Sendable {
    public static let defaultServerPort = 47390

    public var folder: String? = nil
    public var eventRetentionDays: Retention = .default
    /// True when config.json held an invalid retention value (treated as 30; spec §5.1).
    public var retentionWasInvalid = false
    public var serverPort: Int? = nil
    public var setupComplete = false
    public var confirmedFolder: String? = nil

    public init() {}
}

/// Reads and writes `config.json`, the single source of truth for the folder (spec §3).
/// Paths are injected; the shipped binaries use `live()`. Unknown keys are preserved.
public struct ConfigStore: Sendable {
    public let configDir: URL
    public let homeDir: URL

    public init(configDir: URL, homeDir: URL) {
        self.configDir = configDir
        self.homeDir = homeDir
    }

    public static func live() -> ConfigStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ConfigStore(
            configDir: home.appendingPathComponent("Library/Application Support/AgentDrop", isDirectory: true),
            homeDir: home
        )
    }

    public var configFile: URL { configDir.appendingPathComponent("config.json") }
    public var defaultFolder: URL { homeDir.appendingPathComponent("AgentDrop", isDirectory: true) }

    public func load() throws -> AgentDropConfig {
        let dict = try readDict()
        var config = AgentDropConfig()
        config.folder = dict["folder"] as? String
        switch dict["eventRetentionDays"] {
        case nil:
            config.eventRetentionDays = .default
        case let value as String where value == "forever":
            config.eventRetentionDays = .forever
        case let value as NSNumber where Self.isWholeNumber(value) && value.intValue >= 1:
            config.eventRetentionDays = .days(value.intValue)
        default:
            config.eventRetentionDays = .default
            config.retentionWasInvalid = true
        }
        config.serverPort = dict["serverPort"] as? Int
        config.setupComplete = dict["setupComplete"] as? Bool ?? false
        config.confirmedFolder = dict["confirmedFolder"] as? String
        return config
    }

    public func folderURL(_ config: AgentDropConfig) -> URL {
        config.folder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
    }

    public func setFolder(_ url: URL) throws {
        var dict = try readDict()
        dict["folder"] = url.standardizedFileURL.path
        try writeDict(dict)
    }

    public func setRetention(_ retention: Retention) throws {
        var dict = try readDict()
        switch retention {
        case .forever: dict["eventRetentionDays"] = "forever"
        case .days(let n): dict["eventRetentionDays"] = n
        }
        try writeDict(dict)
    }

    private static func isWholeNumber(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue == n.doubleValue.rounded()
    }

    private func readDict() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configFile.path) else { return [:] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(contentsOf: configFile))
        } catch {
            throw AgentDropError.invalid("Can't read \(configFile.path): \(error.localizedDescription)")
        }
        guard let dict = object as? [String: Any] else {
            throw AgentDropError.invalid("\(configFile.path) must contain a JSON object")
        }
        return dict
    }

    private func writeDict(_ dict: [String: Any]) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: configFile, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigTests`
Expected: all tests pass, including all 5 invalid-retention arguments.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentDropCore/Config.swift Tests/AgentDropCoreTests/ConfigTests.swift
git commit -m "feat(core): config.json store with retention parsing and unknown-key preservation"
```

---

### Task 4: Drop model, store, schema, event log

**Files:**
- Create: `Sources/AgentDropCore/Drop.swift`, `Sources/AgentDropCore/Store.swift`, `Sources/AgentDropCore/EventLog.swift`
- Modify: `Tests/AgentDropCoreTests/Support.swift` (append `TestClock`, `TempDir`)
- Test: `Tests/AgentDropCoreTests/StoreTests.swift`

**Interfaces:**
- Consumes: `AgentDropError`, `DropID`, `Retention`
- Produces:
  - `enum DropKind: String { note, handoff }`, `enum HandoffStatus: String { open, claimed, done }`
  - `struct Drop` (fields: `id, filename, isFolder, title, description, project, tags, from, createdAt, updatedAt, readAt, kind, status, claimedBy, statusNote, archived, missing`; computed `isInInbox`, `isUnread`)
  - `struct DropJSON: Encodable` (`init(drop:path:)`), spec §4 JSON shape with explicit `null`s
  - `final class DropStore: Sendable`: `static func open(folder:retention:now:) throws -> DropStore`, `folder`, `storeID`, `path(of:) -> URL`, `json(_:) -> DropJSON`, `events(afterSeq:) throws -> [StoredEvent]`
  - internal: `mutate(_:)`, `read(_:)`, `static fetchDrop(_:id:)`, `static fetchDrops(_:sql:arguments:)`, `Date.unixTime`
  - `enum EventType: String` (`created, content, metadata, status, archived, missing, read, removed`), `struct StoredEvent`, internal `EventLog.append(...)`, `EventLog.encode(_:)`, `EventLog.encodeObject(_:)`

- [ ] **Step 1: Extend the test support**

Append to `Tests/AgentDropCoreTests/Support.swift`:
```swift
final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_760_000_000)) { now = start }
    func advance(days: Double) { now = now.addingTimeInterval(days * 86_400) }
    func advance(seconds: Double) { now = now.addingTimeInterval(seconds) }
}

final class TempDir: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdrop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ relative: String, _ contents: String) throws -> URL {
        try data(relative, Data(contents.utf8))
    }

    @discardableResult
    func data(_ relative: String, _ data: Data) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/AgentDropCoreTests/StoreTests.swift`:
```swift
import Foundation
import GRDB
import Testing
@testable import AgentDropCore

struct StoreTests {
    @Test func openCreatesStoreInsideTheFolder() throws {
        let tmp = try TempDir()
        let folder = tmp.url.appendingPathComponent("AgentDrop", isDirectory: true)
        let store = try DropStore.open(folder: folder, retention: .default)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".agentdrop/index.sqlite").path))
        #expect(store.storeID.count == 12)
        let (version, mode) = try store.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA user_version"), try String.fetchOne(db, sql: "PRAGMA journal_mode"))
        }
        #expect(version == Schema.migrations.count)
        #expect(mode == "wal")
    }

    @Test func storeIDIsStableAcrossReopenAndDistinctPerFolder() throws {
        let tmp = try TempDir()
        let a = tmp.url.appendingPathComponent("A", isDirectory: true)
        let b = tmp.url.appendingPathComponent("B", isDirectory: true)
        let first = try DropStore.open(folder: a, retention: .default).storeID
        #expect(try DropStore.open(folder: a, retention: .default).storeID == first)
        #expect(try DropStore.open(folder: b, retention: .default).storeID != first)
    }

    @Test func eventSeqIsStrictlyIncreasing() throws {
        let tmp = try TempDir()
        let clock = TestClock()
        let store = try DropStore.open(folder: tmp.url, retention: .default, now: { clock.now })
        for i in 0..<3 {
            try store.mutate { db in
                try EventLog.append(db, type: .metadata, dropID: "aaaaa\(i + 2)", dataJSON: "{}",
                                    before: nil, after: nil, at: clock.now, retention: .default)
            }
        }
        let seqs = try store.events().map(\.seq)
        #expect(seqs.count == 3)
        #expect(seqs == seqs.sorted() && Set(seqs).count == 3)
    }

    @Test func retentionDeletesOnlyExpiredEventRows() throws {
        let tmp = try TempDir()
        let clock = TestClock()
        let store = try DropStore.open(folder: tmp.url, retention: .days(30), now: { clock.now })
        func append(_ id: String) throws {
            try store.mutate { db in
                try EventLog.append(db, type: .metadata, dropID: id, dataJSON: "{}",
                                    before: nil, after: nil, at: clock.now, retention: .days(30))
            }
        }
        try append("aaaaa2")
        clock.advance(days: 31)
        try append("aaaaa3")
        #expect(try store.events().map(\.dropID) == ["aaaaa3"])
    }

    @Test func foreverRetentionKeepsEverything() throws {
        let tmp = try TempDir()
        let clock = TestClock()
        let store = try DropStore.open(folder: tmp.url, retention: .forever, now: { clock.now })
        for id in ["aaaaa2", "aaaaa3"] {
            try store.mutate { db in
                try EventLog.append(db, type: .metadata, dropID: id, dataJSON: "{}",
                                    before: nil, after: nil, at: clock.now, retention: .forever)
            }
            clock.advance(days: 400)
        }
        #expect(try store.events().count == 2)
    }

    @Test func dropJSONMatchesSpecShapeWithNulls() throws {
        let drop = Drop(id: "k7f2qa", filename: "auth-plan.md", isFolder: false, title: "Auth refactor plan",
                        description: nil, project: nil, tags: ["spec"], from: "djleague/x",
                        createdAt: Date(timeIntervalSince1970: 1_760_208_240),
                        updatedAt: Date(timeIntervalSince1970: 1_760_208_240), readAt: nil,
                        kind: .handoff, status: .open, claimedBy: nil, statusNote: nil,
                        archived: false, missing: false)
        let data = try JSONEncoder().encode(DropJSON(drop: drop, path: "/x/auth-plan.md"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(obj.keys) == ["id", "filename", "path", "title", "description", "project", "tags", "from",
                                  "kind", "status", "claimedBy", "statusNote", "createdAt", "updatedAt",
                                  "readAt", "archived", "isFolder", "missing"])
        #expect(obj["description"] is NSNull)
        #expect(obj["claimedBy"] is NSNull)
        #expect(obj["createdAt"] as? String == "2025-10-11T18:44:00Z")
        #expect(obj["status"] as? String == "open")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter StoreTests`
Expected: compile failure: `cannot find 'DropStore' in scope`.

- [ ] **Step 4: Implement the model**

`Sources/AgentDropCore/Drop.swift`:
```swift
import Foundation

public enum DropKind: String, Sendable, CaseIterable {
    case note, handoff
}

public enum HandoffStatus: String, Sendable, CaseIterable {
    case open, claimed, done
}

/// One registered drop (spec §3 data model).
public struct Drop: Equatable, Sendable {
    public var id: String
    public var filename: String
    public var isFolder: Bool
    public var title: String
    public var description: String?
    public var project: String?
    public var tags: [String]
    public var from: String
    public var createdAt: Date
    public var updatedAt: Date
    public var readAt: Date?
    public var kind: DropKind
    public var status: HandoffStatus?
    public var claimedBy: String?
    public var statusNote: String?
    public var archived: Bool
    public var missing: Bool

    /// Spec §4 Terms: open handoff, not archived, not missing.
    public var isInInbox: Bool { kind == .handoff && status == .open && !archived && !missing }
    /// Spec §4 Terms: never viewed in the app, not archived, not missing.
    public var isUnread: Bool { readAt == nil && !archived && !missing }
}

/// Spec §4 "JSON shape". Optional fields are always present (as `null`).
public struct DropJSON: Encodable, Sendable {
    public let drop: Drop
    public let path: String

    public init(drop: Drop, path: String) {
        self.drop = drop
        self.path = path
    }

    enum Key: String, CodingKey {
        case id, filename, path, title, description, project, tags, from, kind, status
        case claimedBy, statusNote, createdAt, updatedAt, readAt, archived, isFolder, missing
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(drop.id, forKey: .id)
        try c.encode(drop.filename, forKey: .filename)
        try c.encode(path, forKey: .path)
        try c.encode(drop.title, forKey: .title)
        try c.encode(drop.description, forKey: .description)
        try c.encode(drop.project, forKey: .project)
        try c.encode(drop.tags, forKey: .tags)
        try c.encode(drop.from, forKey: .from)
        try c.encode(drop.kind.rawValue, forKey: .kind)
        try c.encode(drop.status?.rawValue, forKey: .status)
        try c.encode(drop.claimedBy, forKey: .claimedBy)
        try c.encode(drop.statusNote, forKey: .statusNote)
        try c.encode(drop.createdAt.iso, forKey: .createdAt)
        try c.encode(drop.updatedAt.iso, forKey: .updatedAt)
        try c.encode(drop.readAt?.iso, forKey: .readAt)
        try c.encode(drop.archived, forKey: .archived)
        try c.encode(drop.isFolder, forKey: .isFolder)
        try c.encode(drop.missing, forKey: .missing)
    }
}

extension Date {
    /// `2026-10-11T18:44:00Z`
    public var iso: String { formatted(.iso8601) }
    var unixTime: Double { timeIntervalSince1970 }
}
```

- [ ] **Step 5: Implement the event log**

`Sources/AgentDropCore/EventLog.swift`:
```swift
import Foundation
import GRDB

/// Spec §5.1 event types. `content` is written by the server's watcher (Plan 2).
public enum EventType: String, Sendable, CaseIterable {
    case created, content, metadata, status, archived, missing, read, removed
}

public struct StoredEvent: Equatable, Sendable {
    public let seq: Int64
    public let type: EventType
    public let dropID: String
    public let at: Date
    public let data: String
    public let inboxBefore: Bool
    public let inboxAfter: Bool
    public let projectBefore: String?
    public let projectAfter: String?

    init(row: Row) {
        seq = row["seq"]
        type = EventType(rawValue: row["type"])!
        dropID = row["drop_id"]
        at = Date(timeIntervalSince1970: row["at"])
        data = row["data"]
        inboxBefore = row["inbox_before"]
        inboxAfter = row["inbox_after"]
        projectBefore = row["project_before"]
        projectAfter = row["project_after"]
    }
}

enum EventLog {
    /// Appends one event row and applies retention cleanup, inside the caller's transaction.
    static func append(_ db: Database, type: EventType, dropID: String, dataJSON: String,
                       before: Drop?, after: Drop?, at: Date, retention: Retention) throws {
        try db.execute(
            sql: """
                INSERT INTO event (type, drop_id, at, data, inbox_before, inbox_after, project_before, project_after)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [type.rawValue, dropID, at.unixTime, dataJSON,
                        before?.isInInbox ?? false, after?.isInInbox ?? false,
                        before?.project, after?.project])
        if case .days(let days) = retention {
            try db.execute(sql: "DELETE FROM event WHERE at < ?",
                           arguments: [at.addingTimeInterval(-Double(days) * 86_400).unixTime])
        }
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }

    /// Encodes a dictionary whose values are String, Bool, Int, [String], or NSNull.
    static func encodeObject(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

func orNull(_ value: String?) -> Any {
    if let value { return value }
    return NSNull()
}
```

- [ ] **Step 6: Implement the store**

`Sources/AgentDropCore/Store.swift`:
```swift
import Foundation
import GRDB

enum Schema {
    /// Index i upgrades user_version i → i+1. Never edit a shipped entry; append new ones.
    static let migrations: [String] = [
        """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE drops (
            id TEXT PRIMARY KEY,
            filename TEXT NOT NULL UNIQUE,
            is_folder INTEGER NOT NULL,
            title TEXT NOT NULL,
            description TEXT,
            project TEXT,
            from_identity TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            read_at REAL,
            kind TEXT NOT NULL CHECK (kind IN ('note', 'handoff')),
            status TEXT CHECK (status IN ('open', 'claimed', 'done')),
            claimed_by TEXT,
            status_note TEXT,
            archived INTEGER NOT NULL DEFAULT 0,
            missing INTEGER NOT NULL DEFAULT 0,
            CHECK ((kind = 'handoff') = (status IS NOT NULL))
        );
        CREATE TABLE drop_tag (
            drop_id TEXT NOT NULL REFERENCES drops(id) ON DELETE CASCADE,
            tag TEXT NOT NULL,
            PRIMARY KEY (drop_id, tag)
        );
        CREATE TABLE event (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            drop_id TEXT NOT NULL,
            at REAL NOT NULL,
            data TEXT NOT NULL,
            inbox_before INTEGER NOT NULL,
            inbox_after INTEGER NOT NULL,
            project_before TEXT,
            project_after TEXT
        );
        CREATE INDEX event_at ON event(at);
        """,
    ]

    static func migrate(_ db: Database) throws {
        let current = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard current < migrations.count else { return }
        for sql in migrations[current...] {
            try db.execute(sql: sql)
        }
        if current == 0 {
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('store_id', ?)",
                           arguments: [DropID.storeID()])
        }
        try db.execute(sql: "PRAGMA user_version = \(migrations.count)")
    }
}

/// The metadata store for one drop folder (spec §3 "Metadata store").
public final class DropStore: Sendable {
    public let folder: URL
    public let storeID: String
    let pool: DatabasePool
    let retention: Retention
    let now: @Sendable () -> Date

    private init(folder: URL, storeID: String, pool: DatabasePool, retention: Retention,
                 now: @escaping @Sendable () -> Date) {
        self.folder = folder
        self.storeID = storeID
        self.pool = pool
        self.retention = retention
        self.now = now
    }

    public static func open(folder: URL, retention: Retention,
                            now: @escaping @Sendable () -> Date = { Date() }) throws -> DropStore {
        let metaDir = folder.appendingPathComponent(".agentdrop", isDirectory: true)
        let path = metaDir.appendingPathComponent("index.sqlite").path
        do {
            try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.busyMode = .timeout(5)
            let pool = try DatabasePool(path: path, configuration: configuration)
            let storeID: String = try pool.writeWithoutTransaction { db in
                try db.inTransaction(.immediate) {
                    try Schema.migrate(db)
                    return .commit
                }
                return try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'store_id'")!
            }
            return DropStore(folder: folder, storeID: storeID, pool: pool, retention: retention, now: now)
        } catch let error as AgentDropError {
            throw error
        } catch {
            throw AgentDropError.invalid("Can't open the store at \(path): \(error)")
        }
    }

    /// Runs `body` in an IMMEDIATE transaction (write lock held from the start).
    func mutate<T>(_ body: (Database) throws -> T) throws -> T {
        do {
            return try pool.writeWithoutTransaction { db in
                var result: T?
                try db.inTransaction(.immediate) {
                    result = try body(db)
                    return .commit
                }
                return result!
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
            throw AgentDropError.invalid("store busy, retry")
        }
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        do {
            return try pool.read(body)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
            throw AgentDropError.invalid("store busy, retry")
        }
    }

    public func path(of drop: Drop) -> URL {
        folder.appendingPathComponent(drop.filename, isDirectory: drop.isFolder)
    }

    public func json(_ drop: Drop) -> DropJSON {
        DropJSON(drop: drop, path: path(of: drop).path)
    }

    public func events(afterSeq: Int64 = 0) throws -> [StoredEvent] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM event WHERE seq > ? ORDER BY seq", arguments: [afterSeq])
                .map(StoredEvent.init(row:))
        }
    }

    static func fetchDrop(_ db: Database, id: String) throws -> Drop? {
        try fetchDrops(db, sql: "SELECT * FROM drops WHERE id = ?", arguments: [id]).first
    }

    static func fetchDrops(_ db: Database, sql: String, arguments: StatementArguments) throws -> [Drop] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            let id: String = row["id"]
            let tags = try String.fetchAll(db, sql: "SELECT tag FROM drop_tag WHERE drop_id = ? ORDER BY rowid",
                                           arguments: [id])
            return Drop(row: row, tags: tags)
        }
    }
}

extension Drop {
    init(row: Row, tags: [String]) {
        self.init(
            id: row["id"],
            filename: row["filename"],
            isFolder: row["is_folder"],
            title: row["title"],
            description: row["description"],
            project: row["project"],
            tags: tags,
            from: row["from_identity"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            readAt: (row["read_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
            kind: DropKind(rawValue: row["kind"])!,
            status: (row["status"] as String?).flatMap(HandoffStatus.init(rawValue:)),
            claimedBy: row["claimed_by"],
            statusNote: row["status_note"],
            archived: row["archived"],
            missing: row["missing"]
        )
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter StoreTests`
Expected: all 6 tests pass. (`2025-10-11T18:44:00Z` corresponds to epoch 1_760_208_240.)

- [ ] **Step 8: Commit**

```bash
git add Sources/AgentDropCore Tests/AgentDropCoreTests
git commit -m "feat(core): drop model, SQLite store with migrations, event log with retention"
```

---

### Task 5: `add` (files, folders, stdin, in-place, move, collisions)

**Files:**
- Create: `Sources/AgentDropCore/TitleExtractor.swift`, `Sources/AgentDropCore/DropStore+Add.swift`
- Modify: `Tests/AgentDropCoreTests/Support.swift` (append `Fixture`)
- Test: `Tests/AgentDropCoreTests/AddTests.swift`

**Interfaces:**
- Consumes: `Validation`, `DropStore.mutate`, `EventLog`, `DropID`
- Produces: `enum AddSource { case path(URL), stdin(Data) }`, `struct AddRequest` (`init(source:name:title:description:project:tags:from:handoff:move:)`, defaults for all but `source`/`from`), `DropStore.add(_:) throws -> Drop`, internal `DropStore.isRegistered(filename:)`; test `Fixture`

- [ ] **Step 1: Add the test fixture**

Append to `Tests/AgentDropCoreTests/Support.swift`:
```swift
struct Fixture {
    let tmp: TempDir
    let clock: TestClock
    let store: DropStore
    var folder: URL { store.folder }

    init(retention: Retention = .default) throws {
        let tmp = try TempDir()
        let clock = TestClock()
        let folder = tmp.url.appendingPathComponent("AgentDrop", isDirectory: true)
        self.tmp = tmp
        self.clock = clock
        self.store = try DropStore.open(folder: folder, retention: retention, now: { clock.now })
    }

    /// A file outside the drop folder.
    func outside(_ name: String, _ contents: String = "# Plan\n") throws -> URL {
        try tmp.file("outside/\(name)", contents)
    }

    @discardableResult
    func add(_ name: String = "plan.md", _ contents: String = "# Plan\n", from: String = "tester",
             project: String? = nil, tags: [String] = [], handoff: Bool = false) throws -> Drop {
        let source = try tmp.file("outside-\(UUID().uuidString)/\(name)", contents)
        return try store.add(AddRequest(source: .path(source), project: project, tags: tags,
                                        from: from, handoff: handoff))
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/AgentDropCoreTests/AddTests.swift`:
```swift
import Foundation
import Testing
@testable import AgentDropCore

struct AddTests {
    let fm = FileManager.default

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
}
```

Append to `Tests/AgentDropCoreTests/Support.swift`:
```swift
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func withLock(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter AddTests`
Expected: compile failure: `cannot find 'AddRequest' in scope`.

- [ ] **Step 4: Implement title extraction**

`Sources/AgentDropCore/TitleExtractor.swift`:
```swift
import Foundation

/// Default titles (spec §3 data model `title`).
enum TitleExtractor {
    static func title(for url: URL, isFolder: Bool) -> String? {
        if isFolder {
            let fm = FileManager.default
            let readme = url.appendingPathComponent("README.md")
            if fm.fileExists(atPath: readme.path) { return firstHeading(in: readme) }
            let markdown = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".md") }
                .sorted()
            return markdown.first.flatMap { firstHeading(in: url.appendingPathComponent($0)) }
        }
        let ext = url.pathExtension.lowercased()
        guard ext == "md" || ext == "markdown" else { return nil }
        return firstHeading(in: url)
    }

    static func fallback(filename: String, isFolder: Bool) -> String {
        guard !isFolder else { return filename }
        let base = (filename as NSString).deletingPathExtension
        return base.isEmpty ? filename : base
    }

    private static func firstHeading(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty { return heading }
        }
        return nil
    }
}
```

- [ ] **Step 5: Implement `add`**

`Sources/AgentDropCore/DropStore+Add.swift`:
```swift
import Foundation
import GRDB

public enum AddSource: Sendable {
    case path(URL)
    case stdin(Data)
}

public struct AddRequest: Sendable {
    public var source: AddSource
    public var name: String?
    public var title: String?
    public var description: String?
    public var project: String?
    public var tags: [String]
    public var from: String
    public var handoff: Bool
    public var move: Bool

    public init(source: AddSource, name: String? = nil, title: String? = nil, description: String? = nil,
                project: String? = nil, tags: [String] = [], from: String, handoff: Bool = false,
                move: Bool = false) {
        self.source = source
        self.name = name
        self.title = title
        self.description = description
        self.project = project
        self.tags = tags
        self.from = from
        self.handoff = handoff
        self.move = move
    }
}

extension DropStore {
    private struct Placement {
        let filename: String
        let isFolder: Bool
        /// Our own copy, removed if registration fails afterwards.
        let cleanupOnFailure: URL?
    }

    /// Spec §4 `drop add`.
    public func add(_ request: AddRequest) throws -> Drop {
        let from = try Validation.identity(request.from, field: "--from")
        let project = try request.project.map { try Validation.identity($0, field: "--project") }
        let tags = Validation.unique(try request.tags.map(Validation.tag))
        let title = try request.title.map { try Validation.text($0, field: "--title") }
        let description = try request.description.map { try Validation.text($0, field: "--desc") }

        let placement = try place(request)
        do {
            let url = folder.appendingPathComponent(placement.filename)
            let finalTitle = title
                ?? TitleExtractor.title(for: url, isFolder: placement.isFolder)
                ?? TitleExtractor.fallback(filename: placement.filename, isFolder: placement.isFolder)
            return try insert(placement, title: finalTitle, description: description, project: project,
                              tags: tags, from: from, handoff: request.handoff)
        } catch {
            if let copy = placement.cleanupOnFailure { try? FileManager.default.removeItem(at: copy) }
            throw error
        }
    }

    func isRegistered(filename: String) throws -> Bool {
        try read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM drops WHERE filename = ?)",
                              arguments: [filename]) ?? false
        }
    }

    private func place(_ request: AddRequest) throws -> Placement {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        switch request.source {
        case .stdin(let data):
            guard let rawName = request.name else {
                throw AgentDropError.invalid("drop add - requires --name <filename>")
            }
            let name = try Validation.dropName(rawName)
            guard !data.isEmpty else { throw AgentDropError.invalid("stdin was empty; nothing to drop") }
            guard !request.move else { throw AgentDropError.invalid("--move can't be used with stdin") }
            let final = try claimName(name, isFolder: false) { try data.write(to: $0, options: .withoutOverwriting) }
            return Placement(filename: final, isFolder: false, cleanupOnFailure: folder.appendingPathComponent(final))

        case .path(let rawSource):
            let source = rawSource.standardizedFileURL
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fm.attributesOfItem(atPath: source.path) // does not follow symlinks
            } catch {
                throw AgentDropError.notFound("No such file or directory: \(source.path)")
            }
            let isFolder: Bool
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular?: isFolder = false
            case .typeDirectory?: isFolder = true
            case .typeSymbolicLink?:
                throw AgentDropError.invalid("\(source.path) is a symlink; symlinks can't be dropped")
            default:
                throw AgentDropError.invalid("\(source.path) is not a regular file or directory")
            }

            let root = folder.resolvingSymlinksInPath().path
            let resolvedSource = source.resolvingSymlinksInPath().path
            if resolvedSource == root || root.hasPrefix(resolvedSource + "/") {
                throw AgentDropError.invalid("Can't drop the drop folder itself or a folder that contains it")
            }
            let parent = source.deletingLastPathComponent().resolvingSymlinksInPath().path

            if parent == root {
                // Already a top-level entry: register in place (optionally renaming).
                let current = source.lastPathComponent
                if try isRegistered(filename: current) {
                    throw AgentDropError.conflict("\(current) is already registered")
                }
                guard let requested = request.name, requested != current else {
                    return Placement(filename: try Validation.dropName(current), isFolder: isFolder,
                                     cleanupOnFailure: nil)
                }
                let name = try Validation.dropName(requested)
                let destination = folder.appendingPathComponent(name)
                let taken = try isRegistered(filename: name)
                if taken || fm.fileExists(atPath: destination.path) {
                    throw AgentDropError.conflict("\(name) already exists in the drop folder")
                }
                try fm.moveItem(at: source, to: destination)
                return Placement(filename: name, isFolder: isFolder, cleanupOnFailure: nil)
            }

            if parent.hasPrefix(root + "/") {
                throw AgentDropError.invalid(
                    "\(source.path) is inside a subfolder of the drop folder; only top-level entries can be drops")
            }

            let name = try Validation.dropName(request.name ?? source.lastPathComponent)
            let final = try claimName(name, isFolder: isFolder) { destination in
                if request.move {
                    try fm.moveItem(at: source, to: destination)
                } else {
                    try fm.copyItem(at: source, to: destination)
                }
            }
            return Placement(filename: final, isFolder: isFolder,
                             cleanupOnFailure: request.move ? nil : folder.appendingPathComponent(final))
        }
    }

    /// Writes to the first free name (`plan.md`, `plan-2.md`, …). Losing a race to another
    /// writer surfaces as "file exists" and moves on to the next candidate.
    private func claimName(_ name: String, isFolder: Bool, write: (URL) throws -> Void) throws -> String {
        for n in 1...1_000 {
            let candidate = n == 1 ? name : Validation.suffixed(name, n: n, isFolder: isFolder)
            let destination = folder.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            if try isRegistered(filename: candidate) { continue }
            do {
                try write(destination)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw AgentDropError.conflict("Couldn't find a free name for \(name)")
    }

    private func insert(_ placement: Placement, title: String, description: String?, project: String?,
                        tags: [String], from: String, handoff: Bool) throws -> Drop {
        let now = self.now()
        do {
            return try mutate { db in
                var id = DropID.generate()
                while try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM drops WHERE id = ?)",
                                        arguments: [id]) == true {
                    id = DropID.generate()
                }
                let drop = Drop(id: id, filename: placement.filename, isFolder: placement.isFolder, title: title,
                                description: description, project: project, tags: tags, from: from,
                                createdAt: now, updatedAt: now, readAt: nil,
                                kind: handoff ? .handoff : .note, status: handoff ? .open : nil,
                                claimedBy: nil, statusNote: nil, archived: false, missing: false)
                try db.execute(
                    sql: """
                        INSERT INTO drops (id, filename, is_folder, title, description, project, from_identity,
                                           created_at, updated_at, kind, status)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [drop.id, drop.filename, drop.isFolder, drop.title, drop.description, drop.project,
                                drop.from, now.unixTime, now.unixTime, drop.kind.rawValue, drop.status?.rawValue])
                for tag in tags {
                    try db.execute(sql: "INSERT INTO drop_tag (drop_id, tag) VALUES (?, ?)", arguments: [id, tag])
                }
                try EventLog.append(db, type: .created, dropID: id, dataJSON: EventLog.encode(json(drop)),
                                    before: nil, after: drop, at: now, retention: retention)
                return drop
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw AgentDropError.conflict("\(placement.filename) is already registered")
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter AddTests`
Expected: all tests pass. If `concurrentAddsOfSameNameBothSucceed` is flaky, the race window is between `claimName`'s existence check and `write`. `.withoutOverwriting`/`copyItem` must be what fails, never a silent overwrite. Do not "fix" it with a lock that only covers this process.

- [ ] **Step 7: Commit**

```bash
git add Sources/AgentDropCore Tests/AgentDropCoreTests
git commit -m "feat(core): add drops from files, folders and stdin with collision-safe naming"
```

---

### Task 6: Resolve, list, inbox, lazy missing check

**Files:**
- Create: `Sources/AgentDropCore/DropStore+Query.swift`
- Test: `Tests/AgentDropCoreTests/QueryTests.swift`

**Interfaces:**
- Consumes: `DropStore.read/mutate/fetchDrop/fetchDrops`, `EventLog`, `Validation.isUnder`
- Produces: `DropStore.resolve(_ ref: String) throws -> Drop` (id first, then exact filename; marks missing + emits `missing` once), `struct ListFilter` (`project, tags, from, fromUnder, handoffsOnly, status, unreadOnly, includeArchived, limit (default 50), inboxOnly`; `init()`), `DropStore.list(_:) throws -> [Drop]` (newest first), `DropStore.inbox(project:) throws -> [Drop]`

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropCoreTests/QueryTests.swift`:
```swift
import Foundation
import GRDB
import Testing
@testable import AgentDropCore

struct QueryTests {
    @Test func resolveByIdThenExactFilename() throws {
        let f = try Fixture()
        let drop = try f.add("auth-plan.md")
        #expect(try f.store.resolve(drop.id).id == drop.id)
        #expect(try f.store.resolve("auth-plan.md").id == drop.id)
        expectError(2) { _ = try f.store.resolve(String(drop.id.prefix(3))) } // no prefix matching
        expectError(2) { _ = try f.store.resolve("AUTH-PLAN.md") }
    }

    @Test func deletedFileBecomesMissingAndLeavesInbox() throws {
        let f = try Fixture()
        let drop = try f.add("h.md", handoff: true)
        #expect(try f.store.inbox(project: nil).map(\.id) == [drop.id])
        try FileManager.default.removeItem(at: f.store.path(of: drop))
        let resolved = try f.store.resolve(drop.id)
        #expect(resolved.missing)
        #expect(try f.store.inbox(project: nil).isEmpty)
        _ = try f.store.resolve(drop.id) // second resolve: no second event
        let types = try f.store.events().map(\.type)
        #expect(types == [.created, .missing])
        let last = try f.store.events().last!
        #expect(last.inboxBefore && !last.inboxAfter)
    }

    @Test func listIsNewestFirstWithDefaultLimitAndArchivedExcluded() throws {
        let f = try Fixture()
        var ids: [String] = []
        for i in 0..<55 {
            ids.append(try f.add("n\(i).md").id)
            f.clock.advance(seconds: 1)
        }
        let listed = try f.store.list(ListFilter())
        #expect(listed.count == 50)
        #expect(listed.first?.id == ids.last)
        try f.store.mutate { db in try db.execute(sql: "UPDATE drops SET archived = 1 WHERE id = ?", arguments: [ids.last!]) }
        #expect(try f.store.list(ListFilter()).first?.id == ids[53])
        var all = ListFilter(); all.includeArchived = true; all.limit = nil
        #expect(try f.store.list(all).count == 55)
    }

    @Test func filtersCombine() throws {
        let f = try Fixture()
        let a = try f.add("a.md", from: "djleague/autodev/AutoDev DJ-1234 [ef013ae]", project: "dj", tags: ["PR"], handoff: true)
        let b = try f.add("b.md", from: "djleague2", project: "dj", tags: ["pr"])
        let c = try f.add("c.md", from: "djleague", project: "other")

        var under = ListFilter(); under.fromUnder = "djleague"
        #expect(Set(try f.store.list(under).map(\.id)) == [a.id, c.id])

        var exact = ListFilter(); exact.from = "djleague"
        #expect(try f.store.list(exact).map(\.id) == [c.id])

        var tag = ListFilter(); tag.tags = ["PR"]
        #expect(try f.store.list(tag).map(\.id) == [a.id], "tags match exactly, case included")

        var project = ListFilter(); project.project = "dj"; project.handoffsOnly = true
        #expect(try f.store.list(project).map(\.id) == [a.id])

        var status = ListFilter(); status.status = .open
        #expect(try f.store.list(status).map(\.id) == [a.id])
        _ = b
    }

    @Test func unreadExcludesArchivedAndMissingEvenWithAll() throws {
        let f = try Fixture()
        let keep = try f.add("keep.md")
        let archived = try f.add("arch.md")
        let gone = try f.add("gone.md")
        try f.store.mutate { db in try db.execute(sql: "UPDATE drops SET archived = 1 WHERE id = ?", arguments: [archived.id]) }
        try FileManager.default.removeItem(at: f.store.path(of: gone))
        _ = try f.store.resolve(gone.id)
        var filter = ListFilter(); filter.unreadOnly = true; filter.includeArchived = true
        #expect(try f.store.list(filter).map(\.id) == [keep.id])
    }

    @Test func inboxScopedByProjectAndExcludesArchived() throws {
        let f = try Fixture()
        let one = try f.add("1.md", project: "p", handoff: true)
        _ = try f.add("2.md", project: "q", handoff: true)
        _ = try f.add("3.md", project: "p")
        let archived = try f.add("4.md", project: "p", handoff: true)
        try f.store.mutate { db in try db.execute(sql: "UPDATE drops SET archived = 1 WHERE id = ?", arguments: [archived.id]) }
        #expect(try f.store.inbox(project: "p").map(\.id) == [one.id])
        #expect(try f.store.inbox(project: nil).count == 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter QueryTests`
Expected: compile failure: `value of type 'DropStore' has no member 'resolve'`.

- [ ] **Step 3: Implement**

`Sources/AgentDropCore/DropStore+Query.swift`:
```swift
import Foundation
import GRDB

public struct ListFilter: Equatable, Sendable {
    public var project: String?
    public var tags: [String] = []
    public var from: String?
    public var fromUnder: String?
    public var handoffsOnly = false
    public var status: HandoffStatus?
    public var unreadOnly = false
    public var includeArchived = false
    /// Spec §4 `drop list`: default 50. `nil` = no limit.
    public var limit: Int? = 50
    public var inboxOnly = false

    public init() {}
}

extension DropStore {
    /// Id first, then exact filename (spec §3.1). Marks the drop missing (with one `missing`
    /// event) if its file is gone (spec §3.2 "lazily when it resolves an id").
    public func resolve(_ ref: String) throws -> Drop {
        let found: Drop? = try read { db in
            if DropID.isWellFormed(ref), let drop = try Self.fetchDrop(db, id: ref) { return drop }
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM drops WHERE filename = ?",
                                               arguments: [ref]) else { return nil }
            return try Self.fetchDrop(db, id: id)
        }
        guard let drop = found else { throw AgentDropError.notFound("No drop matches '\(ref)'") }
        return try refreshMissing(drop)
    }

    private func refreshMissing(_ drop: Drop) throws -> Drop {
        guard !drop.missing, !FileManager.default.fileExists(atPath: path(of: drop).path) else { return drop }
        let now = self.now()
        return try mutate { db in
            guard let before = try Self.fetchDrop(db, id: drop.id) else {
                throw AgentDropError.notFound("No drop matches '\(drop.id)'")
            }
            guard !before.missing else { return before }
            try db.execute(sql: "UPDATE drops SET missing = 1, updated_at = ? WHERE id = ?",
                           arguments: [now.unixTime, drop.id])
            let after = try Self.fetchDrop(db, id: drop.id)!
            try EventLog.append(db, type: .missing, dropID: drop.id, dataJSON: "{}",
                                before: before, after: after, at: now, retention: retention)
            return after
        }
    }

    /// Newest first (spec §4 `drop list`).
    public func list(_ filter: ListFilter) throws -> [Drop] {
        var clauses: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []
        if !filter.includeArchived { clauses.append("archived = 0") }
        if let project = filter.project { clauses.append("project = ?"); arguments.append(project) }
        for tag in filter.tags {
            clauses.append("EXISTS (SELECT 1 FROM drop_tag t WHERE t.drop_id = drops.id AND t.tag = ?)")
            arguments.append(tag)
        }
        if let from = filter.from { clauses.append("from_identity = ?"); arguments.append(from) }
        if let prefix = filter.fromUnder {
            // Whole levels only: the prefix itself, or "prefix/…". substr counts code points.
            clauses.append("(from_identity = ? OR substr(from_identity, 1, ?) = ?)")
            arguments += [prefix, prefix.unicodeScalars.count + 1, prefix + "/"]
        }
        if filter.handoffsOnly { clauses.append("kind = 'handoff'") }
        if let status = filter.status { clauses.append("status = ?"); arguments.append(status.rawValue) }
        if filter.unreadOnly { clauses.append("read_at IS NULL AND archived = 0 AND missing = 0") }
        if filter.inboxOnly {
            clauses.append("kind = 'handoff' AND status = 'open' AND archived = 0 AND missing = 0")
        }
        var sql = "SELECT * FROM drops"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY created_at DESC, rowid DESC"
        if let limit = filter.limit { sql += " LIMIT ?"; arguments.append(limit) }
        let finalSQL = sql
        let finalArguments = StatementArguments(arguments)
        return try read { db in try Self.fetchDrops(db, sql: finalSQL, arguments: finalArguments) }
    }

    /// Spec §4 Terms "Inbox".
    public func inbox(project: String?) throws -> [Drop] {
        var filter = ListFilter()
        filter.inboxOnly = true
        filter.project = project
        filter.limit = nil
        return try list(filter)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter QueryTests`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentDropCore/DropStore+Query.swift Tests/AgentDropCoreTests/QueryTests.swift
git commit -m "feat(core): resolve by id or filename, list filters, inbox, lazy missing check"
```

---

### Task 7: Edit (incl. kind changes), archive, mark read, remove record

**Files:**
- Create: `Sources/AgentDropCore/DropStore+Edit.swift`
- Test: `Tests/AgentDropCoreTests/EditTests.swift`

**Interfaces:**
- Consumes: `resolve`, `mutate`, `fetchDrop`, `EventLog`, `Validation`, `orNull`
- Produces: `struct EditRequest` (`init(title:description:project:addTags:removeTags:kind:)`, all defaulted), `DropStore.edit(_:_:) throws -> Drop`, `DropStore.setArchived(_:_:) throws -> Drop`, `DropStore.markRead(_:) throws -> Drop`, `DropStore.removeRecord(_:) throws`

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropCoreTests/EditTests.swift`:
```swift
import Foundation
import Testing
@testable import AgentDropCore

struct EditTests {
    @Test func editChangesFieldsAndEmitsOneMetadataEvent() throws {
        let f = try Fixture()
        let drop = try f.add("p.md", tags: ["a"])
        let edited = try f.store.edit(drop.id, EditRequest(title: "New", description: "Why", project: "proj",
                                                           addTags: ["b", "a"], removeTags: ["a"]))
        #expect(edited.title == "New" && edited.description == "Why" && edited.project == "proj")
        #expect(edited.tags == ["b"])
        let events = try f.store.events()
        #expect(events.map(\.type) == [.created, .metadata])
        let data = try JSONSerialization.jsonObject(with: Data(events[1].data.utf8)) as! [String: Any]
        #expect(Set(data.keys) == ["title", "description", "project", "tags"])
        #expect(events[1].projectBefore == nil && events[1].projectAfter == "proj")
    }

    @Test func noOpEditEmitsNothing() throws {
        let f = try Fixture()
        let drop = try f.add("p.md")
        _ = try f.store.edit(drop.id, EditRequest(title: drop.title))
        #expect(try f.store.events().count == 1)
    }

    @Test func kindChangeRules() throws {
        let f = try Fixture()
        let note = try f.add("n.md")
        let handoff = try f.store.edit(note.id, EditRequest(kind: .handoff))
        #expect(handoff.kind == .handoff && handoff.status == .open)
        let last = try f.store.events().last!
        #expect(last.type == .metadata && !last.inboxBefore && last.inboxAfter)

        let back = try f.store.edit(note.id, EditRequest(kind: .note))
        #expect(back.kind == .note && back.status == nil)

        let claimed = try f.add("c.md", handoff: true)
        _ = try f.store.claim(claimed.id, by: "agent-a")
        let msg = expectError(3) { _ = try f.store.edit(claimed.id, EditRequest(kind: .note)) }
        #expect(msg == "\(claimed.id) is claimed by agent-a; release it first")

        let done = try f.add("d.md", handoff: true)
        _ = try f.store.done(done.id, note: nil)
        let msg2 = expectError(3) { _ = try f.store.edit(done.id, EditRequest(kind: .note)) }
        #expect(msg2 == "\(done.id) is done; reopen it first")
    }

    @Test func archiveRoundTripAndInboxMembership() throws {
        let f = try Fixture()
        let drop = try f.add("h.md", handoff: true)
        #expect(try f.store.setArchived(drop.id, true).archived)
        #expect(try f.store.inbox(project: nil).isEmpty)
        _ = try f.store.setArchived(drop.id, true) // no-op, no event
        let restored = try f.store.setArchived(drop.id, false)
        #expect(!restored.archived)
        let events = try f.store.events()
        #expect(events.map(\.type) == [.created, .archived, .archived])
        #expect(events[2].inboxAfter && !events[2].inboxBefore)
        #expect(FileManager.default.fileExists(atPath: f.store.path(of: drop).path))
    }

    @Test func markReadOnlyOnce() throws {
        let f = try Fixture()
        let drop = try f.add("r.md")
        #expect(try f.store.markRead(drop.id).readAt == f.clock.now)
        f.clock.advance(seconds: 10)
        #expect(try f.store.markRead(drop.id).readAt != f.clock.now)
        #expect(try f.store.events().filter { $0.type == .read }.count == 1)
    }

    @Test func removeRecordOnlyForMissingDrops() throws {
        let f = try Fixture()
        let drop = try f.add("x.md")
        expectError(1) { try f.store.removeRecord(drop.id) }
        try FileManager.default.removeItem(at: f.store.path(of: drop))
        try f.store.removeRecord(drop.id)
        expectError(2) { _ = try f.store.resolve(drop.id) }
        #expect(try f.store.events().map(\.type) == [.created, .missing, .removed])
    }

    @Test func editValidatesInput() throws {
        let f = try Fixture()
        let drop = try f.add("v.md")
        expectError(1) { _ = try f.store.edit(drop.id, EditRequest(project: "  ")) }
        expectError(1) { _ = try f.store.edit(drop.id, EditRequest(addTags: ["a\nb"])) }
        expectError(2) { _ = try f.store.edit("zzzzzz", EditRequest(title: "x")) }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EditTests`
Expected: compile failure: `cannot find 'EditRequest' in scope`. (`claim`/`done` come in Task 8. If you run Task 7 alone, the two kind-rule assertions that use them fail to compile. Implement Task 8 before running this file in full, or temporarily comment out those six lines.)

- [ ] **Step 3: Implement**

`Sources/AgentDropCore/DropStore+Edit.swift`:
```swift
import Foundation
import GRDB

public struct EditRequest: Sendable {
    public var title: String?
    public var description: String?
    public var project: String?
    public var addTags: [String]
    public var removeTags: [String]
    public var kind: DropKind?

    public init(title: String? = nil, description: String? = nil, project: String? = nil,
                addTags: [String] = [], removeTags: [String] = [], kind: DropKind? = nil) {
        self.title = title
        self.description = description
        self.project = project
        self.addTags = addTags
        self.removeTags = removeTags
        self.kind = kind
    }
}

extension DropStore {
    /// Spec §4 `drop edit`; kind changes follow §4.2 "Changing kind". One `metadata` event.
    public func edit(_ ref: String, _ request: EditRequest) throws -> Drop {
        let target = try resolve(ref)
        let title = try request.title.map { try Validation.text($0, field: "--title") }
        let description = try request.description.map { try Validation.text($0, field: "--desc") }
        let project = try request.project.map { try Validation.identity($0, field: "--project") }
        let addTags = Validation.unique(try request.addTags.map(Validation.tag))
        let removeTags = request.removeTags.map { $0.trimmingCharacters(in: .whitespaces) }
        let now = self.now()

        return try mutate { db in
            guard let before = try Self.fetchDrop(db, id: target.id) else {
                throw AgentDropError.notFound("No drop matches '\(ref)'")
            }
            var changes: [String: Any] = [:]
            var sets: [String] = []
            var setArguments: [(any DatabaseValueConvertible)?] = []
            var condition = "id = ?"
            var conditionArguments: [(any DatabaseValueConvertible)?] = [before.id]

            if let title, title != before.title {
                sets.append("title = ?"); setArguments.append(title); changes["title"] = title
            }
            if let description, description != before.description {
                sets.append("description = ?"); setArguments.append(description); changes["description"] = description
            }
            if let project, project != before.project {
                sets.append("project = ?"); setArguments.append(project); changes["project"] = project
            }
            if let kind = request.kind, kind != before.kind {
                if before.status == .claimed {
                    throw AgentDropError.conflict(
                        "\(before.id) is claimed by \(before.claimedBy ?? "unknown"); release it first")
                }
                if before.status == .done {
                    throw AgentDropError.conflict("\(before.id) is done; reopen it first")
                }
                if kind == .handoff {
                    sets += ["kind = 'handoff'", "status = 'open'"]
                } else {
                    sets += ["kind = 'note'", "status = NULL", "claimed_by = NULL", "status_note = NULL"]
                }
                condition += " AND kind = ? AND status IS ?"
                conditionArguments += [before.kind.rawValue, before.status?.rawValue]
                changes["kind"] = kind.rawValue
                changes["status"] = kind == .handoff ? "open" : NSNull()
            }

            let newTags = addTags.filter { !before.tags.contains($0) }
            let droppedTags = removeTags.filter { before.tags.contains($0) }
            if !newTags.isEmpty || !droppedTags.isEmpty {
                changes["tags"] = before.tags.filter { !droppedTags.contains($0) } + newTags
            }
            guard !changes.isEmpty else { return before }

            sets.append("updated_at = ?"); setArguments.append(now.unixTime)
            try db.execute(sql: "UPDATE drops SET \(sets.joined(separator: ", ")) WHERE \(condition)",
                           arguments: StatementArguments(setArguments + conditionArguments))
            guard db.changesCount == 1 else {
                throw AgentDropError.conflict("\(before.id) changed while editing; retry")
            }
            for tag in newTags {
                try db.execute(sql: "INSERT INTO drop_tag (drop_id, tag) VALUES (?, ?)", arguments: [before.id, tag])
            }
            for tag in droppedTags {
                try db.execute(sql: "DELETE FROM drop_tag WHERE drop_id = ? AND tag = ?", arguments: [before.id, tag])
            }
            let after = try Self.fetchDrop(db, id: before.id)!
            try EventLog.append(db, type: .metadata, dropID: before.id, dataJSON: EventLog.encodeObject(changes),
                                before: before, after: after, at: now, retention: retention)
            return after
        }
    }

    /// Spec §4 `drop archive` / `--undo`. The file is never touched.
    public func setArchived(_ ref: String, _ archived: Bool) throws -> Drop {
        let target = try resolve(ref)
        let now = self.now()
        return try mutate { db in
            guard let before = try Self.fetchDrop(db, id: target.id) else {
                throw AgentDropError.notFound("No drop matches '\(ref)'")
            }
            guard before.archived != archived else { return before }
            try db.execute(sql: "UPDATE drops SET archived = ?, updated_at = ? WHERE id = ?",
                           arguments: [archived, now.unixTime, before.id])
            let after = try Self.fetchDrop(db, id: before.id)!
            try EventLog.append(db, type: .archived, dropID: before.id,
                                dataJSON: EventLog.encodeObject(["archived": archived]),
                                before: before, after: after, at: now, retention: retention)
            return after
        }
    }

    /// Spec §5.1 `read`: first view in the app only. Used by Plan 3.
    public func markRead(_ ref: String) throws -> Drop {
        let target = try resolve(ref)
        let now = self.now()
        return try mutate { db in
            guard let before = try Self.fetchDrop(db, id: target.id) else {
                throw AgentDropError.notFound("No drop matches '\(ref)'")
            }
            guard before.readAt == nil else { return before }
            try db.execute(sql: "UPDATE drops SET read_at = ? WHERE id = ? AND read_at IS NULL",
                           arguments: [now.unixTime, before.id])
            let after = try Self.fetchDrop(db, id: before.id)!
            try EventLog.append(db, type: .read, dropID: before.id,
                                dataJSON: EventLog.encodeObject(["readAt": now.iso]),
                                before: before, after: after, at: now, retention: retention)
            return after
        }
    }

    /// Spec §3.2 "Remove record": only for drops whose file is gone. Used by Plan 3.
    public func removeRecord(_ ref: String) throws {
        let target = try resolve(ref)
        guard target.missing else {
            throw AgentDropError.invalid("\(target.id) still has its file; only missing drops can be removed")
        }
        let now = self.now()
        try mutate { db in
            try db.execute(sql: "DELETE FROM drops WHERE id = ?", arguments: [target.id])
            try EventLog.append(db, type: .removed, dropID: target.id, dataJSON: "{}",
                                before: target, after: nil, at: now, retention: retention)
        }
    }
}
```

- [ ] **Step 4: Commit (tests run after Task 8)**

```bash
git add Sources/AgentDropCore/DropStore+Edit.swift Tests/AgentDropCoreTests/EditTests.swift
git commit -m "feat(core): edit with kind-change rules, archive, mark read, remove record"
```

---

### Task 8: Handoff transitions

**Files:**
- Create: `Sources/AgentDropCore/DropStore+Transitions.swift`
- Test: `Tests/AgentDropCoreTests/TransitionTests.swift`

**Interfaces:**
- Consumes: `resolve`, `mutate`, `fetchDrop`, `EventLog`, `Validation`, `orNull`
- Produces: `DropStore.claim(_:by:) throws -> Drop`, `release(_:)`, `done(_:note:)`, `reopen(_:)`, all returning the updated `Drop`

- [ ] **Step 1: Write the failing tests**

`Tests/AgentDropCoreTests/TransitionTests.swift`:
```swift
import Foundation
import Testing
@testable import AgentDropCore

struct TransitionTests {
    @Test func fullLifecycle() throws {
        let f = try Fixture()
        let h = try f.add("h.md", handoff: true)
        let claimed = try f.store.claim(h.id, by: "djleague/build-feature-x")
        #expect(claimed.status == .claimed && claimed.claimedBy == "djleague/build-feature-x")
        let released = try f.store.release(h.id)
        #expect(released.status == .open && released.claimedBy == nil)
        _ = try f.store.claim(h.id, by: "b")
        let done = try f.store.done(h.id, note: "shipped in PR #42")
        #expect(done.status == .done && done.statusNote == "shipped in PR #42" && done.claimedBy == "b")
        let reopened = try f.store.reopen(h.id)
        #expect(reopened.status == .open && reopened.claimedBy == nil && reopened.statusNote == nil)
        let statusEvents = try f.store.events().filter { $0.type == .status }
        #expect(statusEvents.count == 5)
        let data = try JSONSerialization.jsonObject(with: Data(statusEvents[0].data.utf8)) as! [String: Any]
        #expect(data["from"] as? String == "open" && data["to"] as? String == "claimed")
        #expect(data["claimedBy"] as? String == "djleague/build-feature-x")
        #expect(data["statusNote"] is NSNull)
    }

    @Test func doneDirectlyFromOpen() throws {
        let f = try Fixture()
        let h = try f.add("h.md", handoff: true)
        #expect(try f.store.done(h.id, note: nil).status == .done)
    }

    @Test func illegalTransitionsAreConflictsWithCurrentState() throws {
        let f = try Fixture()
        let h = try f.add("h.md", handoff: true)
        _ = try f.store.claim(h.id, by: "djleague/build-feature-x")
        let msg = expectError(3) { _ = try f.store.claim(h.id, by: "other") }
        #expect(msg == "\(h.id) is claimed by djleague/build-feature-x")
        expectError(3) { _ = try f.store.reopen(h.id) }
        _ = try f.store.done(h.id, note: nil)
        #expect(expectError(3) { _ = try f.store.claim(h.id, by: "x") } == "\(h.id) is done")
        expectError(3) { _ = try f.store.release(h.id) }
        expectError(3) { _ = try f.store.done(h.id, note: nil) }
    }

    @Test func transitionsOnNotesAreInvalid() throws {
        let f = try Fixture()
        let n = try f.add("n.md")
        expectError(1) { _ = try f.store.claim(n.id, by: "a") }
        expectError(1) { _ = try f.store.done(n.id, note: nil) }
    }

    @Test func claimRequiresValidIdentity() throws {
        let f = try Fixture()
        let h = try f.add("h.md", handoff: true)
        expectError(1) { _ = try f.store.claim(h.id, by: " ") }
    }

    @Test func concurrentClaimsExactlyOneWins() throws {
        let f = try Fixture()
        let h = try f.add("race.md", handoff: true)
        let winners = Locked<[String]>([])
        let conflicts = Locked<Int>(0)
        DispatchQueue.concurrentPerform(iterations: 10) { i in
            let store = try! DropStore.open(folder: f.folder, retention: .default)
            do {
                _ = try store.claim(h.id, by: "agent-\(i)")
                winners.withLock { $0.append("agent-\(i)") }
            } catch let e as AgentDropError where e.exitCode == 3 {
                conflicts.withLock { $0 += 1 }
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        #expect(winners.value.count == 1)
        #expect(conflicts.value == 9)
        #expect(try f.store.resolve(h.id).claimedBy == winners.value.first)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TransitionTests`
Expected: compile failure: `value of type 'DropStore' has no member 'claim'`.

- [ ] **Step 3: Implement**

`Sources/AgentDropCore/DropStore+Transitions.swift`:
```swift
import Foundation
import GRDB

extension DropStore {
    private enum FieldChange {
        case keep, set(String), clear
    }

    /// Spec §4.2: `open → claimed`.
    public func claim(_ ref: String, by: String) throws -> Drop {
        let by = try Validation.identity(by, field: "--by")
        return try transition(ref, from: [.open], to: .claimed, claimedBy: .set(by), statusNote: .keep)
    }

    /// Spec §4.2: `claimed → open`.
    public func release(_ ref: String) throws -> Drop {
        try transition(ref, from: [.claimed], to: .open, claimedBy: .clear, statusNote: .keep)
    }

    /// Spec §4.2: `open → done`, `claimed → done`.
    public func done(_ ref: String, note: String?) throws -> Drop {
        let note = try note.map { try Validation.text($0, field: "--note") }
        return try transition(ref, from: [.open, .claimed], to: .done, claimedBy: .keep,
                              statusNote: note.map { .set($0) } ?? .keep)
    }

    /// Spec §4.2: `done → open`.
    public func reopen(_ ref: String) throws -> Drop {
        try transition(ref, from: [.done], to: .open, claimedBy: .clear, statusNote: .clear)
    }

    private func transition(_ ref: String, from allowed: Set<HandoffStatus>, to target: HandoffStatus,
                            claimedBy: FieldChange, statusNote: FieldChange) throws -> Drop {
        let resolved = try resolve(ref)
        let now = self.now()
        return try mutate { db in
            guard let before = try Self.fetchDrop(db, id: resolved.id) else {
                throw AgentDropError.notFound("No drop matches '\(ref)'")
            }
            guard before.kind == .handoff, let current = before.status else {
                throw AgentDropError.invalid("\(before.id) is a note, not a handoff")
            }
            guard allowed.contains(current) else {
                throw AgentDropError.conflict(Self.stateMessage(before))
            }
            var sets = ["status = ?", "updated_at = ?"]
            var arguments: [(any DatabaseValueConvertible)?] = [target.rawValue, now.unixTime]
            for (column, change) in [("claimed_by", claimedBy), ("status_note", statusNote)] {
                switch change {
                case .keep: break
                case .set(let value): sets.append("\(column) = ?"); arguments.append(value)
                case .clear: sets.append("\(column) = NULL")
                }
            }
            arguments += [before.id, current.rawValue]
            // Conditional update: a concurrent writer that moved the status first makes this a no-op.
            try db.execute(sql: "UPDATE drops SET \(sets.joined(separator: ", ")) WHERE id = ? AND status = ?",
                           arguments: StatementArguments(arguments))
            guard db.changesCount == 1 else {
                let latest = try Self.fetchDrop(db, id: before.id) ?? before
                throw AgentDropError.conflict(Self.stateMessage(latest))
            }
            let after = try Self.fetchDrop(db, id: before.id)!
            let data: [String: Any] = ["from": current.rawValue, "to": target.rawValue,
                                       "claimedBy": orNull(after.claimedBy), "statusNote": orNull(after.statusNote)]
            try EventLog.append(db, type: .status, dropID: before.id, dataJSON: EventLog.encodeObject(data),
                                before: before, after: after, at: now, retention: retention)
            return after
        }
    }

    /// e.g. `k7f2qa is claimed by djleague/build-feature-x` (spec §4.2).
    static func stateMessage(_ drop: Drop) -> String {
        switch drop.status {
        case .claimed?: "\(drop.id) is claimed by \(drop.claimedBy ?? "unknown")"
        case .done?: "\(drop.id) is done"
        case .open?: "\(drop.id) is open"
        case nil: "\(drop.id) is a note, not a handoff"
        }
    }
}
```

- [ ] **Step 4: Run all Core tests**

Run: `swift test --filter AgentDropCoreTests`
Expected: every Core test passes, including `EditTests` (from Task 7) and `concurrentClaimsExactlyOneWins`.

- [ ] **Step 5: Verify every mutation writes exactly one event**

Add to `Tests/AgentDropCoreTests/TransitionTests.swift`:
```swift
struct OneEventPerMutationTests {
    @Test func eachMutationAppendsExactlyOneRow() throws {
        let f = try Fixture()
        func count() throws -> Int { try f.store.events().count }
        let h = try f.add("h.md", handoff: true);                          #expect(try count() == 1)
        _ = try f.store.edit(h.id, EditRequest(title: "T", addTags: ["x"])); #expect(try count() == 2)
        _ = try f.store.claim(h.id, by: "a");                               #expect(try count() == 3)
        _ = try f.store.release(h.id);                                      #expect(try count() == 4)
        _ = try f.store.done(h.id, note: "n");                              #expect(try count() == 5)
        _ = try f.store.reopen(h.id);                                       #expect(try count() == 6)
        _ = try f.store.setArchived(h.id, true);                            #expect(try count() == 7)
        _ = try f.store.markRead(h.id);                                     #expect(try count() == 8)
    }
}
```
Run: `swift test --filter OneEventPerMutationTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentDropCore/DropStore+Transitions.swift Tests/AgentDropCoreTests/TransitionTests.swift
git commit -m "feat(core): handoff transitions with conditional updates and status events"
```

---

### Task 9: CLI harness, `where`, `config`

**Files:**
- Modify: `Package.swift` (full replacement below)
- Create: `Sources/DropCLI/CLIContext.swift`, `Sources/DropCLI/DropCLI.swift`, `Sources/DropCLI/Output.swift`, `Sources/DropCLI/Commands/ConfigCommands.swift`, `Sources/drop/main.swift`
- Test: `Tests/dropCLITests/TestEnv.swift`, `Tests/dropCLITests/ConfigCommandTests.swift`

**Interfaces:**
- Consumes: `ConfigStore`, `AgentDropConfig`, `Retention`, `DropStore.open`, `AgentDropError`
- Produces:
  - `final class OutputSink` (`init(handle:)`, `write(_:)`, `line(_:)`, `text`, `data`)
  - `struct CLIContext` (`config, cwd, now, readStdin, stdout, stderr, findExecutable, runProcess`; `static func live()`; `@TaskLocal static var current`; `openStore() throws -> DropStore`; `resolvePath(_:) -> URL`)
  - `enum DropCLI { static func run(_ arguments: [String], context: CLIContext) -> Int32 }`
  - `struct DropCommand` (root; `subcommands` array extended in Tasks 10–11), `struct JSONOption`
  - `enum Output` (`emit`, `emitJSON`, `line(for:)`, `details(for:path:)`, `printDrop(_:store:json:)`, `printDrops(_:store:json:)`)
  - test `TestEnv` (`run(_ args: String...) -> Result`, `Result.code/out/err/outData/json/jsonArray`, `stdin`, `codeExecutable`, `processCalls`, `dropFolder`, `file(_:_:)`)

- [ ] **Step 1: Replace `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDrop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentDropCore", targets: ["AgentDropCore"]),
        .executable(name: "drop", targets: ["drop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AgentDropCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "DropCLI",
            dependencies: [
                "AgentDropCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "drop", dependencies: ["DropCLI"]),
        .testTarget(
            name: "AgentDropCoreTests",
            dependencies: ["AgentDropCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "dropCLITests", dependencies: ["DropCLI", "AgentDropCore"]),
    ]
)
```

- [ ] **Step 2: Write the test environment and failing tests**

`Tests/dropCLITests/TestEnv.swift`:
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

    @discardableResult
    func run(_ arguments: String...) -> Result {
        let out = OutputSink(), err = OutputSink()
        let stdin = self.stdin, clock = self.clock, code = self.codeExecutable
        let context = CLIContext(
            config: config, cwd: cwd, now: { clock }, readStdin: { stdin },
            stdout: out, stderr: err,
            findExecutable: { $0 == "code" ? code : nil },
            runProcess: { [weak self] executable, args in
                self?.lock.withLock { self?._processCalls.append((executable, args)) }
                return 0
            })
        let status = DropCLI.run(arguments, context: context)
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

`Tests/dropCLITests/ConfigCommandTests.swift`:
```swift
import Foundation
import Testing
@testable import DropCLI

struct ConfigCommandTests {
    @Test func whereDefaultsToHomeAgentDrop() throws {
        let env = try TestEnv()
        let r = env.run("where")
        #expect(r.code == 0)
        #expect(r.trimmedOut == env.dropFolder.path)
        #expect(env.run("where", "--json").json["folder"] as? String == env.dropFolder.path)
    }

    @Test func setFolderResolvesRelativeTildeAndSpaces() throws {
        let env = try TestEnv()
        #expect(env.run("config", "set-folder", "Agent Drop Folder").code == 0)
        let expected = env.cwd.appendingPathComponent("Agent Drop Folder").path
        #expect(env.run("where").trimmedOut == expected)
        #expect(FileManager.default.fileExists(atPath: expected))

        #expect(env.run("config", "set-folder", "~/Desk top/drops").code == 0)
        #expect(env.run("where").trimmedOut == env.home.appendingPathComponent("Desk top/drops").path)
    }

    @Test func setFolderRejectsAFile() throws {
        let env = try TestEnv()
        try env.file("not-a-dir", "x")
        let r = env.run("config", "set-folder", "not-a-dir")
        #expect(r.code == 1)
        #expect(r.err.hasPrefix("drop: "))
    }

    @Test func setRetentionValidates() throws {
        let env = try TestEnv()
        #expect(env.run("config", "set-retention", "14").code == 0)
        #expect(env.run("config", "show", "--json").json["eventRetentionDays"] as? Int == 14)
        #expect(env.run("config", "set-retention", "forever").code == 0)
        #expect(env.run("config", "show", "--json").json["eventRetentionDays"] as? String == "forever")
        for bad in ["0", "-1", "7.5", "weekly"] {
            #expect(env.run("config", "set-retention", bad).code == 1)
        }
    }

    @Test func showListsEverySettingAndDisclosesCleanup() throws {
        let env = try TestEnv()
        let r = env.run("config", "show")
        #expect(r.code == 0)
        for key in ["folder:", "eventRetentionDays:", "serverPort:", "setupComplete:", "confirmedFolder:"] {
            #expect(r.out.contains(key))
        }
        #expect(r.out.contains("Your drops and files are never deleted."))
        let json = env.run("config", "show", "--json").json
        #expect(json["serverPort"] as? Int == 47390)
        #expect(json["setupComplete"] as? Bool == false)
        #expect(json["confirmedFolder"] is NSNull)
        #expect((json["warnings"] as? [String])?.isEmpty == true)
    }

    @Test func showWarnsAboutInvalidRetention() throws {
        let env = try TestEnv()
        try FileManager.default.createDirectory(at: env.config.configDir, withIntermediateDirectories: true)
        try Data(#"{"eventRetentionDays": 0}"#.utf8).write(to: env.config.configFile)
        let r = env.run("config", "show")
        #expect(r.code == 0)
        #expect(r.err.contains("invalid"))
        #expect((env.run("config", "show", "--json").json["warnings"] as? [String])?.count == 1)
    }

    @Test func usageErrorsExitOneAndJsonErrorsGoToStdout() throws {
        let env = try TestEnv()
        let human = env.run("config", "set-retention")
        #expect(human.code == 1 && human.out.isEmpty && !human.err.isEmpty)
        let json = env.run("config", "set-retention", "0", "--json")
        #expect(json.code == 1 && json.err.isEmpty)
        #expect(json.json["code"] as? Int == 1)
        #expect(json.json["error"] is String)
    }

    @Test func helpExitsZero() throws {
        let env = try TestEnv()
        let r = env.run("--help")
        #expect(r.code == 0)
        #expect(r.out.contains("USAGE"))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter ConfigCommandTests`
Expected: compile failure: `cannot find 'CLIContext' in scope`.

- [ ] **Step 4: Implement the context**

`Sources/DropCLI/CLIContext.swift`:
```swift
import AgentDropCore
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

    public init(config: ConfigStore, cwd: URL, now: @escaping @Sendable () -> Date,
                readStdin: @escaping @Sendable () -> Data, stdout: OutputSink, stderr: OutputSink,
                findExecutable: @escaping @Sendable (String) -> URL?,
                runProcess: @escaping @Sendable (URL, [String]) throws -> Int32) {
        self.config = config
        self.cwd = cwd
        self.now = now
        self.readStdin = readStdin
        self.stdout = stdout
        self.stderr = stderr
        self.findExecutable = findExecutable
        self.runProcess = runProcess
    }

    @TaskLocal public static var current: CLIContext = .live()

    public static func live() -> CLIContext {
        CLIContext(
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
            runProcess: { executable, arguments in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
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

- [ ] **Step 5: Implement the runner, root command, and output helpers**

`Sources/DropCLI/DropCLI.swift`:
```swift
import AgentDropCore
import ArgumentParser
import Foundation

public enum DropCLI {
    /// Parses and runs one invocation; returns the process exit code (spec §4 Global rules).
    public static func run(_ arguments: [String], context: CLIContext) -> Int32 {
        let wantsJSON = arguments.contains("--json")
        return CLIContext.$current.withValue(context) {
            do {
                var command = try DropCommand.parseAsRoot(arguments)
                try command.run()
                return 0
            } catch let error as AgentDropError {
                report(error.message, code: error.exitCode, json: wantsJSON, context: context)
                return error.exitCode
            } catch {
                if DropCommand.exitCode(for: error) == .success {
                    context.stdout.line(DropCommand.fullMessage(for: error))
                    return 0
                }
                report(DropCommand.fullMessage(for: error), code: 1, json: wantsJSON, context: context)
                return 1
            }
        }
    }

    private struct ErrorJSON: Encodable {
        let error: String
        let code: Int32
    }

    private static func report(_ message: String, code: Int32, json: Bool, context: CLIContext) {
        if json {
            context.stdout.line(Output.jsonString(ErrorJSON(error: message, code: code)))
        } else {
            context.stderr.line("drop: \(message)")
        }
    }
}

struct DropCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drop",
        abstract: "Agent Drop: a shared drop folder with context, for humans and coding agents.",
        version: "0.1.0",
        subcommands: [Where.self, Config.self]
    )
}

struct JSONOption: ParsableArguments {
    @Flag(name: .long, help: "Machine-readable JSON output.")
    var json = false
}
```

`Sources/DropCLI/Output.swift`:
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

    /// One tab-separated line: id, state, title, project, from, created[, flags].
    static func line(for drop: Drop) -> String {
        let state = drop.status.map { "handoff:\($0.rawValue)" } ?? "note"
        var fields = [drop.id, state, drop.title, drop.project ?? "-", drop.from, drop.createdAt.iso]
        if drop.archived { fields.append("[archived]") }
        if drop.missing { fields.append("[missing]") }
        return fields.joined(separator: "\t")
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
        return rows.map { "\($0.0):".padding(toLength: 13, withPad: " ", startingAt: 0) + $0.1 }
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

`Sources/drop/main.swift`:
```swift
import DropCLI
import Foundation

exit(DropCLI.run(Array(CommandLine.arguments.dropFirst()), context: .live()))
```

- [ ] **Step 6: Implement `where` and `config`**

`Sources/DropCLI/Commands/ConfigCommands.swift`:
```swift
import AgentDropCore
import ArgumentParser
import Foundation

struct Where: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "where", abstract: "Print the drop folder path in use.")
    @OptionGroup var output: JSONOption

    func run() throws {
        let context = CLIContext.current
        let folder = context.config.folderURL(try context.config.load()).path
        if output.json { Output.emitJSON(["folder": folder]) } else { Output.emit(folder) }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change settings in config.json.",
        subcommands: [SetFolder.self, SetRetention.self, Show.self]
    )

    struct SetFolder: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-folder", abstract: "Set the drop folder (created if needed).")
        @Argument(help: "Folder path.") var path: String
        @OptionGroup var output: JSONOption

        func run() throws {
            let context = CLIContext.current
            let url = context.resolvePath(path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw AgentDropError.invalid("\(url.path) exists and is not a folder")
            }
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw AgentDropError.invalid("Can't create \(url.path): \(error.localizedDescription)")
            }
            try context.config.setFolder(url)
            if output.json { Output.emitJSON(["folder": url.path]) } else { Output.emit(url.path) }
        }
    }

    struct SetRetention: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-retention",
            abstract: "How long the change log keeps entries: whole days ≥ 1, or 'forever'.")
        @Argument(help: "Days (≥ 1) or 'forever'.") var value: String
        @OptionGroup var output: JSONOption

        func run() throws {
            guard let retention = Retention(argument: value) else {
                throw AgentDropError.invalid("retention must be a whole number of days ≥ 1, or 'forever'")
            }
            try CLIContext.current.config.setRetention(retention)
            if output.json { Output.emitJSON(["eventRetentionDays": retention.displayValue]) }
            else { Output.emit("eventRetentionDays: \(retention.displayValue)") }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show", abstract: "Print every config.json setting.")
        @OptionGroup var output: JSONOption

        static let disclosure = "Old entries in the change log are deleted as new changes come in. Your drops and files are never deleted."
        static let invalidWarning = "eventRetentionDays in config.json is invalid; using 30 days"

        func run() throws {
            let context = CLIContext.current
            let settings = try context.config.load()
            let snapshot = ConfigJSON(
                folder: context.config.folderURL(settings).path,
                retention: settings.eventRetentionDays,
                serverPort: settings.serverPort ?? AgentDropConfig.defaultServerPort,
                setupComplete: settings.setupComplete,
                confirmedFolder: settings.confirmedFolder,
                warnings: settings.retentionWasInvalid ? [Self.invalidWarning] : [])
            if output.json {
                Output.emitJSON(snapshot)
                return
            }
            let retention: String = switch settings.eventRetentionDays {
            case .forever: "forever"
            case .days(let n): "\(n)"
            }
            Output.emit("folder:             \(snapshot.folder)")
            Output.emit("eventRetentionDays: \(retention)")
            Output.emit("                    \(Self.disclosure)")
            Output.emit("serverPort:         \(snapshot.serverPort)")
            Output.emit("setupComplete:      \(snapshot.setupComplete)")
            Output.emit("confirmedFolder:    \(snapshot.confirmedFolder ?? "-")")
            for warning in snapshot.warnings { context.stderr.line("warning: \(warning)") }
        }
    }
}

struct ConfigJSON: Encodable {
    let folder: String
    let retention: Retention
    let serverPort: Int
    let setupComplete: Bool
    let confirmedFolder: String?
    let warnings: [String]

    enum Key: String, CodingKey {
        case folder, eventRetentionDays, serverPort, setupComplete, confirmedFolder, warnings
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(folder, forKey: .folder)
        switch retention {
        case .forever: try c.encode("forever", forKey: .eventRetentionDays)
        case .days(let n): try c.encode(n, forKey: .eventRetentionDays)
        }
        try c.encode(serverPort, forKey: .serverPort)
        try c.encode(setupComplete, forKey: .setupComplete)
        try c.encode(confirmedFolder, forKey: .confirmedFolder)
        try c.encode(warnings, forKey: .warnings)
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter ConfigCommandTests`
Expected: all tests pass.

Run: `swift build && .build/debug/drop --help`
Expected: usage text listing `where` and `config`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/DropCLI Sources/drop Tests/dropCLITests
git commit -m "feat(cli): in-process CLI harness, where, config set-folder/set-retention/show"
```

---

### Task 10: `add`, `show`, `cat`, `path`, `list`, `latest`, `inbox`

**Files:**
- Create: `Sources/DropCLI/Commands/AddCommand.swift`, `Sources/DropCLI/Commands/ReadCommands.swift`
- Modify: `Sources/DropCLI/DropCLI.swift` (`subcommands` list)
- Test: `Tests/dropCLITests/AddReadCommandTests.swift`

**Interfaces:**
- Consumes: `CLIContext.current/openStore/resolvePath/readStdin`, `DropStore.add/resolve/list/inbox/path/json`, `AddRequest`, `ListFilter`, `Output`
- Produces: commands `Add`, `Show`, `Cat`, `PathCommand`, `ListCommand`, `Latest`, `Inbox`; `struct ListFilterOptions: ParsableArguments` with `func filter() throws -> ListFilter`; helper `requireFile(_:store:) throws -> URL`

- [ ] **Step 1: Write the failing tests**

`Tests/dropCLITests/AddReadCommandTests.swift`:
```swift
import Foundation
import Testing
@testable import DropCLI

struct AddReadCommandTests {
    @Test func addPrintsIdAndRequiresFrom() throws {
        let env = try TestEnv()
        try env.file("plan.md", "# Auth plan")
        let missingFrom = env.run("add", "plan.md")
        #expect(missingFrom.code == 1)
        let r = env.run("add", "plan.md", "--from", "djleague/build-feature-x", "--project", "dj",
                        "--tag", "spec", "-m", "Why it matters", "--handoff")
        #expect(r.code == 0)
        let id = r.trimmedOut
        #expect(id.count == 6)
        let shown = env.run("show", id, "--json").json
        #expect(shown["title"] as? String == "Auth plan")
        #expect(shown["from"] as? String == "djleague/build-feature-x")
        #expect(shown["status"] as? String == "open")
        #expect(shown["path"] as? String == env.dropFolder.appendingPathComponent("plan.md").path)
    }

    @Test func addFromStdinAndJson() throws {
        let env = try TestEnv()
        env.stdin = Data("# Notes\nbody".utf8)
        let r = env.run("add", "-", "--name", "notes.md", "--from", "a", "--json")
        #expect(r.code == 0)
        #expect(r.json["filename"] as? String == "notes.md")
        #expect(env.run("cat", "notes.md").out == "# Notes\nbody")
        env.stdin = Data()
        #expect(env.run("add", "-", "--name", "e.md", "--from", "a").code == 1)
    }

    @Test func addErrorCodes() throws {
        let env = try TestEnv()
        #expect(env.run("add", "nope.md", "--from", "a").code == 2)
        try env.file(".hidden", "x")
        #expect(env.run("add", ".hidden", "--from", "a").code == 1)
        #expect(env.run("add", ".hidden", "--from", "a", "--name", "visible.md").code == 0)
    }

    @Test func unicodeAndSpacesRoundTrip() throws {
        let env = try TestEnv()
        let name = "Q3 plan — draft ✅.md"
        try env.file(name, "# Q3 ✅\nCafé")
        let id = env.run("add", name, "--from", "a").trimmedOut
        #expect(env.run("cat", name).out == "# Q3 ✅\nCafé")
        #expect(env.run("path", id).trimmedOut == env.dropFolder.appendingPathComponent(name).path)
        #expect(env.run("show", name, "--json").json["title"] as? String == "Q3 ✅")
    }

    @Test func catWritesBinaryBytesUnchanged() throws {
        let env = try TestEnv()
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0xFE])
        bytes.append(contentsOf: (0..<256).map { UInt8($0) })
        try env.data("pixel.png", bytes)
        let id = env.run("add", "pixel.png", "--from", "a").trimmedOut
        #expect(env.run("cat", id).outData == bytes)
    }

    @Test func catRejectsJsonFoldersAndMissingFiles() throws {
        let env = try TestEnv()
        try env.file("p.md", "x")
        let id = env.run("add", "p.md", "--from", "a").trimmedOut
        let json = env.run("cat", id, "--json")
        #expect(json.code == 1 && json.json["code"] as? Int == 1)
        try env.file("bundle/README.md", "# B")
        let folderID = env.run("add", "bundle", "--from", "a").trimmedOut
        #expect(env.run("cat", folderID).code == 1)
        #expect(env.run("path", folderID).trimmedOut == env.dropFolder.appendingPathComponent("bundle").path)
        try FileManager.default.removeItem(at: env.dropFolder.appendingPathComponent("p.md"))
        #expect(env.run("cat", id).code == 2)
        #expect(env.run("show", id, "--json").json["missing"] as? Bool == true)
    }

    @Test func listFiltersAndJsonArray() throws {
        let env = try TestEnv()
        try env.file("a.md", "a"); try env.file("b.md", "b"); try env.file("c.md", "c")
        _ = env.run("add", "a.md", "--from", "djleague/autodev/AutoDev DJ-1 [ef013ae]", "--tag", "PR")
        _ = env.run("add", "b.md", "--from", "djleague2", "--tag", "pr")
        _ = env.run("add", "c.md", "--from", "djleague", "--handoff")
        #expect(env.run("list", "--json").jsonArray.count == 3)
        #expect(env.run("list", "--from-under", "djleague", "--json").jsonArray.count == 2)
        #expect(env.run("list", "--tag", "PR", "--json").jsonArray.count == 1)
        #expect(env.run("list", "--handoffs", "--json").jsonArray.count == 1)
        #expect(env.run("list", "--status", "claimed", "--json").jsonArray.isEmpty)
        #expect(env.run("list", "--status", "bogus").code == 1)
        #expect(env.run("list", "--limit", "0").code == 1)
        #expect(env.run("list").out.split(separator: "\n").count == 3)
    }

    @Test func latestAndCatFlag() throws {
        let env = try TestEnv()
        #expect(env.run("latest").code == 2)
        try env.file("one.md", "first"); try env.file("two.md", "second")
        _ = env.run("add", "one.md", "--from", "a")
        _ = env.run("add", "two.md", "--from", "a", "--project", "p")
        #expect(env.run("latest", "--json").json["filename"] as? String == "two.md")
        #expect(env.run("latest", "--cat").out == "second")
        #expect(env.run("latest", "--cat", "--json").code == 1)
        #expect(env.run("latest", "--project", "nope").code == 2)
    }

    @Test func inboxListsOpenHandoffs() throws {
        let env = try TestEnv()
        try env.file("h1.md", "1"); try env.file("h2.md", "2"); try env.file("n.md", "n")
        _ = env.run("add", "h1.md", "--from", "a", "--project", "p", "--handoff")
        _ = env.run("add", "h2.md", "--from", "a", "--project", "q", "--handoff")
        _ = env.run("add", "n.md", "--from", "a", "--project", "p")
        #expect(env.run("inbox", "--json").jsonArray.count == 2)
        #expect(env.run("inbox", "--project", "p", "--json").jsonArray.count == 1)
        #expect(env.run("inbox", "--project", "none").out.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AddReadCommandTests`
Expected: FAIL. Every `run("add", …)` exits 1 with "Unexpected argument 'add'".

- [ ] **Step 3: Implement `add`**

`Sources/DropCLI/Commands/AddCommand.swift`:
```swift
import AgentDropCore
import ArgumentParser
import Foundation

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Drop a file or folder (or '-' for stdin) into the drop folder and register it.")

    @Argument(help: "File or folder to drop, or '-' to read content from stdin (requires --name).")
    var path: String
    @Option(help: "Who is dropping this. Required, free-form, never guessed.")
    var from: String
    @Option(help: "Top-level name for the drop (default: the source's name).")
    var name: String?
    @Option(help: "Title (default: first '# heading', else the filename).")
    var title: String?
    @Option(name: [.customShort("m"), .customLong("desc")], help: "Why this exists / context.")
    var desc: String?
    @Option(help: "Project (free-form).")
    var project: String?
    @Option(name: .customLong("tag"), help: "Tag (repeatable).")
    var tags: [String] = []
    @Flag(help: "Make this a handoff (status: open).")
    var handoff = false
    @Flag(help: "Move instead of copy.")
    var move = false
    @OptionGroup var output: JSONOption

    func run() throws {
        let context = CLIContext.current
        let store = try context.openStore()
        let source: AddSource = path == "-" ? .stdin(context.readStdin()) : .path(context.resolvePath(path))
        let drop = try store.add(AddRequest(
            source: source, name: name, title: title, description: desc, project: project,
            tags: tags, from: from, handoff: handoff, move: move))
        if output.json { Output.emitJSON(store.json(drop)) } else { Output.emit(drop.id) }
    }
}
```

- [ ] **Step 4: Implement the read commands**

`Sources/DropCLI/Commands/ReadCommands.swift`:
```swift
import AgentDropCore
import ArgumentParser
import Foundation

struct ListFilterOptions: ParsableArguments {
    @Option(help: "Exact project.") var project: String?
    @Option(name: .customLong("tag"), help: "Exact tag (repeatable; all must match).") var tags: [String] = []
    @Option(help: "Exact --from value.") var from: String?
    @Option(name: .customLong("from-under"), help: "A --from prefix and everything under it (split on '/').")
    var fromUnder: String?
    @Flag(help: "Handoffs only.") var handoffs = false
    @Option(help: "open, claimed, or done.") var status: String?
    @Flag(help: "Unread only (not archived, not missing).") var unread = false
    @Option(help: "Maximum results (default 50).") var limit: Int = 50
    @Flag(help: "Include archived drops.") var all = false

    func filter() throws -> ListFilter {
        var filter = ListFilter()
        filter.project = project
        filter.tags = tags
        filter.from = from
        filter.fromUnder = fromUnder
        filter.handoffsOnly = handoffs
        if let status {
            guard let parsed = HandoffStatus(rawValue: status) else {
                throw AgentDropError.invalid("--status must be open, claimed, or done")
            }
            filter.status = parsed
        }
        filter.unreadOnly = unread
        guard limit >= 1 else { throw AgentDropError.invalid("--limit must be at least 1") }
        filter.limit = limit
        filter.includeArchived = all
        return filter
    }
}

/// The drop's file, or exit 2 if it's gone.
func requireFile(_ drop: Drop, store: DropStore) throws -> URL {
    guard !drop.missing else { throw AgentDropError.notFound("The file for \(drop.id) is missing") }
    return store.path(of: drop)
}

/// Raw bytes to stdout (spec §4 `drop cat`; never sets read_at).
func writeContents(of drop: Drop, store: DropStore) throws {
    let url = try requireFile(drop, store: store)
    guard !drop.isFolder else {
        throw AgentDropError.invalid("\(drop.id) is a folder drop; use `drop path \(drop.id)`")
    }
    CLIContext.current.stdout.write(try Data(contentsOf: url))
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Metadata plus absolute path.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        let drop = try store.resolve(id)
        if output.json { Output.emitJSON(store.json(drop)) }
        else { Output.emit(Output.details(for: drop, path: store.path(of: drop).path)) }
    }
}

struct Cat: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cat", abstract: "Print the file's contents.")
    @Argument(help: "Id or exact filename.") var id: String
    @Flag(help: "Not supported: cat prints raw contents.") var json = false

    func run() throws {
        if json { throw AgentDropError.invalid("drop cat prints raw file contents; --json isn't supported") }
        let store = try CLIContext.current.openStore()
        try writeContents(of: try store.resolve(id), store: store)
    }
}

struct PathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path", abstract: "Print the absolute path only.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        let url = try requireFile(try store.resolve(id), store: store)
        if output.json { Output.emitJSON(["path": url.path]) } else { Output.emit(url.path) }
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List drops, newest first (archived hidden unless --all).")
    @OptionGroup var filters: ListFilterOptions
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrops(try store.list(try filters.filter()), store: store, json: output.json)
    }
}

struct Latest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "latest", abstract: "The newest drop matching the same filters as list.")
    @OptionGroup var filters: ListFilterOptions
    @Flag(help: "Print the file's contents instead of its metadata.") var cat = false
    @OptionGroup var output: JSONOption

    func run() throws {
        if cat && output.json { throw AgentDropError.invalid("--cat and --json can't be combined; use one or the other") }
        let store = try CLIContext.current.openStore()
        var filter = try filters.filter()
        filter.limit = 1
        guard let drop = try store.list(filter).first else { throw AgentDropError.notFound("No drops match") }
        if cat { try writeContents(of: try store.resolve(drop.id), store: store); return }
        if output.json { Output.emitJSON(store.json(drop)) }
        else { Output.emit(Output.details(for: drop, path: store.path(of: drop).path)) }
    }
}

struct Inbox: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox", abstract: "Open handoffs (not archived, not missing).")
    @Option(help: "Only this project.") var project: String?
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrops(try store.inbox(project: project), store: store, json: output.json)
    }
}
```

- [ ] **Step 5: Register the commands**

In `Sources/DropCLI/DropCLI.swift`, replace the `subcommands:` line with:
```swift
        subcommands: [Add.self, Show.self, Cat.self, PathCommand.self, ListCommand.self, Latest.self,
                      Inbox.self, Where.self, Config.self]
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter AddReadCommandTests`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/DropCLI Tests/dropCLITests/AddReadCommandTests.swift
git commit -m "feat(cli): add, show, cat, path, list, latest, inbox"
```

---

### Task 11: `edit`, `archive`, handoff commands, `code`, `agent-instructions`

**Files:**
- Create: `Sources/DropCLI/Commands/EditCommands.swift`, `Sources/DropCLI/Commands/HandoffCommands.swift`, `Sources/DropCLI/Commands/HumanCommands.swift`
- Modify: `Sources/DropCLI/DropCLI.swift` (`subcommands` list)
- Test: `Tests/dropCLITests/HandoffCommandTests.swift`

**Interfaces:**
- Consumes: `DropStore.edit/setArchived/claim/release/done/reopen/resolve`, `EditRequest`, `requireFile`, `Output.printDrop`, `CLIContext.findExecutable/runProcess`
- Produces: commands `Edit`, `Archive`, `Claim`, `Release`, `Done`, `Reopen`, `Code`, `AgentInstructions`; `AgentInstructions.text`

- [ ] **Step 1: Write the failing tests**

`Tests/dropCLITests/HandoffCommandTests.swift`:
```swift
import Foundation
import Testing
@testable import DropCLI

struct HandoffCommandTests {
    func handoff(_ env: TestEnv, project: String = "p") throws -> String {
        env.stdin = Data("# Do the thing".utf8)
        return env.run("add", "-", "--name", "task-\(UUID().uuidString.prefix(4)).md", "--from", "agent-a",
                       "--project", project, "--handoff").trimmedOut
    }

    @Test func endToEndHandoffLifecycle() throws {
        let env = try TestEnv()
        let id = try handoff(env)
        #expect(env.run("inbox", "--project", "p", "--json").jsonArray.first?["id"] as? String == id)

        let claim = env.run("claim", id, "--by", "djleague/build-feature-x", "--json")
        #expect(claim.code == 0 && claim.json["claimedBy"] as? String == "djleague/build-feature-x")
        #expect(env.run("inbox", "--json").jsonArray.isEmpty)

        let second = env.run("claim", id, "--by", "other")
        #expect(second.code == 3)
        #expect(second.err.contains("\(id) is claimed by djleague/build-feature-x"))

        let done = env.run("done", id, "--note", "shipped in PR #42", "--json")
        #expect(done.json["status"] as? String == "done" && done.json["statusNote"] as? String == "shipped in PR #42")
        #expect(env.run("release", id).code == 3)

        #expect(env.run("reopen", id).code == 0)
        #expect(env.run("inbox", "--json").jsonArray.count == 1)
        #expect(env.run("claim", id, "--by", "b").code == 0)
        #expect(env.run("release", id, "--json").json["status"] as? String == "open")
    }

    @Test func claimRequiresBy() throws {
        let env = try TestEnv()
        let id = try handoff(env)
        #expect(env.run("claim", id).code == 1)
    }

    @Test func transitionsOnNotesExitOne() throws {
        let env = try TestEnv()
        try env.file("n.md", "n")
        let id = env.run("add", "n.md", "--from", "a").trimmedOut
        #expect(env.run("claim", id, "--by", "x").code == 1)
        #expect(env.run("claim", "zzzzzz", "--by", "x").code == 2)
    }

    @Test func editAndKindChanges() throws {
        let env = try TestEnv()
        try env.file("n.md", "n")
        let id = env.run("add", "n.md", "--from", "a", "--tag", "x").trimmedOut
        let edited = env.run("edit", id, "--title", "New", "--tag", "y", "--untag", "x", "--kind", "handoff", "--json")
        #expect(edited.code == 0)
        #expect(edited.json["title"] as? String == "New")
        #expect(edited.json["tags"] as? [String] == ["y"])
        #expect(edited.json["status"] as? String == "open")
        _ = env.run("claim", id, "--by", "a")
        let blocked = env.run("edit", id, "--kind", "note")
        #expect(blocked.code == 3 && blocked.err.contains("release it first"))
        #expect(env.run("edit", id, "--kind", "bogus").code == 1)
    }

    @Test func archiveAndUndo() throws {
        let env = try TestEnv()
        let id = try handoff(env)
        #expect(env.run("archive", id, "--json").json["archived"] as? Bool == true)
        #expect(env.run("list", "--json").jsonArray.isEmpty)
        #expect(env.run("inbox", "--json").jsonArray.isEmpty)
        #expect(env.run("archive", "--undo", id).code == 0)
        #expect(env.run("inbox", "--json").jsonArray.count == 1)
    }

    @Test func codeRunsVSCodeOrExplains() throws {
        let env = try TestEnv()
        try env.file("c.md", "c")
        let id = env.run("add", "c.md", "--from", "a").trimmedOut
        let missing = env.run("code", id)
        #expect(missing.code == 1 && missing.err.contains("code"))
        env.codeExecutable = URL(fileURLWithPath: "/usr/local/bin/code")
        #expect(env.run("code", id).code == 0)
        #expect(env.processCalls.first?.1 == [env.dropFolder.appendingPathComponent("c.md").path])
    }

    @Test func agentInstructionsMentionTheEssentials() throws {
        let env = try TestEnv()
        let r = env.run("agent-instructions")
        #expect(r.code == 0)
        for needle in ["drop add", "--from", "drop inbox", "drop claim", "--by", "drop done", "quote"] {
            #expect(r.out.contains(needle), "missing \(needle)")
        }
        #expect(env.run("agent-instructions", "--json").json["instructions"] is String)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HandoffCommandTests`
Expected: FAIL, with "Unexpected argument 'claim'" (and similar) and exit code 1.

- [ ] **Step 3: Implement `edit` and `archive`**

`Sources/DropCLI/Commands/EditCommands.swift`:
```swift
import AgentDropCore
import ArgumentParser

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Change a drop's metadata.")
    @Argument(help: "Id or exact filename.") var id: String
    @Option var title: String?
    @Option(name: [.customShort("m"), .customLong("desc")]) var desc: String?
    @Option var project: String?
    @Option(name: .customLong("tag"), help: "Add a tag (repeatable).") var tags: [String] = []
    @Option(name: .customLong("untag"), help: "Remove a tag (repeatable).") var untags: [String] = []
    @Option(help: "note or handoff.") var kind: String?
    @OptionGroup var output: JSONOption

    func run() throws {
        var parsedKind: DropKind?
        if let kind {
            guard let value = DropKind(rawValue: kind) else {
                throw AgentDropError.invalid("--kind must be note or handoff")
            }
            parsedKind = value
        }
        let store = try CLIContext.current.openStore()
        let drop = try store.edit(id, EditRequest(title: title, description: desc, project: project,
                                                  addTags: tags, removeTags: untags, kind: parsedKind))
        Output.printDrop(drop, store: store, json: output.json)
    }
}

struct Archive: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive", abstract: "Hide a drop from default lists (the file is untouched).")
    @Argument(help: "Id or exact filename.") var id: String
    @Flag(help: "Un-archive.") var undo = false
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrop(try store.setArchived(id, !undo), store: store, json: output.json)
    }
}
```

- [ ] **Step 4: Implement the handoff commands**

`Sources/DropCLI/Commands/HandoffCommands.swift`:
```swift
import AgentDropCore
import ArgumentParser

struct Claim: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claim", abstract: "Pick up an open handoff (exit 3 if someone else has it).")
    @Argument(help: "Id or exact filename.") var id: String
    @Option(help: "Who is claiming. Required, free-form, never guessed.") var by: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrop(try store.claim(id, by: by), store: store, json: output.json)
    }
}

struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "release", abstract: "Un-claim: back to open.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrop(try store.release(id), store: store, json: output.json)
    }
}

struct Done: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "done", abstract: "Mark a handoff finished.")
    @Argument(help: "Id or exact filename.") var id: String
    @Option(help: "What happened, e.g. \"shipped in PR #42\".") var note: String?
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrop(try store.done(id, note: note), store: store, json: output.json)
    }
}

struct Reopen: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reopen", abstract: "Move a done handoff back to open.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrop(try store.reopen(id), store: store, json: output.json)
    }
}
```

- [ ] **Step 5: Implement `code` and `agent-instructions`**

`Sources/DropCLI/Commands/HumanCommands.swift`:
```swift
import AgentDropCore
import ArgumentParser

struct Code: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "code", abstract: "Open the drop in VS Code.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let context = CLIContext.current
        let store = try context.openStore()
        let url = try requireFile(try store.resolve(id), store: store)
        guard let code = context.findExecutable("code") else {
            throw AgentDropError.invalid(
                "VS Code's `code` command isn't on your PATH. In VS Code, run \"Shell Command: Install 'code' command in PATH\".")
        }
        let status = try context.runProcess(code, [url.path])
        guard status == 0 else { throw AgentDropError.invalid("`code` exited with status \(status)") }
        if output.json { Output.emitJSON(["opened": url.path]) }
    }
}

struct AgentInstructions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-instructions", abstract: "Print a snippet for CLAUDE.md / AGENTS.md.")
    @OptionGroup var output: JSONOption

    static let text = """
        ## Agent Drop

        This machine has Agent Drop: a shared drop folder, with context, for handing files to the human and to other agents. Use the `drop` CLI.

        **Your identity.** Pass the identity your harness gives you as `--from` (when dropping) and `--by` (when claiming), exactly as given. Always quote it, because it may contain spaces or brackets: `--from "djleague/autodev/AutoDev DJ-1234 [ef013ae]"`. If you don't have one, ask the user what to use.

        **Drop a file** (spec, plan, report, handoff) with context about what it is and why it matters:

            drop add plan.md --from "<identity>" --project "<project>" --title "Auth refactor plan" -m "Why this exists and what the reader should do"

        - Content without a file: `printf '%s' "$CONTENT" | drop add - --name notes.md --from "<identity>"`
        - A whole folder works too: `drop add ./handoff-bundle/ --from "<identity>"`
        - For another agent to pick up, add `--handoff`. Tag with `--tag <t>` (repeatable).

        **Pick up work:**

            drop inbox --project "<project>" --json      # open handoffs
            drop claim <id> --by "<identity>"            # exit 3 = someone else has it; pick another
            drop cat <id>                                # read it
            drop done <id> --note "What you did, e.g. shipped in PR #42"

        If you can't finish, run `drop release <id>` so someone else can claim it.

        Every command accepts `--json` (except `drop cat`). Exit codes: 0 ok, 1 error, 2 not found, 3 conflict.
        """

    func run() throws {
        if output.json { Output.emitJSON(["instructions": Self.text]) } else { Output.emit(Self.text) }
    }
}
```

- [ ] **Step 6: Register the commands**

In `Sources/DropCLI/DropCLI.swift`, replace the `subcommands:` line with:
```swift
        subcommands: [Add.self, Edit.self, Archive.self, ListCommand.self, Show.self, Cat.self, PathCommand.self,
                      Latest.self, Inbox.self, Claim.self, Release.self, Done.self, Reopen.self, Code.self,
                      Where.self, Config.self, AgentInstructions.self]
```

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: every Core and CLI test passes.

- [ ] **Step 8: Commit**

```bash
git add Sources/DropCLI Tests/dropCLITests/HandoffCommandTests.swift
git commit -m "feat(cli): edit, archive, claim/release/done/reopen, code, agent-instructions"
```

---

### Task 12: Real-binary smoke test, CI, README

**Files:**
- Create: `Scripts/smoke.sh`
- Modify: `.github/workflows/ci.yml`, `README.md`, `docs/superpowers/specs/2026-10-11-agent-drop-design.md` (Status line only)

**Interfaces:**
- Consumes: the built `drop` binary
- Produces: CI that runs `swift test` plus the smoke script against the real default paths

- [ ] **Step 1: Write the smoke script**

`Scripts/smoke.sh`:
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

DROP="${1:?usage: Scripts/smoke.sh <path-to-drop-binary>}"
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
echo "smoke: ok"
```

Run: `chmod +x Scripts/smoke.sh && Scripts/smoke.sh .build/debug/drop`
Expected locally: `smoke.sh: skipped (…)` and exit 0. **Do not** bypass the guard on your own machine.

- [ ] **Step 2: Extend CI**

Replace `.github/workflows/ci.yml` with:
```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - run: swift --version
      - run: swift test
      - run: swift build -c release --product drop
      - name: Real-binary smoke test (ephemeral runner only)
        run: Scripts/smoke.sh .build/release/drop
```

- [ ] **Step 3: Update the README**

Replace the `**Status:**` line in `README.md` with:
````markdown
**Status:** the `drop` CLI works today (Plan 1). The local server, `drop watch`, and the
macOS app are next. See [the design spec](docs/superpowers/specs/2026-10-11-agent-drop-design.md).

## Install (from source)

Requires macOS 14+ and Xcode 16+ (Swift 6).

```bash
git clone https://github.com/MrBenJ/agent-drop.git
cd agent-drop
swift build -c release --product drop
cp .build/release/drop /usr/local/bin/drop   # or anywhere on your PATH
```

## Quick start

```bash
drop add plan.md --from "my-agent" --project my-app -m "Plan for the auth refactor" --handoff
drop inbox --json
drop claim <id> --by "other-agent"
drop cat <id>
drop done <id> --note "shipped in PR #42"
```

Teach your agents with `drop agent-instructions >> CLAUDE.md` (or `AGENTS.md`).

`--from`, `--by`, `--project` and tags are yours to define. Agent Drop never guesses them.
Its only convention is `/` as an optional level separator (`drop list --from-under team`).
````

- [ ] **Step 4: Mark the spec approved**

In `docs/superpowers/specs/2026-10-11-agent-drop-design.md`, change `**Status:** Draft for review` to `**Status:** Approved (2026-10-11)`.

- [ ] **Step 5: Verify**

Run: `swift test && swift build -c release --product drop && Scripts/smoke.sh .build/release/drop`
Expected: all tests pass, the release build succeeds, smoke prints `skipped`.

- [ ] **Step 6: Commit**

```bash
git add Scripts/smoke.sh .github/workflows/ci.yml README.md docs/superpowers/specs/2026-10-11-agent-drop-design.md
git commit -m "chore: real-binary smoke test in CI, README install and quick start"
```

---

## Self-review notes (resolved inline)

- **Spec coverage:** §3 storage/ids/lazy missing → Tasks 3–6. §4 commands → Tasks 9–11 (`watch`, `open` deferred to Plans 2/3 by design). §4.1 → Task 2 + Task 6 (`fromUnder`). §4.2 + kind changes → Tasks 7–8. §5.1 event log, retention, one-row-per-mutation → Tasks 4, 8 Step 5. `read`/`removed` Core APIs exist now for Plan 3. §7 CLI error rows → Tasks 4 (busy, unopenable store), 5 (source errors, empty stdin), 9 (folder creation). §8 → Core tests, in-process CLI tests, smoke tests in CI.
- **Not in this plan (deliberately):** `content` events, server, `server.json`, `setupComplete`/`confirmedFolder` *behavior* (the CLI only reports them in `config show`), app-side reconciliation of unregistered entries.
- **Type consistency:** `Drop`, `DropJSON`, `ListFilter`, `AddRequest`, `EditRequest`, `Retention`, `ConfigStore`, `CLIContext`, `OutputSink`, and `Output` are used with the same names and signatures in every task.
