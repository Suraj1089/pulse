# AGENTS.md — Pulse

> Engineering reference for AI agents, contributors, and automated tooling.

## What Is Pulse?

**Pulse** is a lightweight macOS menu-bar app that surfaces memory pressure at a glance and provides a fast keyboard-driven command palette to quit/force-quit apps, inspect Chrome tabs, view RAM composition, diagnose slowdowns, and update itself. It is written entirely in Swift with SwiftUI, distributed as a standalone `.app` bundle (no App Store, no notarization yet).

- **Website**: <https://pulse0.app>
- **GitHub**: <https://github.com/Suraj1089/pulse>
- **Install**: `curl -fsSL https://pulse0.app/install.sh | bash`

---

## Repository Layout

```
MemBar/                          ← repo root (historically named MemBar)
├── Package.swift                ← SwiftPM package definition (single target: Pulse)
├── VERSION                      ← Single source of truth for the release version (e.g. 1.0.1)
├── LICENSE                      ← MIT
├── README.md
├── AGENTS.md                    ← this file
│
├── Sources/
│   └── Pulse/                   ← all Swift source files
│       ├── App/
│       │   └── PulseApp.swift   ← @main entry point
│       ├── AppDelegate.swift    ← NSApplicationDelegate; owns status-bar item + hotkey
│       ├── CommandPaletteView.swift  ← root SwiftUI view; routes PaletteState → StateView
│       ├── PaletteViewModel.swift    ← query → PaletteState router; thin coordinator
│       ├── Models.swift              ← PressureLevel, AppUsage, SlashCommand.all, etc.
│       │
│       ├── Components/
│       │   ├── ModernFooterView.swift   ← Settings / Update pill / Quit All footer
│       │   ├── PulseBrandHeader.swift   ← Logo + RAM bar header
│       │   ├── SearchFieldView.swift    ← The search input pill
│       │   └── ...                      ← Shared sub-components
│       │
│       ├── States/              ← One file per PaletteState case
│       │   ├── OverviewStateView.swift
│       │   ├── DiagnosisStateView.swift
│       │   ├── MemoryStateView.swift
│       │   ├── CloseStateView.swift
│       │   ├── ChromeTabsStateView.swift
│       │   ├── HelpStateView.swift
│       │   ├── QuitCommandStateView.swift
│       │   ├── CommandSuggestionsView.swift
│       │   ├── UpdateStateView.swift    ← /version and /update commands
│       │   └── NoMatchStateView.swift
│       │
│       └── System/
│           ├── SystemMonitor.swift      ← mach_host_statistics, proc_pidinfo
│           ├── ChromeTabsBridge.swift   ← AppleScript bridge to Chrome
│           ├── UpdateChecker.swift      ← VERSION fetch + in-place ZIP update
│           └── ...
│
├── scripts/
│   └── package.sh               ← Builds release binary, signs (ad-hoc), packages DMG + ZIP
│
├── site/                        ← Static website deployed to pulse0.app
│   ├── index.html
│   ├── install.sh               ← curl-pipe install script
│   ├── VERSION                  ← Serves the current version for update checks (keep in sync)
│   └── ...
│
└── .github/
    └── workflows/
        └── release.yml          ← CI: builds + publishes GitHub Release on VERSION change
```

---

## Building

### Prerequisites
- macOS 14+, Xcode 15+ (or Swift 5.9+ toolchain)
- No external dependencies — pure SwiftPM

### Debug build
```bash
swift build
# Binary at: .build/debug/Pulse
```

### Release build (what CI does)
```bash
swift build -c release
# Binary at: .build/release/Pulse
```

> **Note**: `swift build` inside AI sandbox environments may fail with `Operation not permitted` on the module cache. Run with `BypassSandbox: true` or directly in a terminal.

### Full package (DMG + ZIP + Homebrew formula)
```bash
bash scripts/package.sh
# Outputs in dist/
```

