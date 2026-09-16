# Per-tab memory: findings and design

How do we answer "which tab is eating my RAM?" — the one thing the app
deliberately refuses to fake today (see [Known limitations](../README.md#known-limitations)).

Everything below the first section is grounded in measurements taken on a real
machine, 2026-09-16, Chrome 153.0.8010.48, macOS, 74h uptime, 25 tabs open.

## The framing problem

"Per-tab memory" doesn't exist in Chrome. Memory exists **per renderer
process**, and the tab-to-process relationship is many-to-many:

- Site isolation puts all tabs of one site in a shared renderer.
- Every cross-origin iframe (ads, embeds, trackers) gets its *own* renderer
  via OOPIF.
- The GPU process holds compositing memory driven by whatever is visible.

`ProcessScanner` already gives us the MB for any pid. The entire problem is
**the mapping**.

## What we measured

| Metric | Value |
|---|---|
| Open tabs | 25 |
| `Google Chrome Helper` processes | 70 |
| ...of which `--type=renderer` | 65 |
| ...of which `--extension-process` | 5 |
| Content renderers per tab | **2.4** |
| Non-renderer helpers (GPU/network/storage/audio) | 5 |
| RSS summed over renderers | 7.6 GB (double-counts shared pages) |
| AppleScript latency, 25 tabs' URLs | 0.246 s wall |

Renderers outnumber tabs 2.6:1 — the opposite of the site-isolation-sharing
intuition. OOPIFs dominate; extensions are a rounding error at 5 of 65.

### Footprint distribution

| Band | Count | Total | Each |
|---|---|---|---|
| Top 12 | 12 | ~3.2 GB | 181–606 MB |
| Middle | 34 | ~3.8 GB | ~111 MB avg |
| Bottom 19 | 19 | ~0.8 GB | 23–64 MB |

Not one villain, and not a long thin tail — a **fat middle**. 34 renderers in
the 60–180 MB band are half of Chrome's memory, and none is individually
actionable. Killing the single largest renderer recovers ~8%.

**This is the central product finding.** Rolling up to the tab isn't a
presentation nicety; it is the only level at which the numbers mean anything.

## Options evaluated

| Approach | Verdict |
|---|---|
| CDP / `--remote-debugging-port` | ✗ Chrome 136+ ignores it on the default profile; can't reach the user's real tabs. Only gives JS heap anyway. |
| `chrome.processes` extension API | ✗ Dev channel only |
| `performance.measureUserAgentSpecificMemory()` | ✗ Needs cross-origin isolation |
| Renderer argv via `KERN_PROCARGS2` | ✗ **Measured: no origin present.** See flag dump below. |
| Renderer open FDs / sockets | ✗ Network goes through the network service, not renderers |
| Scrape Chrome's Task Manager over AX | ⚠️ Chrome's own ground truth, but forces accessibility mode, needs a visible window, brittle across versions |
| Active JS probe (`execute javascript` + CPU delta) | ✗ **Rejected.** Runs in the main frame only, so it misses the OOPIFs that hold most of the memory. Also force-reloads discarded tabs. |
| **Burst pairing (passive)** | ✅ **Chosen** |

### Renderer argv, as measured

```
--type=renderer
--origin-trial-disabled-features=...
--lang=en-US
--num-raster-threads=4
--renderer-client-id=130
--launch-time-ticks=75970819466
--metrics-shmem-handle=... --field-trial-handle=... --seatbelt-client=804
```

No origin, no site, no tab id. But two flags carry the design:

- **`--renderer-client-id`** — a dense monotonic counter. Gives exact creation
  order independent of pid (which wraps), and lets us detect *how many*
  renderers were born between two observations with no missed events.
- **`--launch-time-ticks`** — high-resolution creation timestamp on
  `mach_absolute_time()`'s clock. Almost certainly microseconds (Chromium's
  `base::TimeTicks` internal representation), but **do not hardcode the unit**:
  calibrate at runtime by comparing the max observed value against our own
  clock. That also absorbs any `mach_absolute_time` vs `mach_continuous_time`
  sleep-accounting drift.

## Chosen design: burst pairing

When a tab opens, its main-frame renderer *and* all its OOPIF renderers are
born in the same window. Attribute the whole burst to that tab.

Cross-site navigation works the same way — the old cluster dies, a new one is
born, and the tab's URL changes in the same interval. So **the map converges as
the user browses** rather than decaying: tabs that predate MemBar's launch get
mapped the first time they're navigated. This is the same epistemics as the
existing idle-time tracking ("knowledge builds up the longer it runs").

### Inverted polling

The AppleScript costs 246 ms for 25 tabs, so it can't be polled continuously.
It doesn't need to be — renderer births are observable for free in the process
scan we already run:

1. Every ~2 s, diff the Chrome helper pid set from the existing `ProcessScanner`
   sweep. Free; already happening.
2. **Only for new pids**, read argv via `KERN_PROCARGS2` and extract `--type`,
   `--renderer-client-id`, `--launch-time-ticks`.
3. **Only if renderers actually appeared**, fire the tab fetch off-main-thread.
4. Diff tabs; attribute the burst.

Zero Apple Events while idle, and every tab open is caught within ~2 s.

### Main frame vs. iframe, for free

Within a burst, the first renderer is the main frame and later ones are
subframes. No extra signal needed. That makes a headline no other tool
surfaces well: *"ads and embeds in your open tabs are using ~1.5 GB."*

### Presentation rules

- Report a tab as **"≈ X MB across N processes"** — never a false-precision
  single number.
- **Browser overhead** (the 5 non-renderer helpers + the browser process) gets
  its own line. It is attributable to no tab and can't be closed away.
- Unmapped renderers stay **explicitly unmapped**. Consistent with the
  project's no-fabrication stance; better an honest gap than a guess.
- Never sum RSS across 65 processes — shared framework pages get counted up to
  65 times. `phys_footprint` only.

## Available today, no mapping required

The distribution alone is a shippable state with zero new permissions and no
new plumbing: renderer count, largest single renderer, the fat-middle band, and
distinct-site count from the tab URLs we already fetch. Worth building first.

## Open questions

- Real `phys_footprint` total vs. the 7.6 GB RSS sum — sets the double-count
  budget when a renderer is shared between two tabs.
- Burst attribution when several tabs open at once (session restore, opening a
  bookmark folder). Likely answer: mark the whole batch unmapped rather than
  guess.
- How stable is a renderer that hosts iframes for *two* tabs? Splitting its
  footprint is arbitrary; showing it under both with a shared-marker is
  probably more honest.
- Safari: WebKit is one WebContent process per tab and Activity Monitor appears
  to show the origin in the process name. If that's reachable
  programmatically, Safari per-tab may be far cheaper than Chrome. Untested.
