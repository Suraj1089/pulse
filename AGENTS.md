# AGENTS.md — Pulse

> Engineering reference for AI agents, contributors, and automated tooling.

## What is Pulse?

**Pulse** is a native macOS code editor (Swift + AppKit) built around one constraint: **stay at 50–60 MB of physical footprint in normal use and never exceed 100 MB**, with zero CPU while idle. It ships as a standalone `.app` (ad-hoc signed, not notarized).

- **Website**: <https://pulse0.app> (static, in `site/`; screenshots there and in `assets/` are cropped from the CI capture in `scripts/screenshot.sh`)
- **Install**: `curl -fsSL https://pulse0.app/install.sh | bash`

## Non-negotiables

The full contribution rules (what is out of scope, the restrictions CI enforces, the per-PR memory budget and the design guidelines) are in [CLAUDE.md › Contribution rules](CLAUDE.md#contribution-rules). They apply to every contributor and every AI tool, not only Claude. Reviews follow [REVIEW.md](REVIEW.md).


1. **Memory budget.** CI (`.github/workflows/ci.yml` → `scripts/memory-check.sh`) launches the app in five scenarios and fails above 100 MB. On pull requests `scripts/memory-compare.sh` also fails any change that adds more than 5 MB to a scenario or 512 KB to the executable compared with the base branch, unless a maintainer adds the `memory-approved` label.
2. **No idle work.** No polling timers while the app is inactive, no animations that run continuously, no background indexing that is not triggered by the user.
3. **AppKit only.** No SwiftUI, no WKWebView, no storyboards/XIBs. They each pull in large frameworks for things the editor does not need.
4. **One dependency.** SwiftTerm (terminal emulation), pinned with `exact:`. Releases from 1.19 on need swift-tools 6.x, which the `macos-14` release runner lacks. Think hard before adding another.
5. **Lazy by default.** The terminal, the go-to-file index, and folder contents are created on first use.

## Layout

```
Package.swift                 SwiftPM manifest (single executable target)
VERSION                       Release version; changing it on main publishes a release
Sources/Pulse/
├── main.swift                NSApplication bootstrap
├── App/
│   ├── AppDelegate.swift     Launch, open-file events, activation hooks
│   ├── WindowManager.swift   All windows: one per folder, routing opens, the saved session, update check, resource meter
│   ├── MainWindowController  One window (one folder); all menu commands (responder chain)
│   ├── MainMenu.swift        Menu bar built in code
│   └── Session.swift         session.json (folder, tabs, unsaved text) + recent folders
├── Editor/
│   ├── EditorViewController  The editor panes (split right/down), terminal split, status bar
│   ├── EditorPane            One pane: its tabs, path bar, text view, layout manager and gutter
│   ├── CodeTextView          NSTextView subclass: indent, comments, current line
│   ├── LineNumberRuler       Gutter; draws visible lines only
│   ├── SyntaxHighlighter     Regex pass → layout-manager temporary attributes
│   ├── Language.swift        Per-language rules + extension detection
│   ├── TabBarView / StatusBarView / EmptyStateView
│   ├── WelcomeController     Welcome tab (first launch, Help › Welcome); built when shown
│   ├── DiffViewController    Diff tab for a changed file (Source Control click)
├── Sidebar/                  File tree, project search panel, the switcher
├── Palette/CommandPalette    Go to file / commands / go to line, fuzzy matching
├── Terminal/TerminalPanel    Terminal tabs (+) and side-by-side panes (split), one SwiftTerm view and shell each, created on demand
├── Claude/                   Claude Code's IDE connection: ClaudeBridge (lock file, MCP replies, selection) on LoopbackWebSocketServer (BSD sockets)
├── Workspace/                Document (text + line index), FileNode, FileIndex, ProjectSearch, PathFilter (include/exclude globs)
├── Support/                  Theme (dynamic colors, fonts), ResourceMonitor
└── Resources/                Info.plist (embedded via linker), AppIcon.icns
scripts/
├── bundle.sh                 Fast single-arch dist/Pulse.app
├── policy-check.sh           CLAUDE.md restrictions R1–R6 (used by CI)
├── memory-check.sh           Memory budget scenarios (used by CI)
├── memory-compare.sh         PR vs. base build, alternating rounds (used by CI on PRs)
├── claude-ide-client.py      Stands in for Claude Code in the memory check's connected scenario
├── screenshot.sh             Real light/dark screenshots (CI publishes them to the `screenshots` branch)
├── package.sh                Universal release: DMG, ZIP, Homebrew cask
└── make-icons.swift         Every icon (app, site, favicon, README, social card) from assets/logo.svg
```

## Architecture notes

- **Documents vs. view.** A `Document` owns an `NSTextStorage`, its own `UndoManager`, and a lazily rebuilt line-start index. Each `EditorPane` has one `NSLayoutManager`/`CodeTextView`, and switching its tabs moves that layout manager onto the document's storage. A window has one pane until Split Editor Right / Down (⌥⌘\, the tab's right-click menu) adds one next to the active pane; panes nest in split views for a grid. A file in two panes is one `Document`: one storage, one undo history, a layout manager per pane. `replaceTextStorage` would move every layout manager on a storage (both panes), so a shared storage is left with `removeLayoutManager`/`addLayoutManager`. Temporary attributes (highlighting) are per layout manager, so each pane highlights what it shows. A pane closes with its last tab and detaches its layout manager. `documents` lists each file once across panes (session, autosave); commands, the status bar and Claude Code follow the focused pane. Panes are not restored by the session.
- **TextKit 1 on purpose.** Non-contiguous layout, `NSRulerView` line numbers and temporary attributes are mature and cheap there.
- **Highlighting.** One combined `NSRegularExpression` per language; alternatives are ordered so comments and strings win. Full pass up to 300 KB (debounced 80 ms after edits), visible range ±20k chars above that.
- **Autosave.** On by default: modified files with a path are written 1 s after typing stops, on app deactivation, and at quit. Untitled buffers (and everything, if autosave is off) survive via `~/Library/Application Support/Pulse/session.json`.
- **Diffs.** A click on a changed file in Source Control opens one reusable diff tab. `git diff` computes it in a short-lived process (`Workspace/GitDiff.swift`); Pulse reads at most 3 MB / 50,000 lines of output, keeps the text once (in the diff view's storage) plus 9 bytes a line, and draws line colors and the old/new number gutter for visible lines only. Diff tabs are not saved in the session.
- **Claude Code.** Each window speaks Claude Code's IDE protocol (what VS Code's extension does), so `claude` in its terminal shows "⧉ N lines selected". `Claude/ClaudeBridge.swift` starts with the window's first terminal, and only if Claude Code's config folder (`$CLAUDE_CONFIG_DIR` or `~/.claude`) exists. It then listens on 127.0.0.1 (`Claude/LoopbackWebSocketServer.swift`: BSD sockets and main-queue dispatch sources, no networking framework, no thread, no timer, no pings) and writes `~/.claude/ide/<port>.lock` (mode 0600: pid, folder, `ideName: "Pulse"`, auth token). New shells in that window get `CLAUDE_CODE_SSE_PORT` and `ENABLE_IDE_INTEGRATION=true`, and `/ide` works from other terminals. Handshakes need the token, no `Origin` and a loopback `Host`; the `mcp` subprotocol is echoed (the CLI requires it). Selection changes are debounced 100 ms and sent only while a client is connected. A caret moving within a file sends nothing, and the text is capped at 64K characters (the CLI keeps the first 2,000; the range carries the rest). Nothing is kept between sends. The CLI calls `closeAllDiffTabs`, `getDiagnostics` and `close_tab` whether or not they are listed; Pulse answers them and lists no tools. `openDiff` gets "tool not found", and the CLI then asks in the terminal as usual (checked against CLI 2.1.301). ⇧⌘K sends `at_mentioned` to the Claude whose process descends from the focused shell. The lock file is removed when the window closes; a killed Pulse's is cleaned up on the next start. Launch scratch builds with `CLAUDE_CONFIG_DIR` pointing at a temp folder, or a real `claude` (yours, or an agent's) can find and connect to them; tests and `scripts/memory-check.sh` already do.
- **Resource meter.** `proc_pid_rusage` for Pulse and for its direct children (shells), sampled every 2 s only while active. CPU ticks are converted with `mach_timebase_info`.

