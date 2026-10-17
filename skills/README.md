# Agent skills

Skills that teach AI agents running on a *sending* Mac to drop finished work into your Agent Drop on another Mac, over Tailscale, with `drop add ... --to laptop`.

| Skill | For | Source |
|---|---|---|
| `agent-drop-send` | OpenClaw agents | `skills/openclaw/agent-drop-send/SKILL.md` |
| `agent-drop-send` | Hermes agents | `skills/hermes/agent-drop-send/SKILL.md` |

Both carry the same instructions: preflight checks, when to drop and when not to, the exact command, fire-and-forget, and how to report failures. Only the front matter differs.

## Prerequisites

On the sending Mac, install the `drop` CLI (0.2.0 or newer) and register your receiving Mac once. `--key -` reads the key from stdin so it stays out of shell history:

```bash
pbpaste | drop remote add laptop --url http://<host>:47400 --key -
drop remote test laptop
```

Copy the key from the receiving Mac's Settings first, so `pbpaste` supplies it. To type it instead without echoing or recording it:

```bash
read -rs KEY; printf '%s' "$KEY" | drop remote add laptop --url http://<host>:47400 --key -; unset KEY
```

## Install

From a checkout of this repo, on the sending Mac:

```bash
Scripts/install-agent-skills.sh --openclaw --hermes
```

Pass only the flag you need, and `--dry-run` to see the destinations without copying. Defaults:

- OpenClaw: `~/.openclaw/workspace/skills/agent-drop-send` (override with `OPENCLAW_SKILLS_DIR`)
- Hermes: `~/.hermes/skills/productivity/agent-drop-send` (override with `HERMES_SKILLS_DIR`)

An existing copy is replaced. Restart the gateways afterwards if they are running, so they pick up the new skill.

## Using a remote name other than `laptop`

The skills default to a remote called `laptop`. If you registered the remote under another name (`drop remote add studio ...`), either:

- tell your agent "my Agent Drop remote is called `studio`" and it will use that name in place of `laptop`, or
- edit the installed `SKILL.md` and replace `--to laptop` with `--to studio`.
