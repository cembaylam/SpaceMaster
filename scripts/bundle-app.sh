#!/bin/bash
# Build the SwiftPM executable and assemble + sign build/SpaceMaster.app.
# Usage: scripts/bundle-app.sh [debug|release]
set -euo pipefail
CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product SpaceMaster
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/SpaceMaster.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SpaceMaster" "$APP/Contents/MacOS/SpaceMaster"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --options runtime --entitlements Resources/SpaceMaster.entitlements "$APP" >/dev/null
echo "$APP"
