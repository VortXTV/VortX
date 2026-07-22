# Player-rework acceptance harness

A runnable gate that verifies the local HLS server (`VortXRemuxHLSServer`) against
the REQ-260722-09 + REQ-260722-04 contract (7 points). It is written against the
**contract**, independently of the implementation: it is RED against current beta
and turns GREEN when the rework is correct. It exercises **real runtime behaviour**
- it reads the server's own request log (`Caches/diagnostics.log`, the channel the
overnight run used) and, while a plain-remux MKV is playing, fetches playlists and
segment bytes over the simulator's shared loopback. It never asserts on source text.
The plain and Dolby Vision lanes share the startup gate and the playlist builder
(`DVPlaybackPolicy.mediaPlaylistHeader` + `VortXRemuxHLSServer.buildMediaBody`), so
every point is observable with a plain MKV - which is all this machine has.

## Re-run when the rework lands

```bash
cd test/player-conformance
./run-conformance.sh selftest          # validate the oracle (no sim needed)
./run-conformance.sh mutants           # every load-bearing oracle mutant must die
./run-conformance.sh trace             # points 1,3,4,6,7 from the sim's live container log
./run-conformance.sh live-auto          # UNATTENDED full 7-point battery (no human)
./run-conformance.sh live-auto --starve # point 7's timeout path, also unattended
./run-conformance.sh live-auto --rotation-control # force a real diagnostics rollover
./run-conformance.sh live-auto --no-reader        # historical AVPlayer-only control
```

`live-auto` is the whole thing end to end: it generates a fixture MKV with `ffmpeg`,
serves it range-capably from the Mac's LAN address, starts playback headlessly through
the DEBUG playback hook (`DEBUG-PLAYBACK-HOOK.md`), waits for the real
`readyToPlay -> play()` line, snapshots the exact product-only trace, advances the HLS
read head with an explicitly labeled test reader, runs the battery, and tears the
session down. Add
`--spool <dir>` once the rework names a spool directory. The manual flow still works
unchanged if you would rather drive playback yourself:

```bash
# play a plain (non-DV) .mkv on the booted Apple TV 4K sim so it routes to the
# AVFoundation plain-remux HLS lane (log shows: "route ... isDV=false ... -> engine=avfoundation"),
# and while it is PLAYING:
./run-conformance.sh live --spool <caches-spool-dir>   # full 7-point battery + segment/IDR + availability probe
```

`live` and `live-auto` exit `0` when every point is GREEN/EXEMPT, `1` when the gate ran
and at least one point is RED (the product signal), and `3` for INFRA: the session could
not be stood up OR could not be OBSERVED. That second half matters. "I could not reach
the thing I meant to measure" is INFRA, never a verdict: if the live channel cannot fetch
the media playlist, or every segment probe fails to reach the server, the run exits `3`
naming the port, where the port came from, the HTTP status or transport error, and
whether the app and the fixture server were still alive. It does NOT degrade those points
to INDETERMINATE and then exit `1`, which would report an observation failure as a
product regression. "There is genuinely nothing to measure" (point 5 with no spool
directory) stays a legitimate INDETERMINATE. CI must never read a `3` as a player
regression.

Everything builds under the stable derived-data path `/tmp/dd-harness` (never a
per-run path). `./run-conformance.sh app-build` rebuilds `VortXTV` into that same
path if you need to regenerate a trace from a fresh binary. The gate exits `0` only
when **every** point is GREEN/EXEMPT; against beta it exits non-zero. Subcommands
also run directly: `/tmp/dd-harness/bin/player-conformance {selftest|trace <log>|live --container <dir>|spool <dir>}`.

## What each point needs, and current beta status

| # | Point | Channel | Beta now |
|---|-------|---------|----------|
| 1 | Startup cohort ≥6 segs AND ≥15000 ms (integer-ms from EXTINF text) | trace + live | **RED** - first `/media.m3u8` served at `segs=2`, ~8000 ms |
| 2 | Every published segment starts on an IDR frame | live (init + fMP4 parse) | **RED** - the sampled first video access units fail the combined MP4-sync and AVC/HEVC-IDR test |
| 3 | First video seg id == 0 AND first alt-audio seg id == 0 | trace + live | **RED** - video half is 0; no alternate-audio rendition exists (audio muxed) |
| 4 | No advertised-segment 404 through the RFC 8216 §6.2.2 window | trace diagnostics + live complete-response probes | **RED, proven** - playlist advertised 116 while ~34 are resident; 16 advertised ids probed, all returned complete `HTTP 404` responses |
| 5 | Spool bounded (Caches, session-global) + reclaimed to zero after session | live (filesystem) | **INDETERMINATE** - no on-disk spool exists yet; needs the rework's spool dir |
| 6 | Startup latency: mount → readyToPlay ≤ 30000 ms | trace | **GREEN** - 1177 ms in the overnight run |
| 7 | Fail-soft counted: exactly one `hls_startup_cohort_timeout` + 404 on timeout, none otherwise | trace (both paths, via `live-auto --starve`) | **PENDING / INDETERMINATE** - event absent in beta; success-path invariant holds, and `--starve` now drives the timeout path unattended |

