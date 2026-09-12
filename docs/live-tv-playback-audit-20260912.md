# Live Apple TV playback follow-up — 12 September 2026

## Scope and evidence

TV-only local test build 248, based on `115c30a71` plus this change. No public release, feed edit,
provider ranking change, or private-engine source publication is part of this follow-up.

The original diagnostic 21 was read completely in the preceding audit. This follow-up retrieved complete
app log files remotely, but reviewed the relevant playback windows rather than claiming another complete
line-by-line read. An administrator-authorized, device-only sysdiagnose supplied AppleAVD evidence that
the release app had discarded. Raw device logs, account preferences, and system archives remain private.

## Confirmed hardware fallback mechanism

The AIOStreams selection requested VideoToolbox and contained H.264, 3840×2160, 8-bit 4:2:0. AppleAVD
opened its hardware session on an idle core. The initial session was invalidated without a decoded frame.
Subsequent sessions reported missing reference-picture lists, including a session not started with an
I-frame; callbacks returned bad-data status `-12909`. Six errors occurred before software was active.
The first visible app time was 10.010 seconds despite resume zero and auto-skip off. Output drops then
increased from 66 to 264 in roughly 30 seconds, alongside a shallow cache.

The later smooth selection through Debridio was HEVC, not the same encode. It negotiated VideoToolbox,
had a slightly different duration, and advanced steadily. This is not evidence of a TorBox outage or
proof that 4K H.264 is generally unsupported. It also does not isolate network throughput using two
identical files.

**Unresolved:** why the first session/packet chain fails. The pinned mpv includes an H.264 first-packet
SEI probe followed by a flush; FFmpeg can also invalidate VideoToolbox during format renegotiation or
after a no-output callback. A system trace alone does not establish which initiated this run. Repeated
session creation after bad-data callbacks matches the pinned FFmpeg recovery path, but neither deleting
the initial probe nor forcing hardware forever is shipped as an unverified cure. The exact failed URL was
no longer the saved source, and a bounded refetch did not return an unambiguous matching candidate.

## Implemented

- Relative tvOS seeks now receive the existing out-of-cache refill hold and generation-owned recovery
  watchdog, just as absolute seeks do. Relative command semantics and the viewer's pause intent remain
  unchanged. This repairs a specific missing guard; it does not prove every pause/seek freeze resolved.
- Selected native WebVTT cues can use the existing app subtitle overlay, making outline/shaded/box
  appearance app-controlled without changing system-wide caption settings. AVFoundation still selects
  and times the track. The native renderer is suppressed before publishing supported text; cues replace
  rather than accumulate. Seek flush, selection, item replacement, external subtitles, and teardown clear
  or fence obsolete callbacks. Unknown/bitmap output stays native. PiP and AirPlay retain native captions.
- Probe-enabled release builds subscribe only to decoder log categories and export bounded allowlisted
  reason codes. This includes VT frame status, no-output callback status/reconfiguration, format/session
  failure, and waiting for a keyframe. No raw log text, stream URL, or header is exported. Receipts are
  capped and deduplicated per controller; absence of a classified receipt is not absence of an error.
  FFmpeg's logger is shared, so its messages alone do not prove source ownership.
- Retains `115c30a71`: 32 MiB next-episode warmup response limit matches its request; source recovery
  no longer introduces a synthetic pause while preserving an actual viewer pause.

## Verification and limits

- Standalone decoder receipt tests: 52 category/prefix checks and 9 privacy rejections passed.
- Native subtitle bridge tests passed with complete Swift concurrency checking and warnings as errors:
  renderer exclusion, cue replacement/expiry, flush, stale callbacks, unsupported fallback, engine wiring,
  and eight PiP/AirPlay ownership combinations.
- Relative seek regression and diagnostic-21 binge regression tests passed.
- Cache-flush receipt contract (35 checks) and remux terminal policy tests passed.
- Independent Terra code review passed, including a PiP/AirPlay correction and generation-before-teardown
  overlay clear correction. The final decoder extension received a separate passing review.
- Fresh generic-device tvOS Release build succeeds; the final artifact receipt records source, binaries,
  build version, retained dependency hashes, and IPA checksum. No old application bundle is reused.

No on-TV soak or visual subtitle verification is claimed for this new binary. Remote device access works,
but this Mac has no valid signing identity/provisioning profile, so the unsigned IPA must be signed and
sideloaded before the next test. Administrator authentication is not Apple application signing authority.

## Overnight follow-up — local build 249

### Paused DV failure: device-backed cause

