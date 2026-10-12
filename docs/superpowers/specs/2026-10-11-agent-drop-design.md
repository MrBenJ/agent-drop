# Agent Drop — Design

**Date:** 2026-10-11
**Status:** Draft for review
**Repo:** `MrBenJ/agent-drop` (public, MIT)

## 1. Purpose

Coding agents (Claude Code, Codex, pi, …) routinely produce files meant for someone
else: Markdown specs, plans, handoff notes, reports. Today these land in a plain folder
on the Desktop. That works, but the folder can't say *why* a file exists, *who* made it,
*which project* it belongs to, or *whether anyone has acted on it*.

Agent Drop is a small macOS app + CLI that keeps the folder and adds that missing layer.

**Readers are both humans and agents.** A human browses drops in a window; an agent
picks up handoffs left by another agent. Handoff pickup is a core feature, not an extra.

### Success criteria

- Any agent that can run a shell command can drop, find, read, and claim files with no
  per-agent integration.
- How drops are labeled (`--from`, `--project`, tags) is up to each user; Agent Drop
  imposes no naming convention beyond `/` as an optional level separator (§4.1).
- The human sees new drops at a glance (menu bar unread count, optional notification)
  and can view any Markdown drop rendered, or open it in VS Code, in one click.
- Handoffs have visible status: open, claimed, or done (allowed transitions in §4.2).
- The folder remains a plain folder. Uninstalling the app loses no files.
- The app is small and cheap to leave running.

### Non-goals (v1)

- Sync across machines, sharing between users, or any service reachable beyond
  `127.0.0.1` (the local server in §5 is loopback-only).
- Write endpoints on the local server (v1 is read + events only; writes go through the
  CLI).
- An MCP server (possible later; the CLI is the universal interface).
- Addressing handoffs to a specific recipient agent (`--to`). Can be added later as an
  optional field without breaking anything.
- Editing file contents inside the app.
- Homebrew distribution, code signing, and notarization (v1 ships as build-from-source
  plus a GitHub release zip; packaging is a follow-up).

## 2. Architecture

One repo: a Swift package (`AgentDropCore`, `AgentDropServer`, `drop`) plus an Xcode
project for the app (§9).

| Product | Kind | Responsibility |
|---|---|---|
| `AgentDropCore` | Swift library | Data model, SQLite store, event log, folder operations, id generation, id/filename resolution, transitions, validation. All **domain** logic lives here. |
| `AgentDropServer` | Swift library | HTTP server, SSE, token/`Host` checks, port fallback, `server.json`, and the folder watcher that writes debounced `content` events (§5). All **server** logic lives here. Depends on Core. |
| `drop` | CLI executable | Thin command layer over `AgentDropCore` (swift-argument-parser); uses `AgentDropServer`'s shared wire types for `drop watch`. |
| `AgentDrop.app` | SwiftUI app | UI only: main window + menu bar extra. Reads/writes through `AgentDropCore` and hosts an `AgentDropServer` instance. |

