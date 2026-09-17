# MemBar

See what's eating your RAM and quit it — a Raycast-style memory monitor for your Mac's menu bar, showing memory
pressure, top memory users, and quit/close actions. Implemented in SwiftUI from the
[`design/project/MemPalette.dc.html`](design/project/MemPalette.dc.html) handoff design in this repo (the design's
working title was "MemPalette" — see [`design/`](design/) for the original handoff bundle and chat transcript).

This build runs on **real system data**: live kernel memory stats, real per-app memory footprint, real app icons,
real quitting, and real Chrome tab titles. Nothing in the UI is hardcoded — see [Known limitations](#known-limitations)
for the one thing that's a real signal but not an exact one (per-tab memory), and why.

## Requirements

- macOS 14+
- Xcode 15+ (or the Swift 5.9+ toolchain via `swift build` / `swift run`)
- Not sandboxed / not from the App Store — it reads other processes' memory footprint and quits them, which the
  App Sandbox doesn't allow.

## Run it

```sh
swift run
```

or open `Package.swift` in Xcode and run the `MemBar` scheme.

The app is menu-bar only (no Dock icon): look for the small four-block icon in the menu bar, whose filled-cell
count tracks live pressure. Click it to open the palette, or press `⌘⌥M` (see [Permissions](#permissions)).
Type `memory`, `why is my mac slow`, `chrome`, or `what can I close` to see the other states — everything routes
off the same live data, so what you see always matches what's actually running.

## Permissions

Two features are gated behind macOS's standard permission prompts; without them, the app degrades gracefully
rather than crashing or hanging:

- **`⌘⌥M` global shortcut** — needs Accessibility (or Input Monitoring) access, under System Settings → Privacy &
  Security. Without it, the shortcut just doesn't fire; opening the palette by clicking the menu bar icon still
  works.
- **Chrome tab breakdown** — the first time you type `chrome`, macOS prompts for Automation access to let MemBar
  control Google Chrome (this is how the "chrome" state reads real tab titles and closes tabs). Without it, that
  state shows an explanatory empty state instead of tab data.

Both prompts are tied to the app's code signature. Since `swift run`/Xcode debug builds are ad-hoc signed, macOS
may re-prompt across rebuilds during development — that's expected, not a bug.

## What's real

- **Memory stats** (total/used/free, the App/Wired/Compressed/Cached/Free composition, and the pressure history
  chart) — read straight from the kernel via `host_statistics64`, the same call `vm_stat` uses.
- **Memory pressure LOW/MEDIUM/HIGH** — macOS's own pressure signal (`DispatchSource.makeMemoryPressureSource`),
  the same one Activity Monitor's pressure gauge reads — not a percentage heuristic.
- **Top memory users** — every regular (Dock-visible) app, with memory summed across it *and* every helper/renderer
  process nested under its bundle path (so Chrome's many `Google Chrome Helper` processes count as one "Chrome"),
  using `libproc`'s `proc_pid_rusage` (`phys_footprint` — the same figure Activity Monitor's Memory column shows).
- **App icons** — `NSRunningApplication.icon`, not a color swatch.
- **Quitting** — `NSRunningApplication.terminate()`. Real, not decorative.
- **Idle duration** — tracked from `NSWorkspace` activation notifications since the app launched. A freshly
  launched MemBar won't yet know an app's been idle for hours; that knowledge builds up the longer it runs.
- **Chrome tab titles/URLs, and closing tabs** — real, via AppleScript (see Permissions above).

## Known limitations

- **Chrome per-tab memory is real, but represents a lower bound.** MemBar derives per-tab footprint by pairing renderer birth bursts with tab open/navigation events via `sysctl(KERN_PROCARGS2)` and `libproc`. If a tab embeds an iframe whose site already shares an existing renderer process, that shared memory is not duplicated into the new tab's count. Tab memory figures are therefore an honest lower bound, denoted with "≈" alongside real process and subframe counts. Unmeasured tabs (e.g. from session restore or bulk opens) are displayed as "—" rather than guessed or estimated.
