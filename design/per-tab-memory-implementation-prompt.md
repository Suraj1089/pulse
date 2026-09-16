# Build prompt: per-tab memory in MemBar

Hand this to a coding agent working in this repo on a Mac. It is written to be
self-contained — the agent does not have the conversation this came out of.

Read [`per-tab-memory.md`](per-tab-memory.md) in this directory first. It has
the measurements and the reasoning; this file is the build order.

---

## What you are building

MemBar's Chrome-tabs state currently shows real tab titles and URLs but
**deliberately shows no per-tab memory**, because Chrome doesn't expose it.
You are going to derive it, honestly, and redesign the row to present it.

## Hard constraints

- **macOS 14+, Swift 5.9, SwiftUI/AppKit.** Build with `swift build`, run with
  `swift run`. Do not add an Xcode project.
- **No new package dependencies.** Everything here is `Darwin`, `libproc`,
  `AppKit`, `Foundation`.
- **Not sandboxed.** The app reads other processes' memory and quits them.
  Don't add entitlements that would break that.
- **Don't touch the design tokens.** `Sources/MemBar/Support/Theme.swift`
  encodes a handoff design. Use `Metrics`/`Fonts`/`Theme`; don't add new
  colors or sizes without reusing what's there.
- **This codebase has never been compiled.** See Phase 0.

## Facts already established — do not re-derive, do not contradict

Measured on a real machine against Chrome 153, 25 tabs open:

| | |
|---|---|
| Open tabs | 25 |
| `Google Chrome Helper` processes | 70 |
| ...of which `--type=renderer` | 65 |
| ...of which `--extension-process` | 5 |
| **Content renderers per tab** | **2.4** |
| Non-renderer helpers (GPU/network/storage/audio) | 5 |
| AppleScript latency, 25 tabs | 0.246 s |

**There are more renderers than tabs, not fewer.** Cross-origin iframes
(OOPIFs) each get their own renderer. Any design that assumes one process per
tab is wrong.

Footprint distribution across the 65 renderers: top 12 hold ~3.2 GB
(181–606 MB each), a middle 34 hold ~3.8 GB (~111 MB each), the bottom 19 hold
~0.8 GB. **There is no single villain** — killing the largest renderer recovers
about 8%. This is why rollup to the tab is the whole point.

### Approaches already evaluated and rejected — do not implement these

- **Chrome DevTools Protocol / `--remote-debugging-port`.** Chrome 136+ ignores
  it unless `--user-data-dir` is also non-default, so it cannot reach the
  user's real profile and real tabs. It also only exposes JS heap, not
  footprint. Do not add it, do not suggest relaunching Chrome with flags.
- **`chrome.processes` extension API.** Dev channel only.
- **`performance.measureUserAgentSpecificMemory()`.** Needs cross-origin
  isolation; arbitrary sites don't have it.
- **Origin in renderer argv.** Measured: not present. The full flag set is
  `--type`, `--origin-trial-disabled-features`, `--lang`,
  `--num-raster-threads`, `--renderer-client-id`, `--launch-time-ticks`, and
  opaque shmem/field-trial/seatbelt handles. No site, no URL, no tab id.
- **Active JS probe via AppleScript `execute javascript`.** Rejected: it runs
  in the main frame only, so it misses the OOPIFs holding most of the memory,
  and it force-reloads discarded tabs.
- **`vmmap` / `footprint` / `task_for_pid`.** Chrome renderers are
  hardened-runtime sandboxed and reject these without root. `proc_pid_rusage`
  (already used by `ProcessScanner`) works on same-uid processes and is the
  only reason this app functions at all.

---

## Phase 0 — get a green build. Do this first, alone.

The project was authored without a Swift toolchain and has never been
compiled. Before adding anything:

```sh
swift build 2>&1 | head -50
```

Fix whatever it reports — type errors, API misuse, missing imports — with the
**smallest** changes that compile. Do not refactor, do not rename, do not
"improve" working code. Then:

```sh
swift run
```

Confirm the menu-bar icon appears and the palette opens. Commit this
separately as a build fix. **Do not start Phase 1 until `swift build`
succeeds.**

