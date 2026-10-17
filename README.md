# Agent Drop

A small macOS app + CLI that gives coding agents (Claude Code, Codex, pi, …) a shared
drop folder with context: what each file is, why it exists, which project it's from,
and whether a handoff has been picked up.

**Status:** v0.2: the `drop` CLI, the local server with `drop watch`, AgentDrop.app
(menu bar + main window), and sending drops from another Mac over Tailscale. Download a release or build from source; the app is not notarized yet. See
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

## Command reference: `drop remote`

```bash
drop remote add <name> --url <url> --key <key|-> [--json]   # save or replace a remote
drop remote list [--json]                                   # names and URLs; never keys
drop remote remove <name> [--json]
drop remote test <name> [--json]                            # reachable, and key accepted?
drop add <path|-> --to <remote|env> --from <who> [-m <why>] [--json]
```

`--key -` reads the key from stdin. With `--json`, `remote add` and `remote test` print
`{"name": ..., "url": ...}`, `remote remove` prints `{"removed": "<name>"}`, and `remote
list` prints an array of those objects. Remotes are saved in `remotes.json` in the config
folder (mode 0600). Remote failures exit 1, except a 404 from the remote, which exits 2.
`drop agent-instructions` mentions `--to` too.

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

## Sending drops from another Mac (Tailscale)

An agent on a second Mac (say a Mac mini) can drop finished work into the Agent Drop on
your laptop, over [Tailscale](https://tailscale.com). It is off until you turn it on.

**On the receiving Mac:** open Agent Drop → Settings → General → **Tailnet** and switch on
**Receive drops from my tailnet**. The status line under it says what is going on:
"Receiving on <host>:<port>", "Tailscale not connected", "Port N is in use", "Starts when
Agent Drop is serving", or "Off". Click **Copy setup command** to get a line like
`drop remote add laptop --url http://<host>:47400 --key <key>`. **Regenerate key** makes a
new key; every sender using the old one stops working until you give it the new one.

**On the sending Mac:** install the `drop` CLI (0.2.0 or newer), then register the receiver
once. Piping the key keeps it out of your shell history. Copy it in Settings first, then:

```bash
pbpaste | drop remote add laptop --url http://<host>:47400 --key -
drop remote test laptop                       # reachable, and the key is accepted
drop add plan.md --to laptop --from "mini-agent" -m "Plan for the auth refactor"
```

`drop add --to <remote>` works with files, folders and `-` (stdin, with `--name`). It is
fire-and-forget: the drop is saved on the receiving Mac and its app notifies you. The
sender needs no local setup, and `--move` is not allowed with `--to`. For a machine where
config files are awkward, `--to env` reads `AGENT_DROP_REMOTE_URL` and
`AGENT_DROP_REMOTE_KEY` instead.

**What this exposes, in plain words:**

- The receiver listens only on the Mac's Tailscale address (port 47400, set with
  `tailnetPort` in config.json; there is no fallback port), never on your Wi-Fi or LAN
  address. If Tailscale is down, nothing listens.
- Every request needs the shared key, and the sender must be a Tailscale device (a
  `100.64.0.0/10` address). Only the Settings toggle can turn receiving on; editing
  config.json can't.
- The tailnet accepts exactly two things: `POST /drops` (add a drop) and `POST /ping` (the
  `drop remote test` check). Nothing can be **read** over the network; every other route
  is a 404. The local server and `drop watch` are unchanged.
- Limits: 200 MB per drop (`tailnetMaxBytes`), two uploads at once (a third gets 503), and
  a drop is refused (507) if less than 1 GB of disk would remain free. Folders may contain
  only plain files and folders; a link or an odd path rejects the whole drop.
- Anyone who has the key and is on your tailnet can add drops to your folder, so treat the
  key like a password and regenerate it if it leaks.

**Firewall:** the app is ad-hoc signed, so with the macOS firewall on, it may ask to accept
incoming connections again after each update. Allow it, or senders get "Can't reach".

## Skills for OpenClaw and Hermes

Agents running on the sending Mac can be taught to use `drop add --to` by installing a
skill: `Scripts/install-agent-skills.sh --openclaw --hermes`. See
[skills/README.md](skills/README.md).

## Making a release

1. Set the version in `App/Info.plist` (`CFBundleShortVersionString`) and
   `Sources/DropCLI/DropCLI.swift` (`version:`).
2. Write `docs/releases/v<version>.md`.
3. Push a tag `v<version>`. The Release workflow tests, builds the universal zip with
   `Scripts/package-release.sh` (which refuses a tag that doesn't match both versions),
   and creates a **draft** release. Review it on GitHub and publish.

## License

MIT
