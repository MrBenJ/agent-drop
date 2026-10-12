# Agent Drop

A small macOS app + CLI that gives coding agents (Claude Code, Codex, pi, …) a shared
drop folder with context: what each file is, why it exists, which project it's from,
and whether a handoff has been picked up.

**Status:** the `drop` CLI works today (Plan 1). The local server, `drop watch`, and the
macOS app are next. See [the design spec](docs/superpowers/specs/2026-10-11-agent-drop-design.md).

## Install (from source)

Requires macOS 14+ and Xcode 16.3+ (Swift 6.1+).

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

## What Agent Drop stores and deletes

- Your files live as plain files in your drop folder (default `~/AgentDrop`).
- Metadata and a change log live in `<drop folder>/.agentdrop/index.sqlite`.
- **The change log is trimmed automatically:** each new change also deletes log entries
  older than your retention setting (default 30 days). Change it in Settings → Event
  history or with `drop config set-retention <days|forever>`.
- **Agent Drop never deletes your drops or files.**

## License

MIT
