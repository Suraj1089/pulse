# MemPalette

A macOS menu-bar command palette (Raycast/Alfred-style) showing memory pressure, top memory users, and quit/close
actions, implemented in SwiftUI from the `project/MemPalette.dc.html` handoff design in this repo.

This build is **UI only, with mock data** — no real memory polling, `NSRunningApplication` enumeration, or
app-quitting. It's meant to validate the interaction design before wiring up real system monitoring.

## Requirements

- macOS 14+
- Xcode 15+ (or the Swift 5.9+ toolchain via `swift build` / `swift run`)

## Run it

```sh
swift run
```

or open `Package.swift` in Xcode and run the `MemPalette` scheme.

The app is menu-bar only (no Dock icon): look for the small four-block icon in the menu bar. Click it to open the
palette, or press `⌘⌥M` (requires Accessibility/Input Monitoring permission for the global shortcut to register).
Type `memory`, `why is my mac slow`, `chrome`, or `what can I close` to see the other states.

## What's implemented

- Menu bar icon ("allocation blocks" concept): a 2×2 grid whose filled-cell count tracks live pressure.
- A floating, non-activating `NSPanel` command palette that closes on Escape or losing focus, and resizes to fit
  its content (400–480pt).
- All states from the handoff: default overview (LOW/HIGH pressure), diagnosis ("why is my mac slow"), a merged
  memory view (overview numbers + the pressure-history/composition charts added in the second design pass),
  apps-to-close, and a Chrome per-tab breakdown.
- Hover-driven selection and chart readouts, a live-ticking pressure history (mirrors the handoff script's
  1.6s interval), and full light/dark support.

## Known limitations

- No real system data — everything in `Models.swift` is hardcoded mock data matching the design's numbers.
- The global `⌘⌥M` hotkey is best-effort; without permission it silently won't fire.
- This was written and reviewed without access to a Mac/Xcode in the authoring environment, so it hasn't been
  compiled yet — check it in Xcode before relying on it.
