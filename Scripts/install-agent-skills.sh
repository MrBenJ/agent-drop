#!/usr/bin/env bash
# Install the agent-drop-send skill for OpenClaw and/or Hermes agents.
set -euo pipefail

usage() {
    cat <<USAGE
Usage: install-agent-skills.sh [--openclaw] [--hermes] [--dry-run]

  --openclaw   install into \${OPENCLAW_SKILLS_DIR:-\$HOME/.openclaw/workspace/skills}
  --hermes     install into \${HERMES_SKILLS_DIR:-\$HOME/.hermes/skills/productivity}
  --dry-run    print destinations without copying anything
USAGE
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
do_openclaw=0
do_hermes=0
dry_run=0

for arg in "$@"; do
    case "$arg" in
        --openclaw) do_openclaw=1 ;;
        --hermes) do_hermes=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install-agent-skills.sh: unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$do_openclaw" -eq 0 ] && [ "$do_hermes" -eq 0 ]; then
    usage >&2
    exit 2
fi

install_skill() {
    local src="$1" dest_parent="$2"
    local dest="$dest_parent/agent-drop-send"
    if [ "$dry_run" -eq 1 ]; then
        echo "would install $dest"
        return
    fi
    mkdir -p "$dest_parent"
    rm -rf "$dest"
    cp -R "$src" "$dest"
    echo "installed $dest"
}

if [ "$do_openclaw" -eq 1 ]; then
    install_skill "$root/skills/openclaw/agent-drop-send" "${OPENCLAW_SKILLS_DIR:-$HOME/.openclaw/workspace/skills}"
fi
if [ "$do_hermes" -eq 1 ]; then
    install_skill "$root/skills/hermes/agent-drop-send" "${HERMES_SKILLS_DIR:-$HOME/.hermes/skills/productivity}"
fi

echo
echo "Note: restart the OpenClaw / Hermes gateway if it is already running, so it picks up the new skill."
