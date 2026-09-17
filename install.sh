#!/usr/bin/env bash
# ==============================================================================
# Pulse One-Line Installer for macOS
# Install: curl -fsSL https://raw.githubusercontent.com/Suraj1089/pulse/main/install.sh | bash
# ==============================================================================
set -euo pipefail

REPO="Suraj1089/pulse"
APP_NAME="Pulse.app"
INSTALL_DIR="/Applications"

echo "==> Fetching latest release of Pulse..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    LATEST_TAG="v1.0.0"
fi

VERSION="${LATEST_TAG#v}"
ZIP_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/Pulse-$VERSION.zip"
TMP_ZIP="/tmp/Pulse-$VERSION.zip"
TMP_DIR="/tmp/Pulse_extract"

echo "==> Downloading Pulse $LATEST_TAG..."
curl -fsSL -L "$ZIP_URL" -o "$TMP_ZIP"

echo "==> Installing to $INSTALL_DIR..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
unzip -q -o "$TMP_ZIP" -d "$TMP_DIR"

# Kill existing instance if running
pkill -x Pulse 2>/dev/null || true

# Copy into /Applications
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$TMP_DIR/$APP_NAME" "$INSTALL_DIR/$APP_NAME"

# Clear Gatekeeper quarantine flag
xattr -cr "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true

# Clean up
rm -rf "$TMP_ZIP" "$TMP_DIR"

echo "=========================================================="
echo "  Pulse $LATEST_TAG installed successfully to $INSTALL_DIR!"
echo "  Opening Pulse..."
echo "=========================================================="

open "$INSTALL_DIR/$APP_NAME"
