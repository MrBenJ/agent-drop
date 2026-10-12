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
- The human sees new drops at a glance (menu bar unread count, optional notification)
  and can view any Markdown drop rendered, or open it in VS Code, in one click.
- Handoffs have visible lifecycle state: open → claimed → done.
- The folder remains a plain folder. Uninstalling the app loses no files.
- The app is small and cheap to leave running.

### Non-goals (v1)

- Sync across machines, sharing between users, or any network service.
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
| `AgentDropCore` | Swift library | Data model, SQLite store, folder operations, id generation, project/agent inference. All logic lives here. |
| `drop` | CLI executable | Thin command layer over `AgentDropCore` (swift-argument-parser). |
| `AgentDrop.app` | SwiftUI app | Main window + menu bar extra. Reads/writes through `AgentDropCore`. |

Dependencies: [GRDB.swift](https://github.com/groue/GRDB.swift) (SQLite),
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (CLI),
[swift-cmark](https://github.com/swiftlang/swift-cmark) GFM (Markdown → HTML).

**Minimum macOS:** 14 (Sonoma). Needed for `MenuBarExtra`, `SMAppService`, and the
Observation framework.

**The CLI never requires the app to be running.** Both write directly to the same
store. The app watches the folder and store for changes and refreshes. Agents can hand
off to each other with the app closed.

The app is **not sandboxed**: it must read a user-chosen folder (default on the
Desktop) and launch `code`. On first launch macOS will ask for Desktop folder access;
the app explains why before triggering the prompt.

## 3. Storage

### Drop folder

- Default: `~/Desktop/AgentDrop`.
- Override order (highest first): `AGENT_DROP_DIR` env var → path saved in the app's
  settings (stored in `~/Library/Application Support/AgentDrop/config.json`, which the
  CLI also reads) → default.
- Created on first use by either the CLI or the app.
- Drop files live at the **top level** of the folder. Subdirectories and dotfiles are
  ignored.

### Metadata store

- `<drop folder>/.agentdrop/index.sqlite`, so metadata travels with the folder.
- WAL mode, busy timeout of 5 s, so concurrent CLI invocations and the app coexist.
- Schema version tracked with `PRAGMA user_version`; migrations run in
  `AgentDropCore` on open.

### Data model: `drop`

| Field | Type | Notes |
|---|---|---|
| `id` | text, PK | 6-char short id, see §3.1 |
| `filename` | text, unique | Name of the file in the drop folder |
| `title` | text | Defaults to first Markdown `# heading`, else filename without extension |
| `description` | text, nullable | The why / context |
| `project` | text, nullable | e.g. `courses-app` |
| `tags` | separate `drop_tag(drop_id, tag)` table | Lowercased, trimmed |
| `agent` | text | e.g. `claude-code`, `codex`, `pi`, `unknown` |
| `created_at` | timestamp | |
| `updated_at` | timestamp | |
| `read_at` | timestamp, nullable | Set only by the app when a human views the drop |
| `kind` | `note` \| `handoff` | |
| `status` | `open` \| `claimed` \| `done`, nullable | Non-null iff `kind = handoff` |
| `claimed_by` | text, nullable | Agent name that claimed it |
| `status_note` | text, nullable | e.g. "shipped in PR #42" |
| `archived` | bool | Hidden from default lists |
| `missing` | bool | File no longer present on disk |

### 3.1 Ids

- 6 random characters from a 32-character alphabet: `a–z` and `2–9`, excluding `o`
  and `l` (no `0/o` or `1/l` confusion). ~1.07 billion values.
- Collision checked at insert; regenerate on clash.
- Anywhere an `<id>` is accepted, the CLI also accepts:
  - a **unique prefix** of an id (`k7f` → `k7f2qa`), or
  - an exact **filename** (`auth-plan.md`).
- Ambiguous prefix → exit 1, listing the candidates.

### 3.2 Folder reconciliation

The app watches the folder with FSEvents (and reconciles on launch):

- **File with no record** → shown as *unregistered*, with a one-click "Register" that
  opens a small form (title, description, project, tags, kind). An agent can also
  register it later with `drop add <path-in-folder>`.
- **Record whose file is gone** → `missing = true`; shown greyed out with a
  "Remove record" action. Never silently deleted.
- **File renamed in Finder** → treated as missing + unregistered (no rename tracking in
  v1).

The CLI performs the same missing-file check lazily when it resolves an id.

## 4. The `drop` CLI

### Global rules

- Never prompts interactively.
- `--json` on every command produces machine-readable output on stdout.
- Exit codes: `0` ok · `1` error (including bad input, ambiguous id, wrong kind) ·
  `2` not found · `3` conflict (e.g. handoff already claimed).
- Human-readable output is the default; errors go to stderr.
- An `agentdrop` alias is installed alongside `drop` in case `drop` collides with
  another tool.

### Inference defaults

- **`--project`**: basename of `git rev-parse --show-toplevel` from the current
  directory; unset if not in a git repo.
- **`--agent`**: `AGENT_DROP_AGENT` env var if set; otherwise detected from
  agent-specific environment variables (e.g. `CLAUDECODE=1` → `claude-code`; the exact
  variables for Codex and pi are confirmed during implementation); otherwise `unknown`.

### Commands

**Dropping**

| Command | Behavior |
|---|---|
| `drop add <path> [flags]` | Copies the file into the drop folder and registers it; prints the id. If `<path>` is already inside the folder, registers in place. Name collision → suffix (`plan-2.md`). Flags: `--title`, `-m/--desc`, `--project`, `--tag <t>` (repeatable), `--agent`, `--handoff` (sets `kind=handoff`, `status=open`), `--move` (move instead of copy). Re-adding an already-registered in-folder file → exit 3. |
| `drop add - --name <filename> [flags]` | Same, reading content from stdin. `--name` required. |
| `drop edit <id> [flags]` | Updates metadata: `--title`, `-m/--desc`, `--project`, `--tag <t>`, `--untag <t>`, `--kind note\|handoff`. Changing to `handoff` sets `status=open`; changing to `note` clears status fields. |
| `drop archive <id>` | Sets `archived=true`. `drop archive --undo <id>` reverses it. The file is untouched. |

**Finding and reading**

| Command | Behavior |
|---|---|
| `drop list [filters]` | Newest first, default `--limit 50`, archived excluded. Filters: `--project`, `--tag`, `--agent`, `--handoffs`, `--status open\|claimed\|done`, `--unread`, `--limit <n>`, `--all` (include archived). |
| `drop show <id>` | Metadata plus absolute path. |
| `drop cat <id>` | File contents to stdout. Does **not** set `read_at` (that's for humans). |
| `drop path <id>` | Absolute path only. |
| `drop latest [filters] [--cat]` | Newest match from the same filters as `list`; prints like `show`, or contents with `--cat`. Exit 2 if none. |

**Handoffs**

| Command | Behavior |
|---|---|
| `drop inbox [--all-projects]` | Open handoffs for the inferred project. If no project can be inferred, behaves as `--all-projects`. |
| `drop claim <id> [--agent] [--force]` | `open` → `claimed`, sets `claimed_by`. Atomic (`UPDATE … WHERE status = 'open'`). Already claimed or done → exit 3 unless `--force`. Not a handoff → exit 1. |
| `drop release <id>` | `claimed` → `open`, clears `claimed_by`. |
| `drop done <id> [--note "…"]` | → `done`, sets `status_note`. Allowed from `open` or `claimed`. |

**Human and setup**

| Command | Behavior |
|---|---|
| `drop open <id>` | Opens `agentdrop://drop/<id>` → the app shows that drop's rendered view (launching the app if needed). |
| `drop code <id>` | Runs `code <absolute path>`. If `code` isn't on PATH → exit 1 with a hint. |
| `drop where` | Prints the drop folder path. |
| `drop agent-instructions` | Prints a Markdown snippet for `CLAUDE.md` / `AGENTS.md` teaching an agent when and how to use `drop` (dropping with context, checking `drop inbox`, claim → done). |

### JSON shape

`show`, `add`, `latest`, `claim`, `release`, `done`, `edit`, `archive` return one drop
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
  "agent": "claude-code",
  "kind": "handoff",
  "status": "open",
  "claimedBy": null,
  "statusNote": null,
  "createdAt": "2026-10-11T18:44:00Z",
  "updatedAt": "2026-10-11T18:44:00Z",
  "readAt": null,
  "archived": false,
  "missing": false
}
```

Errors with `--json` print `{"error": "<message>", "code": <exit code>}` to stdout.

## 5. The app (draft — to be refined)

### Shape

- A regular app with a Dock icon and a main window, **plus** a menu bar extra that is
  always present while the app runs.
- Closing the main window does not quit the app; the menu bar keeps running.
- Setting: **Hide Dock icon** (switches activation policy to accessory).
- Setting: **Launch at login** (via `SMAppService`), default on.
- Setting: **Notify on new drops** (via `UserNotifications`), default on. Clicking a
  notification opens that drop.

### Menu bar extra

- Icon with an unread badge count (unread = `read_at IS NULL`, not archived, not
  missing).
- Dropdown: the 10 most recent drops (title, project, agent, relative time, unread dot),
  then a separate **Open handoffs** section, then *Open Agent Drop* / *Settings* /
  *Quit*.
- Clicking a drop opens the main window to it.

### Main window

Three-column `NavigationSplitView`:

1. **Sidebar:** Inbox (all, unread first) · Handoffs (grouped open / claimed / done) ·
   Unregistered · Archived · then Projects, Tags, and Agents as filter lists.
2. **List:** title, project, agent, tags, relative time, unread dot, handoff status
   pill. Search field filters title, description, and filename.
3. **Detail:** metadata header (description, project, tags, agent, timestamps, handoff
   status, status note), action buttons, then the file preview.

Viewing a drop in the detail pane sets `read_at`.

### Actions in the detail pane

- **View rendered** (default preview for `.md`).
- **Open in VS Code** (`code <path>`; disabled with a tooltip if `code` isn't found).
- **Reveal in Finder**.
- **Copy path** and **Copy `drop cat <id>`** (handy for pasting into an agent).
- Handoffs: **Mark done** / **Reopen** (humans can override status).
- **Edit metadata**, **Archive**.

### Rendering

- Markdown: GFM via swift-cmark → HTML, displayed in a `WKWebView` with bundled CSS
  that follows light/dark mode. Relative image links resolve against the drop folder.
  Links open in the default browser. JavaScript in the rendered content is disabled.
- Plain text / code files: monospace text view.
- Everything else (images, PDFs, …): Quick Look preview (`QLPreviewView`).

## 6. Error handling

- Store can't be opened (corrupt / unreadable): CLI exits 1 with the path and the
  underlying error; app shows a banner with *Reveal in Finder*. Never auto-deletes the
  store.
- Drop folder missing: recreated by CLI or app on next use.
- Busy database beyond the 5 s timeout: exit 1 with "store busy, retry".
- Source file for `drop add` doesn't exist or isn't a regular file: exit 2.
- `drop add -` with empty stdin: exit 1.

## 7. Testing

- **`AgentDropCore`** (XCTest/Swift Testing): store CRUD, migrations, id generation and
  prefix/filename resolution, claim atomicity under concurrent writers, reconciliation
  (unregistered / missing), project and agent inference. Each test uses a temp
  directory.
- **`drop` CLI**: integration tests that run the built binary with `AGENT_DROP_DIR`
  pointed at a temp folder, asserting stdout (`--json`), stderr, and exit codes for
  every command, including the handoff lifecycle end-to-end.
- **App**: view models unit-tested against a temp store; UI verified manually against a
  checklist (menu bar count, notification, rendered view, VS Code open, unregistered
  register flow).

## 8. Repo layout

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
