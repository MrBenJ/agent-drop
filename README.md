# Agent Drop

A small macOS app + CLI that gives coding agents (Claude Code, Codex, pi, …) a shared
drop folder with context: what each file is, why it exists, which project it's from,
and whether a handoff has been picked up.

**Status:** design phase. See [the design spec](docs/superpowers/specs/2026-10-11-agent-drop-design.md).

## What Agent Drop stores and deletes

- Your files live as plain files in your drop folder (default `~/AgentDrop`).
- Metadata and a change log live in `<drop folder>/.agentdrop/index.sqlite`.
- **The change log is trimmed automatically:** each new change also deletes log entries
  older than your retention setting (default 30 days). Change it in Settings → Event
  history or with `drop config set-retention <days|forever>`.
- **Agent Drop never deletes your drops or files.**

## License

MIT
