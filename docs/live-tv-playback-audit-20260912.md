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