## What still needs a human, and what no longer does

- **A fresh live plain-remux session no longer needs a human.** The Debug build
  carries a headless playback hook (`DEBUG-PLAYBACK-HOOK.md`), so `live-auto` mints
  a real session under `xcrun simctl` alone. Point 2 and the point-4 active probe
  are therefore fully automatable now: `live-auto` generates its own fixture,
  serves it, plays it, and decides both from the live server.
- **Point 5 is still only half measurable, and not because of the simulator.**
  There is no on-disk spool in the current tree - the store is the in-memory
  `VortXRemuxBuffer` - so there is no directory to size. Point 5 becomes measurable
  when the REQ-260722-09 rework lands its spool directory; pass that path as
  `--spool <dir>` and `live-auto` measures it both mid-session and again after
  teardown for the reclaimed-to-zero half. Until then the point reports
  INDETERMINATE and the runner says so; it is never faked or inferred.
- **Point 7's positive path no longer needs a human or a special fixture.**
  `live-auto --starve` paces the existing fixture below the rate at which the
  contract's cohort floor can fill, which drives the timeout path deterministically.
  See the `--starve` section below. The counted event does not exist in the current
  beta, so the point stays PENDING/INDETERMINATE today; the channel is wired and
  runs, so the rework's fail-soft is verifiable the moment it lands.
- **Physical Dolby Vision display-mode switching** is hardware-only - the sim logs
  "display switch skipped: the simulator has no HDMI display modes" - and is out of
  this harness's scope regardless (it is a plain-remux gate).

## The `live-auto` source fixture (generated, never committed)

`live-auto` builds its own source with `ffmpeg` into `/tmp/dd-harness/fixtures`, beside
the stable derived-data path. No media binary is ever committed and no file from anyone's
library is used.

This is distinct from the two small byte-exact fragmented-MP4 fixtures committed as
base64 for the oracle self-test. Those files are real `ffmpeg` output, not synthetic
box builders: one is AVC with video-first `traf` order and one is HEVC with audio-first
order. The self-test decodes them in memory, resolves the `vide` track from
`moov/trak/tkhd/mdia/hdlr/stsd`, reads NAL framing from `avcC` or `hvcC`, and then
matches that track by `tfhd.track_ID` in the media fragment.

**Four** properties of the fixture are load-bearing, and none is obvious from reading the
script, so the reasoning is recorded here in full. Each was found the same way: a
parameter that looked like a detail turned out to decide whether a gate point could fail
at all. **A fixture that cannot make a point FAIL is not testing that point.** Every one
of these numbers is derived from a constant the harness already owns, never picked, so
`Contract.swift` stays the single source of truth; do not replace any of them with a
literal.

### GOP 6.000 s, deliberately LONGER than the 4 s hard cut (point 2)

This is the difference between a fixture that TESTS point 2 and one that FAKES it. The
segmenter's entire cut rule is one predicate, `VortXMKVRemuxStream.swift:2030-2032`:

```swift
guard (isKey && elapsed >= Self.hlsTargetSegmentSecs)   // 1.0 s
        || elapsed >= Self.hlsMaxSegmentSecs            // 4.0 s
        || openBytes >= Self.hlsMaxSegmentBytes else { return }
```

Cut on the first KEYFRAME past 1 s, else hard-cut at 4 s on whatever frame is current.
Only that hard cut lacks an `isKey` guard, so only the hard cut can begin a segment
mid-GOP, and that is the entire hazard point 2 exists to catch. At any keyframe interval
of 4 s **or less** the keyframe branch always fires first, every cut lands IDR-aligned,
and point 2 scores a **false GREEN** with the defect completely untouched.

