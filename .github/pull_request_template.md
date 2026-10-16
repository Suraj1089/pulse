## What and why

<!-- What does this change do, and which part of Pulse's core job (opening, reading, editing, searching code; the terminal) does it serve? -->

## Type

- [ ] Fix
- [ ] Performance / memory improvement
- [ ] Improvement to an existing feature
- [ ] New feature (in scope per CLAUDE.md › Contribution rules)

## Memory and idle cost

<!-- Required for anything user-facing. Run ./scripts/memory-check.sh on the base build and this build, alternating a few rounds (or ./scripts/memory-compare.sh base/dist/Pulse.app dist/Pulse.app). -->

| Scenario | Before | After |
|---|---|---|
| Empty window | | |
| 10 files open | | |
| 10 files + terminal | | |

- What is created, when, and what releases it:
- Any new timer, observer, cache or child process (and its bound):

## Checklist

- [ ] `./scripts/policy-check.sh` passes
- [ ] `swift test` passes
- [ ] No new dependency, framework, network call, background work or bundled asset (CLAUDE.md › Restrictions)
- [ ] I did not edit the rules, thresholds or allowlists to make this pass
