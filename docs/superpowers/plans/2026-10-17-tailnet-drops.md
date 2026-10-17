# Tailnet Drops (v0.2.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `drop add <path> --to laptop` on another Mac on the same tailnet send a drop to the laptop's Agent Drop. Receiving is opted into only through a Settings toggle. Ship it as v0.2.0, with OpenClaw and Hermes skills.

**Architecture:**
- **Receiver.** A second Hummingbird server (`TailnetServer`), separate from the loopback `HTTPServer`. It binds only the laptop's Tailscale IPv4 on a fixed port and exposes `POST /drops` and `POST /ping`, nothing else.
- **Uploads.** Each upload streams to a staging file, is unpacked (for folders) and validated, then registered through the existing `DropStore.add` path, using a new `.staged` source. `AgentDropService` owns the tailnet listener's lifecycle. The app turns it on via `AppSettings` (UserDefaults), never via `config.json`.
- **Sender.** The `drop` CLI gains named remotes (`remotes.json`) and `drop add --to`. These use a small `TailnetClient`.

**Tech Stack:** Swift 6 / SwiftPM, Hummingbird 2.27, swift-argument-parser, GRDB, swift-testing (`@Test`), SwiftUI.

**Spec:** `docs/superpowers/specs/2026-10-17-tailnet-drops-design.md`. Read it alongside this plan. Section refs (§) point there.

## Global Constraints

- Branch: `feat/tailnet-drops`. Run `swift build` and `swift test` from the repo root before every commit; both must pass.
- Loopback server behavior is unchanged. All existing tests stay green, and only the token comparison changes (to constant time).
- Tailnet port default **47400** (`tailnetPort` in config.json). **No port fallback.**
- Per-drop cap default **200 MB** = `200 * 1024 * 1024` bytes (`tailnetMaxBytes` in config.json). Exceeding it → **413**.
- At most **2** uploads in flight; a 3rd → **503**. Free space after the upload must stay ≥ **1 GB** = `1 << 30` bytes, else **507**.
- Tailnet peers: IPv4 `100.64.0.0/10` only. IPv6 is out of scope for v0.2.0 (my call, allowed by §4.2 "optionally").
- Sender key: 32 random bytes hex (`ServerInfo.newToken()`), in `<configDir>/tailnet.json`, mode 0600. It never rotates on restart and is created only by the Settings toggle.
- `remotes.json` on the sender is mode 0600. `drop remote list` never prints keys.
- The receive toggle lives in UserDefaults key `receiveFromTailnet`. An `allowTailnet` key in config.json is ignored. Neither `drop config show` nor any `drop config set-*` exposes the toggle.
- Error JSON keeps the v0.1 shape `{"error": "...", "status": N}`. CLI exit codes keep the v0.1 conventions (all remote failures are exit 1, except a remote 404 → 2).
- Skills contain no "Ben" or "Aria"; the remote name defaults to `laptop`.
- Version **0.2.0**, with `CFBundleVersion` **3**.

## Review Focus

1. **A connection drops mid-upload.** The staging files are deleted and the in-flight slot is released, so later uploads aren't stuck at 503. → Task 5 test `abortedUploadCleansUpAndFreesTheSlot`.
2. **Tailscale connects after the app starts** (laptop wakes, or Tailscale launches late). The listener appears within one poll interval with no app restart. If Tailscale disconnects, the state becomes `notConnected`. → Task 6 test `listenerFollowsTailscaleComingAndGoing`.
3. **Regenerating the key in Settings** rejects the old key immediately, without a restart. → Task 5 test `regeneratedKeyTakesEffectWithoutRestart`.
4. **Unicode or space-containing names, titles, and descriptions** survive query-string encoding byte for byte (`Q3 plan — draft ✅.md`). → Task 7 test `unicodeNamesAndDescriptionsRoundTrip`.
5. **An empty (0-byte) file and a folder with empty subfolders** send fine. Both exist and look normal. → Task 1 test `emptyFilesAndEmptyFoldersSurvive`, Task 7 test `emptyFileSends`.

---

### Task 1: `DropPack`, the folder wire format

A folder travels as a simple framed stream that only this codebase writes and reads. That's safer and smaller than tar: there are no link types to forget about.

**Files:**
- Create: `Sources/AgentDropCore/DropPack.swift`
- Test: `Tests/AgentDropCoreTests/DropPackTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum DropPack {
      public enum Failure: Error, Equatable { case malformed(String), tooLarge(limit: Int64) }
      /// Rejects (AgentDropError.invalid) a source folder containing anything but regular files and directories.
      public static func write(folder: URL, to output: URL) throws
      /// Unpacks into `destination` (must not exist; created). Total file bytes > maxBytes → .tooLarge.
      public static func unpack(_ pack: URL, into destination: URL, maxBytes: Int64) throws
  }
  ```
- Format:
  - Header: magic `ADPK1\n` (6 bytes).
  - Records: 1 type byte, then a big-endian `UInt32` path byte length, then the UTF-8 relative path (`/`-separated).
    - `d`: a directory.
    - `f`: a file, followed by a big-endian `UInt64` size and that many bytes.
    - `e`: end of stream, with no path.
  - The writer emits records in depth-first sorted order, each directory before its contents.
- Unpack rejects the whole pack, by throwing `.malformed` and removing `destination`, on any of:
  - a bad magic header;
  - an unknown type byte;
  - a truncated record;
  - a missing `e` record, or bytes after it;
  - an empty path, or one starting with `/`;
  - a `.`, `..` or empty path component, or a NUL byte;
  - a duplicate path;
  - a parent directory that wasn't declared by an earlier `d` record (the root is implicit);
  - a path length over 4096.
- Files are created with `O_CREAT | O_EXCL | O_NOFOLLOW`.