---

## Running Locally

After a debug build, launch directly:
```bash
open .build/debug/Pulse.app
# or:
.build/debug/Pulse
```

The app hides from the Dock (`LSUIElement = YES`) and appears only in the menu bar. Press **⌘⌥P** to open the command palette.

---

## Architecture

### State Machine

`PaletteViewModel.state` is the single routing signal:

```
query (String)
    │
    ▼
PaletteViewModel.state  ← computed var, pure function of `query`
    │
    ▼
CommandPaletteView  switch model.state {
    ├── .overview       → OverviewStateView
    ├── .diagnosis      → DiagnosisStateView
    ├── .memory         → MemoryStateView
    ├── .close          → CloseStateView
    ├── .chromeTabs     → ChromeTabsStateView
    ├── .help           → HelpStateView
    ├── .version        → UpdateStateView
    ├── .update         → UpdateStateView
    ├── .quitCommand    → QuitCommandStateView
    ├── .commandSuggestions → CommandSuggestionsView
    └── .noMatch        → NoMatchStateView
```

### Adding a New Slash Command

1. Add a case to `PaletteState` in `PaletteViewModel.swift`
2. Add routing in the `state` computed var (slash prefix block + NL fallback)
3. Create `Sources/Pulse/States/<Name>StateView.swift`
4. Add the case to the `switch` in `CommandPaletteView.swift`
5. Register in `SlashCommand.all` in `Models.swift`

### Update Flow

`UpdateChecker` (singleton `UpdateChecker.shared`):
1. Fetches `https://pulse0.app/VERSION` (plain text, no GitHub API)
2. Compares with `CFBundleShortVersionString`
3. If newer: sets `checkState = .updateAvailable(latest:)` → footer pill appears
4. `performUpdate()`: downloads `releases/latest/download/Pulse.zip`, unzips, replaces `/Applications/Pulse.app`, clears quarantine, relaunches

---

## Release Process

1. **Bump version**: edit `VERSION` file at repo root (e.g. `1.0.2`)
2. **Also update** `site/VERSION` to the same value (used by update checker)
3. **Commit & push** to `main`:
   ```bash
   git add VERSION site/VERSION
   git commit -m "chore: bump to 1.0.2"
   git push
   ```
4. **CI triggers** (`.github/workflows/release.yml`) automatically:
   - Runs `scripts/package.sh`
   - Creates GitHub Release `v1.0.2`
   - Uploads: `Pulse-1.0.2.dmg`, `Pulse-1.0.2.zip`, `Pulse.dmg` (permalink), `Pulse.zip` (permalink), `pulse.rb` (Homebrew formula)
5. **Deploy site**: push `site/` changes (auto-deployed via Cloudflare/Vercel)

> Do **not** manually create tags — the workflow creates them from the VERSION file via `target_commitish`.

---

## Key URLs

| Resource | URL |
|---|---|
| Website | https://pulse0.app |
| Install script | https://pulse0.app/install.sh |
| VERSION endpoint | https://pulse0.app/VERSION |
| Latest DMG | https://github.com/Suraj1089/pulse/releases/latest/download/Pulse.dmg |
| Latest ZIP | https://github.com/Suraj1089/pulse/releases/latest/download/Pulse.zip |
| GitHub Releases | https://github.com/Suraj1089/pulse/releases |

---

## Design Principles

- **No telemetry, no analytics, no network calls at launch** — update checks are opt-in via `/version` or `/update`
- **Apple-minimalist UI** — vibrancy materials, OKLCH colors, SF Symbols, no custom assets beyond the app icon
- **Single SwiftPM package** — no CocoaPods, no Carthage, no SPM plugins
- **LSUIElement** — no Dock icon, lives only in menu bar
- **`autosaveName = "PulseStatusItem"`** — position persists across reboots; user can ⌘-drag to reorder

---

## Copyright

© 2026 px0 · MIT licensed
