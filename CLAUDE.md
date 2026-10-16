# CLAUDE.md

@AGENTS.md

AGENTS.md is the engineering reference (layout, architecture, release process). This file holds **the rules every change must follow**, whoever writes it, and notes for working on Pulse with an agent. AI reviewers apply these rules as described in [REVIEW.md](REVIEW.md).

---

## Contribution rules

Pulse exists to be a code editor that stays small: **50–60 MB of memory in normal use, never more than 100 MB, and no CPU while idle.** Every feature is paid for in memory, idle work, launch time and maintenance. A change is accepted only when what it gives the core job (opening, reading, editing and searching code, with a terminal at hand) is clearly worth what it costs.

Being useful is not enough to justify a feature; many editors already offer everything. Pulse's value is what it leaves out.

### In scope

These are the things Pulse does. Improving them (faster, smaller, more correct) is always welcome:

- Opening folders and files; the file tree; tabs; session recovery and autosave
- Text editing, syntax highlighting (regex rules in `Language.swift`), find/replace, go to line
- Project search, go to file, the command palette
- The integrated terminal (tabs and splits, created on demand)
- The source-control panel and diff tab as they exist today (status and diffs through short-lived `git` processes)
- Preferences that already exist: font sizes, appearance, key bindings
- The resource meter, the updater, the `pulse` command

### Out of scope: reject

Changes in these areas are declined, however small the first version looks. Each one is a door to background work and memory growth.

| Rule | Not accepted |
|---|---|
| **S1** | Extensions, plugins, scripting runtimes (JavaScript, Lua, Python) or a plugin API |
| **S2** | AI features: completions, chat, LLM or model calls, local models |
| **S3** | Telemetry, analytics, crash reporting services, accounts, sign-in, any network traffic other than the updater |
| **S4** | Web content: `WKWebView`, HTML previews (Markdown preview included), embedded browsers |
| **S5** | Language servers, indexers or symbol databases that start on their own. A language-server feature can only be proposed as opt-in, in a separate process, shown in the resource meter, and stopped when idle; open an issue first |
| **S6** | Minimap, animations, transitions, decorative effects, bundled fonts, images or theme packs |
| **S7** | Always-on background work: file-system watchers, polling, periodic `git fetch`/status, auto-update checks more than once a day |
| **S8** | Tools that belong elsewhere: debugger, full Git client (staging UI, history graph, merge tool), database/HTTP clients, project templates, task runners |
| **S9** | New preferences or modes for things one sensible default covers. Every setting is code, UI and state |

If you think something here should change, open an issue and make the case before writing code.

### Restrictions (checked by CI)

`scripts/policy-check.sh` enforces these on every push and pull request. Exceptions are made only by the maintainer, by editing the allowlists in that script (routed to them through CODEOWNERS). **Never edit the allowlists, the CI thresholds, REVIEW.md or these rules to make your own change pass.**

| Rule | Restriction |
|---|---|
| **R1** | Frameworks: `AppKit`, `Foundation`, `Darwin`, `SwiftTerm` only. No SwiftUI, WebKit, Combine, CoreData, ML, analytics or AI SDKs |
| **R2** | Dependencies: exactly one package, SwiftTerm, pinned with `exact:`. Write the code yourself or don't add the feature |
| **R3** | No network APIs (`URLSession`, `Network.framework`, web views). Only `App/Updater.swift` may run `curl` |
| **R4** | No idle work: no repeating timers, display links, timer sources or file-system watchers (the resource meter is the one timer, and it stops when Pulse is inactive). Refresh on app activation or user action instead |
| **R5** | Child processes only in the allowlisted files, and only short-lived (one search, one `git` call). Their memory must not stay resident |
| **R6** | No storyboards, XIBs, asset catalogs, fonts, images or media in the app. UI is built in code with system controls and SF Symbols |

### Memory budget for contributions

CI measures three scenarios (empty window, ten files, ten files + terminal):

- **Hard limit:** any scenario above **100 MB** fails (`scripts/memory-check.sh`).
- **Per-PR limit:** on pull requests, the build is compared with the base branch on the same runner. More than **+5 MB** in any scenario, or more than **+512 KB** of executable, fails (`scripts/memory-compare.sh`). The maintainer can accept a justified increase with the `memory-approved` label.
- **Target:** stay at or under **60 MB**. Measured today: about 15 MB empty and 32 MB with ten files.