---

## Phase 1 — the distribution view (no mapping, ships alone)

This delivers real value with zero new permissions and no tab↔process
mapping. Build and verify it before anything else.

### 1.1 Classify Chrome's helper processes

New file `Sources/MemBar/System/ChromeProcessInventory.swift`.

Read each Chrome process's argv via `sysctl(KERN_PROCARGS2)`. This works for
same-uid processes without elevated privileges.

```swift
import Darwin

enum ProcessArguments {
    /// argv via sysctl(KERN_PROCARGS2). Unlike task_for_pid, this works
    /// against Chrome's hardened-runtime renderers without root.
    static func arguments(of pid: pid_t) -> [String]? {
        // Size from kern.argmax rather than a probing call: KERN_PROCARGS2
        // doesn't reliably report its own size, and the process can exit
        // between a sizing call and the fetch.
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMIB, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(argmax))
        var size = Int(argmax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        // Layout: argc(Int32) | exec_path\0 | \0 padding | argv[0..argc-1] | env
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }

        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }   // skip exec_path
        while i < size, buffer[i] == 0 { i += 1 }   // skip NUL padding

        var args: [String] = []
        var current: [CChar] = []
        while i < size, args.count < Int(argc) {
            if buffer[i] == 0 {
                current.append(0)
                args.append(String(cString: current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(buffer[i])
            }
            i += 1
        }
        return args
    }
}
```

Parse into:

```swift
struct ChromeHelper {
    enum Kind { case renderer, extensionRenderer, gpu, network, utility, other }
    let pid: pid_t
    let kind: Kind
    /// --renderer-client-id — a dense monotonic counter. Gives exact
    /// creation order independent of pid, which wraps.
    let clientID: Int?
    /// --launch-time-ticks — Chromium base::TimeTicks, microseconds.
    let launchTicks: UInt64?
    let footprintBytes: UInt64
}
```

Flags are `--key=value` or bare `--key`. `--type=renderer` plus
`--extension-process` means `.extensionRenderer`. Absent `--type` is the
browser process.

**Caching is required.** Reading argv for 70 processes on every 3 s tick is
waste. Cache by pid, and only read argv for pids you haven't seen. Evict on
pid disappearance.

### 1.2 Surface the distribution

Add to the Chrome state header, above the tab list:

- total footprint, process count, tab count (already there via `chromeSummary`)
- largest single renderer
- the band breakdown: how many renderers over 180 MB, 60–180 MB, under 60 MB
- extension renderer count and their total
- **browser overhead**: GPU + network + utility + browser process, as its own
  line, labelled as not closeable

**Never sum RSS across these processes.** Shared framework pages get counted
once per process — across 65 processes that's a first-order error, not a
rounding one. Use `phys_footprint` from the existing `ProcessScanner` only.

### 1.3 Verify Phase 1 on the Mac

```sh
# Your renderer count — the app's number must match this
ps -axww -o command= | grep -c '[C]hrome Helper (Renderer)'

# Extension renderers
ps -axww -o command= | grep '[C]hrome Helper (Renderer)' | grep -c 'extension-process'
```

The app's total for Chrome should also match Activity Monitor's Chrome row
(both are `phys_footprint`). If the app reads noticeably higher, you're
double-counting.

---

## Phase 2 — renderer birth detection

### 2.1 Fix tab identity first. This is a correctness bug, not a nicety.

`ChromeTab.id` is currently `"\(windowIndex).\(tabIndex)"` — **positional**.
Close one tab and every later tab shifts index, so any map keyed on it
silently mis-attributes memory to the wrong tab.

Chrome's AppleScript dictionary exposes a stable per-session `id` on `tab`.
Switch to it. In `ChromeTabsBridge.fetchSource`, add `(id of t)` to the
emitted fields and make it `ChromeTab.id`. Keep window/tab index as separate
fields for display and ordering, but never as identity.

Also rewrite `closeTab` to close by id rather than index:

```applescript
tell application "Google Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      if (id of t) is TARGET then close t
    end repeat
  end repeat
end tell
```

