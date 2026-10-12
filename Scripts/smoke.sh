#!/usr/bin/env bash
# Real-binary smoke test (spec §8). It uses the REAL default paths
# (~/AgentDrop and ~/Library/Application Support/AgentDrop), so it only runs on
# ephemeral GitHub Actions machines, never on a developer's Mac.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "smoke.sh: skipped (runs only on GitHub Actions because it uses the real default paths)"
  exit 0
fi

DROP="${1:?usage: Scripts/smoke.sh <path-to-drop-binary> <path-to-agentdrop-devhost>}"
DEVHOST="${2:?usage: Scripts/smoke.sh <path-to-drop-binary> <path-to-agentdrop-devhost>}"
support="$HOME/Library/Application Support/AgentDrop"
work="${RUNNER_TEMP:?}/agentdrop-smoke"
mkdir -p "$work"

[[ "$("$DROP" where)" == "$HOME/AgentDrop" ]]

printf '# Smoke plan\n' > "$work/smoke plan.md"
id=$("$DROP" add "$work/smoke plan.md" --from "ci/smoke [1]" --project smoke --handoff)
[[ "$("$DROP" cat "$id")" == "# Smoke plan" ]]
"$DROP" inbox --project smoke --json | grep -q "\"id\":\"$id\""

"$DROP" claim "$id" --by "ci/a"
set +e
"$DROP" claim "$id" --by "ci/b"
code=$?
set -e
[[ "$code" -eq 3 ]]

"$DROP" done "$id" --note "smoke ok" >/dev/null
[[ -z "$("$DROP" inbox --project smoke)" ]]
[[ -f "$HOME/AgentDrop/.agentdrop/index.sqlite" ]]

# drop watch (Plan 2). Before setup it refuses with the spec's message.
set +e
out=$("$DROP" watch --inbox 2>&1)
code=$?
set -e
[[ "$code" -eq 1 && "$out" == *"hasn't been set up yet"* ]]

# The dev host stands in for the app: same service, real server.json, real FSEvents.
"$DEVHOST" --temporary-setup > "$work/devhost.log" 2>&1 &
host=$!
for _ in $(seq 1 100); do [[ -f "$support/server.json" ]] && break; sleep 0.1; done
grep -q '"status":"running"' "$support/server.json"

"$DROP" watch --inbox --project smoke2 --once --json > "$work/watch.out" &
watcher=$!
sleep 2
printf '# Second\n' > "$work/second.md"
id2=$("$DROP" add "$work/second.md" --from "ci/smoke" --project smoke2 --handoff)
wait "$watcher"
grep -q "\"dropId\":\"$id2\"" "$work/watch.out"
grep -q '"type":"created"' "$work/watch.out"

kill -INT "$host"
wait "$host"
[[ ! -f "$support/server.json" ]]
# --temporary-setup put config.json back exactly (it didn't exist before).
[[ ! -f "$support/config.json" ]]
echo "smoke: ok"
