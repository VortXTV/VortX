# Apple playback: diagnostics 21–23, 26 September 2026

## Evidence coverage

Read-only agents read all records in the supplied Downloads copies: diagnostic 21 (17,186 lines), 22 (13,873 lines), and 23 (18,477 records, including its unterminated last record). These filenames have been reused; these counts identify this batch, not earlier reports with the same number. After the owner restarted the Apple TV, a fresh 3,246-line persistent app log was retrieved from the device. Private raw logs remain outside the repository.

Diagnostic 23 includes a long healthy libmpv run followed by an embedded older incident, so file order is not chronological. The failed DV run's playlist stopped advancing while the player drained its remaining lead. A loopback 410 appeared only after teardown; it is not the initiating failure. The fresh device log also contains an actual upstream read stall and a separate remux production gap without a recorded network error. Neither proves that all AIOStreams or TorBox requests are broken.

## Source corrections

- **DV publication capacity:** rewind history and producer lead each independently spent the entire 352 MiB publication allowance. The resulting publication and retained predecessor could block the 1 GiB physical spool until an HLS resource deadline expired. One publication now plans 128 MiB history, 160 MiB forward lead and 64 MiB post-close allowance. The gate acts after closing a segment, so that allowance is necessary. Existing advertised-resource deadlines and aggregate physical admission remain enforced.
- **Player/producer buffer coupling:** measured-bitrate requests use the actual forward allocation. The preferred eight-second floor becomes a soft floor bounded by half the affordable duration; otherwise high-bitrate media could ask for more buffered time than production can supply. Unknown-bitrate behavior is unchanged.
- **Source/episode surface retention:** an already-admitted MPV replacement no longer clears fallback and recreates AVPlayer with the original launch episode. Explicit engine switches construct the surface from the active URL, headers and content hints on both Apple surfaces.
- **Transport and screensaver ownership:** TV idle prevention follows viewer play intent, not transient native pause callbacks during fallback/rebuffering. A process-wide owner lease prevents an old view's disappearance from releasing a replacement view's idle prevention. Handoffs carry viewer pause intent. Tagged callbacks from a superseded load cannot overwrite pause or buffering state on either Apple surface.
- **Empty prepared sources:** a zero-packet next-episode URL is exhausted immediately. Its exact load can accept a late-arriving alternative, bounded by the existing 20-second settlement policy. Competing no-frame/retry timers are retired, and secondary errors for that same load cannot reopen the dead URL. The overall recovery cap remains. Cancellation, source/episode replacement, explicit pause and exhausted hop budget are respected. Terminal publication clears the reconnecting spinner.
- **Resume recovery:** the ordinary stall watchdog cannot reload an unconfirmed resume target while the exact deferred-resume watchdog owns it. Recovery nudges use the no-cache-hold resume API and a confirmed position, rather than arming the manual-scrub hold/refill watchdog. Continue Watching's valid persistence floor is retained.
- **Diagnostics:** one receipt per spool admission wait distinguishes local physical capacity from upstream starvation, including companion-resource bytes. No source URL, account identifier or credential is logged by the new receipt.

## Verification

The production-spool replay reproduces the legacy block at step 33, then advances 200 steps with the repaired allocation and every advertised URI retained through its deadline (peak 106/128 scaled units). A variable 7–65 MiB cohort replay uses the real producer ledger and post-close gate for 300 consumer steps: 16 MiB observed overshoot, peak 808/1024 units, no early eviction. These are bounded synthetic replays, not physical-TV playback.

Focused checks cover DV publication/seek contracts, producer lead and target coupling (including 16/20-second boundaries and 200–1,000 Mb/s), live-player behavior, empty-source ownership/settlement, resume reconciliation, idle-owner replacement, and source wiring. Independent read-only reviewers examined the actual remux allocation, transition/ownership and resume patches. Review findings about close-boundary overshoot, old-view idle release, raw pause intent and stale tagged callbacks were corrected before delivery.

All of those focused suites passed, as did terminal-failure and Apple/tvOS native-debrid recovery contracts, the residual-diagnostic source contract and iOS surface parsing. The final Full tvOS Release build succeeded with signing disabled. That local compile does not supply production service configuration or a signing identity; distribution must use the existing configured artifact lane and its gates.

## Limits and next device check

The old logs did not record physical-spool accounting, so the source-proven capacity defect is consistent with the frozen-playlist incident, not a proven explanation of every field stall. Unusually large GOPs, companion resources or open-stage allocations can still reach aggregate admission; the new receipts will distinguish that case. Unknown bitrate cannot provide an affordability guarantee until evidence arrives.

The resume patch prevents the confirmed reload/cache-hold conflict; time-position events still lack a per-seek command generation, so it does not prove that a late completion of an abandoned seek can never briefly update presentation. No decoder-selection, live-NNTP throughput, subtitle-rendering or Android fix is claimed in this batch.

On the test build, exercise a high-bitrate DV title through several rolling-window advances, pause/resume and rewind, AV→MPV fallback past the TV's screensaver interval, and multiple next episodes launched from Continue Watching. Match any new failure to its load token and new capacity receipt. A successful build or harness is not an overnight playback result.
