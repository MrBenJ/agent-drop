# Agent Drop

A small macOS app + CLI that gives coding agents (Claude Code, Codex, pi, …) a shared
drop folder with context: what each file is, why it exists, which project it's from,
and whether a handoff has been picked up.

**Status:** the `drop` CLI works today (Plan 1). The local server and `drop watch` are built
(Plan 2); the macOS app that hosts the server is next (Plan 3). Until then,
`agentdrop-devhost` stands in for the app (see below). See
[the design spec](docs/superpowers/specs/2026-10-11-agent-drop-design.md).

## Install (from source)

Requires macOS 14+ and Xcode 26+ (Swift 6.2+).

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

## Watching for changes

`drop watch` streams changes from the app's local server (127.0.0.1 only, token-protected):

```bash
drop watch --inbox --project my-app      # handoffs arriving in the Inbox
drop watch <id> --json                   # every change to one drop, as JSON lines
drop watch --inbox --once                # wait for the next arrival, then exit
```

It launches the app in the background if it isn't running. **Until the app exists**,
run the development stand-in in another terminal instead:

```bash
swift run agentdrop-devhost --temporary-setup
```

It serves your configured drop folder exactly as the app will (content watcher, local
server, `server.json`) until Ctrl-C. `--temporary-setup` marks the app's first-run setup
as done only while it runs, and puts `config.json` back exactly as it was on exit.

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

## License

MIT
