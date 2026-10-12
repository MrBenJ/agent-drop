#!/bin/bash
# Builds AgentDrop.app from the AgentDrop executable: .build/AgentDrop.app.
# Usage: Scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration" --product AgentDrop
bin="$(swift build -c "$configuration" --show-bin-path)"
app=".build/AgentDrop.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/AgentDrop" "$app/Contents/MacOS/AgentDrop"
cp App/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
# Ad-hoc signature: not notarized (spec §1 non-goals), but a signed bundle is what
# notifications and the login item expect.
codesign --force --sign - "$app"
echo "$app"