This is not the same rule as "a GOP that does not divide evenly into 4 s". A 3 s GOP
satisfies that and still hides the hazard: measured, it produced 2.92 s / 3.00 s
segments, zero hard cuts, and point 2 GREEN with zero offenders. **The interval must
exceed 4 s.** At 6 s the cuts are periodic and half of them are mid-GOP by construction:

```
seg0   0.0 -> 4.0   hard cut at 4 s              (starts on the t=0 keyframe: IDR)
seg1   4.0 -> 6.0   keyframe cut, elapsed 2.0 s  (STARTS MID-GOP: non-IDR)
seg2   6.0 -> 10.0  hard cut                     (starts on the t=6 keyframe: IDR)
seg3  10.0 -> 12.0  keyframe cut                 (STARTS MID-GOP: non-IDR)
```

6 s also leaves the post-cut remainder at 2.0 s, comfortably clear of the 1 s target
floor, so the following keyframe cut is unambiguous rather than a floating-point coin
toss (a 5 s GOP puts that remainder on exactly 1.000 s).

### Delivery paced at 4x the fixture's own bitrate (point 1)

Unpaced, a LAN server hands the simulator the whole 92 MiB in well under a second, so the
remux closes **every** segment of the file before AVPlayer issues its first
`/media.m3u8` request. The session degenerates into an instant ENDLIST VOD: measured, the
server answered that first request with `segs=30 ended=true` and point 1 scored **GREEN**
while the beta's real premature-open defect sat untouched. That defect is
`VortXRemuxHLSServer.swift:433`, `minStartupSegments = 2` against the contract's 6, and it
is only observable when the producer and the player actually race, which is the real
debrid/direct condition. Paced, the first playlist response is the real one, `segs=2`.

Pacing is safe because `serveMedia` HOLDS the request until the gate opens
(`VortXRemuxHLSServer.swift:451`) rather than 404ing it. The rate is derived from the
fixture's own size and duration, never hardcoded, so swapping the fixture cannot silently
unpace it.

### Sized and actively drained so the window GENUINELY EVICTS (point 4)

Point 4 asks whether the playlist advertises segments the server can no longer serve. If
nothing has been evicted, the question is unanswerable and the point cannot fail. The
first version of this fixture, 150 s / ~92 MiB with a flat 45 s soak, was exactly that
case: the active probe fetched all 15 predicted-evicted ids and got **HTTP 200 on every
one**, and the point only went RED on the latent arithmetic. That looked like a
contract-interpretation question. It was not. It was a fixture that was too small.

The buffer's two relevant rules, both in `VortXRemuxBuffer.swift`:

- Eviction is driven by the READ HEAD, not by production:
  `keepFrom = max(storageBase, readHead - windowFloorBytes)` (`:274`). Segment 0 survives
  until the read head passes `windowFloorBytes`, and the read head advances at roughly
  playback rate.
- The resident ceiling once the engine is ready is
  `windowFloorBytes + producerLeadFull` = 64 + 64 = **128 MiB** (`:80-81`, `:101`).

A ~92 MiB fixture never reaches that ceiling and its read head barely grazes the 64 MiB
floor, so nothing is ever evicted. The current source fixture is sized from those
numbers, and the bounded reader deadline is derived rather than guessed:

```
reader deadline base = EVICTION_MARGIN x windowFloorMiB
                       / (fixture bytes / fixture seconds)
```

`windowFloorMiB` is read out of `Contract.swift` at runtime rather than restated in the
script, and `EVICTION_MARGIN_PERCENT` defaults to 120 so the deadline is comfortably
past the floor rather than sitting on the knife edge that produced the misleading
result. The runner logs the exact arithmetic for the generated fixture.

```
[live-auto] eviction sizing: buffer evicts at (readHead - 64 MiB), read head advances
[live-auto]   at playback rate <measured B/s>. Need read head past 120% of 64 MiB
[live-auto]   = <derived bytes>, so soak = <derived bytes> / <measured B/s> = <derived>s.
```

Point 4 is decided by the live battery's complete-response probes, never by prediction.
The synthetic reader also carries an optional beta-defect observation: it must first
observe a complete `HTTP 200` for `seg0.m4s`; a successfully fetched current manifest
must still advertise that id; and only then can two consecutive complete `HTTP 404` or
`410` responses report stale retirement. Curl transfer completion and HTTP status are
recorded separately. A nonzero transfer result, a partial response, a timeout, or a
single transient response resets that proof and can never report the defect.

