#!/usr/bin/env bash
# Mechanical checks for the hard rules in CLAUDE.md ("Restrictions"). Each
# failure names its rule (R1, R2, ...). Runs anywhere bash and grep run;
# CI runs it on every push and pull request.
#
#   ./scripts/policy-check.sh
#
# The allowlists below are the only way to add an exception, so an exception
# always shows up in the diff of this file, which CODEOWNERS routes to the
# maintainer. Do not add inline "ignore" comments.
set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0
fail() {
    # $1 rule, $2 file (or "-"), $3 message
    FAILED=1
    if [ "$2" = "-" ]; then
        echo "::error title=$1::$3"
    else
        echo "::error file=$2,title=$1::$3"
    fi
    echo "  ✗ [$1] ${2/#-/(repo)}: $3" >&2
}

in_list() {
    local needle="$1"; shift
    for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
    return 1
}

APP_SOURCES="Sources/Pulse"

# ---------------------------------------------------------------------------
# R1. Frameworks: AppKit, Foundation, Darwin and SwiftTerm only.
#     (No SwiftUI, WebKit, Combine, CoreData, ML, analytics or AI SDKs.)
ALLOWED_IMPORTS=(AppKit Foundation Darwin SwiftTerm)
ALLOWED_TEST_IMPORTS=(AppKit Foundation Darwin SwiftTerm XCTest Pulse)

