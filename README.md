# Agent Drop

A small macOS app + CLI that gives coding agents (Claude Code, Codex, pi, …) a shared
drop folder with context: what each file is, why it exists, which project it's from,
and whether a handoff has been picked up.

**Status:** v0.1: the `drop` CLI, the local server with `drop watch`, and AgentDrop.app
(menu bar + main window). Download a release or build from source; the app is not notarized yet. See
[the design spec](docs/superpowers/specs/2026-10-11-agent-drop-design.md).

## Install from a release

Download the latest `AgentDrop-<version>.zip` from
[Releases](https://github.com/MrBenJ/agent-drop/releases). It's universal (Apple
silicon and Intel) and needs macOS 14+. Its `INSTALL.txt` has the steps:

```bash
cp -R AgentDrop.app /Applications/
cp drop /usr/local/bin/drop          # or any directory on your PATH
xattr -dr com.apple.quarantine /Applications/AgentDrop.app /usr/local/bin/drop
open /Applications/AgentDrop.app
```

Releases are ad-hoc signed, not notarized. Clearing the quarantine flag once (or
right-clicking the app in Finder → **Open**) lets macOS run them.

## Install (from source)

Requires macOS 14+ and Xcode 26+ (Swift 6.2+).

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

## Quick start

```bash
drop add plan.md --from "my-agent" --project my-app -m "Plan for the auth refactor" --handoff
drop inbox --json
drop claim <id> --by "other-agent"
drop cat <id>
drop done <id> --note "shipped in PR #42"
```

Teach your agents with `drop agent-instructions >> CLAUDE.md` (or `AGENTS.md`).

`drop open <id>` shows a drop in the app (rendered Markdown, file previews, handoff
buttons). The menu bar icon counts unread drops.

`--from`, `--by`, `--project` and tags are yours to define. Agent Drop never guesses them.
Its only convention is `/` as an optional level separator (`drop list --from-under team`).

## Watching for changes

`drop watch` streams changes from the app's local server (127.0.0.1 only, token-protected):

```bash
drop watch --inbox --project my-app      # handoffs arriving in the Inbox
drop watch <id> --json                   # every change to one drop, as JSON lines
drop watch --inbox --once                # wait for the next arrival, then exit
```

It launches the app in the background (no window, menu bar icon only) if it isn't
running, and needs the app's setup to be finished.

For development without the app, `swift run agentdrop-devhost --temporary-setup` serves
the configured folder the same way from a terminal until Ctrl-C. `--temporary-setup`
marks setup as done only while it runs and puts `config.json` back on exit. Don't run it
while the app is running.

## What Agent Drop stores and deletes

- Your files live as plain files in your drop folder (default `~/AgentDrop`).
- Metadata and a change log live in `<drop folder>/.agentdrop/index.sqlite`.
- While the app runs, `~/Library/Application Support/AgentDrop/server.json` holds its
  local server's port and a random access token (readable only by you, new on every
  start). It is removed when the app quits.
- **The change log is trimmed automatically:** each new change also deletes log entries
  older than your retention setting (default 30 days). Change it in Settings → Event
  history or with `drop config set-retention <days|forever>`.
- **Agent Drop never deletes your drops or files.**

## Making a release

1. Set the version in `App/Info.plist` (`CFBundleShortVersionString`) and
   `Sources/DropCLI/DropCLI.swift` (`version:`).
2. Write `docs/releases/v<version>.md`.
3. Push a tag `v<version>`. The Release workflow tests, builds the universal zip with
   `Scripts/package-release.sh` (which refuses a tag that doesn't match both versions),
   and creates a **draft** release. Review it on GitHub and publish.

## License

MIT