**Pacing still controls startup, but AVPlayer no longer owns test progress.** One source
rate still has two opposed requirements, so it cannot simply be turned up:

- Too FAST and the producer runs ahead into the buffer's park ceiling. Parking blocks
  inside the SOURCE READ, so the app's own detector fails the remux. Measured at 4x:
  `live source read stalled 48.2s (rc=-5, produced=125901614B)` then
  `hls 404 /media.m3u8 (remux failed)` and a demotion, ~95 s in. At 125% it still parked,
  later: the playlist froze at `segs=70` for 40 s while AVPlayer polled, then
  `mid-play AVPlayer endFileError (Playback Stopped) -> demote to libmpv in place`.
- Too SLOW and the startup cohort takes long enough that AVPlayer abandons the mount
  before becoming ready. Measured at 113%: the gate opened 5.3 s after mount and
  AVPlayer issued no further request after receiving the playlist.

The second failure was the key reliability finding. Point 2 deliberately exposes
non-IDR starts, and AVPlayer can stop fetching those media segments. Once that happens,
waiting for AVPlayer to advance the single buffer read head is circular: expected
128 MiB back-pressure freezes production, AVPlayer reports `Playback Stopped`, and the
product intentionally demotes to libmpv. The HLS listener disappearing at that point is
therefore expected fail-soft behavior, not a crash or an unexplained source stall.

The default run now takes an immutable product-only trace snapshot immediately after
readiness and before any test traffic, then starts a synthetic HLS reader. The reader:

- consumes data only for ids present in a successfully fetched live manifest, while
  the separate retirement control deliberately probes `seg0.m4s`;
- consumes them in exact numeric order and never skips or races ahead;
- records every manifest, segment, and retirement request with both curl transfer result
  and HTTP status in
  `/tmp/dd-harness/last-reader-control.log`;
- classifies repeated manifest or advertised-segment read failures as INFRA;
- reports the stale-retirement defect only after prior same-session complete 200,
  current advertisement, and two consecutive complete 404/410 responses; and
- proceeds to the same acceptance battery when seg0 remains served, disappears from
  the playlist, or the optional defect control remains inconclusive.

The synthetic requests are excluded from trace verdict evidence at the byte boundary.
`/tmp/dd-harness/last-session.log` is the product-only snapshot, while
`/tmp/dd-harness/last-full-session.log` retains the later diagnostic timeline. The
snapshot must remain nonempty and have the same `cksum` after all test traffic.

**Acceptance does not require the defect.** A timer or prediction never becomes a
point-4 verdict. If every advertised segment remains completely served, the default run
continues and the live battery can score that conforming behavior GREEN. If seg0 is
removed from the current playlist, the reader does not probe the unadvertised path and
continues. If stale retirement is proven, it is reported and the same live battery
independently scores the advertised-id 404/410. `--no-reader` deliberately retains the
historical AVPlayer-only soak and confirmation path as a diagnostic control; it is
expected to reproduce the old demotion chain on the affected beta.

One knock-on worth knowing about, because it will bite anyone who tunes these numbers.
Once the run really evicts, the LOWEST advertised ids are precisely the dead ones, so
point 2's segment sampler must walk to the first `--sample` segments that are actually
**retrievable** instead of the first N advertised. With a naive `prefix(N)` it spends its
whole budget on 404s and reports "checked 0 segments", and point 2 silently stops being
decided. Sizing for one point can blind another.

### Served from the Mac's LAN address, over a range-capable server

A loopback URL is vetoed by the router, the engine gate and the remux candidacy alike,
which silently lands the stream on libmpv and tests the wrong engine. The address is
DHCP-assigned and discovered at runtime with `ipconfig getifaddr`, never hardcoded. A
server without `206` support breaks the remux read path in a way that looks like a player
bug, so `python3 -m http.server` is not usable here; `range-server.py` is, and
`live-auto` verifies a real `curl -r` returns `206` with a correct `Content-Range` before
it launches the app.

The default `live-auto` begins its explicit reader after `readyToPlay`; `--soak` sets the
derived deadline base rather than an idle delay. The historical `--no-reader` control
still idles for that period. The product-only session at
`/tmp/dd-harness/last-session.log` can be re-read with `trace`.

## Point 2's fail-closed oracle

Point 2 accepts a segment only when both independent signals agree for the first sample
of the resolved video track:

1. ISO-BMFF sample flags say the sample is sync (`sample_is_non_sync_sample` is clear).
2. The length-prefixed access unit contains an AVC IDR NAL type 5 or a base-layer
   (`nuh_layer_id == 0`) HEVC IDR NAL type 19/20, using the NAL length size from the
   init segment. Nonzero-layer IDR-type NALs remain structurally valid but are not
   base-layer random-access proof.

Missing or unmatched `track_ID`, ambiguous video tracks, duplicate matching `traf`
boxes, unresolved multiple sample descriptions, unsupported FullBox versions or flags,
unknown codec/framing, bad sample ranges, short NAL headers, invalid reserved bits,
absent flags, and malformed NAL tails all fail closed as unknown. Every `trun` record
declared by `sample_count` must fit exactly, and the NAL walker reaches exact sample
termination before reporting an IDR. There is no first-`traf` or last-`traf` fallback.
`./run-conformance.sh selftest` exercises the real AVC video-first and HEVC audio-first
two-track fixtures plus malformed structural and NAL fixtures. It also uses a deterministic
`URLProtocol` to cover response-plus-error, post-timeout completion, and an advertised
partial segment. The shell self-test serves truncated 200, 404, and 410 responses locally
and proves they remain transport failures. Separate shell controls prove that both
fully served and playlist-removed conforming behaviors proceed to the battery, while
two complete stale advertised-id 404s are still reported. `mutants` removes each
load-bearing guard one at a time; all ten mutants must die: wrong track,
nil/unmatched track fallback, unknown `tkhd`, sync-only, NAL-only, audio-first order,
video-first order, HEVC IDR without the base-layer guard, and restoration of the old
defect-required acceptance path. The tenth mutates the 4-byte `tkhd` FullBox-header
guard so real-init-derived 1-, 2-, and 3-byte malformed payloads turn the self-test RED.

## Reliability controls and evidence boundary

`live-auto --rotation-control` proves the product snapshot survives a real rolling-log
boundary. After the snapshot, it sends labeled unknown-path requests that return 404 and
do not touch manifests, segments, or the read head. It proceeds only after observing the
real `diagnostics.log` byte size shrink, preserves counts in
`/tmp/dd-harness/last-rotation-control.log`, and then rechecks the snapshot fingerprint.

The predecessor default path completed three consecutive warm runs and three consecutive
runs immediately following `simctl install`; all six observed the beta defect and
reached the expected product-gate exit 1 instead of INFRA. Those runs are historical
reliability evidence, not a requirement that a corrected server reproduce the defect.
A separate rollover run observed a real log shrink after 498 labeled requests and
retained the same nonempty product snapshot.

## `live-auto --starve`: point 7's positive path

Point 7 wants **exactly one** `hls_startup_cohort_timeout` plus a 404 into the libmpv
demotion when the startup cohort cannot fill, and **zero** events otherwise. The
success-path half is provable on any normal run. The counted-timeout half needs a source
that cannot fill the cohort, which this harness used to record as needing a fixture we did
not have.

It does not need a fixture. It needs a slower pace, which is already a parameter:

```bash
./run-conformance.sh live-auto --starve
```

The starving rate is derived from the contract's own numbers, not chosen:

```
starve rate = mediaBytesPerSec x minStartupMs / (STARVE_FACTOR x sloMountToReadyMs)
```

so the contract's cohort duration floor takes `STARVE_FACTOR` times the point 6 SLO to
deliver and provably cannot fill before any startup deadline. Both constants are read out
of `Contract.swift`. The runner logs the derivation:

```
[starve] starving pace 80223 B/s. Derivation: the contract's cohort floor is
[starve]   6 segments AND 15000 ms; delivering 15000 ms of media
[starve]   at this rate takes 120s, i.e. 4x the 30000 ms
[starve]   mount->ready SLO, so the cohort provably cannot fill before any startup deadline.
```

**This mode's success criterion is the opposite of the normal one, and the code says so
explicitly.** On a starved start the contract WANTS the fail-soft to fire, so a demotion
to libmpv is the EXPECTED terminal state here, not the INFRA exit-3 condition it is on a
normal run. `readyToPlay` is the anomaly in this mode: it means the pace failed to starve,
and the runner says so and tells you to raise `VORTX_STARVE_FACTOR`. Because the HLS
server is gone once the session demotes, `--starve` evaluates the captured session with
`trace` rather than `live`; point 7 is a trace-channel point anyway.