## Building

```bash
swift build                    # debug
swift run Pulse .              # run, opening the current folder
./scripts/bundle.sh            # dist/Pulse.app
./scripts/memory-check.sh      # budget check
```

## Release process

A push to `main` is released by `release.yml` only when its commit message contains `[release]` (for a merged PR, put it in the PR title; GitHub copies it into the merge commit), it passes CI (build, `swift test`, memory budget) and something in the app changed since the last release (pushes that only touch `site/`, `assets/`, `*.md`, `LICENSE`, `install.sh`, `Tests/` or `.github/` are skipped). It builds the universal app with `scripts/package.sh` and publishes `Pulse.dmg`, `Pulse.zip` and the Homebrew cask. `install.sh` and the in-app Update button both use `releases/latest`, so they always serve the newest release. A pushed `v*` tag or a manual run of the workflow always releases.

- Version: if the exact version in `VERSION` has no release yet, it is released as is (bump `VERSION` to `2.1.0` to ship 2.1.0). Otherwise the next patch is used (`2.0.0` → `2.0.1` → …). Pushing a `v*` tag releases that tag.
- Releases run one at a time and build the exact commit CI tested.
- `scripts/package.sh` marks release builds (`PulseReleaseBuild` in Info.plist). Only those check for updates on their own: at launch and at most once a day on activation, via a short-lived `curl` (`App/Updater.swift`). Pulse › Check for Updates… checks on demand in any build.
- An update downloads that release's `Pulse.zip`, checks the bundle id and version, quits Pulse, swaps the bundle in place and reopens it (tabs and unsaved text come back through session recovery). If the app's folder isn't writable, it offers to copy the install command.
- Releases are ad-hoc signed and not notarized (there is no Apple Developer ID), so macOS blocks a `Pulse.app` downloaded in a browser. The website and README therefore offer only `curl -fsSL https://pulse0.app/install.sh | bash` (the script clears the quarantine flag). Don't link the DMG or ZIP for download until releases are notarized; they are still published for the installer, the updater and the Homebrew cask.
- The website uses Google Analytics 4 (`G-MCM9LLHVXG`), loaded only on pulse0.app and only after a visitor clicks Accept in its cookie banner (`window.pulseAnalytics` in `site/index.html`; the choice is kept in `localStorage`, and Cookie settings in the footer changes it, deleting the `_ga` cookies on decline). Clicks on an install command's Copy button are sent as `copy_install_command`. If what is collected changes, update the site's PRIVACY.md section with it. The Pulse app itself collects nothing.
- The website names no version (so it can't go stale), and `site/VERSION` is not updated per release; downloads don't depend on it. When features or the memory numbers change, update `site/index.html`, `site/llms.txt`, `site/llms-full.txt` and the README together; the screenshots and `site/og-image.png` come from the CI capture on the `screenshots` branch.

## The `pulse` terminal command

`Sources/Pulse/Resources/pulse` is a shell script copied into `Pulse.app/Contents/Resources/` by `bundle.sh` and `package.sh`; it finds the app from its own real path and runs `open -a`. `App/CommandLineTool.swift` links it as `pulse` into the first writable, non-system folder on the user's PATH (read once from the login shell): automatically on the first launch of a release build, or from Pulse › Install 'pulse' Command, which falls back to `/usr/local/bin` with the macOS administrator prompt. It never replaces a different program named `pulse`, re-points links left at a moved or deleted Pulse.app, and never edits shell profiles. The Homebrew cask declares it with `binary`.

## Copyright

© 2026 pulse0.app · MIT licensed
