#!/bin/bash
# Builds AgentDrop.app from the AgentDrop executable: .build/AgentDrop.app.
# Usage: Scripts/build-app.sh [debug|release] [--universal]
#   --universal  arm64 + x86_64 in one binary (what releases ship); slower to build.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="release"
arch_flags=()
for argument in "$@"; do
  case "$argument" in
    debug|release) configuration="$argument" ;;
    --universal) arch_flags=(--arch arm64 --arch x86_64) ;;
    *) echo "usage: Scripts/build-app.sh [debug|release] [--universal]" >&2; exit 1 ;;
  esac
done
swift build -c "$configuration" ${arch_flags[@]+"${arch_flags[@]}"} --product AgentDrop
bin="$(swift build -c "$configuration" ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)"
app=".build/AgentDrop.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/AgentDrop" "$app/Contents/MacOS/AgentDrop"
cp App/Info.plist "$app/Contents/Info.plist"
cp App/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
plutil -lint "$app/Contents/Info.plist" >/dev/null
# Ad-hoc signature: not notarized (spec §1 non-goals), but a signed bundle is what
# notifications and the login item expect.
codesign --force --sign - "$app"
echo "$app"
