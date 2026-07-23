# Player HLS conformance harness

This standalone Swift harness checks the runtime HLS contract shared by the
plain-remux and Dolby Vision lanes. It compiles the production
`DVPlaybackPolicy.swift`, fetches the running loopback server, parses its durable
request trace, and measures the complete `Library/Caches/VortXHLS` root.

It does not treat source-text matches, byte-window estimates, or harness-created
requests as product evidence.

## Contract

| Point | Required runtime behavior | Evidence |
|---|---|---|
| 1 | Frozen target is 12 seconds. A non-ended startup publishes at least 6 closed segments and at least 36,000 rendered-media milliseconds. A completed short source is exempt. | Production policy selftest, first response trace, live playlist bytes |
| 2 | Every advertised video segment starts with MP4 sync metadata and an IDR NAL. | Complete init and segment responses |
| 3 | The first video and alternate-audio requests both use absolute segment id 0. | Product-only request trace |
| 4 | `seq` is the first absolute id, `segs` is cardinality, and the advertised range is `[seq, seq + segs)`. Every master, variant, map, video, and audio URI in the current publication returns a complete 200. Resources from the captured startup publication remain fetchable after the window slides. Sliding playlists never declare EVENT. | Immutable startup capture, trace, and complete loopback responses |
| 5 | The complete `Library/Caches/VortXHLS` root stays at or below 536,870,912 bytes, with exactly one active launch and one active session. Teardown reaches zero bytes and zero active sessions. | Production spool-only contract plus deterministic container-root discovery |
| 6 | The independent mount-to-ready wall deadline is 30,000 ms. Readiness must win strictly before the deadline. | Trace timestamps and production deadline behavior |
| 7 | A starved startup produces exactly one current-format `hls_startup_cohort_timeout`, then a complete, bounded HTTP 404 for `/master.m3u8`, and never reaches ready. A successful startup produces no timeout event. | Dedicated point-7 trace plus harness HTTP completion receipt |

The duration floor and wall deadline are separate. Delivering 36 seconds of
media does not extend or reset the 30-second wall clock.

## Deterministic gates

From the repository root:

```sh
bash test/player-conformance/run-conformance.sh selftest
bash test/player-conformance/run-conformance.sh fixture-assert
bash test/player-conformance/run-conformance.sh media-fixture
bash test/player-conformance/run-conformance.sh mutants
bash test/player-conformance/run-conformance.sh production-contract
VORTX_SIM_UDID=YOUR_TVOS_SIMULATOR_UDID \
  bash test/player-conformance/run-conformance.sh app-build
```

`selftest` compiles the harness, executes the exact boundary cases, and runs the
dedicated fixture assertions. The boundary matrix includes:

- 5 segments above 36,000 ms remains closed.
- 6 segments at 35,999 ms remains closed.
- 6 segments at exactly 36,000 ms opens.
- A completed short source is exempt.
- Target duration is 12.
- A sliding `seq=8, segs=6` body means `[8,14)`, emits matching URI ids, omits
  the zero-only start hint, and never declares EVENT.
- `audio0-seg8.m4s` is accepted while old aliases are rejected.
- Point 7 rejects a media-segment 404, a duplicate event, missing fields, and a
  timeout path that reaches ready. A server log line without the completed HTTP
  receipt is insufficient.
- Production spool admission accepts 536,870,912 bytes, rejects one byte more
  before creating a file, and never evicts protected media to admit a write.
- Multiple active launch or session directories, noncanonical UUID names, and
  the zero UUID are rejected.

`fixture-assert` intentionally checks only facts present in the two committed
traces. It does not pretend that a trace contains fMP4 bytes or filesystem state.
The normal fixture proves current response grammar, absolute-zero startup,
nonzero sliding, exact alternate-audio requests, the success-path event count,
and the wall SLO. The timeout fixture proves only the full point-7 tuple.

`media-fixture` validates all 420 seconds, exactly one H.264 1280x720 yuv420p
video at 24 fps, exactly two 48 kHz stereo AAC tracks with the expected language
and default topology, no extra streams, and all 70 six-second keyframes.

`mutants` must exit successfully only after all eleven load-bearing fMP4 and startup
mutations turn the selftest red. `production-contract` compiles the real spool
implementation, runs its selected assertions, then compiles a temporary 511 MiB
source mutant and requires the exact production-cap assertion to fail. `app-build`
builds and installs Debug, builds Release for the active arm64 simulator, and
scans the Release executable to prove the DEBUG hook strings are absent.

## Trace commands

```sh
# All trace-observable points. Non-observable points remain INDETERMINATE.
/tmp/dd-harness/bin/player-conformance trace path/to/diagnostics.log

# Strict timeout-path oracle used by live-auto --starve.
/tmp/dd-harness/bin/player-conformance trace path/to/diagnostics.log --only-point7
```

