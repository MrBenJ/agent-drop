# Agent Drop v0.2.0: drops over the tailnet (`allowTailnet`)

Date: 2026-10-17. Status: design, awaiting approval.
Revises the v0.1 spec (`2026-10-11-agent-drop-design.md`). This design deliberately
reverses two of the v0.1 non-goals. They are listed in §9.

## 1. Why

Ben develops on his main laptop, which runs AgentDrop.app. A Mac mini on the same
Tailscale tailnet runs his agents: **Aria** (OpenClaw) and **Cadence** (Hermes). He
drives them mostly from Telegram. When they finish something he should read, such as a
plan, a report, or a screenshot, there's no way to put it in front of him. It stays on
the mini.

v0.2.0 lets an agent on another tailnet machine **send** a drop to the laptop's Agent
Drop. It arrives with full context (who sent it, which project it's for, and why) and
triggers the usual new-drop notification. The laptop stays the single inbox. Other
machines are senders only.

## 2. Goals, non-goals, anti-goals

**Goals**
- On the sending machine:
  `drop add report.md --to laptop --from aria --project courses-app -m "…"`. The drop
  appears in the laptop's app as if it had been added on the laptop.
- Opt-in on the receiver (a Settings toggle, off by default). It's set up once on each side.
- Agent skills for OpenClaw and Hermes, shipped in this repo, so Aria and Cadence know
  when and how to drop things to Ben.

**Non-goals (v0.2.0)**
- **Fire-and-forget only.** Senders never read, list, watch, claim, or finish drops on
  the receiver. The sender gets the new drop's id back, and that's it.
- Ben's phone, and any non-Mac sender other than `curl`-able HTTP.
- Using Tailscale identity (`whois`) for auth, HTTPS, Tailscale Serve/Funnel.
- Syncing stores between machines, or more than one receiver per sender command.
- Being reachable from outside the tailnet.

**Anti-goals: failures even if it "works"**
- Anything listening beyond the tailnet, or listening at all while the Tailnet toggle is off.
- Turning on tailnet sending also exposes **reading** of drops, events, or file contents
  over the network.
- Any change to v0.1 loopback behavior (port, token, Host check, `drop watch`) when the
  setting is off.
- A malicious or buggy sender being able to write outside the drop folder (path
  traversal, symlinks in uploaded folders), or fill the disk with no limit.

## 3. Trust model (Ben's decision)

The tailnet is just Ben's own devices, so being on the tailnet is the main trust
boundary. On top of that, every request needs a **long-lived shared key**. That stops a
stray request from some other tailnet service, and gives Ben a switch to revoke it
(regenerate the key). The aria-actions service on the mini already uses this model
(Tailscale-only bind, a bearer token compared in constant time) and is the reference.

## 4. Receiver: the laptop app

### 4.1 Setting
- **Only the Settings toggle can turn receiving on** (Ben's decision).
  - The on/off state is **not** a `config.json` key. It lives in app-only state written
    only by the toggle: `AppSettings`/UserDefaults, or a builder-chosen equivalent.
  - A `config.json` edit, the CLI, or `drop config` can't enable it, and none of them
    expose the setting. An `allowTailnet` key in `config.json` is ignored.
  - This blocks an agent quietly turning it on through the config file the app watches.
    It is not a defense against a process that can already do anything as Ben.
  - `tailnet.json` (the key) is created only by the toggle's first turn-on, never at
    service start.
- `config.json` gets `tailnetPort: Int` (absent = **47400**) and `tailnetMaxBytes`
  (§4.5). Both are harmless while receiving is off.
- Settings → General gets a "Tailnet" section under the "Local server" row:
  - an on/off toggle;
  - status: `Receiving on bens-macbook-pro.tail07da74.ts.net:47400`, or *Tailscale not
    connected*, or *port 47400 in use*;
  - the sender key, with **Copy setup command** (copies the full `drop remote add …` line
    from §5.2) and **Regenerate key**.
- `AppModel`'s `Applied` key must include both new values, so changing them restarts the
  service (today only folder, confirmation, and port do).

### 4.2 A second, separate listener
- When the Tailnet toggle is on, the service starts a **second HTTP server**, bound only to
  the laptop's Tailscale address(es), on `tailnetPort`. The existing loopback server is
  untouched.
- **There's no port fallback.** Senders hard-code the port, so if it's taken, show the
  error in Settings rather than moving.
- That listener has exactly one data route: `POST /drops`, plus a data-free `POST /ping`
  for `drop remote test` (§5.2). Every other path, including the v0.1 GET routes,
  returns 404. Reads stay on loopback (anti-goal §2).
- Finding the Tailscale address: an IPv4 address in `100.64.0.0/10` on a `utun*`
  interface, which must also appear in `Self.TailscaleIPs` whenever `tailscale status
  --json` answers. Other interfaces are never used: that range is also carrier-grade NAT,
  so a Wi-Fi or LAN address can fall inside it (revised during the v0.2.0 build). IPv6
  is out of scope for v0.2.0. The MagicDNS name comes from
  `tailscale status --json` when the CLI is present. Without it, only IP-addressed Host
  headers are accepted.
- The service must cope with Tailscale coming up after the app, or the address changing.
  Detect that and rebind. **Builder's call** on how (network path monitor vs. periodic
  check).

### 4.3 Request checks on the tailnet listener (all required, every request)
1. The peer address is inside the tailnet ranges above; otherwise 403.
2. `Host` is one of `<tailscale-ip>:<port>`, `<magicdns-fqdn>:<port>`, or
   `<magicdns-short-name>:<port>`, with no duplicate Host headers; otherwise 403. This
   matches the v0.1 DNS-rebinding defense.
3. `Authorization: Bearer <sender key>`, compared **in constant time**; otherwise 401.
   (Also switch the v0.1 loopback token check to constant time. It's a free fix.)

### 4.4 The sender key
- 32 random bytes, hex. Generated the first time the toggle is turned on, stored in
  `<configDir>/tailnet.json` (mode 0600, same atomic-write pattern as `server.json`).
- It does **not** rotate on restart, unlike the loopback token. Only **Regenerate**
  changes it.
- Never written to logs or to `server.json`.

### 4.5 `POST /drops`
- Metadata: the same fields as `drop add`: `from` (required), `name`, `title`, `desc`,
  `project`, `tags[]`, `handoff`, plus whether the payload is a file or a folder.
- Payload: one file, or one folder.
- **Wire format is the builder's call**, within these constraints:
  - The body is **streamed** to `<folder>/.agentdrop/staging/<uuid>/`, never buffered
    whole in memory.
  - A folder is sent as an archive, for example tar. Extraction must **reject**: absolute
    paths, `..` components, symlinks, hard links, device files, and anything that isn't a
    regular file or directory. Reject the whole drop, don't skip entries.
  - **Size cap:** `tailnetMaxBytes` in `config.json`, default **200 MB**, enforced while
    streaming. Exceeding it returns 413 and deletes the staging files. Uncompressed size
    counts for folders.
- **Disk-fill guard** (my call, beyond the per-request cap):
  - At most **2 uploads in flight**. A third gets 503 "busy".
  - Before streaming, refuse with 507 (or 503, builder's call) if free space on the
    drop folder's volume would fall below 1 GB.
  - No daily or overall quota in v0.2.0.
- After staging, it goes through the **same `DropStore` add path**. The upload
  handler needs its own internal source type for already-staged files, because the CLI's
  `.path` case rejects anything inside the drop folder, and staging is inside it.
  The rest of the path is the same as the CLI's:
  validation, name collision suffixing, title extraction, the `created` event, so the
  app's notification fires unchanged. It's always a copy (there's no `--move` over the
  wire).
- Response: `201` with the drop's JSON (the v0.1 shape). Errors use the v0.1 shape:
  - 400 for validation;
  - 401, 403, 404, 413;
  - 503 for busy or locked;
  - 500 for anything else.
- The app is the only receiver: when it isn't running there's no listener, and senders
  get "connection refused" (§5.3).

## 5. Sender: the `drop` CLI on another Mac

### 5.1 `drop add --to <remote>`
- `--to <name>` sends to a configured remote instead of the local store. Everything else
  stays the same: `--from` is required, plus `--name`, `--title`, `-m`, `--project`,
  `--tag`, `--handoff`, `--json`, and stdin via `-`.
- `--move` with `--to` is an error (keeps it simple: nothing is deleted on the sender).
- With `--to`, the CLI **needs no local Agent Drop setup**: no `config.json` folder, no
  store, and no app on the sender.
- Output matches a local `drop add`: the id, or the drop JSON with `--json`, as returned
  by the receiver.

### 5.2 Remotes
- `drop remote add <name> --url http://<host>:<port> --key <key>`
- `drop remote list`, which shows names and URLs, never keys
- `drop remote remove <name>`
- `drop remote test <name>`: an authenticated no-op that reports reachable / bad key /
  not running. **Builder's call** whether that's a dedicated route (it must still be
  POST-only, or a HEAD on `/drops`) or something else. It must not expose any drop data.
- Stored in `<configDir>/remotes.json`, mode 0600.
- `AGENT_DROP_REMOTE_URL` + `AGENT_DROP_REMOTE_KEY` env vars work as an unnamed remote
  for `--to env` (my call: handy for agents whose config dirs are awkward). Drop this if
  it complicates things.

### 5.3 Errors (agents read these, so make them plain and actionable)
- Unreachable or refused → "Can't reach `laptop` (<url>). Is the laptop awake, on
  Tailscale, with Agent Drop running and *Tailnet* turned on?", with a nonzero exit code.
- 401 → "The key for `laptop` was rejected. It may have been regenerated: run `drop remote
  add laptop …` again."
- 413 → states the limit.
- Exit codes follow the v0.1 CLI conventions. New ones only where no existing code fits.

## 6. Agent skills in this repo

- New top-level `skills/` folder:
  - `skills/openclaw/agent-drop-send/SKILL.md`, in the OpenClaw format (`name`,
    `description` front matter), installed to `~/.openclaw/workspace/skills/agent-drop-send/`.
  - `skills/hermes/agent-drop-send/SKILL.md`, in the Hermes format (adds `version`,
    `platforms: [macos]`, `prerequisites.commands: [drop]`, `metadata.hermes.tags`),
    installed to `~/.hermes/skills/productivity/agent-drop-send/`.
  - `Scripts/install-agent-skills.sh [--openclaw] [--hermes]`, which copies them into
    place, so they can be installed and updated with one command on the mini.
- Skill content (the same for both, adapted to each format):
  - **When:** the agent finished something its human should read or review (a plan,
    spec, report, summary, screenshot, or generated file). Not for chat replies, and
    not for secrets or credentials (`.env` files, keys).
  - **How:** `drop add <path> --to <remote> --from <agent name> --project <repo or topic>
    -m "<one sentence: what it is and why they're getting it>" --json`. Add `--handoff`
    only when it's work for the human to pick up.
  - The remote name defaults to `laptop`, and the README says how to change it.
  - **Fire-and-forget:** after sending, tell the human in the current channel (e.g.
    Telegram) that it's in Agent Drop, with the title. Don't poll or wait.
  - **On failure:** relay the CLI's error to the human, and don't retry in a loop.
  - Preflight: `drop --version` must be 0.2.0 or newer, and `drop remote list` must show
    the remote.
- The skills are written for any user, with no hard-coded "Ben" or "Aria" (it's an open
  source repo). The agent passes its own name as `--from`.
- Ben's personal Claude Code `/drop` skill (`~/.claude/skills/drop/`) is unchanged.

## 7. Rollout on Ben's machines (after the release)

1. The laptop installs AgentDrop.app and `drop` 0.2.0, then turns on Tailnet in
   Settings and clicks **Copy setup command**.
2. The mini: install `drop` 0.2.0 to `~/.local/bin/drop` (0.1.1 is there now). That
   directory is on PATH for both `ai.openclaw.gateway` and `ai.hermes.gateway`.
3. Run the copied `drop remote add laptop …` on the mini, then `drop remote test laptop`.
4. Run `Scripts/install-agent-skills.sh --openclaw --hermes` on the mini. Restart the
   gateways if they don't pick up new skills live.
5. Smoke test: ask Aria over Telegram to drop a file, and check the laptop notification.

## 8. Release

- Version bump to **0.2.0** in `App/Info.plist` (`CFBundleShortVersionString`, and
  `CFBundleVersion` → 3) and in `Sources/DropCLI/DropCLI.swift`.
  `Scripts/package-release.sh` checks that they match the tag.
- `docs/releases/v0.2.0.md` in the existing format: "What's new" / "Fixed" (the
  constant-time token check) / "Install".
- README: a "Sending drops from another Mac (Tailscale)" section, `drop remote` in the
  CLI reference, a skills install section, and the security model in plain words.
- `drop agent-instructions` mentions `--to` when remotes are configured (**builder's
  call** whether it's conditional or always included).
- Update the v0.1 spec's non-goals (§9) to point to this document.

- **Signing stays ad hoc** (my call). The macOS application firewall is off on Ben's
  laptop (checked 2026-10-17). For users who have it on, the README explains that an
  ad-hoc-signed app may ask "accept incoming connections?" again after each update.
  Settings shows a hint if the listener is bound but no connection ever arrives. Real
  Developer ID signing and notarization stay a non-goal.

## 9. v0.1 non-goals this reverses
- "Any service reachable beyond `127.0.0.1`": now allowed, but only the tailnet
  listener, only while opted in, and only for `POST /drops`.
- "Write endpoints on the local server": now there's one write endpoint, on the tailnet
  listener only. The loopback server stays read-only.
- `--to` recipient addressing, which v0.1 deferred, now exists as `--to <remote>` naming
  a *machine*, not an agent.

## 10. Testing
- The listener's bind address must be injectable, so tests can run the tailnet listener
  on `127.0.0.1` (CI has no Tailscale) and simulate the tailnet Host names and peer
  ranges. Peer-range checking must be testable apart from the real interface.
- Required cases:
  - Every check in §4.3, each failing alone.
  - Each route except `POST /drops` returns 404 on the tailnet listener.
  - The size cap, both mid-stream and with an archive that expands too large.
  - Each malicious-archive case in §4.5.
  - A name collision.
  - A `created` event emitted for a remote drop.
  - Setting off → no listener at all.
  - `Applied` changes → restart.
  - CLI: `--to` with no local setup; `--move` + `--to` rejected; each §5.3 error.
- `docs/manual-test-checklist.md` gains a real two-machine pass: laptop + mini.

## 11. Left to the builder
The wire format (§4.5), how address changes are detected (§4.2), the shape of
`remote test` (§5.2), the conditional `agent-instructions` text (§8), and internal code
structure, as long as the loopback server's behavior is unchanged.