check_imports() {
    local dir="$1"; shift
    local allowed=("$@")
    while IFS=: read -r file line text; do
        module="$(echo "$text" | sed -E 's/^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*).*/\4/')"
        if ! in_list "$module" "${allowed[@]}"; then
            fail R1 "$file" "line $line imports '$module'. Allowed: ${allowed[*]}. See CLAUDE.md › Restrictions."
        fi
    done < <(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+' "$dir" --include='*.swift' 2>/dev/null)
}
check_imports "$APP_SOURCES" "${ALLOWED_IMPORTS[@]}"
[ -d Tests ] && check_imports Tests "${ALLOWED_TEST_IMPORTS[@]}"

# ---------------------------------------------------------------------------
# R2. Dependencies: exactly one package, SwiftTerm, pinned with exact:.
PACKAGE_LINES="$(grep -cE '\.package\(' Package.swift || true)"
if [ "$PACKAGE_LINES" != "1" ]; then
    fail R2 Package.swift "declares $PACKAGE_LINES packages; only SwiftTerm is allowed."
fi
if ! grep -qE '\.package\(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "[0-9.]+"\)' Package.swift; then
    fail R2 Package.swift "SwiftTerm must be pinned with exact:."
fi
if [ -f Package.resolved ]; then
    ALLOWED_PINS=(swiftterm swift-argument-parser)
    while read -r identity; do
        in_list "$identity" "${ALLOWED_PINS[@]}" || fail R2 Package.resolved "resolves unexpected package '$identity'."
    done < <(grep -oE '"identity"[[:space:]]*:[[:space:]]*"[^"]+"' Package.resolved | sed -E 's/.*"([^"]+)"$/\1/')
fi

# ---------------------------------------------------------------------------
# R3. No network APIs and no web views. The updater talks to GitHub through
#     a short-lived curl process; nothing else goes on the network.
while IFS=: read -r file line _; do
    fail R3 "$file" "line $line uses a network or web-view API. Pulse makes no network requests (CLAUDE.md › Restrictions)."
done < <(grep -rnE '\b(URLSession|URLRequest|NWConnection|NWListener|NWPathMonitor|CFNetwork|WKWebView|WebView|JSContext|JSVirtualMachine)\b' "$APP_SOURCES" --include='*.swift' 2>/dev/null)

CURL_ALLOWED=("$APP_SOURCES/App/Updater.swift")
while IFS=: read -r file line _; do
    in_list "$file" "${CURL_ALLOWED[@]}" || fail R3 "$file" "line $line runs curl. Only App/Updater.swift may."
done < <(grep -rnE '(/usr/bin/curl|"curl")' "$APP_SOURCES" --include='*.swift' 2>/dev/null)

# ---------------------------------------------------------------------------
# R4. No idle work: repeating timers, display links and timer sources only
#     in the resource meter (which stops while Pulse is inactive).
TIMER_ALLOWED=("$APP_SOURCES/Support/ResourceMonitor.swift")
while IFS=: read -r file line _; do
    in_list "$file" "${TIMER_ALLOWED[@]}" || fail R4 "$file" "line $line adds a repeating timer, display link or timer source. Pulse does no work while idle."
done < <(grep -rnE '(repeats:[[:space:]]*true|scheduledTimer|CADisplayLink|CVDisplayLink|displayLink\(|makeTimerSource|DispatchSourceTimer|NSAnimation\b)' "$APP_SOURCES" --include='*.swift' 2>/dev/null)

# File-system watchers keep work running in the background. Pulse refreshes
# when the app becomes active instead.
while IFS=: read -r file line _; do
    fail R4 "$file" "line $line watches the file system continuously. Refresh on activation instead."
done < <(grep -rnE '\b(FSEventStream[A-Za-z]*|makeFileSystemObjectSource|NSFilePresenter|kqueue)\b' "$APP_SOURCES" --include='*.swift' 2>/dev/null)

# ---------------------------------------------------------------------------
# R5. Child processes only where they are short-lived and accounted for.
PROCESS_ALLOWED=(
    "$APP_SOURCES/Workspace/ProjectSearch.swift"   # ripgrep, one search
    "$APP_SOURCES/Workspace/GitStatus.swift"       # git status, on activation
    "$APP_SOURCES/Workspace/GitDiff.swift"         # git diff, one file
    "$APP_SOURCES/App/Updater.swift"               # curl / ditto, on update
    "$APP_SOURCES/App/CommandLineTool.swift"       # login shell PATH lookup, once
)
while IFS=: read -r file line _; do
    in_list "$file" "${PROCESS_ALLOWED[@]}" || fail R5 "$file" "line $line starts a child process. Allowed only in: ${PROCESS_ALLOWED[*]##*/}."
done < <(grep -rnE '(\bProcess\(\)|posix_spawn|NSTask\b)' "$APP_SOURCES" --include='*.swift' 2>/dev/null)

# ---------------------------------------------------------------------------
# R6. Bundle contents: no Interface Builder files, asset catalogs, fonts or
#     media; only the listed resources ship.
while IFS= read -r file; do
    fail R6 "$file" "Interface Builder files and asset catalogs are not allowed; build UI in code."
done < <(find Sources -name '*.storyboard' -o -name '*.xib' -o -name '*.nib' -o -name '*.xcassets' 2>/dev/null)

ALLOWED_RESOURCES=(Info.plist AppIcon.icns AppIcon.iconset pulse)
if [ -d "$APP_SOURCES/Resources" ]; then
    for entry in "$APP_SOURCES"/Resources/*; do
        name="$(basename "$entry")"
        in_list "$name" "${ALLOWED_RESOURCES[@]}" || fail R6 "$entry" "is not an allowed resource (${ALLOWED_RESOURCES[*]}). Fonts, images and media grow the app and its memory."
    done
fi
while IFS= read -r file; do
    case "$file" in "$APP_SOURCES"/Resources/*) continue ;; esac
    fail R6 "$file" "media and font files belong nowhere in Sources/."
done < <(find Sources -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.pdf' -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.ttf' -o -iname '*.otf' -o -iname '*.woff*' \) 2>/dev/null)

# ---------------------------------------------------------------------------
if [ "$FAILED" -ne 0 ]; then
    echo ""
    echo "Policy check failed. These rules protect Pulse's memory and idle budget;"
    echo "see CLAUDE.md › Restrictions. An exception needs the maintainer's"
    echo "agreement and an allowlist change in scripts/policy-check.sh."
    exit 1
fi
echo "Policy check passed (R1 frameworks, R2 dependencies, R3 network, R4 idle work, R5 processes, R6 bundle)."