The parser consumes the production shapes:

```text
hls resp /media.m3u8 seq=8 segs=6 ended=false ...
hls resp /audio0.m3u8 seq=8 segs=6
hls req /audio0-seg8.m4s
hls_startup_cohort_timeout waitedMs=30000 requiredCount=6 requiredDurationMs=36000 actualCount=... actualDuration=...
hls 404 /master.m3u8
```

A segment 404 is attributed to point 4 when its id was inside any observed
advertised range for that same video or audio playlist. Any unrelated 404 cannot
satisfy point 7.

## Live gate

With one plain-remux session already playing in the booted simulator:

```sh
bash test/player-conformance/run-conformance.sh live
```

The runner resolves the app data container once. The binary derives both
`Library/Caches/diagnostics.log` and `Library/Caches/VortXHLS` from that same
container, requires exactly one trace session, fetches the master and both media
playlists, and requests every URI they advertise.

Infrastructure and product failures are intentionally distinct:

- Missing tools, an unavailable simulator, or failure to inspect the authoritative
  spool exits 3 as INFRA.
- After the DEBUG hook accepts and mounts the source, a timeout, truncated body,
  no-ready outcome, demotion, or stalled window is a product failure and exits 1.
- A complete non-200 response for an advertised URI is a product failure and
  exits 1.
- A complete 200 whose fMP4 bytes fail the IDR oracle is a product failure.

The root inspection sorts directory names, rejects unexpected entries and
symlinks, totals every regular file below the entire root with overflow checks,
and does not accept a caller-selected session subtree.

## Unattended live flow

```sh
VORTX_SIM_UDID=YOUR_TVOS_SIMULATOR_UDID \
  bash test/player-conformance/run-conformance.sh live-auto
VORTX_SIM_UDID=YOUR_TVOS_SIMULATOR_UDID \
  bash test/player-conformance/run-conformance.sh live-auto --starve
```

The normal flow:

1. Generates or validates a Matroska source with H.264 video, one default
   English AAC primary, and one Spanish AAC alternate.
2. Validates the complete cached or new source with the exact video, audio,
   duration, no-extra-stream, and full keyframe-cadence contract above.
3. Serves the file from a non-loopback address with byte-range support.
4. Launches the DEBUG playback hook with a per-run UUID and proves one ordered
   accept, matching real route token, HLS server, and plain-remux mount generation.
5. Captures one coherent immutable sequence-zero publication before readiness,
   including all variants and alternate audio, at the shortest common prefix
   that contains at least six segments and 36,000 rendered milliseconds.
6. Reads the real advertised variant URI, validates the exact contiguous range,
   fetches every segment, and stops only after a valid nonzero sequence appears.
7. Re-fetches every map and segment from the retained startup publication, then
   runs the live battery against that capture and the current server generation.
8. Terminates the app and polls until the whole HLS root has zero bytes and zero
   active sessions.

The synthetic reader uses only URIs from the successfully fetched manifest. Its
traffic begins after the product-only trace boundary and therefore cannot create
trace evidence for points 3, 4, or 7.

The starve flow changes only delivery pace. After the same provenance proof, it
performs one bounded `/master.m3u8` request and records the actual curl status,
body length, and return code. It then invokes `trace --only-point7`. Exit 0 means
the complete point-7 tuple was proven. Failures in unrelated points cannot make
starve exit 0 or prevent this dedicated verdict.

## Exit codes

- `0`: requested deterministic gate or product contract passed.
- `1`: the gate ran and found a product or oracle failure.
- `2`: invalid usage or an unreadable input.
- `3`: infrastructure prevented a trustworthy live observation.

## Files

- `Contract.swift`: the numeric acceptance contract and seven point labels.
- `HLSWindow.swift`: minimal value-type mirror needed to compile production
  `DVPlaybackPolicy.swift` in isolation.
- `Playlist.swift`: exact EXTINF, absolute-id, range, and URI parser.
- `Trace.swift`: current production log parser and point-7 tuple oracle.
- `Live.swift`: complete loopback and whole-root filesystem evaluation.
- `FMP4.swift`, `FMP4Fixtures.swift`, and the base64 fixtures: fail-closed IDR
  oracle and mutation inputs.
- `main.swift`: CLI, boundary tests, and dedicated fixture assertions.
- `run-conformance.sh`: deterministic build and simulator driver.

## Scope boundary

This harness is a pre-cut build, protocol, and runtime gate. Beta field proof on
real devices, including VoiceOver behavior, remains explicitly unproven and is a
post-cut activity. It is not a prerequisite for these deterministic gates and
this harness does not claim to substitute for it.