- [ ] **Step 1: Write the failing tests** in `DropPackTests`:
  - `roundTripPreservesTreeAndBytes`: a folder with `a.md`, `sub/b.bin` (random 100 KB) and `sub/deeper/c.txt` → write → unpack → the same relative paths and byte-equal contents.
  - `emptyFilesAndEmptyFoldersSurvive`: `empty.txt` (0 bytes) and `hollow/` (an empty dir) both exist after the round trip.
  - `writeRejectsSymlinks`: the source folder contains a symlink → `AgentDropError.invalid`.
  - `@Test(arguments: ["../escape", "/abs", "a/../b", "a//b", "./a", "", "a\u{0}b"])` `unpackRejectsBadPaths(_:)`: a hand-built pack with one `f` record at that path → `.malformed`, and `destination` doesn't exist afterwards.
  - `unpackRejectsUndeclaredParent`: an `f` record `x/y.txt` with no `d x` → `.malformed`.
  - `unpackRejectsDuplicates`, `unpackRejectsTruncation` (drop the last 3 bytes), `unpackRejectsTrailingBytes`, `unpackRejectsUnknownType` (type byte `l`).
  - `unpackEnforcesLimit`: two 600-byte files with `maxBytes: 1000` → `.tooLarge(limit: 1000)`, and `destination` is removed.
  - A test helper `func pack(_ records: [(UInt8, String, Data?)]) -> Data` builds raw packs.

- [ ] **Step 2: Run them and see them fail:** `swift test --filter DropPackTests`. Expected: a compile failure ("cannot find 'DropPack'").

