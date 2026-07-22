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
./run-conformance.sh trace             # points 1,3,4,6,7 from the sim's live container log
./run-conformance.sh live-auto          # UNATTENDED full 7-point battery (no human)
./run-conformance.sh live-auto --starve # point 7's timeout path, also unattended
```

`live-auto` is the whole thing end to end: it generates a fixture MKV with `ffmpeg`,
serves it range-capably from the Mac's LAN address, starts playback headlessly through
the DEBUG playback hook (`DEBUG-PLAYBACK-HOOK.md`), waits for the real
`readyToPlay -> play()` line, runs the battery, and tears the session down. Add
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
| 2 | Every published segment starts on an IDR frame | live (fMP4 parse) | **RED** - of 12 retrievable segments sampled, every one starts on a non-sync sample |
| 3 | First video seg id == 0 AND first alt-audio seg id == 0 | trace + live | **RED** - video half is 0; no alternate-audio rendition exists (audio muxed) |
| 4 | No advertised-segment 404 through the RFC 8216 §6.2.2 window | trace (latent) + live (active probe **and** the same latent arithmetic) | **RED, proven** - playlist advertised 116 while ~34 are resident; 16 advertised ids probed, all `HTTP 404` |
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

## The `live-auto` fixture (generated, never committed)

`live-auto` builds its own source with `ffmpeg` into `/tmp/dd-harness/fixtures`, beside
the stable derived-data path. No media binary is ever committed and no file from anyone's
library is used.

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

### Sized and soaked so the window GENUINELY EVICTS (point 4)

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
floor, so nothing is ever evicted. The run is now sized from those numbers instead:

```
soak = EVICTION_MARGIN x windowFloorMiB / (fixture bytes / fixture seconds)
```

`windowFloorMiB` is read out of `Contract.swift` at runtime rather than restated in the
script, and `EVICTION_MARGIN` defaults to 2 so the read head travels comfortably past the
floor rather than sitting on the knife edge that produced the misleading result. At the
current 420 s fixture that derives a 209 s soak, and the runner logs the arithmetic:

```
[live-auto] eviction sizing: buffer evicts at (readHead - 64 MiB), read head advances
[live-auto]   at playback rate 641791 B/s. Need read head past 2 x 64 MiB
[live-auto]   = 134217728 B, so soak = 134217728 / 641791 = 209s (fixture is 420s of media).
```

Point 4 now carries proof rather than prediction: 16 advertised ids probed, all `HTTP 404`.

**Pacing is the hard constraint, and the window is narrow.** One knob controls two
opposed requirements, so it cannot simply be turned up:

- Too FAST and the producer runs ahead into the buffer's park ceiling. Parking blocks
  inside the SOURCE READ, so the app's own detector fails the remux. Measured at 4x:
  `live source read stalled 48.2s (rc=-5, produced=125901614B)` then
  `hls 404 /media.m3u8 (remux failed)` and a demotion, ~95 s in. At 125% it still parked,
  later: the playlist froze at `segs=70` for 40 s while AVPlayer polled, then
  `mid-play AVPlayer endFileError (Playback Stopped) -> demote to libmpv in place`.
- Too SLOW and the startup cohort takes long enough that AVPlayer abandons the mount
  before becoming ready. Measured at 113%: the gate opened 5.3 s after mount and
  AVPlayer issued no further request after receiving the playlist.

The runner derives the rate from `windowFloorMiB` and the soak and logs the arithmetic,
but treat that as a starting point rather than a proof: the read head lags playback by
more than the simple model assumes. Both failure modes are now detected explicitly and
reported as INFRA naming the harness as the cause, instead of surfacing as a mystery.

**Eviction is confirmed, not assumed.** After the soak the runner polls `GET /seg0.m4s`
until it returns a real non-200, the positive control that point 4's active strand has
something to find. A timer alone is not enough: three consecutive runs evicted 19
segments by probe time while a run immediately after `simctl install` had evicted
nothing, leaving point 4 on the latent prediction. If eviction cannot be confirmed in the
bounded wait, the runner says so and the NOTE marks the verdict as prediction-only.

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

`live-auto` streams for the derived `--soak` period after `readyToPlay` before probing,
because at the instant of readiness the EVENT playlist holds only the two segments the
beta's gate opened on. It keeps the captured session log at
`/tmp/dd-harness/last-session.log` so the same run can be re-read with `trace`.

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

## KNOWN OPEN RISKS (read before trusting a run)

Written down rather than hoped away. Each is DETECTED and correctly classified as INFRA
(exit 3), so none can be misread as a player regression, but none is fully understood.

**1. The post-install path is flaky: measured 1 pass in 3.** Three consecutive runs, each
preceded by a fresh `xcrun simctl install`, gave exit 3, exit 3, exit 1. The two failures
were identical: the app's HLS server became unreachable ~55 s into the eviction
confirmation, with `app process alive: YES` and `fixture server alive: YES`, so the app
process was up but the playback session had ended. The consistent 55 s timing points to a
deterministic cause rather than noise, most likely the same producer-park class as the
pacing constraint above. **Do not treat a single green post-install run as proof.** The
warm path (no reinstall) ran three consecutive times with byte-identical verdicts.

**2. "Session became unreachable" cannot yet be attributed.** The runner names the harness
as the cause wherever it can (source-read stall, fixture-server death, supersession), but
this case is reported honestly as unattributed rather than blamed on the player.

**3. Fixture-server liveness reporting was wrong until recently, so older run logs lie.**
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
- `FMP4.swift` - `moof/traf/tfhd/trun` walk to decide if a segment's first sample is a sync (IDR) frame.
- `Trace.swift` - slices one plain-remux session from a request log and evaluates points 1,3,4,6,7.
- `Live.swift` - loopback fetch + segment/IDR + availability probe + spool measure. Point 4 there ORs two strands: an active probe aimed at the ids the window arithmetic says are already evicted, and that arithmetic itself (shared with `Trace` via `Trace.availabilityWindow`, so the two channels can never disagree on the numbers).
- `main.swift` - CLI + oracle self-test (boundary cases 5×4.000 closed, 6×3.000 open, 15×1.000 open, 14.999 closed, 15.000 open).
- `run-conformance.sh` - builds the harness at `/tmp/dd-harness` and drives the modes, including the unattended `live-auto`.
- `range-server.py` - range-capable (206), rate-paced, non-loopback single-file server for the `live-auto` fixture.
- `DEBUG-PLAYBACK-HOOK.md` - the app-side contract for the headless playback trigger `live-auto` drives.
