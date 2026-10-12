#!/usr/bin/env bash
# Real-binary smoke test (spec §8). It uses the REAL default paths
# (~/AgentDrop and ~/Library/Application Support/AgentDrop), so it only runs on
# ephemeral GitHub Actions machines, never on a developer's Mac.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "smoke.sh: skipped (runs only on GitHub Actions because it uses the real default paths)"
  exit 0
fi

DROP="${1:?usage: Scripts/smoke.sh <path-to-drop-binary>}"
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
echo "smoke: ok"
