---
name: agent-drop-send
description: Send a finished file or folder (plan, spec, report, screenshot, generated output) to your human's Agent Drop on another Mac over Tailscale. Use when you've produced something they should read or review, or when they ask you to "drop" or "send" it to them.
---

# Agent Drop: send finished work to your human

Agent Drop is a Mac app your human runs on another Mac. `drop add ... --to laptop` sends a file or folder there over Tailscale, where it shows up in their Agent Drop inbox with its title, context and who sent it.

## 1. Preflight

Check once per session, before the first drop:

```bash
drop --version        # must be 0.2.0 or newer
drop remote list      # must show the remote, "laptop" by default
```

- If `drop` is missing or older than 0.2.0, stop and tell your human what is missing. Do not try to install or upgrade it yourself.
- If the remote is not listed, say so and ask the human to run `drop remote add`. Never invent a URL or key.
- The default remote name is `laptop`. If your human gave you a different remote name, use it everywhere below in place of `laptop`.

## 2. When to drop, and when not to

Drop things your human should read or review later, and that are finished:

- plans, specs, design docs, reports, summaries
- screenshots, generated images, exports, build output
- a folder of related results

Do not drop:

- secrets, `.env` files, API keys, tokens, credentials, private keys
- chat replies or short answers. Say those in the conversation instead.
- half-finished scratch work or logs nobody asked for

If you are unsure whether a file contains a secret, do not send it. Ask.

## 3. The command

```bash
drop add <path> --to laptop --from "<your agent name>" --project "<repo or topic>" \
  -m "<one sentence: what it is and why they're getting it>" --json
```

- `<path>` is a file or a folder.
- `--from` is your own agent name. It is required.
- `--project` is the repo or topic the work belongs to.
- `-m` is one plain sentence: what it is, and why they are getting it.
- `--json` makes the output machine-readable. On success it includes the drop's title; use that title when you tell your human.
- Optional: `--title "<title>"` to override the title, `--tag <tag>` (repeatable).
- Add `--handoff` only when it is work your human should pick up and continue. Leave it off for plain "here is a thing to read".
- `--move` is not allowed together with `--to`.

To send generated text without writing a file first, pipe it in. `--name` is required with stdin:

```bash
cat plan.md | drop add - --name plan.md --to laptop --from "<your agent name>" \
  --project "<repo or topic>" -m "<what it is and why>" --json
```

## 4. Fire and forget

When the command succeeds, tell your human in the channel you are already talking in that it is in Agent Drop, and name the title. For example: "Dropped 'Auth plan' into your Agent Drop." Then move on. Do not poll, re-send, or check whether they have opened it.

## 5. On failure

The CLI prints errors as `drop: <message>` (or `{"error": ..., "code": ...}` with `--json`) and exits non-zero. Exit code 2 means the remote name is unknown.

- Relay the error message to your human verbatim. Do not paraphrase it or guess at causes.
- Do not retry in a loop. At most one retry, and only if the human asks.
- Never print, log or paste the remote's key.
