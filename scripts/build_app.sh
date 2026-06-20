#!/bin/bash
# Build Cadence.app — a self-contained macOS app bundle from the SwiftPM build.
# Usage: scripts/build_app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG"
APP="build/Cadence.app"
VERSION="0.1.0"
BUNDLE_ID="com.sotoisra.cadence"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The app binary and the recorder shim live side by side in MacOS/ so the app
# can find and install the recorder regardless of where it is moved.
cp "$BIN/Cadence" "$APP/Contents/MacOS/Cadence"
cp "$BIN/cadence-rec" "$APP/Contents/MacOS/cadence-rec"
chmod +x "$APP/Contents/MacOS/Cadence" "$APP/Contents/MacOS/cadence-rec"

# App icon (regenerate if missing).
ICON="Sources/Cadence/Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then swift scripts/make_icon.swift "$ICON" >/dev/null 2>&1 || true; fi
[ -f "$ICON" ] && cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Cadence</string>
    <key>CFBundleDisplayName</key>       <string>Cadence</string>
    <key>CFBundleExecutable</key>        <string>Cadence</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Ad-hoc codesign so it launches locally without Gatekeeper friction.
echo "▸ Ad-hoc signing…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ Built $APP"
echo "  Run with:  open $APP"