Dependencies: [GRDB.swift](https://github.com/groue/GRDB.swift) (SQLite),
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (CLI),
[swift-cmark](https://github.com/swiftlang/swift-cmark) GFM (Markdown → HTML),
[Hummingbird 2](https://github.com/hummingbird-project/hummingbird) (HTTP server, on SwiftNIO).

**Minimum macOS:** 14 (Sonoma). Needed for `MenuBarExtra`, `SMAppService`, and the
Observation framework.

**Every CLI command except `drop watch` and `drop open` works without the app running.** The CLI and
the app both write directly to the same store. The app watches the folder and store for changes and
refreshes. Agents can hand off to each other with the app closed.

**The app also runs a local server (§5)** that publishes read endpoints and a live
event stream for `drop watch` and other applications. `drop watch` launches the app in
the background if it isn't running.

The app is **not sandboxed**: it must read a user-chosen folder and launch `code`. If
the user points it at a protected location (Desktop, Documents, Downloads), macOS asks
for access the first time the app touches it; the app explains why before triggering
the prompt.

**First-run setup** happens in the app's window: folder confirmation (and any macOS
access prompt) plus the launch-at-login question (§6). Finishing it writes
`"setupComplete": true` to `config.json`. Until then neither the server nor the content
watcher runs (§5.2), so `drop watch` always exits 1 (there is no server to connect to;
§4 Watching). Other CLI commands work
before setup; they run under the terminal's own file access.

**Before setup is complete, the app does not touch the drop folder at all:** no
reconciliation, no folder creation, no FSEvents watching, no rendering, no server. It
reads only `config.json` (Application Support, no permission needed).
- Any launch before setup (Dock, login item, `drop open`, `agentdrop://` link) shows the
  setup window first.
- Setup shows the folder actually configured (which the CLI may have changed). If it is
  in a protected location, setup explains the macOS prompt and only then touches the
  folder; for an unprotected folder (e.g. the default `~/AgentDrop`) there is no prompt
  to explain.
- A `drop open <id>` received before setup is remembered; when setup completes, the app
  navigates to that drop.

## 3. Storage

### Drop folder

- Default: `~/AgentDrop` (no macOS permission prompt). Users who want it on the Desktop
  set it with `drop config set-folder ~/Desktop/AgentDrop`.
- The folder path has **one source of truth**:
  `~/Library/Application Support/AgentDrop/config.json`, read by both the app and the
  CLI. If the file is absent, both use the default. There is no environment-variable
  override.
- Changed from the app's Settings or with `drop config set-folder <path>`. The app
  watches `config.json` and switches immediately when the CLI changes it.
- Switching folders moves nothing. The old folder keeps its files and its own
  `.agentdrop/` store; switching back restores it.
- Created on first use by either the CLI or the app.
- **A drop is one top-level entry** of the folder: either a regular file or a
  directory (a *folder drop*). Entries whose names start with `.` are ignored.
- Everything inside a folder drop belongs to that drop; nested files are never drops
  of their own.
- Symlinks are not drops: `drop add` rejects them, and reconciliation ignores them.

### Metadata store

- `<drop folder>/.agentdrop/index.sqlite`, so metadata travels with the folder.
- WAL mode, busy timeout of 5 s, so concurrent CLI invocations and the app coexist.
- Schema version tracked with `PRAGMA user_version`; migrations run in
  `AgentDropCore` on open.

### Data model: `drop`

| Field | Type | Notes |
|---|---|---|
| `id` | text, PK | 6-char short id, see §3.1 |
| `filename` | text, unique | Name of the top-level file or directory in the drop folder |
| `is_folder` | bool | `true` for a folder drop |
| `title` | text | Defaults to the first Markdown `# heading` (for a folder drop: of its `README.md`, else its first `.md` alphabetically), else the filename without extension |
| `description` | text, nullable | The why / context |
| `project` | text, nullable | Free-form (see §4.1), e.g. `courses-app` |
| `tags` | separate `drop_tag(drop_id, tag)` table | Lowercased, trimmed |
| `from` | text | Free-form identity of whoever dropped it (see §4.1), e.g. `djleague/build-feature-x` |
| `created_at` | timestamp | |
| `updated_at` | timestamp | |
| `read_at` | timestamp, nullable | Set only by the app when a human views the drop |
| `kind` | `note` \| `handoff` | |
| `status` | `open` \| `claimed` \| `done`, nullable | Non-null iff `kind = handoff` |
| `claimed_by` | text, nullable | Free-form identity of the claimer (see §4.1) |
| `status_note` | text, nullable | e.g. "shipped in PR #42" |
| `archived` | bool | Hidden from default lists |
| `missing` | bool | File no longer present on disk |

### 3.1 Ids

- 6 random characters from a 32-character alphabet: `a–z` and `2–9`, excluding `o`
  and `l` (no `0/o` or `1/l` confusion). ~1.07 billion values.
- Collision checked at insert; regenerate on clash.
- Anywhere an `<id>` is accepted, the CLI also accepts an exact **filename**
  (`auth-plan.md`). Ids are always matched in full; there is no prefix matching.

### 3.2 Folder reconciliation

After setup is complete (§2), the app watches the folder with FSEvents (and reconciles on launch):

- **Top-level file or directory with no record** → shown as *unregistered*, with a one-click "Register" that
  opens a small form (title, description, from, project, tags, kind). An agent can also
  register it later with `drop add <path-in-folder>`.
- **Record whose file or directory is gone** → `missing = true`; shown greyed out with a
  "Remove record" action. Never silently deleted.
- **File or directory renamed in Finder** → treated as missing + unregistered (no rename tracking in
  v1).

The CLI performs the same missing-file check lazily when it resolves an id.

## 4. The `drop` CLI

### Global rules

- Never prompts interactively.
- `--json` is accepted on every command except those that print raw file contents
  (`drop cat`, `drop latest --cat`), where it exits 1. Elsewhere it produces
  machine-readable output on stdout.
- Exit codes: `0` ok · `1` error (including bad input, ambiguous id, wrong kind) ·
  `2` not found · `3` conflict (e.g. handoff already claimed).
- Human-readable output is the default. In human-readable mode errors go to stderr; with
  `--json`, errors are printed to stdout as JSON (shape below) and nothing goes to
  stderr.

### Terms

- **Inbox** always means handoffs with status `open` that are **not archived and not
  missing**, in the CLI (`drop inbox`), the server, and the app alike.
- **All Drops** is the app's view of every non-archived drop.
- **Unread** = `read_at IS NULL` **and** not archived **and** not missing. One
  definition in `AgentDropCore`, used by `drop list --unread` (even with `--all`), the
  server's `unread` filter, and the menu bar badge. Only viewing a drop in the app sets
  `read_at`; CLI reads (`drop cat`) never do. Unregistered entries are not drops and
  never count as unread.

### 4.1 Identity fields: `--from`, `--by`, `--project`

The CLI **never guesses or fills in** these values: no git-repo inference, no
environment-variable detection. A value is stored only if it was passed explicitly.

- **They belong to the user.** The meaning of these values is up to each user (or their
  harness). Agent Drop applies exactly one rule: `/` separates levels (below). Values
  without `/` are a flat list and are never touched. Nothing else about a value is
  interpreted, and exact-match filters (`--from`, `--project`) always compare the whole
  string.
- **Rules:** non-empty, leading/trailing whitespace trimmed, no newlines or control
  characters, at most 200 characters. Spaces, slashes, brackets, etc. are allowed.
- **`/` is the one documented convention: a level separator.** If values contain `/`, the app shows them
  as a collapsible tree and `--from-under <prefix>` matches the prefix itself and
  everything beneath it (`--from-under djleague` matches `djleague` and
  `djleague/autodev/…`, but not `djleague2`). Values without `/` are simply a flat list.
- **`--from`** is required on `drop add`. **`--by`** is required on `drop claim`.
  **`--project`** is always optional; omitted means no project.

*Example convention (one user's setup, not a requirement):* a harness integration
passes `workspace/tab`, or `workspace/space/tab` for sub-workspaces, e.g.
`djleague/build-feature-x` or `djleague/autodev/AutoDev DJ-1234 [ef013ae]`.

### Commands

**Dropping**

| Command | Behavior |
|---|---|
| `drop add <path> [flags]` | Copies the file, or the directory recursively, into the drop folder and registers it; prints the id. If `<path>` is already a top-level entry of the drop folder, registers in place; with `--name`, the entry is first renamed to that name (name rule applies; name taken → exit 3). Any other path inside the drop folder (inside a subdirectory) → exit 1. Symlink → exit 1. Optional `--name <name>` sets the drop's top-level name (default: the source's basename). **Name rule** (also for `drop add -`): the resulting name must not start with `.`, be empty, contain `/`, or be `.`/`..` → exit 1, suggesting `--name`. Name collision → suffix (`plan-2.md`). Flags: `--title`, `-m/--desc`, `--project`, `--tag <t>` (repeatable), `--from` (required), `--name`, `--handoff` (sets `kind=handoff`, `status=open`), `--move` (move instead of copy). Re-adding an already-registered entry → exit 3. |
| `drop add - --name <filename> [flags]` | Same, reading content from stdin (always a file drop). `--name` required; same name rule. |
| `drop edit <id> [flags]` | Updates metadata: `--title`, `-m/--desc`, `--project`, `--tag <t>`, `--untag <t>`, `--kind note\|handoff`. Kind changes follow §4.2 ("Changing kind"). |
| `drop archive <id>` | Sets `archived=true`. `drop archive --undo <id>` reverses it. The file is untouched. |

**Finding and reading**

| Command | Behavior |
|---|---|
| `drop list [filters]` | Newest first. The only defaults are: archived drops excluded (use `--all`) and `--limit 50`; no other filter applies unless passed. `latest` and `GET /drops` share these defaults. Filters: `--project`, `--tag`, `--from`, `--from-under`, `--handoffs`, `--status open\|claimed\|done`, `--unread` (see Terms), `--limit <n>`, `--all` (include archived). |
| `drop show <id>` | Metadata plus absolute path. |
| `drop cat <id>` | File contents to stdout. Does **not** set `read_at` (that's for humans). |
| `drop path <id>` | Absolute path only. |
| `drop latest [filters] [--cat]` | Newest match from the same filters as `list`; prints like `show`, or raw contents with `--cat`. `--cat` with `--json` → exit 1 ("use one or the other"). Exit 2 if none. |

**Handoffs**

| Command | Behavior |
|---|---|
| `drop inbox [--project <p>]` | The Inbox (§4 Terms: open, not archived, not missing), optionally narrowed to one project. |
| `drop claim <id> --by <identity>` | See §4.2. |
| `drop release <id>` | See §4.2. |
| `drop done <id> [--note "…"]` | See §4.2. |
| `drop reopen <id>` | See §4.2. |

**Watching**

| Command | Behavior |
|---|---|
| `drop watch <id> [--once] [--json]` | Subscribes to events for one drop (§5.3). Prints one line per event (one JSON object per line with `--json`) until interrupted. Ends with exit 0 after a `missing` or `removed` event. `--once`: exits 0 after the first event. |
| `drop watch --inbox [--project <p>] [--once] [--json]` | Subscribes to handoffs entering the Inbox (§5.3), optionally for one project. |

`drop watch` first checks `setupComplete` in `config.json`; if it isn't `true`, it exits 1
immediately: "Agent Drop hasn't been set up yet. Open the Agent Drop app once to finish
setup." Otherwise it reads `server.json` (§5.2). If it says `no-port`, it exits 1 with that
reason. If the app isn't running, it launches it **without
opening its window** and waits up to 10 s for the server. Server unreachable after that
→ exit 1. Unknown id → exit 2.

"Without opening its window" is not invisible: the menu bar icon appears as on any
launch, so the user can always see the app is running and quit it. The app **keeps
running** after the watch ends. Reason: it behaves like any Mac app: once launched, it
runs until quit. It is always visible in the menu bar, so the user can see it and quit
it. Quitting automatically when watchers leave would cut off other server clients and
stop `content` events (§5.1). The launch-at-login setting controls only whether it
starts at login.

**Human and setup**

| Command | Behavior |
|---|---|
| `drop open <id>` | Opens `agentdrop://drop/<id>` → the app shows that drop's rendered view (launching the app if needed). |
| `drop code <id>` | Runs `code <absolute path>`. If `code` isn't on PATH → exit 1 with a hint. |
| `drop where` | Prints the drop folder path in use. |
| `drop config set-folder <path>` | Sets the drop folder in `config.json` (creating the folder if needed). |
| `drop config set-retention <days\|forever>` | Sets `eventRetentionDays` (§5.1). `days` is a whole number ≥ 1; anything else → exit 1. |
| `drop config show` | Prints every `config.json` setting: folder, event retention, server port, setup status. |
| `drop agent-instructions` | Prints a Markdown snippet for `CLAUDE.md` / `AGENTS.md` teaching an agent when and how to use `drop` (dropping with context, checking `drop inbox`, claim → done). It tells the agent to pass whatever identity its harness provides as `--from`/`--by`, and shows quoting for values with spaces. |

### 4.2 Handoff transitions

`open`, `claimed`, and `done` are states, not a strict sequence. These are the only
legal transitions; the CLI and app share one implementation in `AgentDropCore`.

| CLI | App button | From → To | Effect |
|---|---|---|---|
| `drop claim <id> --by X` | (none) | `open → claimed` | Sets `claimed_by` |
| `drop release <id>` | Release | `claimed → open` | Clears `claimed_by` |
| `drop done <id> [--note]` | Mark done | `open → done`, `claimed → done` | Sets `status_note` if given |
| `drop reopen <id>` | Reopen | `done → open` | Clears `claimed_by` and `status_note` |

- Each transition is a single conditional update (`UPDATE … WHERE status = <from>`), so
  concurrent claims can't both succeed.
- Any other transition → exit 3, with the current state in the message (e.g.
  `k7f2qa is claimed by djleague/build-feature-x`). There is no `--force`; taking over
  a stale claim is `release` then `claim`.
- Any transition on a `note` → exit 1.
- `done` is permanent until explicitly reopened. Nothing auto-archives.

**Changing kind** (`drop edit --kind`, or the app's edit form):

| Current | Change | Result |
|---|---|---|
| note | `--kind handoff` | Handoff with `status = open` |
| handoff, `open` | `--kind note` | Note; status fields cleared |
| handoff, `claimed` | either | Exit 3: "…is claimed by …; release it first" |
| handoff, `done` | either | Exit 3: "…is done; reopen it first" |

The check is part of the conditional update, like the transitions above. A kind change
emits one `metadata` event with `{kind, status}`. In the app, the kind picker is
disabled (with a tooltip) while a handoff is claimed or done.

### JSON shape

`show`, `add`, `latest`, `claim`, `release`, `done`, `reopen`, `edit`, `archive` return one drop
object; `list` and `inbox` return an array of them:

```json
{
  "id": "k7f2qa",
  "filename": "auth-plan.md",
  "path": "/Users/me/AgentDrop/auth-plan.md",
  "title": "Auth refactor plan",
  "description": "Plan for moving sessions to cookies; Codex should implement.",
  "project": "courses-app",
  "tags": ["spec", "handoff"],
  "from": "djleague/build-feature-x",
  "kind": "handoff",
  "status": "open",
  "claimedBy": null,
  "statusNote": null,
  "createdAt": "2026-10-11T18:44:00Z",
  "updatedAt": "2026-10-11T18:44:00Z",
  "readAt": null,
  "archived": false,
  "isFolder": false,
  "missing": false
}
```

Errors with `--json` print `{"error": "<message>", "code": <exit code>}` to stdout.

## 5. Local server & events

### 5.1 Event log

- Every mutation, from the CLI or the app, appends one row to an `event` table in the
  same SQLite transaction as the change:
  `seq` (integer, autoincrement) · `type` · `drop_id` · `at` · `data` (JSON) ·
  `inbox_before` · `inbox_after` (bool) · `project_before` · `project_after`. The
  before/after columns let the server filter Inbox arrivals exactly, live and on
  `Last-Event-ID` replay alike (§5.3).
- `content` events are written by `AgentDropServer`'s folder watcher (running in the app) when FSEvents reports a change to a drop's
  file (or anything inside a folder drop), debounced per drop (300 ms of quiet). Content
  changes made while the app isn't running produce no event.
- **Retention (disclosed, configurable).** `eventRetentionDays` in `config.json`:
  a number of days (default `30`) or `"forever"`. When it is a number, every transaction
  that appends an event row (mutations **and** `content` events) also deletes event rows
  older than that (`DELETE FROM event WHERE at < …`,
  indexed on `at`). No timer runs. Because cleanup rides on writes, events are kept for
  **at least** the retention period; with no writes, older rows can remain until the
  next one. `"forever"` disables cleanup and the log grows without limit. An invalid
  value in `config.json` (not a whole number ≥ 1 or `"forever"`) is treated as `30`, and
  both the app (banner) and `drop config show` (warning) say so.
- **Cleanup only ever deletes event-log rows.** Drops, their files, and their metadata
  are never deleted by it.
- Disclosure: the app's Settings → Event history shows the current value, with presets
  (7 / 30 / 90 days / Forever) and a **Custom…** field accepting any whole number of
  days ≥ 1 (same rule as the CLI), so any value set from the CLI is displayed as-is. It carries the note "Old entries in the change log are deleted as new changes come
  in. Your drops and files are never deleted." `drop config show` prints it. The README
  documents it under "What Agent Drop stores and deletes".

| `type` | Emitted when | `data` |
|---|---|---|
| `created` | A drop is registered | the drop object |
| `content` | The drop's file / folder contents changed | `{}` |
| `metadata` | `drop edit` or the app's edit form changed metadata | changed fields |
| `status` | Any §4.2 transition | `{from, to, claimedBy, statusNote}` |
| `archived` | Archived or un-archived | `{archived}` |
| `missing` | The drop's file / folder disappeared | `{}` |
| `read` | A human views the drop in the app for the first time (`read_at` goes from null to set; never re-emitted) | `{readAt}` |
| `removed` | The record is deleted via **Remove record** (§3.2) | `{}` |

### 5.2 Server

- Implemented in `AgentDropServer` and hosted by the app. Two parts, each with one rule:

  | Part | Runs when |
  |---|---|
  | **Content watcher** (writes `content` events, §5.1) | App running **and** setup complete |
  | **Server** (HTTP + SSE) | App running **and** setup complete **and** a port was bound |

  Both start the moment setup completes and keep running with the window closed. If no
  port is available, the content watcher still runs (clients catch up via
  `Last-Event-ID` later) and the app shows a banner with **Retry**, which re-attempts
  the port range.
- HTTP on `127.0.0.1` only.
- Port: `47390` by default, configurable in `config.json`. If it is taken, the app tries
  the next 9 ports.
- On start, the app writes `~/Library/Application Support/AgentDrop/server.json`
  (permissions `0600`): `{ "status": "running", "port": …, "token": "…", "pid": … }`.
  A new random token is generated each start. If no port could be bound, it writes
  `{ "status": "no-port", "pid": … }` instead (updated if **Retry** succeeds). Before
  setup is complete no `server.json` is written. The file is removed on clean quit.
  `drop watch` treats a `server.json` whose `pid` is not a live process as "app not
  running".
- Every request requires `Authorization: Bearer <token>`. Requests whose `Host` header
  is not `127.0.0.1:<port>` or `localhost:<port>` are rejected. (A web page in the
  user's browser can reach localhost; the token and `Host` check stop it.)

### 5.3 Endpoints (v1: read + events only)

| Endpoint | Returns |
|---|---|
| `GET /drops` | Array of drop objects. Accepts the same filters as `drop list` as query params. |
| `GET /drops/:id` | One drop object (id or exact filename). |
| `GET /drops/:id/content` | The file's bytes; for a folder drop, a JSON file listing. |
| `GET /events` | Server-sent events for all drops. |
| `GET /events?drop=:id` | Events for one drop. |
| `GET /events?inbox[&project=:p]` | **Arrivals only:** any event after which the drop is in the Inbox (§4 Terms), scoped to project `p` if given, when it was not before — whatever caused it (created, kind change, release, reopen, un-archive, project change into `p`, …). Departures (e.g. claimed by someone else) are not delivered. |

- Each store has a random `storeId`, generated when the store is created and kept in
  it. Each SSE message: `id: <storeId>:<seq>`, `event: <type>`,
  `data: {"storeId", "seq", "type", "dropId", "at", "data"}`.
- **Resume within one store:** clients reconnect with `Last-Event-ID` and receive every
  event of that store with a larger `seq` that matches their filter, back to the
  retention limit (§5.1).
- **Folder switch = clean break:** switching the drop folder restarts the server (open
  streams closed, new token, `server.json` rewritten). A client reconnecting with a
  `Last-Event-ID` from a different `storeId` first receives one `reset` event
  (`data: {"reason": "drop folder changed"}`), then live events from that point; no
  history from the old store is replayed.
- `drop watch <id>` reconnects automatically; if the id isn't in the new store it exits
  2 ("drop folder changed; <id> is not in the current folder"). `drop watch --inbox`
  prints the `reset` and continues on the new folder's Inbox.
- Errors: `{"error": "<message>", "status": <HTTP status>}` with HTTP 400 / 401 / 403 / 404.
  (Distinct from the CLI's `code`, which is an exit code.)

## 6. The app (draft — to be refined)

### Shape

- A regular app with a Dock icon and a main window, **plus** a menu bar extra that is
  always present while the app runs.
- Closing the main window does not quit the app; the menu bar keeps running.
- Setting: **Hide Dock icon** (switches activation policy to accessory).
- Setting: **Launch at login** (via `SMAppService`). During first-run setup (§2) the app asks once:
  "Start Agent Drop at login? Agents and apps that watch for changes need it running",
  with **Yes** pre-selected; afterwards it's an ordinary setting. Reason: the local
  server (§5.2) and `content` events (§5.1) exist only while the app runs (after setup), and other
  applications can't launch it the way `drop watch` does. Idle cost is a file watcher
  plus a listening socket; nothing polls.
- Setting: **Notify on new drops** (via `UserNotifications`), default on. Clicking a
  notification opens that drop.

### Menu bar extra

- Icon with an unread badge count (Unread as defined in §4 Terms). Unregistered entries
  are not in the badge; they get their own count beside **Unregistered** in the sidebar.
- Dropdown: the 10 most recent drops (title, project, from, relative time, unread dot),
  then a separate **Inbox** section (open handoffs), then *Open Agent Drop* / *Settings* /
  *Quit*.
- Clicking a drop opens the main window to it.

### Main window

Three-column `NavigationSplitView`:

1. **Sidebar:** All Drops (everything not archived, newest first, unread marked; the
   default view) · Inbox (open handoffs, with count; same set as `drop inbox`) ·
   Handoffs (grouped open / claimed / done) ·
   Unregistered · Archived · then Projects, Tags, and From as filter lists (From and
   Projects shown as a tree when values contain `/`, see §4.1).
2. **List:** title, project, from, tags, relative time, unread dot, handoff status
   pill. Search field filters title, description, and filename.
3. **Detail:** metadata header (description, project, tags, from, claimed by, timestamps, handoff
   status, status note), action buttons, then the file preview.

Viewing a drop in the detail pane sets `read_at`.

### Actions in the detail pane

- **View rendered** (default preview for `.md`).
- **Open in VS Code** (`code <path>`; disabled with a tooltip if `code` isn't found).
- **Reveal in Finder**.
- **Copy path** and **Copy `drop cat <id>`** (handy for pasting into an agent).
- Handoffs: **Release** / **Mark done** / **Reopen**, which call the same `AgentDropCore`
  transitions as the CLI (§4.2). Humans do not claim from the app.
- **Edit metadata**, **Archive**.

### Rendering

- Markdown: GFM via swift-cmark → HTML, displayed in a `WKWebView` with bundled CSS
  that follows light/dark mode. Relative links and images resolve against the rendered file's own directory (for a
  folder drop's README, the folder drop itself).
  Links open in the default browser. JavaScript in the rendered content is disabled.
- Plain text / code files: monospace text view.
- Everything else (images, PDFs, …): Quick Look preview (`QLPreviewView`).
- Folder drops: a file tree of the drop's contents above the rendered `README.md` (or
  first `.md` alphabetically) if one exists. Selecting a file in the tree previews it
  using the rules above. **Open in VS Code** opens the directory as a workspace.

## 7. Error handling

- Store can't be opened (corrupt / unreadable): CLI exits 1 with the path and the
  underlying error; app shows a banner with *Reveal in Finder*. Never auto-deletes the
  store.
- Drop folder missing: recreated by CLI or app on next use.
- Busy database beyond the 5 s timeout: exit 1 with "store busy, retry".
- Source path for `drop add` doesn't exist: exit 2. Exists but isn't a regular file or
  directory (symlink, socket, device, …): exit 1.
- `drop add -` with empty stdin: exit 1.
- Server port range exhausted: the app shows a banner with **Retry** and keeps running
  without the server (the content watcher still runs, §5.2); `drop watch` exits 1 with
  that reason.
- Server request without a valid token → HTTP 401; with a `Host` outside the §5.2
  allowlist → HTTP 403.

## 8. Testing

- **`AgentDropCore`** (XCTest/Swift Testing): store CRUD, migrations, id generation and
  id/filename resolution, claim atomicity under concurrent writers, reconciliation
  (unregistered / missing), identity-field validation and `--from-under` matching. Each test uses a temp
  directory.
- **Path injection, not overrides:** `AgentDropCore` takes its config directory as a
  parameter. The shipped CLI and app always pass
  `~/Library/Application Support/AgentDrop/`; tests pass a temp directory. The shipped
  binary has no path override of any kind (§3).
- **`drop` CLI** (`dropCLITests`): commands run in-process via swift-argument-parser
  with injected paths, asserting stdout (`--json`), stderr, and exit codes for every
  command, including the handoff lifecycle end-to-end.
- **Real-binary smoke tests**: run only in CI on ephemeral GitHub Actions macOS runners,
  against the real default paths. A guard skips them outside CI so they can never touch
  a developer's real `~/AgentDrop`.
- **Event log**: every mutation writes exactly one event row in the same transaction;
  `seq` is strictly increasing; retention cleanup deletes only expired event rows (never
  drops) and is skipped with `"forever"`.
- **`AgentDropServerTests`** (server started in-process against a temp store): token and `Host` checks, each
  endpoint, SSE delivery for each event type, `Last-Event-ID` resume, `reset` on a
  `storeId` mismatch after a folder switch, content
  debouncing, inbox filtering. (`drop watch` end-to-end tests live in `dropCLITests`,
  against an in-process server.)
- **App**: view models unit-tested against a temp store; UI verified manually against a
  checklist (menu bar count, notification, rendered view, VS Code open, unregistered
  register flow).

## 9. Repo layout

```
agent-drop/
├── Package.swift                 # AgentDropCore, AgentDropServer, drop CLI
├── Sources/
│   ├── AgentDropCore/
│   ├── AgentDropServer/
│   └── drop/
├── Tests/
│   ├── AgentDropCoreTests/
│   ├── AgentDropServerTests/
│   └── dropCLITests/        # incl. `drop watch` end-to-end against an in-process server
├── App/                          # Xcode project for AgentDrop.app (depends on the package)
├── docs/superpowers/specs/
├── LICENSE                       # MIT
└── README.md
```
