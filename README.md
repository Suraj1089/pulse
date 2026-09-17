<div align="center">

# Pulse

**Minimalist, real-time memory monitor & command palette for macOS.**

[![Release](https://img.shields.io/github/v/release/Suraj1089/pulse?style=flat-square&color=black)](https://github.com/Suraj1089/pulse/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?style=flat-square)](https://github.com/Suraj1089/pulse)
[![Swift](https://img.shields.io/badge/swift-5.9%2B-orange?style=flat-square)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![Website](https://img.shields.io/badge/website-pulse0.app-black?style=flat-square)](https://pulse0.app)

[**Download Pulse.dmg**](https://github.com/Suraj1089/pulse/releases/latest/download/Pulse.dmg) • [**Website**](https://pulse0.app) • [**Release Notes**](https://github.com/Suraj1089/pulse/releases)

</div>

---

Pulse lives quietly in your macOS menu bar. Click the icon or press **`⌘⌥P`** to summon an elegant command palette that shows real-time memory pressure, top RAM-consuming applications, inspects Chrome tabs, and lets you quickly terminate or force-quit apps to reclaim memory instantly.

## ✨ Features

- **⚡️ Real-Time Pressure Indicator**: Live 3-bar menu bar icon color-coded for Normal (Green), Warning (Yellow), and Critical (Red) memory pressure states.
- **🎯 ⌘⌥P Command Palette**: Spotlight/Raycast-inspired global hotkey palette. Search, navigate with arrow keys, and quit apps without taking your hands off the keyboard.
- **💥 Instant Force Quit**: Hold `⌥ Option` to switch Quit buttons to immediate kernel-level `SIGKILL` Force Quit.
- **🌐 Chrome Tab Inspector**: Type `chrome` to inspect active Chrome tabs and their memory footprint, closing memory-hog tabs in one click.
- **📊 Detailed Memory Breakdown**: Type `memory` for an instant breakdown of App Memory, Wired, Compressed, Cached, and Free RAM.
- **🔍 System Diagnostics**: Type `why is my mac slow` to diagnose memory pressure causes and receive instant actionable recommendations.
- **🪶 Ultra-Lightweight**: Written in pure native Swift & SwiftUI. Uses ~13.5 MB RAM when idle, with zero background daemons and zero analytics tracking.

---

## 📥 Installation

### Option 1: One-Line Terminal Installer (Recommended)

```sh
curl -fsSL https://pulse0.app/install.sh | bash
```

### Option 2: Direct Download

Download the disk image directly:
👉 [**Download Pulse.dmg (Latest Release)**](https://github.com/Suraj1089/pulse/releases/latest/download/Pulse.dmg)

Open the `.dmg` and drag **Pulse** to your `/Applications` folder.

---

## ⌨️ Shortcuts & Controls

| Shortcut | Action |
| :--- | :--- |
| **`⌘⌥P`** | Toggle command palette from anywhere (global) |
| **`↑` / `↓`** | Navigate running apps and suggestions |
| **`↵` (Return)** | Quit selected application or run command |
| **`⌥` (Hold Option)** | Switch Quit buttons to **Force Quit** (`SIGKILL`) |
| **`esc`** | Dismiss palette |

---

## 🔍 Commands

Type in the palette search bar to run instant diagnostics and filters:

- **`memory`** — View detailed Mach memory allocation (App, Wired, Compressed, Cached, Free) and pressure history.
- **`chrome`** — List open Google Chrome tabs with memory stats and close tabs directly.
- **`why is my mac slow`** — Comprehensive memory diagnostic report and health tips.
- **`quit <app>`** or **`forcequit <app>`** — Search and terminate processes by name.

---

## 🔒 Permissions & Privacy

Pulse runs locally on your Mac with **zero telemetry** and **zero data collection**. It requests standard macOS permissions only when necessary:

- **Accessibility / Input Monitoring**: Required for the global `⌘⌥P` hotkey. *(Optional: clicking the menu bar icon works without any permissions!)*
- **Automation (AppleScript)**: Requested only when running the `chrome` command to inspect open tabs.

---

## 🛠️ Architecture & Performance

- **Mach Kernel Telemetry**: Reads page allocation directly via `host_statistics64` (the exact source used by `vm_stat`) and hooks kernel pressure events with `DispatchSource.makeMemoryPressureSource`.
- **Per-Process Footprint**: Inspects running processes with `proc_pid_rusage` (`phys_footprint`) and aggregates helper/renderer subprocesses under their parent app.
- **Minimal Footprint**: Native binary compiled with Swift 5.9+. Ad-hoc signed and optimized for Apple Silicon (M1/M2/M3/M4) and Intel Macs.

---

## 🏗️ Build from Source

Requirements:
- macOS 14.0+ (Sonoma or Sequoia)
- Xcode 15.0+ or Swift 5.9+

```sh
# Clone repository
git clone https://github.com/Suraj1089/pulse.git
cd pulse

# Run in development
swift run

# Build release DMG, ZIP, and Homebrew formula
./scripts/package.sh
```

---

## 📄 License

Distributed under the **MIT License**. See [`LICENSE`](LICENSE) for details.