The device system archive records AVFoundation `-11866` with underlying CoreMedia `-12888` at
02:46:42.050, followed by the app's paused failed-to-end receipt at 02:46:42.129. Apple identifies
`-12888` as a playlist-unchanged condition in its
[HLS performance session](https://devstreaming-cdn.apple.com/videos/wwdc/2018/502plwzfxg5p7w4na/502/502_measuring_and_optimizing_hls_performance.pdf).
The local producer had parked at 90.504 seconds lead; after the deliberate 02:46:04 pause, the app
served the same non-ended media playlist every six seconds through 02:46:42.

The bounded producer and AVFoundation's growing-playlist freshness requirement conflict during a long
pause. The app then compounded that expiry: `failedToEnd` unconditionally queued a terminal error,
unlike its status-failure handler. On Play that terminal superseded healthy same-mount recovery.
This is not evidence that TorBox was down, nor proof that all reported active-play stalls share this cause.

### Corrected paths

- A failed-to-end event while paused now classifies actual producer health and retains exact same-mount
  recovery evidence. It never reloads or starts playback while held paused.
- Duplicate KVO and failed-to-end callbacks coalesce instead of overriding recovery with a terminal error.
- Published-tail retries rearm only after six seconds of small monotonic clock advances, a usable frame,
  actual/requested playing transport and completed position restoration. Immediate repeated failures,
  paused ticks, missing frames and seek jumps cannot create an unbounded replacement loop.
- A producer finishing during paused recovery no longer means the viewer finished the episode. A position
  inside the retained finalized window resumes using the same playlist and existing selection/DV/position
  restoration; actual final-edge positions remain EOF, invalid/evicted positions remain errors.
- Producer completion or failure during the bounded recovery observation is handled explicitly instead
  of silently abandoning the observation and leaving the item stuck.
- Normal TV source switches preserve explicit viewer pause intent only after load admission, bind it to
  the accepted token, and suppress pre-ready autoplay. A failed retiring engine's pause flag is not treated
  as viewer intent.

The server still publishes only real media and true ENDLIST. No fake segments, fabricated sequence
movement, disabled producer bounds, forced software decoding, or private-engine rebuild is included.

### Verification

- 75 remux terminal/pause/finalized-window/retry-budget checks pass with strict Swift concurrency and
  warnings-as-errors, including source wiring checks. These are policy/contract tests, not a device soak.
- Relative seek, source-switch transport and diagnostic-21 binge regressions pass.
- Native subtitle bridge, decoder-receipt privacy tests and Apple remux recovery policy tests pass.
- Independent Terra review of the complete production diff found no blocker.
- Build/artifact provenance is recorded beside the local IPA after the final tvOS build completes.

The separate 4K H.264 first-session failure remains unresolved. A fresh bounded attempt to retrieve the
same AIOStreams candidate again returned only configuration/password error entries, not the failed media.
No settings, credentials, add-on order or server configuration were changed to work around that response.

## Episode completion, CW target, and season focus follow-up (build 250)

- Issue #223 exposed a missing general premature-EOF guard: after a first frame, an EOF far before a
  known duration could enter watched/auto-next handling. Both Apple players now classify it as a
  same-episode source failure before completion side effects. Recovery uses observed media position,
  not an optimistic seek target or retained resume floor. Live, trailer, unknown-duration and genuine
  final-tail behavior remains unchanged. This closes a proven code gap; the reporter supplied no log,
  so attribution of their particular failure remains unconfirmed.
- Completion evidence and duplicate-EOF suppression belong to a physical mount. AVPlayer item generation
  resets them even when a logical token is reused; libmpv already mints a fresh token on every load.
- Local CW fallback to Details no longer drops its episode ID/resume position on TV and iPhone. An exact
  zero-offset episode remains a valid target, rather than selecting the first unwatched special. A newer
  profile-local first-frame stream receipt supersedes that navigation hint after subsequent playback.
  The hero waits if its exact target is missing from a partial inventory; it does not invent S0E1.
- iOS hero resume offsets are now checked against the selected episode ID, matching tvOS.
- First episode Up explicitly reveals/focuses the selected season chip, not the hero. First-row Down
  still targets the second episode and deeper rows retain native navigation.

Verification: 28 completion-evidence checks, 22 CW-target checks, 43 focus contract checks, 105 existing
integrity checks, 77 Trakt/session contracts, 27 identity caller/mutation checks, the existing EOF ownership
suite and both diagnostic-21/relative-seek Node contracts pass. Changed iOS source parses against the iOS
SDK. Independent Terra/Luna reviews checked recovery ownership and CW/focus wiring; review findings were
resolved before packaging. Artifact/build provenance is recorded alongside the local IPA after build.

Muse Spark 1.3 Contributor was present in the OpenCode Go model catalog, but the bounded read-only attempt
returned no model response before timeout. No model-quality conclusion or successful external review is
claimed. No fresh device diagnostics were pulled while the owner tested the previous IPA. These changes
do not claim to resolve the separate 4K H.264 decoding/initial-frame defect or prove an on-device soak.
