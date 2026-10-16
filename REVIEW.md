# REVIEW.md — how to review a change to Pulse

Instructions for AI code reviewers (Claude Code Review, the `claude-review` workflow, or any agent asked to review a pull request) and a checklist for human reviewers.

The rules live in [CLAUDE.md › Contribution rules](CLAUDE.md#contribution-rules): **Out of scope** (S1–S9), **Restrictions** (R1–R6), the **memory budget** and the **design guidelines**. This file says how to apply them. Cite rule IDs in findings.

## What the reviewer is protecting

Pulse is valuable because it is small: about 15 MB with an empty window, about 32 MB with ten files, never more than 100 MB, and no CPU while idle. Treat a change that makes Pulse bigger, busier at idle or slower to launch as a defect unless the PR shows why the core job needs it. **Usefulness alone is not a justification.**

## Blocking findings (🔴, request changes)

Report any of these as blocking. One is enough to reject the change.

1. **Out-of-scope feature (S1–S9).** Extensions/plugins, AI, telemetry or network use, web views or HTML previews, language servers or indexers that start on their own, minimap/animations/bundled assets, always-on background work, tools that belong elsewhere (debugger, full Git client…), or a new preference a default would cover. Name the rule and suggest the in-scope alternative, if one exists.
2. **Restriction broken (R1–R6)**, even if `policy-check.sh` misses it: a new framework or dependency, a network call, a repeating timer, polling, a file watcher, a long-lived child process, Interface Builder files or bundled media.
3. **Rules weakened.** Any edit to `scripts/policy-check.sh` allowlists, memory thresholds in `memory-check.sh`/`memory-compare.sh`, `.github/workflows/`, `CLAUDE.md`, `REVIEW.md` or `CODEOWNERS` made to let this change pass. Only the maintainer changes these, and says so in the PR.
4. **Unbounded growth.** Arrays, dictionaries, caches or buffers that grow with user data and have no cap; history kept forever; output read without a limit.
5. **Leaks and retention.** Closed documents, tabs, views, terminals or processes kept alive (strong reference cycles between long-lived objects, closures capturing `self` strongly in stored callbacks, observers never removed, child processes never waited on or terminated).
6. **Eager work.** Something built at launch or window load that is used later or rarely (panels, indexes, terminals, large views). It must be created on first use.
7. **Work that scales with the file or project on every keystroke, scroll or selection change** on the main thread (re-highlighting a whole large file, rescanning the tree, re-reading files).
8. **Idle work.** Anything that wakes the app while the user is doing nothing: timers, repeated `asyncAfter` chains, animations, observers that trigger I/O.
9. **Missing evidence.** A user-facing feature without before/after memory numbers in the PR description, or a failing `memory-compare` result without the `memory-approved` label.

## Important findings (🟡, should fix before merge)

- A second instance of something that could be shared (another text view, layout manager, outline view or terminal created where one exists).
- Drawing chrome in `draw(_:)` where a layer property would do.
- Non-trivial new code with no test in `Tests/PulseTests` when the behavior can be driven in-process.
- New UI that isn't a system control, an SF Symbol or a `Theme` color.
- A new setting where one default could serve.
- More code than the problem needs: a new subsystem, abstraction or file for something a few lines in an existing place would do.

## Not findings

Style preferences, naming, and formatting that matches the surrounding code. Don't block on those.

## How to review

1. Read the PR description. Note what it claims to add and its memory numbers.
2. Classify the change: **fix / performance / in-scope improvement / new feature**. For a new feature, decide first whether it is in scope; if not, stop and report S-rule findings. There's no need to review the code of an out-of-scope feature in detail.
3. Read the whole diff with the blocking list above in mind. For every new stored property, collection, observer, closure, timer, queue or process, ask: *when is it created, what bounds it, and what releases it?*
4. Check CI: `policy-check`, `swift test`, the 100 MB `memory-check`, and on PRs `memory-compare`. A red memory job is blocking unless the PR carries the `memory-approved` label.
5. Report findings with file and line, the rule ID, the concrete cost (what grows, when, by how much if measurable) and the smallest fix.

## Verdict

End the review with exactly one of these lines:

- `Verdict: BLOCK` when there is at least one 🔴 finding.
- `Verdict: PASS` otherwise (🟡 findings may still be listed).
