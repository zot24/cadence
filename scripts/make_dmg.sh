#!/bin/bash
# Build Cadence.app and package it into a distributable Cadence.dmg
# (drag-to-Applications layout). Usage: scripts/make_dmg.sh [release|debug]
#
# Signing: build_app.sh ad-hoc signs the app, which is enough to run locally
# (and elsewhere via right-click > Open). For frictionless distribution to other
# Macs, set DEV_ID to a "Developer ID Application: …" identity and the app is
# re-signed with it here; you then still need to notarize the .dmg with
# `xcrun notarytool submit` + `xcrun stapler staple` (requires an Apple account).
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

scripts/build_app.sh "$CONFIG"
APP="build/Cadence.app"
DMG="build/Cadence.dmg"
STAGE="build/dmg-stage"

# Optional real signing if a Developer ID identity is provided.
if [ -n "${DEV_ID:-}" ]; then
  echo "▸ Signing with Developer ID: $DEV_ID"
  codesign --force --deep --options runtime --sign "$DEV_ID" "$APP"
fi

echo "▸ Staging DMG contents…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Cadence.app"
ln -s /Applications "$STAGE/Applications"

echo "▸ Building ${DMG}…"
hdiutil create -volname "Cadence" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|flags" | sed 's/^/  /'