The current index-based close is racy — indices shift between the fetch and
the close.

### 2.2 Diff the helper pid set

`SystemMonitor.refreshFast()` already enumerates every process every 3 s.
Hook there — the scan is free, you're already paying for it.

Each tick, diff the Chrome helper pid set against the previous tick. For
**new pids only**, read argv (Phase 1.1). Emit a `RendererBirth` carrying pid,
clientID, launchTicks, and the observation time.

`--renderer-client-id` is monotonic, so it also tells you whether you missed
any: a jump from 130 to 133 means three renderers were created, even if one
already died.

### 2.3 Trigger the tab fetch from births, not from a timer

The AppleScript costs ~250 ms, so it can't be polled continuously. It doesn't
need to be:

1. Every 3 s, diff the helper pid set (free — already happening).
2. Only if **renderers actually appeared**, fire `ChromeTabsBridge.fetchTabs()`
   on the existing `workQueue`.
3. Diff the tab list against the previous one.

Zero Apple Events while idle; every tab open is caught within one tick.

**Permission gating — important.** `SystemMonitor`'s current design only talks
to Chrome while the Chrome state is visible, deliberately, because the first
AppleScript call blocks on the Automation permission dialog. Birth-triggered
fetching would fire that dialog unprompted, which is a bad first run. So:
**only enable birth-triggered fetching after the user has opened the Chrome
state at least once** and the first fetch succeeded. Persist that flag in
`UserDefaults`. Before then, the map simply doesn't build — that's fine and
matches Phase 3's cold-start design.

---

## Phase 3 — burst pairing and the new row

### 3.1 The pairing rule

When a tab opens, its main-frame renderer **and its OOPIF renderers** are born
in the same window. Attribute the whole burst to that tab.

```
On each tick where renderers were born:
  newTabs   = tabs now, by stable id, minus tabs last seen
  navigated = tabs whose id persisted but whose URL host changed
  births    = renderers born this tick, sorted by clientID ascending

  if newTabs.count == 1 and navigated.isEmpty:
      attribute ALL births to that tab
      lowest clientID = main frame; the rest = subframes
  else if newTabs.isEmpty and navigated.count == 1:
      drop the navigated tab's old renderers; attribute all births to it
  else:
      attribute nothing. Mark the affected tabs unmeasured.
```

**Ambiguity is not a tie to break — it's a state to display.** Session restore
and "open all bookmarks" produce many tabs at once; guessing there produces
confident wrong numbers, which is worse than a dash. This project's whole
stance is real data or none.

Retire mappings when the pid dies. Tabs whose renderers all died and that
haven't been re-observed go back to unmeasured.

### 3.2 Known limits — put these in the code comments and the README

- **Reused iframe renderers are missed.** If a tab embeds a site that already
  has a renderer, no new pid appears and that memory isn't attributed. Tab
  totals are therefore a **lower bound**. This is why the UI says "≈" and
  shows a process count.
- **Shared renderers.** Two tabs on one site share a process. Show the full
  number on both rows with a shared marker, and count it **once** in the
  total. Do not split it in half — closing one of them frees nothing, so
  77/77 would be tidy arithmetic and a practical lie.
- **`--launch-time-ticks` units.** Chromium's `base::TimeTicks` internal value
  is microseconds, on `mach_absolute_time()`'s clock. Validate rather than
  trust: at startup, assert the largest observed value is ≤ the current
  `mach_absolute_time()` converted to microseconds via `mach_timebase_info`.
  If it isn't, log and fall back to clientID ordering alone, which is
  sufficient — ticks are a refinement, not a dependency.

### 3.3 The row

Full mockup, drawn at true 560pt in this app's tokens:
**https://claude.ai/artifact/7v4DPRx1iqAUA7dZ5DcXrx**

Rebuild `tabRow` in `Sources/MemBar/States/ChromeTabsStateView.swift` at
`Metrics.rowHeightWithReason` (46pt — already exists, no new metric):

```
[dot 6] [10] [title / meta ..................] [bar 64x4] [mem 58, right] [Close]
```