A pull request that adds user-facing behaviour must state its memory cost in the description: before/after numbers from `scripts/memory-check.sh` (alternate the two builds over several rounds; see *Measuring memory* below).

### Design guidelines for in-scope work

- **Lazy, then gone.** Create things the first time they are used, never at launch. Release them when their tab, panel or window closes. Nothing retains a closed document, view or process.
- **Share, don't multiply.** One text view and layout manager for all tabs. New features reuse the existing views instead of adding parallel ones.
- **Work in proportion to what's visible.** Draw, highlight and lay out the visible range. Never do work proportional to file or project size on every keystroke.
- **Bound everything.** Every list, cache and buffer has a fixed cap (search results, diff output, scrollback, file index). Unbounded growth keyed by user data is a bug.
- **Heavy work outside the process.** Large one-off jobs run as short-lived child processes (ripgrep, git) whose memory leaves when they exit.
- **No polling.** Refresh on app activation, window focus or an explicit command.
- **Native and plain.** System controls, SF Symbols, `Theme` colors; layer properties (`wantsUpdateLayer`, `layer.backgroundColor`) over `draw(_:)` for chrome.
- **Fewer settings.** Choose one good default. Add a preference only when users genuinely disagree and both options are cheap.
- **Small diffs.** Prefer deleting code to adding it. A feature that needs a new subsystem is probably out of scope.

### When an AI agent is asked to change Pulse

- Before writing code, check the request against **Out of scope** and **Restrictions**. If it conflicts, do not implement it: say which rule it breaks and offer the smallest in-scope alternative (often a terminal command, or improving an existing feature).
- Run `./scripts/policy-check.sh` before finishing, and `swift test` when Swift changed.
- For user-facing changes, measure memory against the base build (below) and put the numbers in the PR description.
- Don't weaken a rule, threshold or allowlist to get a change through; leave that decision to the maintainer.

---

## Running the app safely

- **Never launch Pulse on this repo's own files while someone may be typing.** A launched Pulse window can come to the front and take keystrokes, and autosave writes them to disk a second later. Copy the repo to a scratch folder and launch against the copy.
- `scripts/memory-check.sh` deletes `~/Library/Application Support/Pulse/session.json` (the real session) and opens files from the repo it lives in. Run a copy of the script from a scratch checkout. `scripts/memory-compare.sh` runs it repeatedly, so the same applies.
- Scratch builds marked as a release (`PulseReleaseBuild` in Info.plist) behave like real installs: they check GitHub for updates and, on first launch, link the `pulse` command into a folder on the real PATH (via the login shell, even when launched through `open`). Leave that key out of test bundles, or point `SHELL` at a fake and launch the binary directly; afterwards check `~/.local/bin`, `/usr/local/bin` and `/opt/homebrew/bin` for stray `pulse` links and `defaults delete app.pulse cliInstallAttempted`.
- After code changes, rebuild `dist/Pulse.app` (`./scripts/bundle.sh`) before asking anyone to try it; a stale bundle looks like a missing feature.

## Measuring memory

- Readings drift between runs (window size, whether the window is frontmost, other load). Compare builds by **alternating** baseline and candidate runs, several rounds, and compare pairs, not single numbers. `scripts/memory-compare.sh base/dist/Pulse.app dist/Pulse.app` does exactly this and reports medians.
- A larger saved window size (`PulseMainWindow` frame) raises every scenario; both builds share it, so pairs stay fair.
- Prefer drawing chrome with layer properties (`wantsUpdateLayer`, `layer.backgroundColor`) over `draw(_:)`: no backing store.

## Verifying UI without screen capture

`screencapture` may be denied. Render views in-process instead: `view.bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` from a throwaway hook in a scratch copy. Vibrant sidebar views render blank this way; render the panel's own view to see its contents.

## Tests

`swift test` runs the in-process end-to-end suite in `Tests/PulseTests` (smoke, editor layout, diff, search, preferences and terminal tests). Tests drive the real window controller off screen with the app never activated, use temp fixture folders, and point `SessionState.fileURL` at a temp file.
