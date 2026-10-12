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
  imposes no naming convention.
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

One repo, one Swift package workspace, three products:

| Product | Kind | Responsibility |
|---|---|---|
| `AgentDropCore` | Swift library | Data model, SQLite store, folder operations, id generation, id/filename resolution. All logic lives here. |
| `drop` | CLI executable | Thin command layer over `AgentDropCore` (swift-argument-parser). |
| `AgentDrop.app` | SwiftUI app | Main window + menu bar extra. Reads/writes through `AgentDropCore`. |

Dependencies: [GRDB.swift](https://github.com/groue/GRDB.swift) (SQLite),
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (CLI),
[swift-cmark](https://github.com/swiftlang/swift-cmark) GFM (Markdown → HTML).

**Minimum macOS:** 14 (Sonoma). Needed for `MenuBarExtra`, `SMAppService`, and the
Observation framework.

**Every CLI command except `drop watch` works without the app running.** Both write
directly to the same store. The app watches the folder and store for changes and
refreshes. Agents can hand off to each other with the app closed.

**The app also runs a local server (§5)** that publishes read endpoints and a live
event stream for `drop watch` and other applications. `drop watch` launches the app in
the background if it isn't running.

The app is **not sandboxed**: it must read a user-chosen folder (default on the
Desktop) and launch `code`. On first launch macOS will ask for Desktop folder access;
the app explains why before triggering the prompt.

## 3. Storage

### Drop folder

- Default: `~/Desktop/AgentDrop`.
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

The app watches the folder with FSEvents (and reconciles on launch):

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
- `--json` on every command produces machine-readable output on stdout.
- Exit codes: `0` ok · `1` error (including bad input, ambiguous id, wrong kind) ·
  `2` not found · `3` conflict (e.g. handoff already claimed).
- Human-readable output is the default; errors go to stderr.

### Terms

- **Inbox** always means *open handoffs*, in the CLI (`drop inbox`) and the app alike.
- **All Drops** is the app's view of every non-archived drop.
- **Unread** = `read_at IS NULL` **and** not archived **and** not missing. One
  definition in `AgentDropCore`, used by `drop list --unread` (even with `--all`), the
  server's `unread` filter, and the menu bar badge. Only viewing a drop in the app sets
  `read_at`; CLI reads (`drop cat`) never do. Unregistered entries are not drops and
  never count as unread.

### 4.1 Identity fields: `--from`, `--by`, `--project`

The CLI **never guesses or fills in** these values: no git-repo inference, no
environment-variable detection. A value is stored only if it was passed explicitly.

- **They belong to the user.** Agent Drop stores and filters them and never interprets
  them. Each user (or their harness) decides what goes in them.
- **Rules:** non-empty, leading/trailing whitespace trimmed, no newlines or control
  characters, at most 200 characters. Spaces, slashes, brackets, etc. are allowed.
- **`/` is an optional grouping separator.** If values contain `/`, the app shows them
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
| `drop add <path> [flags]` | Copies the file, or the directory recursively, into the drop folder and registers it; prints the id. If `<path>` is already a top-level entry of the drop folder, registers in place. Any other path inside the drop folder (inside a subdirectory, or a dotfile) → exit 1. Symlink → exit 1. Name collision → suffix (`plan-2.md`). Flags: `--title`, `-m/--desc`, `--project`, `--tag <t>` (repeatable), `--from` (required), `--handoff` (sets `kind=handoff`, `status=open`), `--move` (move instead of copy). Re-adding an already-registered entry → exit 3. |
| `drop add - --name <filename> [flags]` | Same, reading content from stdin (always a file drop). `--name` required. |
| `drop edit <id> [flags]` | Updates metadata: `--title`, `-m/--desc`, `--project`, `--tag <t>`, `--untag <t>`, `--kind note\|handoff`. Changing to `handoff` sets `status=open`; changing to `note` clears status fields. |
| `drop archive <id>` | Sets `archived=true`. `drop archive --undo <id>` reverses it. The file is untouched. |

**Finding and reading**

| Command | Behavior |
|---|---|
| `drop list [filters]` | Newest first, default `--limit 50`, archived excluded. No filters are applied unless passed. Filters: `--project`, `--tag`, `--from`, `--from-under`, `--handoffs`, `--status open\|claimed\|done`, `--unread` (see Terms), `--limit <n>`, `--all` (include archived). |
| `drop show <id>` | Metadata plus absolute path. |
| `drop cat <id>` | File contents to stdout. Does **not** set `read_at` (that's for humans). |
| `drop path <id>` | Absolute path only. |
| `drop latest [filters] [--cat]` | Newest match from the same filters as `list`; prints like `show`, or contents with `--cat`. Exit 2 if none. |

**Handoffs**

| Command | Behavior |
|---|---|
| `drop inbox [--project <p>]` | All open handoffs, optionally narrowed to one project. |
| `drop claim <id> --by <identity>` | See §4.2. |
| `drop release <id>` | See §4.2. |
| `drop done <id> [--note "…"]` | See §4.2. |
| `drop reopen <id>` | See §4.2. |

**Watching**

| Command | Behavior |
|---|---|
| `drop watch <id> [--once] [--json]` | Subscribes to events for one drop (§5.3). Prints one line per event (one JSON object per line with `--json`) until interrupted. Ends with exit 0 after a `missing` event. `--once`: exits 0 after the first event. |
| `drop watch --inbox [--project <p>] [--once] [--json]` | Subscribes to handoffs entering the Inbox (§5.3), optionally for one project. |

`drop watch` reads `server.json` (§5.2); if the app isn't running, it launches it hidden
and waits up to 10 s for the server. Server unreachable after that → exit 1. Unknown
id → exit 2.

**Human and setup**

| Command | Behavior |
|---|---|
| `drop open <id>` | Opens `agentdrop://drop/<id>` → the app shows that drop's rendered view (launching the app if needed). |
| `drop code <id>` | Runs `code <absolute path>`. If `code` isn't on PATH → exit 1 with a hint. |
| `drop where` | Prints the drop folder path in use. |
| `drop config set-folder <path>` | Sets the drop folder in `config.json` (creating the folder if needed). |
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

### JSON shape

`show`, `add`, `latest`, `claim`, `release`, `done`, `reopen`, `edit`, `archive` return one drop
object; `list` and `inbox` return an array of them:

```json
{
  "id": "k7f2qa",
  "filename": "auth-plan.md",
  "path": "/Users/me/Desktop/AgentDrop/auth-plan.md",
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
  `seq` (integer, autoincrement) · `type` · `drop_id` · `at` · `data` (JSON).
- `content` events are written by the app when FSEvents reports a change to a drop's
  file (or anything inside a folder drop), debounced per drop (300 ms of quiet). Content
  changes made while the app isn't running produce no event.
- Events older than 30 days are pruned on app launch.

| `type` | Emitted when | `data` |
|---|---|---|
| `created` | A drop is registered | the drop object |
| `content` | The drop's file / folder contents changed | `{}` |
| `metadata` | `drop edit` or the app's edit form changed metadata | changed fields |
| `status` | Any §4.2 transition | `{from, to, claimedBy, statusNote}` |
| `archived` | Archived or un-archived | `{archived}` |
| `missing` | The drop's file / folder disappeared | `{}` |

### 5.2 Server

- Runs inside the app whenever the app is running. HTTP on `127.0.0.1` only.
- Port: `47390` by default, configurable in `config.json`. If it is taken, the app tries
  the next 9 ports.
- On start, the app writes `~/Library/Application Support/AgentDrop/server.json`
  (permissions `0600`): `{ "port": …, "token": "…", "pid": … }`. A new random token is
  generated each start. The file is removed on clean quit.
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
| `GET /events?inbox[&project=:p]` | Events where a handoff **enters the Inbox**: `created` as a handoff, `metadata` changing kind to handoff, `status` to `open` (release, reopen). |

- Each SSE message: `id: <seq>`, `event: <type>`, `data: {"seq", "type", "dropId", "at", "data"}`.
- Clients reconnect with `Last-Event-ID` and receive every event with a larger `seq`
  that matches their filter (subject to the 30-day pruning).
- Errors use the same JSON error shape as the CLI, with HTTP 400 / 401 / 403 / 404.

## 6. The app (draft — to be refined)

### Shape

- A regular app with a Dock icon and a main window, **plus** a menu bar extra that is
  always present while the app runs.
- Closing the main window does not quit the app; the menu bar keeps running.
- Setting: **Hide Dock icon** (switches activation policy to accessory).
- Setting: **Launch at login** (via `SMAppService`). On first launch the app asks once:
  "Start Agent Drop at login? Agents and apps that watch for changes need it running",
  with **Yes** pre-selected; afterwards it's an ordinary setting. Reason: the local
  server (§5.2) and `content` events (§5.1) exist only while the app runs, and other
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
  that follows light/dark mode. Relative image links resolve against the drop folder.
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
- Server port range exhausted: the app shows a banner and keeps running without the
  server; `drop watch` exits 1 with that reason.
- Server request without a valid token or with a non-loopback `Host` → HTTP 401 / 403.

## 8. Testing

- **`AgentDropCore`** (XCTest/Swift Testing): store CRUD, migrations, id generation and
  id/filename resolution, claim atomicity under concurrent writers, reconciliation
  (unregistered / missing), identity-field validation and `--from-under` matching. Each test uses a temp
  directory.
- **`drop` CLI**: integration tests that run the built binary with `HOME`
  pointed at a temp directory (each test gets its own `config.json` and drop folder), asserting stdout (`--json`), stderr, and exit codes for
  every command, including the handoff lifecycle end-to-end.
- **Event log**: every mutation writes exactly one event row in the same transaction;
  `seq` is strictly increasing; pruning.
- **Server** (against a temp store, started in-process): token and `Host` checks, each
  endpoint, SSE delivery for each event type, `Last-Event-ID` resume, content
  debouncing, inbox filtering. `drop watch` tested end-to-end against it.
- **App**: view models unit-tested against a temp store; UI verified manually against a
  checklist (menu bar count, notification, rendered view, VS Code open, unregistered
  register flow).

## 9. Repo layout

```
agent-drop/
├── Package.swift                 # AgentDropCore + drop CLI
├── Sources/
│   ├── AgentDropCore/
│   └── drop/
├── Tests/
│   ├── AgentDropCoreTests/
│   └── dropCLITests/
├── App/                          # Xcode project for AgentDrop.app (depends on the package)
├── docs/superpowers/specs/
├── LICENSE                       # MIT
└── README.md
```
