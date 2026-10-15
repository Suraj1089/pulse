#!/usr/bin/env bash
# Launches Pulse with a few files and the terminal open, then captures the
# screen in light and dark appearance. Used by CI to produce real
# screenshots for the README and website.
#
#   ./scripts/screenshot.sh dist/Pulse.app
set -euo pipefail

APP="${1:-dist/Pulse.app}"
BIN="$APP/Contents/MacOS/Pulse"
OUT="${OUT:-dist/screenshots}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="$HOME/Library/Application Support/Pulse/session.json"
mkdir -p "$OUT"

# The repo folder first (it becomes the sidebar root), then the tabs; the
# last file is the active one.
FILES=(
    "$REPO_ROOT"
    "$REPO_ROOT/README.md"
    "$REPO_ROOT/Sources/Pulse/Editor/Language.swift"
    "$REPO_ROOT/Sources/Pulse/Editor/EditorViewController.swift"
    "$REPO_ROOT/Sources/Pulse/Workspace/Document.swift"
)

shoot() {
    local name="$1" style="$2"
    rm -f "$SESSION"
    PULSE_DEBUG_LAYOUT=1 PULSE_OPEN_TERMINAL=1 PULSE_APPEARANCE="$style" "$BIN" "${FILES[@]}" &
    local pid=$!
    sleep 8
    screencapture -x "$OUT/$name.png" || echo "screencapture failed for $name"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$SESSION"
}

system_profiler SPDisplaysDataType | grep -i resolution || true
shoot light light
shoot dark dark
ls -la "$OUT"
