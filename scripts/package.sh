#!/bin/bash
# Release build → signed app → DMG (→ notarized when credentials exist).
#   SIGN_ID="Developer ID Application: Name (TEAMID)"  signing identity (default: auto-detect, else ad-hoc)
#   NOTARY_PROFILE=name                                 notarytool keychain profile (skip notarization if unset)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/SpaceMaster.app"
ENT="Resources/SpaceMaster.entitlements"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="$ROOT/dist/SpaceMaster-$VERSION.dmg"

if [[ -z "${SIGN_ID:-}" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi
SIGN_ID="${SIGN_ID:--}"

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift >/dev/null
scripts/bundle-app.sh release >/dev/null
strip -x "$APP/Contents/MacOS/SpaceMaster"

SIGN_ARGS=(--force --options runtime --sign "$SIGN_ID")
[[ "$SIGN_ID" != "-" ]] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" --entitlements "$ENT" "$APP"
codesign --verify --strict --deep "$APP"

# Styled DMG: app + /Applications shortcut, compressed.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
rm -f "$DMG"
hdiutil create -quiet -volname "SpaceMaster $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO "$DMG"
[[ "$SIGN_ID" != "-" ]] && codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

if [[ "$SIGN_ID" != "-" && -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    STATUS="Developer ID signed, notarized, stapled"
elif [[ "$SIGN_ID" != "-" ]]; then
    STATUS="Developer ID signed, NOT notarized (set NOTARY_PROFILE)"
else
    STATUS="ad-hoc signed (no Developer ID identity): on another Mac run 'xattr -dr com.apple.quarantine /Applications/SpaceMaster.app'"
fi
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG"
echo "signing: $SIGN_ID — $STATUS"