- [ ] **Step 3: Implement `DropPack`.** Stream with `FileHandle` in 64 KB chunks; never load a whole file into memory. Walk the source with `attributesOfItem` (which doesn't follow links), like `FolderListing.walk`.

- [ ] **Step 4: Run them and see them pass:** `swift test --filter DropPackTests`. Expected: all pass.

- [ ] **Step 5: Commit:** `git commit -m "feat(core): DropPack folder wire format"`

---

### Task 2: A staged add source and the tailnet config keys

**Files:**
- Modify: `Sources/AgentDropCore/DropStore+Add.swift`. Add `case staged(URL, isFolder: Bool)` to `AddSource`, handle it in `stage`, and make the staging-directory maker public.
- Modify: `Sources/AgentDropCore/Config.swift`
- Test: `Tests/AgentDropCoreTests/AddTests.swift`, `Tests/AgentDropCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces:
  - `AddSource.staged(URL, isFolder: Bool)`: content already inside this store's `.agentdrop/staging/<uuid>/`, owned by the caller (the caller deletes its staging directory afterwards).
  - `public func makeStagingDirectory() throws -> URL` on `DropStore`. It is the existing private `stagingDirectory()`, renamed and made public, and the internal call sites are updated.
  - `AgentDropConfig.tailnetPort: Int?`, `AgentDropConfig.tailnetMaxBytes: Int64?`, `AgentDropConfig.defaultTailnetPort = 47400`, `AgentDropConfig.defaultTailnetMaxBytes: Int64 = 200 * 1024 * 1024`.
- Rules for `.staged`:
  - `request.name` is required; otherwise `invalid("a staged drop needs a name")`.
  - The name goes through `Validation.dropName`.
  - `move == true` → `invalid`.
  - The URL must resolve to a path under `<folder>/.agentdrop/staging/`; otherwise `invalid`.
  - It returns `.copy(url, isFolder:, name:)`, so placement, collision suffixing, title extraction and the `created` event are all unchanged.

- [ ] **Step 1: Write the failing tests:**
  - `AddTests.stagedFileIsPlacedLikeACopy`: write `# Hello` into `makeStagingDirectory()/content`, call `add(.staged(url, isFolder: false), name: "plan.md", from: "aria")` → `drop.filename == "plan.md"`, `drop.title == "Hello"`, the file exists in the drop folder, and one `created` event.
  - `stagedFolderWorks`, and `stagedNameCollisionGetsSuffix` (an existing `plan.md` → `plan-2.md`).
  - `stagedOutsideStagingIsRejected`: a temp-dir URL → `.invalid`.
  - `stagedWithoutNameIsRejected`, `stagedWithMoveIsRejected`.
  - `ConfigTests.tailnetKeysParse`: `{"tailnetPort": 47555, "tailnetMaxBytes": 1000}` → both read. When they're absent → nil.
  - `ConfigTests.allowTailnetKeyIsIgnored`: `{"allowTailnet": true}` loads, and no property reflects it (assert `AgentDropConfig()` equality, apart from the fields set).

- [ ] **Step 2: Run them and see them fail:** `swift test --filter "AddTests|ConfigTests"`. Expected: a compile failure.

- [ ] **Step 3: Implement it** as specified above. `tailnetMaxBytes` reads as `(dict["tailnetMaxBytes"] as? NSNumber)?.int64Value`, ignoring non-positive values.

- [ ] **Step 4: Run them and see them pass:** `swift test --filter "AddTests|ConfigTests"`, then the full `swift test`.

- [ ] **Step 5: Commit:** `git commit -m "feat(core): staged add source and tailnet config keys"`

---

### Task 3: Shared server plumbing (constant-time compare, a generic error middleware, a generic bind)

**Files:**
- Create: `Sources/AgentDropServer/Secrets.swift`
- Modify: `Sources/AgentDropServer/HTTPAPI.swift` (make `ErrorMiddleware` generic; make `AccessMiddleware` use `Secrets`)
- Modify: `Sources/AgentDropServer/HTTPServer.swift` (extract the bind)
- Modify: `Sources/AgentDropServer/ServerInfo.swift` (extract the private-file write)
- Test: `Tests/AgentDropServerTests/HTTPTests.swift` (the existing tests must stay green), plus a new `Tests/AgentDropServerTests/SecretsTests.swift`

**Interfaces:**
- Produces:
  - `enum Secrets { static func constantTimeEquals(_ a: String, _ b: String) -> Bool }`. It compares UTF-8 bytes without an early exit. A length mismatch returns false, but only after a full pass over the longer input.
  - `struct ErrorMiddleware<Context: RequestContext>: RouterMiddleware`, with the same behavior as today.
  - `struct BoundServer: Sendable { let group: ServiceGroup; let task: Task<Void, Error>; func stop() async }`. This is the current `Running`, plus the 2-second graceful-then-cancel logic moved out of `HTTPServer.stop()`; `HTTPServer.stop()` still closes the hub first.
  - `static func bindServer<Context: RequestContext>(_ router: Router<Context>, host: String, port: Int) async -> BoundServer?` (internal, in `HTTPServer.swift`). `HTTPServer` calls it with `"127.0.0.1"`.
  - `enum PrivateFile { static func write(_ data: Data, to url: URL) throws }`: the 0700-dir / 0600-file temp-then-rename logic from `ServerInfoFile.write`. `ServerInfoFile.write` calls it.

- [ ] **Step 1: Write the failing tests** in `SecretsTests`:
  - `equalStringsMatch`;
  - `@Test(arguments: [("abc","abd"), ("abc","ab"), ("","a"), ("a","")]) differentStringsDoNot`.
- [ ] **Step 2: Run them and see them fail:** `swift test --filter SecretsTests`.
- [ ] **Step 3: Implement it and do the refactors.** `AccessMiddleware` uses `Secrets.constantTimeEquals(request.headers[.authorization] ?? "", "Bearer \(token)")`.
- [ ] **Step 4: Run the full suite:** `swift test`. Expected: everything passes, including the unchanged `HTTPAccessTests` and `ServiceTests`.
- [ ] **Step 5: Commit:** `git commit -m "refactor(server): constant-time token check, shared bind and private-file write"`

---

### Task 4: The sender key file and tailnet identity

**Files:**
- Create: `Sources/AgentDropServer/TailnetKey.swift`, `Sources/AgentDropServer/TailnetIdentity.swift`
- Test: `Tests/AgentDropServerTests/TailnetKeyTests.swift`, `Tests/AgentDropServerTests/TailnetIdentityTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct TailnetKeyFile: Sendable {
      public init(configDir: URL)
      public var url: URL                        // <configDir>/tailnet.json, {"key": "<hex>"}
      public func read() -> String?              // nil when absent or unreadable
      public func create() throws -> String      // existing key if present, else new; via PrivateFile.write
      public func regenerate() throws -> String  // always new
  }
  public struct TailnetIdentity: Sendable, Equatable {
      public var address: String       // e.g. "100.85.64.112"
      public var dnsName: String?      // FQDN, no trailing dot, lowercased: "bens-macbook-pro.tail07da74.ts.net"
      public var preferredHost: String { dnsName ?? address }
      public func allowedHosts(port: Int) -> Set<String>  // "<ip>:<p>", "<fqdn>:<p>", "<short>:<p>", all lowercased
  }
  public enum TailnetAccess {
      public static func isTailnetPeer(_ ipv4: String) -> Bool   // 100.64.0.0/10
  }
  public struct TailnetLocator: Sendable {
      public var locate: @Sendable () async -> TailnetIdentity?
      public init(locate: @escaping @Sendable () async -> TailnetIdentity?)
      public static let live: TailnetLocator
  }
  ```
- `live`:
  - The address is the first IPv4 address in `100.64.0.0/10` from `getifaddrs`.
  - `dnsName` is `Self.DNSName` (trailing `.` stripped) from `tailscale status --json`. That's run with a 3 s timeout from the first executable found among `/usr/local/bin/tailscale`, `/opt/homebrew/bin/tailscale` and `/Applications/Tailscale.app/Contents/MacOS/Tailscale`; it's nil on any failure.
  - It returns nil when no tailnet address is found.

- [ ] **Step 1: Write the failing tests:**
  - `TailnetKeyTests`:
    - `createIsStableAndPrivate`: `create()` twice → the same 64-hex key; the file mode is `0o600`.
    - `regenerateChangesIt`.
    - `readIsNilWhenAbsent`.
  - `TailnetIdentityTests`:
    - `@Test(arguments: ["100.64.0.1", "100.85.64.112", "100.127.255.255"]) tailnetPeers`;
    - `@Test(arguments: ["100.63.255.255", "100.128.0.0", "127.0.0.1", "10.0.0.1", "not-an-ip", ""]) nonTailnetPeers`;
    - `allowedHostsCoversIpFqdnAndShortName`: identity `("100.85.64.112", "bens-macbook-pro.tail07da74.ts.net")`, port 47400 → exactly `{"100.85.64.112:47400", "bens-macbook-pro.tail07da74.ts.net:47400", "bens-macbook-pro:47400"}`;
    - `allowedHostsWithoutDNSIsJustTheIP`.
- [ ] **Step 2: Run them and see them fail:** `swift test --filter "TailnetKeyTests|TailnetIdentityTests"`.
- [ ] **Step 3: Implement it.** Parse IPv4 with `inet_pton`.
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit:** `git commit -m "feat(server): tailnet key file and identity"`

---

### Task 5: `TailnetServer`, the receiving listener

**Files:**
- Create: `Sources/AgentDropServer/TailnetServer.swift` (the server, its request context, its routes, and the upload handler)
- Test: `Tests/AgentDropServerTests/TailnetServerTests.swift`, plus a `TailnetFixture` added to `HTTPSupport.swift`

**Interfaces:**
- Consumes: `DropPack.unpack`, `AddSource.staged`, `DropStore.makeStagingDirectory()`, `ErrorMiddleware`, `bindServer(_:host:port:)`, `TailnetIdentity.allowedHosts`, `Secrets`, `APIError`, `HTTPAPI.json`, and `store.json(_:)`.
- Produces:
  ```swift
  public final class TailnetServer: Sendable {
      public struct PortInUse: Error, Equatable { public let port: Int }
      public struct Limits: Sendable { public var maxBytes: Int64; public var maxInFlight = 2; public var minFreeBytes: Int64 = 1 << 30
                                       public init(maxBytes: Int64) }
      public let port: Int
      public static func start(store: DropStore, bindHost: String, port: Int, identity: TailnetIdentity, limits: Limits,
                               key: @escaping @Sendable () -> String?,
                               peerAllowed: @escaping @Sendable (String) -> Bool = TailnetAccess.isTailnetPeer,
                               freeBytes: @escaping @Sendable (URL) -> Int64? = TailnetServer.volumeFreeBytes)
          async throws -> TailnetServer             // throws PortInUse; never tries another port
      public func stop() async
      public static func volumeFreeBytes(_ url: URL) -> Int64?   // volumeAvailableCapacityForImportantUsage
  }
  ```
  - `struct TailnetRequestContext: RequestContext` stores `peer: String?` from `source.channel.remoteAddress?.ipAddress`.
- Middleware order, applied to every request including unknown routes:
  1. `ErrorMiddleware`.
  2. Peer check: `peerAllowed(peer)`, else 403 "Not a tailnet address".
  3. Host check: `allowedHosts(port:)`, with the same duplicate-Host rule as `AccessMiddleware`; else 403 "Host not allowed".
  4. Key check: `key()` is non-nil and `constantTimeEquals("Bearer \(key)")`, else 401 "missing or invalid key".
- Routes:
  - `POST /ping` → 204, no body.
  - `POST /drops`. Query parameters:
    - `kind` = `file` | `folder` (required);
    - `name` (required);
    - `from` (required);
    - optional: `title`, `desc`, `project`, `tag` (repeatable), `handoff` = `true` | `false`.
    - Unknown parameter → 400 `unknown query parameter '<k>'`; a missing required one → 400.
  - Every other method or path → 404 JSON. That includes `GET /drops`, `GET /events`, and `GET /drops/x/content`.
- Upload sequence:
  1. Claim an in-flight slot (an actor counter); if it's full → 503 "Agent Drop is busy receiving; retry shortly".
  2. If `Content-Length` > `maxBytes` → 413.
  3. If `freeBytes(folder)` minus (`Content-Length` or 0) is below `minFreeBytes` → 507 "Not enough free disk space on the receiving Mac".
  4. Stream `request.body` to `staging/upload`, counting bytes; going over `maxBytes` → 413.
     - For `file`: rename `upload` → `staging/content`.
     - For `folder`: `DropPack.unpack(upload, into: staging/content, maxBytes:)`, then delete `upload`. `.tooLarge` → 413, `.malformed` → 400 `invalid folder upload: <reason>`.
  5. `store.add(AddRequest(source: .staged(content, isFolder:), name:, title:, description: desc, project:, tags:, from:, handoff:))`.
  6. Return 201 with `store.json(drop)`.
  7. **Always** (via `defer`, including on errors and cancellation) release the slot and delete the staging dir.
  - The 413 message: `Drop is larger than the <maxBytes / 1_048_576> MB limit`.
- The key is read through `key()` on every request, so a regeneration applies immediately.

- [ ] **Step 1: Write the failing tests.** `TailnetFixture` starts a `TailnetServer` with:
  - `bindHost: "127.0.0.1"`, port `randomPortBase()` (retry the next port on `PortInUse`, up to 10 times, only in the fixture);
  - identity `("100.100.1.2", "laptop.tail-test.ts.net")`;
  - `peerAllowed: { $0 == "127.0.0.1" }`;
  - a mutable key box;
  - injectable `freeBytes`.

  Use `rawHTTP` for exact headers. Each request sends `Host: laptop.tail-test.ts.net:<port>` and the key unless the test varies them.

  Tests:
  - `pingWithKeyIs204`.
  - `@Test(arguments: ["evil.example:P", "127.0.0.1:P", "laptop.tail-test.ts.net:1", "laptop.tail-test.ts.net.evil:P"]) foreignHostIs403` (substitute P with the port). Also a short-name host `laptop:P` and the IP host `100.100.1.2:P` → 204.
  - `duplicateHostIs403`.
  - `wrongOrMissingKeyIs401`; `noKeyFileMeansEverythingIs401` (the key box returns nil).
  - `nonTailnetPeerIs403`: a fixture with `peerAllowed: { _ in false }` → 403 even with a good key.
  - `@Test(arguments: ["GET /drops", "GET /events", "GET /drops/x", "GET /drops/x/content", "PUT /drops", "DELETE /drops/x"]) readRoutesDoNotExist` → 404.
  - `fileUploadCreatesADrop`: POST `kind=file&name=report.md&from=aria&project=courses-app&tag=a&tag=b&desc=Why&handoff=true`, body `# Report\n` → 201. The JSON has `filename "report.md"`, `title "Report"`, `from "aria"`, `tags ["a","b"]`, `kind "handoff"`, `status "open"`. The store lists it, and an `EventHub` subscription receives a `created` event.
  - `folderUploadCreatesAFolderDrop`: a `DropPack` of a 2-file folder → 201, `isFolder true`, contents equal.
  - `missingOrUnknownQueryIs400`: no `from`; `kind=zip`; `frm=x`.
  - `oversizeByContentLengthIs413` (`maxBytes: 1000`, `Content-Length: 5000`).
  - `oversizeWhileStreamingIs413`: chunked, 1500 bytes, no Content-Length. Also no staging leftovers: `.agentdrop/staging` is empty.
  - `maliciousFolderIs400AndLeavesNothing`: a pack with `../escape` → 400. Nothing is created outside the store, and staging is empty.
  - `lowDiskIs507`: `freeBytes` returns `(1 << 30) + 10`, Content-Length 100 → 507.
  - `thirdConcurrentUploadIs503`:
    - open two raw sockets that send headers plus a partial chunked body and stall;
    - a third POST → 503;
    - finish the two → both 201.
  - `abortedUploadCleansUpAndFreesTheSlot` (Review Focus 1):
    - start two stalled uploads and close their sockets;
    - within 2 s, a new upload succeeds (201) and staging holds only nothing or the in-progress dir.
  - `regeneratedKeyTakesEffectWithoutRestart` (Review Focus 3): swap the key box value → the old key gets 401 and the new one 204.
  - `portInUseThrows`: start the fixture, then start a second server on the same port → `PortInUse(port:)`.
  - Add a `rawHTTPConnection` helper to `HTTPSupport.swift` (open, send part, keep open) for the stall tests.
- [ ] **Step 2: Run them and see them fail:** `swift test --filter TailnetServerTests`.
- [ ] **Step 3: Implement `TailnetServer`.** Unknown routes: make sure Hummingbird's unmatched-route and unmatched-method responses both come out as 404 JSON, going through `ErrorMiddleware` (the existing `unknownRouteIsJSON404` shows the loopback equivalent).
- [ ] **Step 4: Run them and see them pass:** `swift test --filter TailnetServerTests`, then the full `swift test`.
- [ ] **Step 5: Commit:** `git commit -m "feat(server): tailnet receiving listener"`

---

### Task 6: Service lifecycle for the tailnet listener

**Files:**
- Modify: `Sources/AgentDropServer/AgentDropService.swift`
- Create: `Sources/AgentDropServer/TailnetState.swift`
- Test: `Tests/AgentDropServerTests/TailnetServiceTests.swift`

**Interfaces:**
- Consumes: `TailnetServer.start`, `TailnetLocator`, `TailnetKeyFile`, `AgentDropConfig.tailnetPort` / `tailnetMaxBytes`.
- Produces:
  ```swift
  public enum TailnetState: Equatable, Sendable {
      case off                                // toggle off
      case waiting                            // toggle on, service not running (setup/confirmation)
      case notConnected                       // no tailnet address found
      case portInUse(Int)
      case receiving(host: String, port: Int) // host = identity.preferredHost
  }
  // AgentDropService.Options additions:
  public var tailnetLocator: TailnetLocator = .live
  public var tailnetPoll: Duration = .seconds(10)
  public var tailnetBindHost: (@Sendable (TailnetIdentity) -> String)? = nil   // tests: { _ in "127.0.0.1" }
  public var tailnetPeerAllowed: @Sendable (String) -> Bool = TailnetAccess.isTailnetPeer
  public var onTailnetChange: @Sendable (TailnetState) -> Void = { _ in }
  // AgentDropService additions:
  public private(set) var tailnetState: TailnetState    // .off initially
  @discardableResult public func setTailnet(enabled: Bool) async -> TailnetState   // runs `serially`
  ```
- Behavior:
  - The enabled flag is remembered across `stop()` and `start()`.
  - `performStart` brings up the tailnet listener after `bindServer` if the flag is set. `performStop` tears it down and the state becomes `.waiting`, or `.off` if the flag is off.
  - While the flag is on and the service runs, a poll task calls `locate()` every `tailnetPoll`:
    - identity changed → stop and restart the listener;
    - identity became nil → stop it, state `.notConnected`;
    - `portInUse` → retry on the next poll.
  - Port and maxBytes are read from `config.load()` at each (re)bind, falling back to the defaults.
  - `key` reads `TailnetKeyFile(configDir:).read()` per request.
  - Every state change calls `onTailnetChange`.

- [ ] **Step 1: Write the failing tests** (a fake locator backed by a lock-protected `TailnetIdentity?` box, `tailnetPoll: .milliseconds(100)`, bind host 127.0.0.1, `peerAllowed` loopback, and a `tailnetPort` written into the test config as `randomPortBase()`):
  - `offByDefaultNoListener`: start the service → `tailnetState == .off`, and connecting to the tailnet port is refused.
  - `enablingStartsReceiving`: `setTailnet(enabled: true)` → `.receiving(host: "laptop.tail-test.ts.net", port: P)`; ping with the key from `TailnetKeyFile.create()` → 204.
  - `disablingStopsTheListener` → `.off`, connection refused.
  - `enabledBeforeStartWaitsThenReceives`: enable on a stopped service → `.waiting`; `start()` → `.receiving`.
  - `listenerFollowsTailscaleComingAndGoing` (Review Focus 2): locator nil → enable → `.notConnected`; set the identity → within 1 s, `.receiving`; set nil → within 1 s, `.notConnected` and connection refused.
  - `portInUseIsReported`: occupy P with a plain listener first → `.portInUse(P)`.
  - `stopRemovesTailnetListenerAndLoopbackStillWorks`: the existing loopback behavior is intact (the `server.json` port answers `GET /drops`).
  - `remoteDropReachesTheEventStream`: enable, upload through `rawHTTP` → the loopback `/events` stream receives `created`, so the app's notifier path is unchanged.
- [ ] **Step 2: Run them and see them fail:** `swift test --filter TailnetServiceTests`.
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run them and see them pass:** the filter, then the full `swift test` (the existing `ServiceTests` stay green).
- [ ] **Step 5: Commit:** `git commit -m "feat(server): service runs the tailnet listener when enabled"`

---

### Task 7: `TailnetClient`, the sender side

**Files:**
- Create: `Sources/AgentDropServer/TailnetClient.swift`
- Test: `Tests/AgentDropServerTests/TailnetClientTests.swift` (against `TailnetFixture`)

**Interfaces:**
- Consumes: `DropPack.write`.
- Produces:
  ```swift
  public struct TailnetClient: Sendable {
      public struct Remote: Sendable, Equatable, Codable { public var url: URL; public var key: String }
      public enum Payload: Sendable { case file(URL), folder(URL), data(Data) }
      public struct Metadata: Sendable { public var name: String; public var from: String; public var title: String?
          public var desc: String?; public var project: String?; public var tags: [String]; public var handoff: Bool }
      public init(remoteName: String, remote: Remote, session: URLSession = .shared)
      public func send(_ payload: Payload, _ metadata: Metadata) async throws -> Data   // receiver's 201 JSON body
      public func ping() async throws
  }
  ```
- `send`:
  - It POSTs to `<url>/drops` with `Authorization: Bearer <key>` and the §Task 5 query parameters, encoded with `URLComponents.queryItems`.
  - `.file` → `URLSession.upload(for:fromFile:)`. `.folder` → `DropPack.write` to a temp file, upload it, delete it. `.data` → `upload(for:from:)`.
  - The timeout is 300 s.
- Errors are all `AgentDropError`. The message is exact, with `<n>` = remoteName and `<u>` = url:
  - connection refused / cannot connect / timed out / DNS failure → `.invalid("Can't reach '<n>' (<u>). Is that Mac awake, on Tailscale, with Agent Drop running and Tailnet turned on?")`
  - 401 → `.invalid("The key for '<n>' was rejected. It may have been regenerated: run `drop remote add <n> --url <u> --key <new key>` again.")`
  - 413 → `.invalid(<server message>)`, which already states the limit.
  - 404 → `.notFound(<server message>)`.
  - any other non-2xx → `.invalid("'<n>' answered <status>: <server message>")`.

- [ ] **Step 1: Write the failing tests:**
  - `sendsAFileAndReturnsTheDrop`;
  - `sendsAFolder`;
  - `sendsData`;
  - `emptyFileSends` (Review Focus 5) → 201 with a 0-byte file;
  - `unicodeNamesAndDescriptionsRoundTrip` (Review Focus 4): name `Q3 plan — draft ✅.md`, desc `Why & how? 100% — "quoted"`, tag `a+b` → the receiver's drop has exactly those values;
  - `pingSucceeds`;
  - `badKeyMessage` (the exact text above);
  - `unreachableMessage` (a closed port);
  - `tooLargeMessage` contains "MB limit".
- [ ] **Step 2: Run them and see them fail:** `swift test --filter TailnetClientTests`.
- [ ] **Step 3: Implement it.** The fixture's Host must match: the test remote URL is `http://127.0.0.1:<port>`, so the fixture identity for these tests uses address `"127.0.0.1"`. Add an `identity:` parameter to `TailnetFixture`.
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit:** `git commit -m "feat(server): tailnet client"`

---

### Task 8: CLI: `drop remote …` and `drop add --to`

**Files:**
- Create: `Sources/DropCLI/Commands/RemoteCommands.swift`, `Sources/DropCLI/RemotesFile.swift`
- Modify: `Sources/DropCLI/Commands/AddCommand.swift`, `Sources/DropCLI/DropCLI.swift` (subcommands, version untouched until Task 11), `Sources/DropCLI/CLIContext.swift` (add `environment: [String: String]`, defaulting to `ProcessInfo.processInfo.environment` in `live()` and `[:]` in the init default), `Sources/DropCLI/Commands/HumanCommands.swift` (agent-instructions text)
- Modify: `Tests/dropCLITests/TestEnv.swift` (an `environment` var passed through)
- Test: `Tests/dropCLITests/RemoteCommandTests.swift`

**Interfaces:**
- Consumes: `TailnetClient`, and `TailnetFixture`-equivalent setup (start a `TailnetServer` over a scratch `DropStore` in the test).
- Produces:
  - `struct RemotesFile { init(configDir: URL); func load() throws -> [String: TailnetClient.Remote]; func save(_: [String: TailnetClient.Remote]) throws }`. The file is `<configDir>/remotes.json`, shaped `{"remotes": {"<name>": {"url": "...", "key": "..."}}}`, written via `PrivateFile.write`. That helper must be `public` in AgentDropServer; make it public in this task if Task 3 left it internal.
  - `CLIContext.remote(named:) throws -> TailnetClient.Remote`:
    - `"env"` → `AGENT_DROP_REMOTE_URL` + `AGENT_DROP_REMOTE_KEY`, or `.invalid("--to env needs AGENT_DROP_REMOTE_URL and AGENT_DROP_REMOTE_KEY")`;
    - otherwise remotes.json, or `.notFound("No remote named '<n>'. Add it with `drop remote add <n> --url … --key …`")`.
  - Commands:
    - `drop remote add <name> --url <url> --key <key>`:
      - the name matches `^[A-Za-z0-9._-]{1,64}$` and isn't `env`;
      - the URL is `http`/`https` with a host and port;
      - the key is 64 hex characters;
      - it overwrites any existing entry and prints `Saved remote '<name>'`.
    - `drop remote list [--json]`: text `name<TAB>url` per line, sorted; JSON `[{"name","url"}]`, with no keys ever.
    - `drop remote remove <name>`: exit 2 if missing.
    - `drop remote test <name>`: an `AsyncParsableCommand`; prints `'<name>' is reachable and accepted the key.`, or exits with the client's error.
  - `Add` gains `@Option var to: String?`. `Add` becomes an `AsyncParsableCommand` that also conforms to a new `protocol SyncRunnable { func runSync() throws }`. `DropCLI.run` (sync) calls `runSync()` for `SyncRunnable` commands instead of rejecting them, so the existing sync tests keep working.
    - `runSync()` is today's local body, and throws `.invalid("--to needs DropCLI.runAsync")` if `to != nil`.
    - `run() async` → `to == nil ? runSync() : sendRemote()`.
    - `sendRemote`:
      - `--move` → `.invalid("--move can't be used with --to; nothing is deleted on this Mac")`;
      - the payload is the path (file or folder, via `FileManager` `isDirectory`; symlinks rejected), or stdin (requires `--name`, rejects empty);
      - the name is `--name ?? lastPathComponent`;
      - it never opens the local store or reads `config.json`'s folder;
      - output is the drop id (from the response JSON's `id`), or the response JSON verbatim with `--json`.
  - Agent-instructions text gets one added paragraph, always included (my call for §8):
    > **Another Mac on your tailnet.** If `drop remote list` shows a remote, `drop add <path> --to <remote> --from "<identity>" -m "…"` sends the drop to that Mac's Agent Drop instead of this one. Fire-and-forget: you get the id back; you can't read, claim or watch it from here.

- [ ] **Step 1: Write the failing tests** in `RemoteCommandTests`:
  - `addListRemoveRoundTrip`: `remotes.json` mode 0600, `list` hides the key, and `--json` has no `key` field.
  - `@Test(arguments: [["env"], ["bad name"], ...]) remoteAddValidates`: an invalid name, a URL without a port, `ftp://`, a 63-hex key → exit 1.
  - `removeMissingIsExit2`.
  - `addToSendsWithoutLocalSetup`: an empty config dir (no `config.json`, no drop folder), `remote add laptop` pointing at a test `TailnetServer`, `await env.runAsync(["add", "plan.md", "--to", "laptop", "--from", "aria", "-m", "Why", "--json"])` → exit 0, the JSON `from == "aria"`; the receiver store has it; `env.dropFolder` does not exist.
  - `addToFolderAndStdin`.
  - `addToWithMoveIsRejected` (exit 1, the source still exists).
  - `addToUnknownRemoteIsExit2`.
  - `addToEnvRemote`: `environment` set → it works; unset → exit 1 with the message above.
  - `syncRunOfAddToIsRejected`: `env.run("add", …, "--to", "laptop")` → exit 1.
  - `remoteTestReportsReachable` and `remoteTestReportsBadKey`.
  - `agentInstructionsMentionsTo`: the output contains `--to <remote>`.
- [ ] **Step 2: Run them and see them fail:** `swift test --filter RemoteCommandTests`.
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run the full `swift test`.** Expected: all pass, including the 29 existing sync `run("add", …)` tests.
- [ ] **Step 5: Commit:** `git commit -m "feat(cli): drop remote and drop add --to"`

---

### Task 9: App: the Tailnet toggle, its status, and the setup command

**Files:**
- Modify: `Sources/AgentDropApp/AppSettings.swift` (add `receiveFromTailnet: Bool`, UserDefaults key `"receiveFromTailnet"`, default false)
- Modify: `Sources/AgentDropApp/AppModel.swift`
- Modify: `Sources/AgentDrop/Shell/SettingsView.swift` (a Tailnet section after "Local server")
- Test: `Tests/AgentDropAppTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `AgentDropService.setTailnet(enabled:)`, `.tailnetState`, `Options.onTailnetChange`, `TailnetKeyFile`.
- Produces (on `AppModel`):
  ```swift
  public private(set) var tailnetState: TailnetState
  public private(set) var tailnetError: String?
  public func setReceiveFromTailnet(_ on: Bool) async   // on: TailnetKeyFile.create() first (failure → tailnetError, toggle stays off); then settings flag + service
  public func regenerateTailnetKey()                    // TailnetKeyFile.regenerate(); failure → tailnetError
  public var tailnetSetupCommand: String?               // nil unless .receiving and a key exists
  ```
  - `tailnetSetupCommand` is exactly `drop remote add laptop --url http://<host>:<port> --key <key>`.
- At init, `AppModel` calls `service.setTailnet(enabled: settings.receiveFromTailnet)` before any start, so a launch with the toggle on resumes receiving.
- `Applied` gains `tailnetPort: Int?` (and `tailnetMaxBytes: Int64?`) from config, so editing those in `config.json` restarts the service. `onTailnetChange` hops to the main actor and sets `tailnetState`.
- SettingsView "Tailnet" section:
  - `Toggle("Receive drops from my tailnet", …)`;
  - a status line:
    - `.off` → "Off";
    - `.waiting` → "Starts when Agent Drop is serving";
    - `.notConnected` → "Tailscale not connected";
    - `.portInUse(p)` → "Port \(p) is in use";
    - `.receiving(h, p)` → "Receiving on \(h):\(p)";
  - with `.receiving`: buttons **Copy setup command** (`NSPasteboard`) and **Regenerate key**. The latter shows a confirmation alert: "Senders using the old key will stop working until you run the new setup command on them."
  - Show `tailnetError` in red, as `loginItemError` is.
  - Under the toggle, in caption text: "Only devices on your Tailscale network can connect, and they can only send drops — never read them. If the macOS firewall is on, allow Agent Drop when asked."

- [ ] **Step 1: Write the failing tests** in `AppModelTests`, using the existing fixture and service options with a fake locator, a 127.0.0.1 bind and loopback peers (as Task 6):
  - `tailnetOffByDefault`: `tailnetState == .off`; `tailnet.json` doesn't exist.
  - `turningOnCreatesKeyAndReceives`: `await setReceiveFromTailnet(true)` → the key file exists; within 1 s `tailnetState == .receiving(...)`; `settings.receiveFromTailnet == true`; `tailnetSetupCommand` matches `^drop remote add laptop --url http://laptop\.tail-test\.ts\.net:\d+ --key [0-9a-f]{64}$`.
  - `configEditCannotTurnItOn`: write `{"allowTailnet": true, ...}` into config.json, call `configDidChange()` → still `.off`, no key file.
  - `relaunchWithToggleOnResumes`: a new `AppModel` with the same UserDefaults suite → `.receiving` once running.
  - `regenerateChangesTheSetupCommandKey`.
  - `changingTailnetPortInConfigRestarts`: change `tailnetPort` → the state's port follows.
- [ ] **Step 2: Run them and see them fail:** `swift test --filter AppModelTests`.
- [ ] **Step 3: Implement the model, then the view.**
- [ ] **Step 4: Run the full `swift test`, then `Scripts/build-app.sh`.** Expected: tests pass and the app builds. Manually check it: open Settings, toggle on, see the "Receiving on …" line, copy the command.
- [ ] **Step 5: Commit:** `git commit -m "feat(app): Tailnet receive toggle and setup command"`

---

### Task 10: Agent skills and their installer

**Files:**
- Create: `skills/openclaw/agent-drop-send/SKILL.md`, `skills/hermes/agent-drop-send/SKILL.md`, `skills/README.md`
- Create: `Scripts/install-agent-skills.sh` (executable)
- Test: `Tests/dropCLITests/SkillFilesTests.swift`. It reads the files from the repo via `#filePath`, so the skills can't silently drift from the CLI.

**Interfaces:**
- Consumes: the CLI surface from Task 8: `drop add --to`, `drop remote list`, `drop --version`.
- OpenClaw front matter (matching `~/.openclaw/workspace/skills/*/SKILL.md` on the mini):
  ```yaml
  ---
  name: agent-drop-send
  description: Send a finished file or folder (plan, spec, report, screenshot, generated output) to your human's Agent Drop on another Mac over Tailscale. Use when you've produced something they should read or review, or when they ask you to "drop" or "send" it to them.
  ---
  ```
- Hermes front matter: the same `name`/`description`, plus:
  ```yaml
  version: 0.2.0
  platforms: [macos]
  prerequisites:
    commands: [drop]
  metadata:
    hermes:
      tags: [Agent Drop, Handoff, Files, Tailscale]
      homepage: https://github.com/MrBenJ/agent-drop
  ```
- The body is the same for both, with the sections from spec §6:
  1. **Preflight:** `drop --version` ≥ 0.2.0; `drop remote list` shows the remote (default `laptop`; the human can name another).
  2. **When to drop / when not to:** never secrets, `.env` files or keys; never chat replies.
  3. **The command:** `drop add <path> --to laptop --from "<your agent name>" --project "<repo or topic>" -m "<one sentence: what it is and why they're getting it>" --json`, plus `--handoff` only for work they should pick up, and the stdin form with `--name`.
  4. **Fire-and-forget:** after success, tell the human in the current channel that it's in Agent Drop, with the title; don't poll.
  5. **On failure:** relay the CLI's error message verbatim; don't retry in a loop.
- `install-agent-skills.sh [--openclaw] [--hermes] [--dry-run]`:
  - It copies `skills/openclaw/agent-drop-send` to `${OPENCLAW_SKILLS_DIR:-$HOME/.openclaw/workspace/skills}/agent-drop-send`, and `skills/hermes/agent-drop-send` to `${HERMES_SKILLS_DIR:-$HOME/.hermes/skills/productivity}/agent-drop-send`.
  - It replaces an existing copy, and prints each destination.
  - With no flags it prints usage and exits 2.
  - It prints a reminder that the gateways may need a restart to pick up new skills.
  - It uses `set -euo pipefail`.
- `skills/README.md`: what each skill is, the install command, and how to point at a remote name other than `laptop`.

- [ ] **Step 1: Write the failing tests** in `SkillFilesTests`:
  - `bothSkillsExistWithFrontMatter`: each file starts with `---\nname: agent-drop-send\n`;
  - `skillsUseTheRealCLISurface`: each contains `--to laptop`, `--from`, `drop remote list` and `--json`, and doesn't contain `Ben` or `Aria`;
  - `hermesHasPrerequisites`: it contains `commands: [drop]` and `platforms: [macos]`;
  - `installerDryRunPrintsBothDestinations`: run `Scripts/install-agent-skills.sh --openclaw --hermes --dry-run` with `OPENCLAW_SKILLS_DIR` / `HERMES_SKILLS_DIR` set to temp dirs → exit 0, both paths in the output, nothing written;
  - `installerCopies`: the same without `--dry-run` → both `SKILL.md` files exist at the destinations;
  - `installerWithoutFlagsExits2`.
- [ ] **Step 2: Run them and see them fail:** `swift test --filter SkillFilesTests`.
- [ ] **Step 3: Write the skills, the README and the script.**
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit:** `git commit -m "feat(skills): OpenClaw and Hermes agent-drop-send skills with installer"`

---

### Task 11: Docs, version 0.2.0, and the release notes

**Files:**
- Modify: `App/Info.plist` (`CFBundleShortVersionString` → `0.2.0`, `CFBundleVersion` → `3`), `Sources/DropCLI/DropCLI.swift` (`version: "0.2.0"`)
- Create: `docs/releases/v0.2.0.md`, in the same sections as `docs/releases/v0.1.1.md`: "What's new" / "Fixed" (the constant-time token check) / "Install"
- Modify: `README.md`:
  - Status line → v0.2;
  - a new section "Sending drops from another Mac (Tailscale)": the toggle, Copy setup command, `drop remote add`, `drop remote test`, `drop add --to`, the trust model in plain words, and the firewall note;
  - a "Skills for OpenClaw and Hermes" section → `skills/README.md`;
  - `drop remote` in the CLI reference.
- Modify: `docs/superpowers/specs/2026-10-11-agent-drop-design.md`: append to each reversed non-goal (§9 of the new spec) "— revised in v0.2.0, see `2026-10-17-tailnet-drops-design.md`".
- Modify: `docs/manual-test-checklist.md`: a "Tailnet (two Macs)" section covering:
  - toggle on, and see "Receiving on";
  - run the setup command on the second Mac, then `drop remote test`;
  - send a file, a folder and stdin, and get a notification for each;
  - sleep the receiver → the sender gets the "Can't reach" error;
  - regenerate the key → the old sender gets the 401 message;
  - toggle off → refused;
  - `curl http://<host>:47400/drops` from the second Mac with the key → 404 (no reads).
- Test: `Tests/dropCLITests` has a version test if one exists; otherwise the check is `Scripts/package-release.sh`'s consistency check.

- [ ] **Step 1: Bump the versions, then run `swift run drop --version`.** Expected: `0.2.0`.
- [ ] **Step 2: Run `grep -n "0.2.0\|<string>3</string>" App/Info.plist`.** Expected: both lines present.
- [ ] **Step 3: Write the docs listed above.**
- [ ] **Step 4: Run the full `swift test` and `Scripts/build-app.sh`.** Expected: all pass and the app builds.
- [ ] **Step 5: Commit:** `git commit -m "release: v0.2.0 — drops over the tailnet"`

Tagging, publishing the release, installing on the Mac mini, and the spec §7 rollout happen after the branch is reviewed and merged. They're not part of this plan's tasks.
