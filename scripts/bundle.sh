#!/usr/bin/env bash
# Builds Pulse for this Mac's architecture and wraps it in dist/Pulse.app.
# Fast path for local testing and CI. For the universal release build
# (DMG, ZIP, Homebrew cask) use scripts/package.sh.
#
#   ./scripts/bundle.sh && open dist/Pulse.app
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$REPO_ROOT/dist/Pulse.app"

cd "$REPO_ROOT"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Pulse" "$APP/Contents/MacOS/Pulse"
cp Sources/Pulse/Resources/Info.plist "$APP/Contents/Info.plist"
cp Sources/Pulse/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -f VERSION ]; then
    plutil -replace CFBundleShortVersionString -string "$(tr -d '[:space:]' < VERSION)" "$APP/Contents/Info.plist"
fi
codesign --force --deep -s - "$APP" >/dev/null

echo "Built $APP"
