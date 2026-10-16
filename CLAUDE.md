# CLAUDE.md

@AGENTS.md

AGENTS.md is the engineering reference (memory budget, non-negotiables, layout, architecture). The notes below are about working on Pulse with an agent.

## Running the app safely

- **Never launch Pulse on this repo's own files while someone may be typing.** A launched Pulse window can come to the front and take keystrokes, and autosave writes them to disk a second later. Copy the repo to a scratch folder and launch against the copy.
- A Pulse with a terminal open writes `~/.claude/ide/<port>.lock`, so a real `claude` (yours, or this agent's) can find and connect to it. Launch scratch builds with `CLAUDE_CONFIG_DIR` pointing at a temp folder; tests and `scripts/memory-check.sh` already do.
- `scripts/memory-check.sh` deletes `~/Library/Application Support/Pulse/session.json` (the real session) and opens files from the repo it lives in. Run a copy of the script from a scratch checkout.
- Scratch builds marked as a release (`PulseReleaseBuild` in Info.plist) behave like real installs: they check GitHub for updates and, on first launch, link the `pulse` command into a folder on the real PATH (via the login shell, even when launched through `open`). Leave that key out of test bundles, or point `SHELL` at a fake and launch the binary directly; afterwards check `~/.local/bin`, `/usr/local/bin` and `/opt/homebrew/bin` for stray `pulse` links and `defaults delete app.pulse cliInstallAttempted`.
- After code changes, rebuild `dist/Pulse.app` (`./scripts/bundle.sh`) before asking anyone to try it; a stale bundle looks like a missing feature.

## Measuring memory

- Readings drift between runs (window size, whether the window is frontmost, other load). Compare builds by **alternating** baseline and candidate runs, several rounds, and compare pairs, not single numbers.
- A larger saved window size (`PulseMainWindow` frame) raises every scenario; both builds share it, so pairs stay fair.
- Prefer drawing chrome with layer properties (`wantsUpdateLayer`, `layer.backgroundColor`) over `draw(_:)`: no backing store.

## Verifying UI without screen capture

`screencapture` may be denied. Render views in-process instead: `view.bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` from a throwaway hook in a scratch copy. Vibrant sidebar views render blank this way; render the panel's own view to see its contents.

## Tests

`swift test` runs the in-process end-to-end suite in `Tests/PulseTests` (in progress: only a smoke test so far). Tests drive the real window controller off screen with the app never activated, use temp fixture folders, and point `SessionState.fileURL` at a temp file.
