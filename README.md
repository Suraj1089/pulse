<div align="center">

<img src="assets/icon.png" alt="Pulse icon" width="120" />

# Pulse

**A light, native code editor for macOS.**

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?style=flat-square)](https://github.com/Suraj1089/pulse)
[![Swift](https://img.shields.io/badge/swift-5.9%2B-orange?style=flat-square)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

</div>

---

Pulse is a code editor written in Swift and AppKit, with no web view, no Electron and no extension host. Its goal is to stay small: **50–60 MB of memory in normal use, and never more than 100 MB**, with no CPU use while you are not typing.

## Features

- **Folders and files**: open a folder, browse it in the sidebar, open many files in tabs.
- **Editing**: syntax highlighting for Swift, JS/TS, Python, Go, Rust, C/C++/Obj-C, Java/Kotlin, Ruby, shell, HTML/XML, CSS, JSON, YAML, TOML, Markdown and SQL. Line numbers, current-line highlight, auto-indent, toggle comment, indent/outdent, word wrap.
- **Find and replace** in the file (the standard macOS find bar), and **project search** (uses `ripgrep` when installed, otherwise a built-in scan).
- **Command palette**: `⌘P` go to file, `⇧⌘P` commands, `⌘L` go to line.
- **Integrated terminal** (`` ⌃` ``), started only when you first open it.
- **Autosave and session recovery**: files save themselves a second after you stop typing, and Pulse reopens your folder, tabs and any unsaved buffers after you quit.
- **Honest resource meter**: the status bar shows Pulse's own memory and CPU, with the terminal's shell measured separately.

Not included, on purpose: extensions, Git UI, debugger, AI features, telemetry.

## Install

```sh
curl -fsSL https://pulse0.app/install.sh | bash
```

Or download [Pulse.dmg](https://github.com/Suraj1089/pulse/releases/latest/download/Pulse.dmg) and drag Pulse to Applications.

Open a folder from the terminal with `open -a Pulse .`

## Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `⌘O` | Open a folder or files |
| `⌘P` | Go to file |
| `⇧⌘P` | Command palette |
| `⌘L` | Go to line |
| `⌘F` / `⌥⌘F` | Find / find and replace in file |
| `⇧⌘F` | Search the project |
| `` ⌃` `` | Show or hide the terminal |
| `⌘/` | Toggle line comment |
| `⌘]` / `⌘[` | Indent / outdent |
| `⇧⌘]` / `⇧⌘[` | Next / previous tab |
| `⌃⌘S` | Toggle sidebar |
| `⌘+` / `⌘-` / `⌘0` | Font size |

## Memory budget

| Scenario | Target | Hard limit |
| :--- | :--- | :--- |
| Empty window | ≤ 40 MB | 100 MB |
| Ten files open | ≤ 60 MB | 100 MB |
| Ten files + terminal (Pulse only) | ≤ 60 MB | 100 MB |

"Memory" means physical footprint, the number Activity Monitor shows. Shells and other processes you start in the terminal are reported separately. CI measures all three scenarios on every push and fails the build above 100 MB; see `scripts/memory-check.sh`.

How it stays small:

- One text view for all tabs. Switching tabs swaps the layout manager onto another document's text, so each extra file costs roughly its own text.
- Syntax colors are layout-manager temporary attributes: no copies of the text, no relayout. Files over 300 KB are highlighted around the visible area only.
- The file tree reads a folder only when you expand it. The go-to-file index is built on first use.
- The terminal view and shell are created the first time you open the terminal.
- Nothing polls in the background. The resource meter samples every 2 s only while Pulse is the active app.

## Build from source

Requirements: macOS 14+, Xcode 15+ (Swift 5.9+).

```sh
git clone https://github.com/Suraj1089/pulse.git
cd pulse

swift run Pulse .                    # run from source, opening this folder
./scripts/bundle.sh                  # build dist/Pulse.app for this Mac
open dist/Pulse.app
./scripts/memory-check.sh            # measure the memory budget locally
./scripts/package.sh                 # universal release build: DMG, ZIP, Homebrew cask
```

## License

MIT. See [`LICENSE`](LICENSE).
