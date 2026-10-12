#!/bin/bash
# Builds the release zip: universal (arm64 + x86_64) AgentDrop.app and drop, plus
# INSTALL.txt, in .build/release-artifacts/AgentDrop-<version>.zip (+ .sha256).
# Usage: Scripts/package-release.sh <version>      e.g. 0.1.0 (the tag without "v")
# Fails unless <version> matches both App/Info.plist and `drop --version`, so a
# release can never ship mislabeled binaries.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "package-release: $*" >&2; exit 1; }

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: Scripts/package-release.sh <major.minor.patch>"
plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
[[ "$plist_version" == "$version" ]] || fail "App/Info.plist says $plist_version, not $version"

universal=(--arch arm64 --arch x86_64)
swift build -c release "${universal[@]}" --product drop
bin="$(swift build -c release "${universal[@]}" --show-bin-path)"
cli_version="$("$bin/drop" --version)"
[[ "$cli_version" == "$version" ]] || fail "drop --version says $cli_version, not $version"
Scripts/build-app.sh release --universal >/dev/null

app=".build/AgentDrop.app"
for binary in "$bin/drop" "$app/Contents/MacOS/AgentDrop"; do
  lipo "$binary" -verify_arch arm64 x86_64 || fail "$binary is not universal"
done
codesign --verify --strict "$app" || fail "AgentDrop.app's signature doesn't verify"

name="AgentDrop-$version"
out=".build/release-artifacts"
stage="$out/$name"
rm -rf "$out"
mkdir -p "$stage"
ditto "$app" "$stage/AgentDrop.app"
cp "$bin/drop" "$stage/drop"
codesign --force --sign - "$stage/drop"
cat > "$stage/INSTALL.txt" <<TXT
Agent Drop $version (macOS 14 or later, Apple silicon and Intel)

1. Install the app:  cp -R AgentDrop.app /Applications/
2. Install the CLI:  cp drop /usr/local/bin/drop     (or any directory on your PATH; may need sudo)
3. These builds are ad-hoc signed, not notarized. macOS quarantines browser downloads,
   so clear that once (or right-click AgentDrop.app in Finder → Open, and confirm):
     xattr -dr com.apple.quarantine /Applications/AgentDrop.app /usr/local/bin/drop
4. open /Applications/AgentDrop.app     The first launch shows setup.

Teach your agents:  drop agent-instructions >> CLAUDE.md     (or AGENTS.md)
More: https://github.com/MrBenJ/agent-drop
TXT
# ditto keeps the app's code signature and any symlinks intact (zip -r doesn't).
(cd "$out" && ditto -c -k --keepParent "$name" "$name.zip" && shasum -a 256 "$name.zip" > "$name.zip.sha256")
echo "$out/$name.zip"
