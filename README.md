# Pulse

A lightweight menu bar memory monitor and command palette for macOS.

Shows real-time memory pressure, top RAM-consuming apps, Chrome tabs, and lets you quickly quit or force-quit apps to free memory.

## Install

Run in terminal:
```sh
curl -fsSL https://pulse0.app/install.sh | bash
```

Or download `Pulse-1.0.0.dmg` from [Releases](https://github.com/Suraj1089/pulse/releases/latest) and move `Pulse.app` into `/Applications`.

## Usage

Click the menu bar icon or press `⌘⌥P` to toggle the palette.

### Shortcuts & Controls

| Shortcut | Action |
| :--- | :--- |
| `⌘⌥P` | Open / close palette (global) |
| `↑` / `↓` | Navigate list items |
| `↵` (Enter) | Quit selected app / execute command |
| `⌥` (Hold Option) | Switch Quit buttons to **Force Quit** (`SIGKILL`) |
| `esc` | Close palette |

### Commands & Search

Type in the search bar to filter apps or run commands:
- `memory` — Memory breakdown (App, Wired, Compressed, Cached, Free) and pressure history.
- `chrome` — List open Google Chrome tabs and close tabs.
- `why is my mac slow` — System memory diagnostics and advice.
- `quit <app>` or `forcequit <app>` — Terminate specific processes.

## Permissions

Pulse runs un-sandboxed to monitor process memory and terminate apps. It requests standard macOS permissions as needed:
- **Accessibility / Input Monitoring**: Required for the global `⌘⌥P` hotkey. (Menu bar click works without it).
- **Automation (AppleScript)**: Prompted when opening the `chrome` view to inspect tab titles and close tabs.

## How It Works

- **Kernel Telemetry**: Reads page allocation via `host_statistics64` (same source as `vm_stat`) and monitors system pressure events via `DispatchSource.makeMemoryPressureSource`.
- **Process Memory**: Inspects running apps with `proc_pid_rusage` (`phys_footprint`) and aggregates child helper/renderer processes under their parent application.
- **Low Overhead**: Dormant when closed (~13.5 MB RAM footprint), only polling lightweight Mach kernel memory statistics.

## Build from Source

Requires macOS 14+ and Xcode 15+ (or Swift 5.9+).

```sh
swift run
```

Package release artifacts (`.dmg`, `.zip`, Homebrew cask):
```sh
./scripts/package.sh
```

