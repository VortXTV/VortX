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

## Fresh next-episode opening — Beta 15 / build 251

The subsequent build-249 device receipt contains S3E2 → S3E3 admission at 11:15:53.669, FILE_LOADED at
11:15:56.562, and first accepted position 4.046 at 11:15:57.145 with resume zero and auto-skip off.
VideoToolbox was active; the existing SDR display mode was retained. No application seek preceded it.
The app immediately committed that offset as the incoming episode. This is the concrete acceptance
defect corrected here, not evidence that a user requested a four-second start.

A bounded, credential-private retrieval found the matching 221,637,419-byte source. Its initial video
and audio timestamps are zero, with video keyframes at 0, 2.002, 4.004, 6.006, and 8.008 seconds. Only
the first 4 MiB was retained for local tests. The tested exact bundled GPL libmpv reports
`v0.41.0-dev-g8c67647b5-dirty`, FFmpeg `n8.1.2`, and uses libplacebo ABI 371. The retained published vendor
archive checksum matches the workflow pin. The build recipe's FFmpeg-9 comments do not establish the
version inside that archive. An earlier test binary accidentally linked non-GPL mpv 0.41 and was rejected;
its result is not used as verification.

The matching file starts at zero on the Mac with that exact runtime, direct VideoToolbox,
GPU-next/MoltenVK and AVFoundation audio, including same-handle replacement and the matching remote
source. Consequently the TV-specific native loss of the opening frames is not reproduced or claimed
root-caused. The separate 4K H.264 first-session failure remains an investigation item.

Implemented a one-shot fresh-origin check for an explicitly configured zero-offset VOD replacement.
It checks raw positions before UI throttling. A first positive position beyond one second issues one
warm `seek 0 absolute+exact`; high ticks cannot commit the episode, update CW, or publish progress while
the correction is pending. A seek event followed by a near-zero position proves the correction landed.
It does not restart the file, change the decoder, flush caches, or change Pause/Play. Nonzero resumes,
live, previews/trailers and unconfigured initial mounts are excluded. Manual/resume seeks supersede
the check. Refused loads retain the prior state and unconsumed configuration; accepted loads own a
fresh token. A rejected seek, eight-second deadline, or EOF before recovery becomes one source error,
not successful completion or repeated rewind. Normal playback never re-arms the check.

Controlled native tests deliberately requested start=4.046 to exercise this recovery, not to pretend
the TV defect was reproduced: the exact seek returned position zero in 0.390 seconds playing and
0.326 seconds paused, preserving `pause=no` and `pause=yes` respectively. Policy and source-wiring
checks cover ownership, stale events, ordinary starts, explicit seeks, paused zero receipts, live and
resume exclusions, failure/EOF handling, supersession, and one-shot command admission. Physical-TV
verification remains necessary to confirm the observed opening now appears reliably on that device.

Final gates: 59 fresh-origin policy/wiring checks, 105 existing integrity checks, 28 completion-evidence
checks, both diagnostic-21/relative-seek Node contracts, 61 release-feed tests and the release-orchestration
contracts pass. The final generic tvOS Release build succeeds after the review correction. Independent
Terra review found no remaining blocker; a separate Luna release audit verified scope, filenames and
Latest-beta markers. No native dependency or private-engine pin changed in this patch.