Against the current beta the counted event does not exist at all (it is part of the
pending rework), so the observed outcome is a demotion **without** a counted event and
point 7 reports INDETERMINATE. **That is the correct result today and nothing is tuned to
manufacture a GREEN.** What this buys is that the CHANNEL is wired and exercised: the run
already produces `saw a 404: true, reached readyToPlay: false`, so the only missing
ingredient is the event itself. The moment the rework emits it, this same command
verifies the positive path with no human and no new fixture.

## Known limits and historical controls

**1. The retained post-install trace shows a failure at roughly 55 s, but not a proven
single root cause.** Its primary evidence records the source fixture and app process
remaining alive, media requests stopping, later `Playback Stopped`, and an in-place
demotion. Buffer-ceiling interaction is a plausible explanation supported by the wider
diagnostic timeline, not a fact established by the retained excerpt alone. The reliable
harness conclusion is narrower: depending on AVPlayer alone to advance the read head
made the test unable to preserve a probeable HLS session. The explicit reader removes
that circular dependency without claiming more than the evidence proves.

**2. `--no-reader` is intentionally not the reliable gate.** It preserves the old path
for reproducing and diagnosing the beta behavior. A listener loss there remains INFRA,
not a product verdict. Use the default reader for acceptance results.

**3. Fixture-server liveness reporting was wrong in still-older logs.**
`start_fixture_server` was called in a command substitution, which runs in a SUBSHELL, so
`SERVER_PID=$!` never reached the parent shell. That silently disabled both the cleanup
trap's kill and the soak's liveness check, and made `server_alive()` report a permanent
false `NO`. **Nine fixture servers leaked across nine runs**, several still streaming at
full rate and competing for CPU and bandwidth with every later run, which plausibly
contributed to earlier flakiness. Fixed, plus a stray sweep at preflight. Any run log
older than that fix showing `fixture server alive at probe time: NO` should be
disbelieved.

If the fixture server does die, its stderr is preserved at
`/tmp/dd-harness/last-fixture-server.log` and the run exits 3 with
`fixture server alive at probe time: NO`.

## Proving it is a real gate (not a RED stamp)

Two synthetic golden traces (no real user data) show the harness flips per behaviour:

```bash
/tmp/dd-harness/bin/player-conformance trace fixtures/post-rework-normal.trace.txt  # points 1,3,4,6 -> GREEN
/tmp/dd-harness/bin/player-conformance trace fixtures/forced-timeout.trace.txt      # point 7 -> GREEN
```

The real overnight beta trace makes points 1, 3, 4 RED; feeding the same harness a
trace with a filled cohort, a `seg0`/`aseg0` first request, a bounded advertised
window, and a single `hls_startup_cohort_timeout`+404 turns them GREEN. (The real
overnight log is deliberately NOT committed - it carries runtime ids; keep it out
of the repo.)

## Files

- `Contract.swift` - the numeric contract + the 7 points + verdict types.
- `Playlist.swift` - EXTINF→integer-ms (no float), media-playlist parse, cohort predicate, server-faithful body build (uses the real `DVPlaybackPolicy` header).
- `FMP4.swift` - resolves the video track and codec from init data, matches `tfhd.track_ID`, locates the first video sample, and requires MP4 sync plus a real AVC/HEVC IDR NAL.
- `FMP4Fixtures.swift` - decodes and splits the two committed byte-exact real fMP4 fixtures used by self-test.
- `fixtures/*.mp4.b64` - real AVC video-first and HEVC audio-first two-track `ffmpeg` output, base64 encoded for source control.
- `Trace.swift` - slices one plain-remux session from a request log and evaluates points 1,3,4,6,7.
- `Live.swift` - loopback fetch + init/segment oracle + availability probe + spool measure. Point 4 there ORs two strands: an active probe aimed at the ids the window arithmetic says are already evicted, and that arithmetic itself (shared with `Trace` via `Trace.availabilityWindow`, so the two channels can never disagree on the numbers).
- `main.swift` - CLI + oracle self-test, including real init/media fixtures, track-order permutations, fail-closed corruptions, and playlist boundary cases.
- `run-conformance.sh` - builds the harness at `/tmp/dd-harness` and drives the modes, including the unattended `live-auto`.
- `range-server.py` - range-capable (206), rate-paced, non-loopback single-file server for the `live-auto` fixture.
- `DEBUG-PLAYBACK-HOOK.md` - the app-side contract for the headless playback trigger `live-auto` drives.
