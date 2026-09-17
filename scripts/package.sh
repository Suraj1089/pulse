#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
APP_BUNDLE="$DIST_DIR/Pulse.app"
DMG_STAGING="$DIST_DIR/dmg_staging"
DMG_NAME="Pulse-$VERSION.dmg"
ZIP_NAME="Pulse-$VERSION.zip"

echo "==> Building release binary for version $VERSION..."
cd "$REPO_ROOT"
swift build -c release

echo "==> Creating clean app bundle structure..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$REPO_ROOT/.build/release/Pulse" "$APP_BUNDLE/Contents/MacOS/Pulse"
chmod +x "$APP_BUNDLE/Contents/MacOS/Pulse"

if [ -f "$REPO_ROOT/Sources/Pulse/Resources/Info.plist" ]; then
    cp "$REPO_ROOT/Sources/Pulse/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
fi

echo "==> Ad-hoc code signing the application..."
codesign --force --deep -s - "$APP_BUNDLE"

echo "==> Creating ZIP archive: $ZIP_NAME..."
(cd "$DIST_DIR" && zip -q -r -y "$ZIP_NAME" "Pulse.app")

echo "==> Preparing drag-and-drop DMG..."
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

echo "==> Creating DMG image: $DMG_NAME..."
hdiutil create -volname "Pulse" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DIST_DIR/$DMG_NAME"

rm -rf "$DMG_STAGING"

echo "==> Computing SHA-256 Checksums..."
DMG_SHA=$(shasum -a 256 "$DIST_DIR/$DMG_NAME" | awk '{print $1}')
ZIP_SHA=$(shasum -a 256 "$DIST_DIR/$ZIP_NAME" | awk '{print $1}')

echo ""
echo "=========================================================="
echo "          PULSE RELEASE PACKAGING COMPLETE"
echo "=========================================================="
echo "DMG File:   dist/$DMG_NAME"
echo "DMG SHA256: $DMG_SHA"
echo ""
echo "ZIP File:   dist/$ZIP_NAME"
echo "ZIP SHA256: $ZIP_SHA"
echo "=========================================================="

# Write out the Homebrew Cask formula
cat <<EOF > "$DIST_DIR/pulse.rb"
cask "pulse" do
  version "$VERSION"
  sha256 "$DMG_SHA"

  url "https://github.com/Suraj1089/pulse/releases/download/v#{version}/Pulse-#{version}.dmg"
  name "Pulse"
  desc "Minimalist, real-time memory monitor & command palette for macOS"
  homepage "https://github.com/Suraj1089/pulse"

  app "Pulse.app"

  zap trash: [
    "~/Library/Preferences/app.pulse.plist",
  ]
end
EOF

echo "Homebrew Cask formula generated at: dist/pulse.rb"
