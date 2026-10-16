#!/usr/bin/env bash
# Compares a candidate build of Pulse with a baseline build (usually main)
# on the same machine: memory in each memory-check.sh scenario and the size
# of the executable. Fails when the candidate costs more than the allowed
# increase, so a feature that quietly adds memory is caught even while the
# total stays under the 100 MB ceiling.
#
#   ./scripts/memory-compare.sh base/dist/Pulse.app dist/Pulse.app
#
# Readings drift between runs, so builds are measured in alternating rounds
# (base, head, head, base, ...) and medians are compared.
#
#   ROUNDS=3                 rounds per build
#   MAX_DELTA_MB=5           allowed increase per scenario, in MB
#   MAX_SIZE_DELTA_KB=512    allowed growth of the executable, in KB
#   ALLOW_INCREASE=1         report increases as warnings instead of failing
#                            (CI sets this when a maintainer adds the
#                            `memory-approved` label)
set -euo pipefail

BASE_APP="$1"
HEAD_APP="$2"
ROUNDS="${ROUNDS:-3}"
MAX_DELTA_MB="${MAX_DELTA_MB:-5}"
MAX_SIZE_DELTA_KB="${MAX_SIZE_DELTA_KB:-512}"
ALLOW_INCREASE="${ALLOW_INCREASE:-0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

measure() {
    # $1 app, $2 results file. memory-check.sh's own 100 MB check still
    # prints; its exit status is ignored here and enforced by its own CI step.
    RESULTS_FILE="$2" SUMMARY_FILE=/dev/null "$HERE/memory-check.sh" "$1" >/dev/null 2>&1 || true
}

for round in $(seq 1 "$ROUNDS"); do
    if [ $((round % 2)) -eq 1 ]; then
        measure "$BASE_APP" "$WORK/base.tsv"; measure "$HEAD_APP" "$WORK/head.tsv"
    else
        measure "$HEAD_APP" "$WORK/head.tsv"; measure "$BASE_APP" "$WORK/base.tsv"
    fi
    echo "round $round/$ROUNDS done"
done

median() {
    # $1 file, $2 scenario, $3 column (2 = Pulse, 3 = children)
    awk -F'\t' -v s="$2" -v c="$3" '$1 == s { print $c }' "$1" | sort -n |
        awk '{ v[NR] = $1 } END { if (NR == 0) { print "n/a"; exit } if (NR % 2) print v[(NR + 1) / 2]; else printf "%.1f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

FAILED=0
ROWS=()
while IFS= read -r scenario; do
    base="$(median "$WORK/base.tsv" "$scenario" 2)"
    head="$(median "$WORK/head.tsv" "$scenario" 2)"
    head_children="$(median "$WORK/head.tsv" "$scenario" 3)"
    if [ "$base" = "n/a" ] || [ "$head" = "n/a" ]; then
        ROWS+=("| $scenario | $base | $head | – | – | could not measure |")
        FAILED=1
        continue
    fi
    delta="$(awk -v a="$head" -v b="$base" 'BEGIN { printf "%+.1f", a - b }')"
    verdict="ok"
    if awk -v d="$delta" -v m="$MAX_DELTA_MB" 'BEGIN { exit !(d > m) }'; then
        if [ "$ALLOW_INCREASE" = "1" ]; then
            verdict="⚠️ +${delta#+} MB, approved by maintainer"
        else
            verdict="❌ more than +$MAX_DELTA_MB MB"
            FAILED=1
        fi
    fi
    ROWS+=("| $scenario | $base MB | $head MB | $delta MB | $head_children MB | $verdict |")
done < <(cut -f1 "$WORK/head.tsv" | awk '!seen[$0]++')

size_kb() { du -k "$1/Contents/MacOS/Pulse" | cut -f1; }
base_kb="$(size_kb "$BASE_APP")"
head_kb="$(size_kb "$HEAD_APP")"
size_delta=$((head_kb - base_kb))
size_verdict="ok"
if [ "$size_delta" -gt "$MAX_SIZE_DELTA_KB" ]; then
    if [ "$ALLOW_INCREASE" = "1" ]; then
        size_verdict="⚠️ approved by maintainer"
    else
        size_verdict="❌ more than +$MAX_SIZE_DELTA_KB KB"
        FAILED=1
    fi
fi

{
    echo "### Memory compared with the base branch"
    echo ""
    echo "Median of $ROUNDS alternating rounds per build, physical footprint. Allowed increase: $MAX_DELTA_MB MB per scenario, $MAX_SIZE_DELTA_KB KB of executable."
    echo ""
    echo "| Scenario | Base | This PR | Change | Child processes (PR) | Result |"
    echo "|---|---|---|---|---|---|"
    printf '%s\n' "${ROWS[@]}"
    echo "| Executable size | $base_kb KB | $head_kb KB | $(printf '%+d' "$size_delta") KB | – | $size_verdict |"
    echo ""
    if [ "$FAILED" -ne 0 ]; then
        echo "**This change makes Pulse use more memory than the budget allows.** If the increase is intended, explain what it buys in the PR description; a maintainer can accept it by adding the \`memory-approved\` label. See CLAUDE.md › Memory budget for contributions."
    fi
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

exit "$FAILED"
