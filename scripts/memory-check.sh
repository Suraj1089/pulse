#!/usr/bin/env bash
# Launches Pulse in three scenarios and reads its physical footprint (the
# number Activity Monitor shows as "Memory") with vmmap.
#
#   1. empty window
#   2. ten source files open
#   3. ten files open + terminal (shell measured separately)
#
# Fails if Pulse itself goes over MAX_MB in any scenario. TARGET_MB is the
# goal we report against.
#
#   ./scripts/memory-check.sh dist/Pulse.app
set -euo pipefail

APP="${1:-dist/Pulse.app}"
BIN="$APP/Contents/MacOS/Pulse"
MAX_MB="${MAX_MB:-100}"
TARGET_MB="${TARGET_MB:-60}"
SETTLE="${SETTLE:-8}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Ten real files from this repo as the "several files open" fixture.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(find "$REPO_ROOT/Sources/Pulse" -name '*.swift' | sort | head -10)

# Start from a clean session so earlier runs don't change what opens.
SESSION="$HOME/Library/Application Support/Pulse/session.json"

footprint_mb() {
    # vmmap prints e.g. "Physical footprint:         41.2M"
    local line value unit
    line="$(vmmap --summary "$1" 2>/dev/null | grep -m1 'Physical footprint:' || true)"
    value="$(echo "$line" | awk '{print $3}')"
    unit="${value: -1}"
    value="${value%?}"
    case "$unit" in
        K) awk -v v="$value" 'BEGIN { printf "%.1f", v / 1024 }' ;;
        M) awk -v v="$value" 'BEGIN { printf "%.1f", v }' ;;
        G) awk -v v="$value" 'BEGIN { printf "%.1f", v * 1024 }' ;;
        *) echo "0" ;;
    esac
}

children_mb() {
    local total=0 child mb
    for child in $(pgrep -P "$1" || true); do
        mb="$(footprint_mb "$child")"
        total="$(awk -v a="$total" -v b="$mb" 'BEGIN { printf "%.1f", a + b }')"
    done
    echo "$total"
}

FAILED=0
RESULTS=()

run_scenario() {
    local name="$1"; shift
    rm -f "$SESSION"
    env "$@" &
    local pid=$!
    sleep "$SETTLE"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "::error::Pulse exited during scenario '$name'"
        FAILED=1
        return
    fi
    local mb shells
    mb="$(footprint_mb "$pid")"
    shells="$(children_mb "$pid")"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$SESSION"

    local verdict="ok"
    if awk -v m="$mb" -v t="$MAX_MB" 'BEGIN { exit !(m > t) }'; then
        verdict="OVER ${MAX_MB} MB"
        FAILED=1
    elif awk -v m="$mb" -v t="$TARGET_MB" 'BEGIN { exit !(m > t) }'; then
        verdict="above ${TARGET_MB} MB target"
    fi
    RESULTS+=("| $name | $mb MB | $shells MB | $verdict |")
    echo "$name: Pulse ${mb} MB, child processes ${shells} MB ($verdict)"
}

run_scenario "Empty window" "$BIN"
run_scenario "10 files open" "$BIN" "${FILES[@]}"
run_scenario "10 files + terminal" PULSE_OPEN_TERMINAL=1 "$BIN" "${FILES[@]}"

{
    echo "### Pulse memory (physical footprint)"
    echo ""
    echo "Budget: ${MAX_MB} MB hard limit · ${TARGET_MB} MB target · measured ${SETTLE}s after launch"
    echo ""
    echo "| Scenario | Pulse | Child processes | Result |"
    echo "|---|---|---|---|"
    printf '%s\n' "${RESULTS[@]}"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

exit "$FAILED"
