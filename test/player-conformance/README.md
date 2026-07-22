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
# then play a plain (non-DV) .mkv on the booted Apple TV 4K sim so it routes to the
# AVFoundation plain-remux HLS lane (log shows: "route ... isDV=false ... -> engine=avfoundation"),
# and while it is PLAYING:
./run-conformance.sh live --spool <caches-spool-dir>   # full 7-point battery + segment/IDR + availability probe
```

Everything builds under the stable derived-data path `/tmp/dd-harness` (never a
per-run path). `./run-conformance.sh app-build` rebuilds `VortXTV` into that same
path if you need to regenerate a trace from a fresh binary. The gate exits `0` only
when **every** point is GREEN/EXEMPT; against beta it exits non-zero. Subcommands
also run directly: `/tmp/dd-harness/bin/player-conformance {selftest|trace <log>|live --container <dir>|spool <dir>}`.

## What each point needs, and current beta status

| # | Point | Channel | Beta now |
|---|-------|---------|----------|
| 1 | Startup cohort ≥6 segs AND ≥15000 ms (integer-ms from EXTINF text) | trace + live | **RED** - first `/media.m3u8` served at `segs=2`, ~8000 ms |
| 2 | Every published segment starts on an IDR frame | live (fMP4 parse) | trace flags the hazard (segments hard-cut at exactly 4.0 s); live-confirmed |
| 3 | First video seg id == 0 AND first alt-audio seg id == 0 | trace + live | **RED** - video half is 0; no alternate-audio rendition exists (audio muxed) |
| 4 | No advertised-segment 404 through the RFC 8216 §6.2.2 window | trace (latent) + live (active probe) | **RED** - EVENT playlist advertises ~75 while ~55 are resident; seg 0..19 evicted-but-advertised |
| 5 | Spool bounded (Caches, session-global) + reclaimed to zero after session | live (filesystem) | needs a live session + the rework's spool dir |
| 6 | Startup latency: mount → readyToPlay ≤ 30000 ms | trace | **GREEN** - 1177 ms in the overnight run |
| 7 | Fail-soft counted: exactly one `hls_startup_cohort_timeout` + 404 on timeout, none otherwise | trace | **PENDING** - event absent in beta; success-path invariant (zero events) holds |

## Not observable on this simulator (stated plainly)

- **A fresh live plain-remux session cannot be stood up by `xcrun simctl` alone.**
  The tvOS app has no play-a-URL deep link (`DeepLinkRouter` only opens a detail
  page), so points 2, the point-4 active probe, and point 5 require a human to start
  a plain MKV playing (as the overnight run did); the harness then decides them from
  the live server. The `--spool` directory is whatever Caches path the rework names.
- **Point 7's positive path** (exactly one timeout event, then a 404 into the libmpv
  demotion) needs a source that never fills the cohort in time. The harness asserts
  the success-path invariant (zero events on a start that reaches readyToPlay) now;
  proving the counted-timeout needs a slow/short source fixture.
- **Physical Dolby Vision display-mode switching** is hardware-only - the sim logs
  "display switch skipped: the simulator has no HDMI display modes" - and is out of
  this harness's scope regardless (it is a plain-remux gate).

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
- `Live.swift` - loopback fetch + segment/IDR + availability probe + spool measure.
- `main.swift` - CLI + oracle self-test (boundary cases 5×4.000 closed, 6×3.000 open, 15×1.000 open, 14.999 closed, 15.000 open).
- `run-conformance.sh` - builds the harness at `/tmp/dd-harness` and drives the modes.
