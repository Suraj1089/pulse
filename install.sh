#!/usr/bin/env bash
# ==============================================================================
# Pulse One-Line Installer for macOS
# Install: curl -fsSL https://pulse0.app/install.sh | bash
# ==============================================================================
set -euo pipefail

REPO="Suraj1089/pulse"
APP_NAME="Pulse.app"
INSTALL_DIR="/Applications"

ZIP_URL="https://github.com/$REPO/releases/latest/download/Pulse.zip"
TMP_ZIP="/tmp/Pulse.zip"
TMP_DIR="/tmp/Pulse_extract"

echo "==> Downloading Pulse..."
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
echo "  Pulse installed successfully to $INSTALL_DIR!"
echo "  Opening Pulse..."
echo "=========================================================="

open "$INSTALL_DIR/$APP_NAME"
