# AGENTS.md — Pulse

> Engineering reference for AI agents, contributors, and automated tooling.

## What is Pulse?

**Pulse** is a native macOS code editor (Swift + AppKit) built around one constraint: **stay at 50–60 MB of physical footprint in normal use and never exceed 100 MB**, with zero CPU while idle. It ships as a standalone `.app` (ad-hoc signed, not notarized).

- **Website**: <https://pulse0.app> (static, in `site/`; screenshots there and in `assets/` are cropped from the CI capture in `scripts/screenshot.sh`)
- **Install**: `curl -fsSL https://pulse0.app/install.sh | bash`

## Non-negotiables

1. **Memory budget.** CI (`.github/workflows/ci.yml` → `scripts/memory-check.sh`) launches the app in three scenarios and fails above 100 MB. Do not merge anything that moves a scenario past the 60 MB target without saying why.
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
│   ├── MainWindowController  The one window; all menu commands (responder chain)
│   ├── MainMenu.swift        Menu bar built in code
│   └── Session.swift         session.json (folder, tabs, unsaved text) + recent folders
├── Editor/
│   ├── EditorViewController  Tabs, the single text view, terminal split, status bar
│   ├── CodeTextView          NSTextView subclass: indent, comments, current line
│   ├── LineNumberRuler       Gutter; draws visible lines only
│   ├── SyntaxHighlighter     Regex pass → layout-manager temporary attributes
│   ├── Language.swift        Per-language rules + extension detection
│   ├── TabBarView / StatusBarView / EmptyStateView
├── Sidebar/                  File tree, project search panel, the switcher
├── Palette/CommandPalette    Go to file / commands / go to line, fuzzy matching
├── Terminal/TerminalPanel    SwiftTerm view, created lazily
├── Workspace/                Document (text + line index), FileNode, FileIndex, ProjectSearch
├── Support/                  Theme (dynamic colors, fonts), ResourceMonitor
└── Resources/                Info.plist (embedded via linker), AppIcon.icns
scripts/
├── bundle.sh                 Fast single-arch dist/Pulse.app
├── memory-check.sh           Memory budget scenarios (used by CI)
├── screenshot.sh             Real light/dark screenshots (CI publishes them to the `screenshots` branch)
└── package.sh                Universal release: DMG, ZIP, Homebrew cask
```

## Architecture notes

- **Documents vs. view.** A `Document` owns an `NSTextStorage`, its own `UndoManager`, and a lazily rebuilt line-start index. The editor has one `NSLayoutManager`/`CodeTextView`; `activate(_:)` calls `layoutManager.replaceTextStorage(...)`.
- **TextKit 1 on purpose.** Non-contiguous layout, `NSRulerView` line numbers and temporary attributes are mature and cheap there.
- **Highlighting.** One combined `NSRegularExpression` per language; alternatives are ordered so comments and strings win. Full pass up to 300 KB (debounced 80 ms after edits), visible range ±20k chars above that.
- **Autosave.** On by default: modified files with a path are written 1 s after typing stops, on app deactivation, and at quit. Untitled buffers (and everything, if autosave is off) survive via `~/Library/Application Support/Pulse/session.json`.
- **Resource meter.** `proc_pid_rusage` for Pulse and for its direct children (shells), sampled every 2 s only while active. CPU ticks are converted with `mach_timebase_info`.

## Building

```bash
swift build                    # debug
swift run Pulse .              # run, opening the current folder
./scripts/bundle.sh            # dist/Pulse.app
./scripts/memory-check.sh      # budget check
```

## Release process

Every push to `main` that passes CI (build, `swift test`, memory budget) is released automatically by `release.yml`, which builds the universal app with `scripts/package.sh` and publishes `Pulse.dmg`, `Pulse.zip` and the Homebrew cask. The website, `install.sh` and the in-app Update button all use `releases/latest`, so they always serve the newest build.

- Version: if the exact version in `VERSION` has no release yet, it is released as is (bump `VERSION` to `2.1.0` to ship 2.1.0). Otherwise the next patch is used (`2.0.0` → `2.0.1` → …). Pushing a `v*` tag releases that tag.
- Releases run one at a time and build the exact commit CI tested.
- `scripts/package.sh` marks release builds (`PulseReleaseBuild` in Info.plist). Only those check for updates on their own: at launch and at most once a day on activation, via a short-lived `curl` (`App/Updater.swift`). Pulse › Check for Updates… checks on demand in any build.
- An update downloads that release's `Pulse.zip`, checks the bundle id and version, quits Pulse, swaps the bundle in place and reopens it (tabs and unsaved text come back through session recovery). If the app's folder isn't writable, it offers the releases page.
- `site/VERSION` and the site's `softwareVersion` are not updated per release; downloads don't depend on them.

## The `pulse` terminal command

`Sources/Pulse/Resources/pulse` is a shell script copied into `Pulse.app/Contents/Resources/` by `bundle.sh` and `package.sh`; it finds the app from its own real path and runs `open -a`. `App/CommandLineTool.swift` links it as `pulse` into the first writable, non-system folder on the user's PATH (read once from the login shell): automatically on the first launch of a release build, or from Pulse › Install 'pulse' Command, which falls back to `/usr/local/bin` with the macOS administrator prompt. It never replaces a different program named `pulse`, re-points links left at a moved or deleted Pulse.app, and never edits shell profiles. The Homebrew cask declares it with `binary`.

## Copyright

© 2026 pulse0.app · MIT licensed