- **Line 1 — tab title.** `Fonts.body`, `theme.textPrimary`, one line, tail
  truncation. The title is what the user recognizes off the tab strip, and
  the only thing distinguishing five `github.com` tabs.
- **Line 2 — `host · N processes`**, `Fonts.monoSmall`, `theme.textDim`, plus
  at most one qualifier: `· 7 embeds`, `· shared with 1 tab`, or
  `· not measured yet`.
- **Bar** — 64×4 capsule, `theme.trackBackground` track, host hue fill, scaled
  against the **largest tab**, not total RAM.
- **Number** — `Fonts.mono`, `.tabularNumbers`, fixed 58pt right-aligned so
  the column stays scannable. `—` in `theme.hint` when unmeasured.
- **Close** — `QuitMode.onSelected` (hover), not the current always-visible
  button. 25 permanent red buttons is a wall.

**Fix the dot hue while you're here.** Today it's
`dotHues[index % dotHues.count]` — keyed to list *position*. Once rows sort by
memory, a tab changes color whenever a neighbour grows, and two tabs on the
same site get different colors. Key it to a stable hash of the **host**:
`Color(oklch: 0.62, 0.12, Double(abs(host.hashValue) % 360))`. Same site, same
color, free visual grouping.

**Sorting.** Measured tabs first, by footprint descending — that is the
question being asked. Unmeasured tabs after them, in tab-strip order. Tabs
titled "New Tab" sort last regardless.

**Row click activates that tab in Chrome** (`set active tab index of window w
to t`). Memory-sorted order breaks the user's spatial memory of the tab strip;
this is the fix, and it beats printing a `w1·t7` coordinate.

### 3.4 Title hygiene

| Raw | Shown | Rule |
|---|---|---|
| `(12) Inbox` | `Inbox (12)` | Move a leading unread count to the tail — it shouldn't win the first four characters of a truncating line. |
| `Pull requests · … — GitHub` | `Pull requests · …` | Strip a trailing site name that repeats the host already on line 2. |
| *(empty)* | `github.com/pulls` | Fall back to path, then bare URL. Never render an empty row. |
| `● Meet — standup` | `Meet — standup` | Strip leading media/recording glyphs; the dot column carries state. |

### 3.5 Other states in the mockup

- **Coverage** in the section header: `18 of 25 measured`. Honest, and it
  explains the dashes without a tooltip.
- **Expanded row.** The selected row unfolds a per-host breakdown: main frame
  first, then each embed host with its frame count and footprint. This is
  where the OOPIF finding becomes a feature.
- **Aggregate embeds callout**: `Embeds and ads across all tabs — 1.5 GB · 31
  processes`, computed from renderers classified as subframes.
- **Footer**: browser overhead, labelled not-closeable.
- **Cold start**: a freshly launched MemBar knows almost nothing. Show
  `2 of 25 measured` and `Tabs are measured when you open or navigate them.`
  Do not hide unmeasured tabs and do not estimate them.

---

## Definition of done

- [ ] `swift build` is clean; `swift run` opens the palette.
- [ ] Renderer/extension counts match the `ps` commands in Phase 1.3.
- [ ] Chrome's total matches Activity Monitor's Chrome row.
- [ ] No AppleScript fires before the user has opened the Chrome state once.
- [ ] Opening a new tab produces a measured row within ~3 s.
- [ ] Closing a tab from a row closes the **right** tab, verified with 10+ tabs
      open and one closed from the middle first.
- [ ] Session restore leaves tabs unmeasured rather than misattributed.
- [ ] Unmeasured tabs render as `—`, never as 0 MB and never estimated.
- [ ] Two tabs on one site show the same number, a shared marker, and are
      counted once in the total.
- [ ] README's "Known limitations" is updated: per-tab memory is now real but
      a lower bound, and says why.

## If you get stuck

Report what you found and stop rather than substituting an approach from the
rejected list. In particular: if burst pairing turns out to attribute poorly
in practice, **say so with the evidence** — do not fall back to estimating
per-tab memory by dividing Chrome's total by tab count. Shipping a plausible
fabricated number is the one outcome this project treats as a failure.
