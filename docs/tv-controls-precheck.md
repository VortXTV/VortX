# TV controls: cheap Up Next rejection

The hidden-controls remote handler checks `upNextRemaining != nil || isCreditsUpNext`
before revealing ordinary transport controls. Resolving `hasNextEpisode` sorts the
episode inventory and maps it into navigation candidates. The getters now reject
ineligible scalar states before doing that work. Eligibility, rounding, identity
precedence, credits behavior and episode navigation are unchanged.

This removes avoidable inventory work from the pre-reveal path. It does not establish
a physical Apple TV latency improvement or remove other work in the player callback,
visible controls, native track discovery or rendering.

## Source-unit regression

Run one local compiler/test lane at a time. The script sets its own priority to nice 15,
uses one compiler job/thread, and runs under a no-network, stage-only-write sandbox.
It requires macOS, Xcode and Node. It does not launch an app, read live preferences,
open media, contact an account or build an SDK/package.

```sh
node scripts/test-tv-upnext-precheck.cjs baseline
node scripts/test-tv-upnext-precheck.cjs current /path/to/stage/printed/by/baseline
```

The first command retains a fresh historical baseline. The second requires that
accepted baseline and unchanged captured source inputs, then compiles the current
production getter bodies. Each executable runs twice. The fixture file is deliberately
the pre-change baseline, not a second production implementation. The preparer checks
its unchanged navigation/sort/current-index bodies against actual source and replaces
only the two getters for the current comparison. Exact sources, compiler commands,
normal-exit receipts, executable hashes and result ledgers remain in `app/_build/`.

The 111-case matrix uses reversed 20, 1,000 and 5,000-episode inventories. It checks
individual getter results and the combined short-circuit expression across identity,
launch/loaded selection, scalar, credits and nonfinite-number cases. SDK-free adapters
count episode-source, consumed-field and metadata accesses; these are not native
queries, SwiftUI render counts or elapsed-time measurements.

Acceptance requires identical unique case/result coverage, no per-case increase in
any counter, zero inventory/metadata work for mid-episode, suppressed and short-runtime
denials at every size, and unchanged positive lookup work for the final-20-second case.
An unchanged, non-optimizing candidate fails this gate. This is targeted expression
coverage, not a full player, asynchronous inventory, duplicate-row or device test.
