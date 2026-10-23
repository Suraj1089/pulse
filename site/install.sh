#!/usr/bin/env bash
# ==============================================================================
# Pulse One-Line Installer for macOS
# Install: curl -fsSL https://pulse0.app/install.sh | bash
# A specific release (newer or older than the one you have):
#          curl -fsSL https://pulse0.app/install.sh | bash -s -- 2.1.3
# `pulse --upgrade` and `pulse --downgrade` run this script with the version
# and PULSE_INSTALL_DIR set to the folder their Pulse.app is in.
# ==============================================================================
set -euo pipefail

REPO="Suraj1089/pulse"
APP_NAME="Pulse.app"
INSTALL_DIR="${PULSE_INSTALL_DIR:-/Applications}"
RELEASES="https://github.com/$REPO/releases"
ZIP_URL="$RELEASES/latest/download/Pulse.zip"

# Colors only when the terminal can show them.
if [ -t 2 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; GREEN=""; RED=""; RESET=""
fi

# Output never stops the install: run from Pulse's own terminal, that
# terminal is gone once the running copy quits below (printf's complaint
# about it goes to /dev/null; the text itself still goes to stderr).
say() { printf "$@" >&2 2>/dev/null || true; }
step() { say '%s==>%s %s\n' "$BOLD$GREEN" "$RESET$BOLD" "$1$RESET"; }
info() { say '    %s\n' "$DIM$1$RESET"; }
fail() { say '%sError:%s %s\n' "$BOLD$RED" "$RESET" "$1"; exit 1; }

# Everything runs inside main, so a partially downloaded script does nothing.
main() {
    [ "$(uname -s)" = "Darwin" ] || fail "Pulse runs on macOS only."
    # Run from Pulse's own terminal, the shell hangs up when Pulse quits below; finish anyway.
    trap '' HUP

    # An optional version to install instead of the latest: 2.1.3 or v2.1.3.
    local wanted="${1:-}"
    wanted="${wanted#v}"
    case "$wanted" in
        *[!0-9.]*|.*|*.) fail "'$1' is not a version. To install Pulse 2.1.3: curl -fsSL https://pulse0.app/install.sh | bash -s -- 2.1.3" ;;
    esac

    tmp="$(mktemp -d -t pulse-install)"
    trap 'rm -rf "${tmp:-}"' EXIT

    step "Downloading Pulse"
    local url version
    if [ -n "$wanted" ]; then
        version="v$wanted"
        url="$RELEASES/download/$version/Pulse.zip"
        info "From $url"
    else
        info "From $ZIP_URL"
        # Resolve "latest" to the actual release so the log can name the version.
        url="$(curl -fsS -o /dev/null -w '%{redirect_url}' "$ZIP_URL" 2>/dev/null || true)"
        version="$(printf '%s' "$url" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')"
        [ -n "$url" ] || url="$ZIP_URL"
    fi
    if [ -n "$version" ]; then info "Version $version"; fi

    # --progress-bar draws on stderr, which is still the terminal when piped to bash.
    local bytes
    bytes="$(curl -fL --progress-bar -o "$tmp/Pulse.zip" -w '%{size_download}' "$url")" \
        || fail "Download failed.${wanted:+ Is $wanted a Pulse release? See $RELEASES.} Check your connection and run the command again."
    info "Downloaded $(awk -v b="$bytes" 'BEGIN { printf "%.1f MB", b / 1048576 }')"

    step "Unpacking"
    unzip -q -o "$tmp/Pulse.zip" -d "$tmp/extract"
    [ -d "$tmp/extract/$APP_NAME" ] || fail "The download did not contain $APP_NAME."
    info "$APP_NAME ready"

    if pgrep -x Pulse >/dev/null 2>&1; then
        step "Quitting the running copy of Pulse"
        info "It reopens with your tabs when the install is done"
        pkill -x Pulse 2>/dev/null || true
        sleep 1
    fi

    step "Installing to $INSTALL_DIR"
    if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
        info "Replacing the existing $APP_NAME"
    fi
    rm -rf "${INSTALL_DIR:?}/$APP_NAME"
    cp -R "$tmp/extract/$APP_NAME" "$INSTALL_DIR/$APP_NAME" \
        || fail "Could not write to $INSTALL_DIR. Try again with: curl -fsSL https://pulse0.app/install.sh | sudo bash${wanted:+ -s -- $wanted}"
    info "Copied $APP_NAME"

    step "Clearing the macOS quarantine flag"
    xattr -cr "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true
    info "Pulse is ad-hoc signed, so this lets it open without a Gatekeeper prompt"

    step "Opening Pulse"
    open "$INSTALL_DIR/$APP_NAME"

    say '\n%sPulse%s is installed in %s.%s\n' "$BOLD$GREEN" "${version:+ $version}" "$INSTALL_DIR" "$RESET"

    # On its first launch Pulse links the `pulse` command into a folder on
    # your PATH (when that needs no password); give it a moment to appear.
    local found=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        hash -r
        if command -v pulse >/dev/null 2>&1; then found=1; break; fi
        sleep 0.5
    done
    if [ -n "$found" ]; then
        say 'Open a folder from Terminal with: %spulse .%s\n' "$BOLD" "$RESET"
        info "In a new terminal tab (or run \`rehash\` in this one)"
    else
        say 'To open folders from Terminal with %spulse .%s, choose %sPulse > Install '"'"'pulse'"'"' Command%s in the app.\n' \
            "$BOLD" "$RESET" "$BOLD" "$RESET"
        info "Until then, this works too: open -a Pulse ."
    fi
}

main "$@"
