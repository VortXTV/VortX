#!/usr/bin/env bash
# =============================================================================
# run-conformance.sh - build + drive the player-rework acceptance harness.
#
# The harness verifies the local HLS server's RUNTIME behaviour against the
# REQ-260722-09 + REQ-260722-04 contract (7 points). It reads the server's own
# request log (Caches/diagnostics.log) the way the overnight run did, and - while
# a plain-remux MKV is playing - fetches playlists + segments over the simulator's
# shared loopback. It NEVER asserts on player source text.
#
# Modes:
#   ./run-conformance.sh selftest         Validate the oracle only (no sim needed).
#   ./run-conformance.sh mutants          Prove every load-bearing fMP4 oracle
#                                          protection turns the selftest RED when
#                                          removed one at a time.
#   ./run-conformance.sh trace [logfile]  Evaluate points 1,3,4,6,7 from a captured
#                                          trace. Defaults to the booted sim's live
#                                          container log.
#   ./run-conformance.sh live [--spool D] Full 7-point battery; needs a plain-remux
#                                          playback LIVE on the sim (manual flow).
#   ./run-conformance.sh live-auto [...]  UNATTENDED full battery: generate a fixture
#                                          MKV, serve it range-capably from the Mac's
#                                          LAN address, start playback headlessly via
#                                          the DEBUG playback hook, wait for real
#                                          readiness, run `live`, tear down.
#   ./run-conformance.sh live-auto --starve
#                                          Same flow at a deliberately STARVING pace,
#                                          to exercise point 7's positive path (the
#                                          counted cohort-timeout fail-soft). Success
#                                          in this mode is the fail-soft FIRING, so a
#                                          libmpv demotion is the EXPECTED outcome and
#                                          is NOT the INFRA condition it is elsewhere.
#   ./run-conformance.sh live-auto --no-reader
#                                          Historical AVPlayer-only read-head control.
#   ./run-conformance.sh live-auto --rotation-control
#                                          Force a real diagnostics.log rollover after
#                                          the immutable product-only snapshot.
#   ./run-conformance.sh all              build + selftest + trace (default).
#   ./run-conformance.sh app-build        (Re)build VortXTV into /tmp/dd-harness so
#                                          a fresh trace can be generated.
#
# EXIT CODES (live / live-auto):
#   0  the gate ran and every point is GREEN/EXEMPT.
#   1  the gate ran and at least one point is RED. This is the PRODUCT signal.
#   3  INFRA: no probeable playback session could be stood up (sim not booted, app
#      not installed, fixture server unreachable, debug hook rejected the URL,
#      silent libmpv demotion, or no readiness marker before the timeout). CI must
#      never read a 3 as a player regression.
#   2  bad usage.
#
# Everything builds under the STABLE derived-data path /tmp/dd-harness - never a
# random per-run path - so incremental rebuilds are cheap and reproducible. The
# generated fixture MKV lives beside it, under /tmp/dd-harness/fixtures, and is
# NEVER committed (media binaries do not belong in the repo).
# =============================================================================
set -euo pipefail

UDID="${VORTX_SIM_UDID:-67640D6F-C574-4511-94C8-8AAE4CFF299D}"   # Apple TV 4K (3rd generation)
BUNDLE_ID="${VORTX_BUNDLE_ID:-com.stremiox.tv}"
SCHEME="${VORTX_SCHEME:-VortXTV}"
DD="/tmp/dd-harness"
BIN="$DD/bin/player-conformance"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
POLICY="$REPO/app/Sources/Player/DVPlaybackPolicy.swift"

# --- live-auto fixture parameters -------------------------------------------
#
# GOP: 6.000 s, deliberately LONGER than the 4 s hard cut.
#   Contract point 2 is "every published segment starts on an IDR frame". The
#   segmenter's whole cut rule is one predicate
#   (VortXMKVRemuxStream.swift:2030-2032):
#
#       (isKey && elapsed >= 1.0) || elapsed >= 4.0 || openBytes >= 32 MiB
#
#   i.e. cut at the first KEYFRAME past 1 s, else HARD-cut at 4 s on whatever
#   frame is current - no isKey guard on the hard cut. That is the hazard recorded
#   as MIS-260722-07, and only the hard cut can produce a non-IDR segment start.
#   So the fixture's keyframe interval must be > 4 s. With ANY GOP of 4 s or less
#   the "first keyframe past 1 s" branch always fires first, every cut is
#   keyframe-aligned, and point 2 scores a FALSE GREEN with the defect untouched.
#   (Measured: a 3 s GOP produced segments of 2.92 s / 3.00 s and zero hard cuts.)
#   At GOP 6 s the cuts are exactly periodic and half of them are mid-GOP:
#     seg0  0.0 -> 4.0  hard cut at 4 s        (starts on the t=0 keyframe: IDR)
#     seg1  4.0 -> 6.0  keyframe cut, elapsed 2.0 s  (STARTS MID-GOP: non-IDR)
#     seg2  6.0 -> 10.0 hard cut                (starts on the t=6 keyframe: IDR)
#     seg3 10.0 -> 12.0 keyframe cut            (STARTS MID-GOP: non-IDR)
#   6 s also leaves the post-cut remainder at 2.0 s, comfortably clear of the 1 s
#   target floor, so the following keyframe cut is unambiguous rather than a
#   floating-point coin toss (a 5 s GOP lands that remainder on exactly 1.000 s).
# Duration: long enough that the session GENUINELY EVICTS (see EVICTION_MARGIN
#   below). A first attempt at 150 s / ~92 MiB was too small and produced a
#   misleading point 4: the active probe fetched all 15 predicted-evicted ids and
#   got HTTP 200 on every one, because nothing had been evicted at all. The buffer
#   evicts at `keepFrom = readHead - windowFloorBytes`
#   (VortXRemuxBuffer.swift:274), and its resident ceiling once the engine is ready
#   is `windowFloorBytes + producerLeadFull` = 64 + 64 = 128 MiB
#   (VortXRemuxBuffer.swift:80-81, :101). A 92 MiB fixture never reaches that
#   ceiling and its read head barely reaches the 64 MiB floor, so seg0 can never
#   go. A fixture that cannot make a point FAIL is not testing that point.
# Audio: a real AAC track is muxed in. Point 3 needs a first alternate-audio
#   segment id, so a video-only fixture could not decide it.
# Extension: must be .mkv - the hook rejects anything without matroska evidence.
FIXTURE_DIR="${VORTX_FIXTURE_DIR:-$DD/fixtures}"
FIXTURE_SECS="${VORTX_FIXTURE_SECS:-420}"
FIXTURE_GOP_SECS=6
FIXTURE_FPS=24
FIXTURE_VBITRATE=5000k
FIXTURE_SIZE=1280x720
FIXTURE_NAME="conformance-gop${FIXTURE_GOP_SECS}s-${FIXTURE_SECS}s.mkv"
FIXTURE="$FIXTURE_DIR/$FIXTURE_NAME"
READY_TIMEOUT="${VORTX_READY_TIMEOUT:-90}"

# --- contract constants, READ FROM Contract.swift rather than restated here ------
# The harness encodes the contract exactly once. Re-typing any of these numbers into
# the runner would be a second source of truth that can silently drift from the gate.
contract_int() {   # $1 = constant name in Contract.swift
  sed -n "s/.*static let $1 = \([0-9_]*\).*/\1/p" "$HERE/Contract.swift" | head -1 | tr -d '_'
}
contract_str() {   # $1 = string constant name in Contract.swift
  sed -n "s/.*static let $1 = \"\([^\"]*\)\".*/\1/p" "$HERE/Contract.swift" | head -1
}
WINDOW_FLOOR_MIB="$(contract_int windowFloorMiB)"        # 64: VortXRemuxBuffer re-read floor
MIN_STARTUP_MS="$(contract_int minStartupMs)"            # 15000: point 1 duration floor
MIN_STARTUP_SEGS="$(contract_int minStartupSegments)"    # 6: point 1 segment floor
SLO_MOUNT_READY_MS="$(contract_int sloMountToReadyMs)"   # 30000: point 6 SLO

# How far past the window floor the READ HEAD must travel before we trust point 4.
# The buffer evicts at `readHead - windowFloorBytes`, so seg0 survives until the read
# head passes windowFloorBytes. The derivation uses playback rate as a conservative
# timing budget; the default explicit reader may advance faster. A 100% margin would
# put the run exactly on that knife edge, which is how the earlier
# 92 MiB fixture produced 15 predicted-evicted ids that all still returned 200. The
# timing budget is DERIVED from this and the fixture's own bitrate, never hardcoded.
EVICTION_MARGIN_PERCENT="${VORTX_EVICTION_MARGIN_PERCENT:-120}"
# Explicit --soak wins. In the default mode this is the reader deadline base; in the
# historical --no-reader control it remains a literal idle soak.
SOAK_SECS="${VORTX_SOAK_SECS:-}"
# Delivery pacing, as a PERCENT of the fixture's own average bitrate.
#
# Two opposing constraints, and the window between them is narrower than it looks:
#
#  LOWER BOUND (point 1): an unpaced LAN server delivers the whole fixture before
#    AVPlayer's first /media.m3u8 request, so the session becomes an instant ENDLIST
#    VOD and the startup gate point 1 measures is never exercised. Anything at or
#    above ~1x already loses that race, because the gate needs 2 closed segments
#    (~6 s of media) while AVPlayer asks at ~0.3 s.
#  UPPER BOUND (session survival): without an active reader, the producer parks in
#    `VortXRemuxBuffer.append`
#    once resident bytes reach `windowFloorBytes + producerLead`. Parking blocks
#    inside the SOURCE READ path, so the app's own stall detector sees no source
#    progress and FAILS the remux. Measured at 4x: "live source read stalled 48.2s
#    (rc=-5, produced=125901614B)" then "hls 404 /media.m3u8 (remux failed)" and a
#    demotion, roughly 95 s in, killing the session before the probe.
#
# `safe_rate_percent` retains that historical model as a conservative source-rate
# ceiling. The default explicit reader, not the estimate, now guarantees read-head
# progress after readiness.
FIXTURE_RATE_PERCENT="${VORTX_FIXTURE_RATE_PERCENT:-150}"
# Historical no-reader pacing model. A safety of 2 (delivery clamped to 125%) still
# parked the producer because AVPlayer stopped consuming non-IDR media; no finite
# model based on playback time can repair a read head that has stopped. The default
# synthetic reader now advances the read head explicitly. Keep this calculation for
# the --no-reader diagnostic control and for conservative pre-readiness pacing, but
# do not treat it as proof that AVPlayer will continue consuming.
PARK_SAFETY="${VORTX_PARK_SAFETY:-1}"
# Extra bounded wait used only by the historical --no-reader diagnostic control.
EVICTION_CONFIRM_SECS="${VORTX_EVICTION_CONFIRM_SECS:-120}"

# Normal live-auto runs use an EXPLICIT synthetic HLS reader after the product-only
# observation boundary. Point 2 deliberately feeds AVPlayer non-IDR segment starts;
# the current product can stop requesting media on that defect while continuing to
# poll the EVENT playlist. If the harness then waits for AVPlayer to advance the one
# global buffer read head, the producer reaches its expected 128 MiB back-pressure
# ceiling, the playlist stops changing, and AVPlayer eventually reports "Playback
# Stopped" and demotes. That destroys the HLS server before point 4 can observe it.
# The synthetic reader consumes only manifest-advertised segments, in exact id order,
# for a bounded window. It reports the stale-advertisement defect when two complete
# 404/410 responses prove it, but a conforming served or playlist-removed segment also
# proceeds to the same acceptance battery. Every request is counted in a sidecar and
# excluded from trace/verdict evidence by a byte boundary recorded BEFORE it starts.
# `--no-reader` retains the historical defect-reproduction control.
SYNTHETIC_READER=1
# Explicit reliability control: after snapshotting the product-only trace, drive
# diagnostics.log through a real app-side rollover and prove the saved trace stays
# nonempty and byte-identical. Off during ordinary runs; enable with
# `live-auto --rotation-control`.
ROTATION_CONTROL=0

# --- starve mode (point 7's positive path) ----------------------------------
# Contract point 7 wants EXACTLY ONE `hls_startup_cohort_timeout` plus a 404 into the
# libmpv demotion when the startup cohort cannot fill in time, and zero events
# otherwise. The success-path half is provable on any normal run; the counted-timeout
# half needs a source that CANNOT fill the cohort. The pacing knob is exactly that,
# so it is a parameter rather than a second fixture: pace so that the contract's own
# cohort duration floor takes far longer to deliver than any startup deadline.
#
#   starve rate = mediaBytesPerSec * minStartupMs / (STARVE_FACTOR * sloMountToReadyMs)
#
# i.e. deliver `minStartupMs` of media over `STARVE_FACTOR` times the point 6 SLO.
# Both numerator constants come from Contract.swift; nothing here is a chosen number
# except the safety factor itself.
STARVE_FACTOR="${VORTX_STARVE_FACTOR:-4}"
STARVE_TIMEOUT="${VORTX_STARVE_TIMEOUT:-180}"

build_harness() {
  mkdir -p "$DD/bin"
  echo "[build] swiftc -> $BIN"
  swiftc -O -o "$BIN" \
    "$HERE/Contract.swift" "$HERE/HLSWindow.swift" "$HERE/Playlist.swift" "$HERE/FMP4.swift" "$HERE/FMP4Fixtures.swift" \
    "$HERE/Trace.swift" "$HERE/Live.swift" "$HERE/main.swift" "$POLICY"
}

run_mutants() {
  local mutants=(
    wrong-track
    nil-unmatched-track
    unknown-tkhd-version
    sync-flag-only
    nal-only
    audio-first-order
    video-first-order
    hevc-idr-layer-zero
    short-tkhd-payload
  )
  local mutant rc failed=0
  for mutant in "${mutants[@]}"; do
    echo ""
    echo "[mutant] $mutant: selftest MUST turn RED"
    set +e
    "$BIN" selftest --mutant "$mutant"
    rc=$?
    set -e
    if [ "$rc" = "1" ]; then
      echo "[mutant] PASS: $mutant was killed (selftest exit 1)"
    else
      echo "[mutant] FAIL: $mutant escaped (selftest exit $rc; expected 1)"
      failed=1
    fi
  done
  echo ""
  echo "[mutant] retirement-defect-required: conforming controls MUST turn RED"
  set +e
  retirement_acceptance_regressions 1
  rc=$?
  set -e
  if [ "$rc" = "1" ]; then
    echo "[mutant] PASS: retirement-defect-required was killed (control exit 1)"
  else
    echo "[mutant] FAIL: retirement-defect-required escaped (control exit $rc; expected 1)"
    failed=1
  fi
  [ "$failed" = "0" ] || return 1
  echo ""
  echo "[mutant] ALL 10 LOAD-BEARING MUTANTS KILLED"
}

# Curl can produce an HTTP status before discovering that the advertised body was
# truncated. HTTP status and transfer completion are therefore independent facts.
# These helpers preserve both, discard partial bodies, and never let a status from a
# nonzero transfer become evidence. Callers record CURL_RC and CURL_STATUS together.
CURL_RC=0
CURL_STATUS=000
curl_capture_complete() {   # $1 = destination, $2 = timeout seconds, $3 = URL
  local destination="$1" timeout="$2" url="$3" partial="${1}.partial.$$" status rc
  rm -f "$partial" "$destination"
  set +e
  status="$(curl -sS -o "$partial" -w '%{http_code}' --max-time "$timeout" "$url" 2>/dev/null)"
  rc=$?
  set -e
  CURL_RC="$rc"
  CURL_STATUS="${status:-000}"
  if [ "$CURL_RC" = "0" ]; then
    mv "$partial" "$destination"
  else
    rm -f "$partial" "$destination"
  fi
}

curl_probe_complete() {   # $1 = timeout seconds, $2 = URL
  local timeout="$1" url="$2" status rc
  set +e
  status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$timeout" "$url" 2>/dev/null)"
  rc=$?
  set -e
  CURL_RC="$rc"
  CURL_STATUS="${status:-000}"
}

curl_transport_regressions() {
  local root portfile server_log server_pid waited=0 port url failed=0
  local destination next_id retired_streak failures
  root="$(mktemp -d /tmp/player-curl-regressions.XXXXXX)"
  portfile="$root/port"
  server_log="$root/server.log"
  python3 - "$portfile" >"$server_log" 2>&1 <<'PY' &
import http.server
import socketserver
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        status = 200
        if "retire-410" in self.path:
            status = 410
        elif "retire" in self.path or "rotation" in self.path:
            status = 404
        body = b"short"
        self.send_response(status)
        self.send_header("Content-Length", str(len(body) + 40))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    with open(sys.argv[1], "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
        handle.flush()
    server.serve_forever()
PY
  server_pid=$!
  while [ ! -s "$portfile" ] && [ "$waited" -lt 50 ]; do
    sleep 0.02
    waited=$((waited + 1))
  done
  if [ ! -s "$portfile" ]; then
    echo "[curl-selftest] FAIL: truncated-response server did not start" >&2
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    rm -rf "$root"
    return 1
  fi
  port="$(cat "$portfile")"
  url="http://127.0.0.1:$port"
  destination="$root/media.m3u8"

  curl_capture_complete "$destination" 2 "$url/truncated-manifest"
  if [ "$CURL_RC" = "0" ] || [ "$CURL_STATUS" != "200" ] || [ -e "$destination" ]; then
    echo "[curl-selftest] FAIL: truncated 200 manifest was trusted (rc=$CURL_RC status=$CURL_STATUS)" >&2
    failed=1
  fi

  next_id=7
  curl_probe_complete 2 "$url/truncated-segment"
  if [ "$CURL_RC" = "0" ] && [ "$CURL_STATUS" = "200" ]; then next_id=$((next_id + 1)); fi
  if [ "$next_id" != "7" ]; then
    echo "[curl-selftest] FAIL: truncated 200 segment advanced the reader" >&2
    failed=1
  fi

  retired_streak=1
  curl_probe_complete 2 "$url/truncated-retire"
  if [ "$CURL_RC" = "0" ] && { [ "$CURL_STATUS" = "404" ] || [ "$CURL_STATUS" = "410" ]; }; then
    retired_streak=$((retired_streak + 1))
  else
    retired_streak=0
  fi
  if [ "$retired_streak" != "0" ]; then
    echo "[curl-selftest] FAIL: truncated retirement response advanced the proof streak" >&2
    failed=1
  fi

  failures=0
  for _ in 1 2 3; do
    curl_probe_complete 2 "$url/truncated-retire-410"
    if [ "$CURL_RC" != "0" ]; then failures=$((failures + 1)); fi
  done
  if [ "$failures" != "3" ]; then
    echo "[curl-selftest] FAIL: repeated truncated retirement responses were not transport failures" >&2
    failed=1
  fi

  curl_probe_complete 2 "$url/truncated-rotation"
  if [ "$CURL_RC" = "0" ] || [ "$CURL_STATUS" != "404" ]; then
    echo "[curl-selftest] FAIL: truncated rotation response did not preserve rc plus HTTP status" >&2
    failed=1
  fi

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  rm -rf "$root"
  [ "$failed" = "0" ] || return 1
  echo "[curl-selftest] PASS: truncated 200 manifest, 200 segment, 404/410 retirement, and rotation responses stayed transport failures"
}

# Pure decision seam for the optional stale-retirement observation. The acceptance
# battery must run on both conforming shapes: an advertised segment may remain served,
# or it may be removed from the playlist before retirement. Only a prior complete 200
# followed by two complete 404/410 responses while the id remains advertised proves
# the beta defect. `mutant=1` deliberately restores the old defect-required behavior.
RETIREMENT_NEXT_STREAK=0
RETIREMENT_DECISION=continue
retirement_observation_step() { # prior200 advertised curl_rc http streak window_complete [mutant]
  local prior200="$1" advertised="$2" curl_rc="$3" http="$4" streak="$5"
  local window_complete="$6" mutant="${7:-0}"
  RETIREMENT_NEXT_STREAK=0
  RETIREMENT_DECISION=continue

  if [ "$advertised" != "1" ]; then
    RETIREMENT_DECISION=proceed-removed
  elif [ "$curl_rc" = "0" ] && { [ "$http" = "404" ] || [ "$http" = "410" ]; } \
      && [ "$prior200" = "1" ]; then
    RETIREMENT_NEXT_STREAK=$((streak + 1))
    if [ "$RETIREMENT_NEXT_STREAK" -ge 2 ]; then
      RETIREMENT_DECISION=defect-observed
    elif [ "$window_complete" = "1" ]; then
      RETIREMENT_DECISION=proceed-unobserved
    fi
  elif [ "$window_complete" = "1" ]; then
    if [ "$curl_rc" = "0" ] && [ "$http" = "200" ]; then
      RETIREMENT_DECISION=proceed-served
    else
      RETIREMENT_DECISION=proceed-unobserved
    fi
  fi

  if [ "$mutant" = "1" ]; then
    case "$RETIREMENT_DECISION" in
      proceed-*) RETIREMENT_DECISION=infra ;;
    esac
  fi
}

retirement_acceptance_regressions() { # optional $1 = old defect-required mutant
  local mutant="${1:-0}" failed=0 first_streak

  retirement_observation_step 1 1 0 200 0 1 "$mutant"
  if [ "$RETIREMENT_DECISION" = "proceed-served" ]; then
    echo "[retirement-selftest] PASS: fully served advertised segment proceeds to the battery"
  else
    echo "[retirement-selftest] FAIL: fully served behavior produced '$RETIREMENT_DECISION'" >&2
    failed=1
  fi

  retirement_observation_step 1 0 0 000 0 0 "$mutant"
  if [ "$RETIREMENT_DECISION" = "proceed-removed" ]; then
    echo "[retirement-selftest] PASS: playlist removal proceeds without probing an unadvertised id"
  else
    echo "[retirement-selftest] FAIL: removed-segment behavior produced '$RETIREMENT_DECISION'" >&2
    failed=1
  fi

  retirement_observation_step 1 1 0 404 0 0 "$mutant"
  first_streak="$RETIREMENT_NEXT_STREAK"
  retirement_observation_step 1 1 0 404 "$first_streak" 0 "$mutant"
  if [ "$RETIREMENT_DECISION" = "defect-observed" ] && [ "$RETIREMENT_NEXT_STREAK" = "2" ]; then
    echo "[retirement-selftest] PASS: two complete advertised-id 404s report the stale-retirement defect"
  else
    echo "[retirement-selftest] FAIL: stale-retirement proof produced '$RETIREMENT_DECISION'/$RETIREMENT_NEXT_STREAK" >&2
    failed=1
  fi

  retirement_observation_step 1 1 18 404 1 0 "$mutant"
  if [ "$RETIREMENT_DECISION" = "continue" ] && [ "$RETIREMENT_NEXT_STREAK" = "0" ]; then
    echo "[retirement-selftest] PASS: truncated 404 resets proof and never reports the defect"
  else
    echo "[retirement-selftest] FAIL: truncated 404 produced '$RETIREMENT_DECISION'/$RETIREMENT_NEXT_STREAK" >&2
    failed=1
  fi

  [ "$failed" = "0" ] || return 1
}

container_log() {
  local c
  c="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)" || {
    echo "cannot locate app container for $BUNDLE_ID on $UDID (is it installed?)" >&2; return 1; }
  echo "$c/Library/Caches/diagnostics.log"
}

app_build() {
  # Regenerate the Xcode project (XcodeGen) then build VortXTV for the tvOS sim
  # into the STABLE derived-data path. Needs the engine xcframeworks already
  # present under app/Vendor (build-core / build-ffi scripts), as for any app build.
  command -v xcodegen >/dev/null || { echo "xcodegen not found (brew install xcodegen)" >&2; exit 1; }
  ( cd "$REPO/app" && xcodegen generate )
  xcodebuild -project "$REPO/app/VortX.xcodeproj" -scheme "$SCHEME" \
    -destination "id=$UDID" -derivedDataPath "$DD" \
    -configuration Debug build
  echo "[app-build] installing onto sim"
  xcrun simctl install "$UDID" "$DD/Build/Products/Debug-appletvsimulator/$SCHEME.app"
}

# =============================================================================
# live-auto
# =============================================================================

SERVER_PID=""
FIXTURE_PORT=""
WORK=""
APP_LAUNCHED=0
MODE_STARVE=0

infra() {   # every INFRA exit funnels through here so the marker is unmistakable
  echo "" >&2
  echo "[INFRA] $*" >&2
  echo "[INFRA] exit 3 - could not stand up a probeable playback session." >&2
  echo "[INFRA] This is NOT a player regression; the gate never ran." >&2
  exit 3
}

cleanup() {
  local rc=$?
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ "$APP_LAUNCHED" = "1" ]; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORK" ] && [ -f "$WORK/server.log" ]; then
    cp "$WORK/server.log" "$DD/last-fixture-server.log" 2>/dev/null || true
  fi
  [ -n "$WORK" ] && rm -rf "$WORK"
  exit $rc
}

# Facts the Swift binary cannot see, used to make an INFRA report specific rather than
# a shrug. Simulator apps run as host processes, so pgrep finds them.
app_alive() {
  if pgrep -f "$SCHEME.app/$SCHEME" >/dev/null 2>&1; then echo "YES"; else echo "NO (the app was gone)"; fi
}
server_alive() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then echo "YES"; else echo "NO"; fi
}

preflight() {
  xcrun simctl list devices booted 2>/dev/null | grep -q "$UDID" \
    || infra "simulator $UDID is not booted. Boot it: xcrun simctl boot $UDID"
  xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data >/dev/null 2>&1 \
    || infra "$BUNDLE_ID is not installed on $UDID. Install it: ./run-conformance.sh app-build"
  command -v ffmpeg >/dev/null \
    || infra "ffmpeg not found; live-auto generates its own fixture. Install it: brew install ffmpeg"
  command -v python3 >/dev/null \
    || infra "python3 not found; it runs the range-capable fixture server."
  # Sweep fixture servers leaked by earlier runs. One still streaming at full rate is
  # enough to skew the pacing this harness depends on.
  # NOTE: `pgrep` exits 1 when nothing matches, and this script runs under
  # `set -o pipefail`, so assigning a pgrep pipeline directly aborts the whole run on
  # the (normal) no-strays path. Gate on the `if` instead, which set -e does not trap.
  local stray=0
  if pgrep -f "$HERE/range-server.py" >/dev/null 2>&1; then
    stray="$(pgrep -f "$HERE/range-server.py" 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [ "${stray:-0}" -gt 0 ]; then
    echo "[live-auto] sweeping $stray leaked fixture server(s) from earlier runs"
    pkill -f "$HERE/range-server.py" || true
    sleep 1
  fi
  # The 4th precondition - "the installed Debug build carries the DEBUG playback
  # hook" - cannot be checked cheaply before launch without inspecting the binary.
  # It is checked HONESTLY after launch instead: if no [debughook] marker of any
  # kind appears, the wait reports exactly that. See wait_for_ready.
}

make_fixture() {
  mkdir -p "$FIXTURE_DIR"
  if [ -s "$FIXTURE" ]; then
    echo "[live-auto] fixture cached: $FIXTURE ($(wc -c < "$FIXTURE" | tr -d ' ') B)"
    return 0
  fi
  echo "[live-auto] generating fixture ${FIXTURE_SECS}s, ${FIXTURE_GOP_SECS}s GOP, H.264+AAC -> $FIXTURE"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=$FIXTURE_SIZE:rate=$FIXTURE_FPS:duration=$FIXTURE_SECS" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$FIXTURE_SECS" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v "$FIXTURE_VBITRATE" \
    -g $((FIXTURE_FPS * FIXTURE_GOP_SECS)) -keyint_min $((FIXTURE_FPS * FIXTURE_GOP_SECS)) \
    -sc_threshold 0 -force_key_frames "expr:gte(t,n_forced*$FIXTURE_GOP_SECS)" \
    -c:a aac -b:a 128k -ac 2 \
    -f matroska "$FIXTURE" \
    || infra "ffmpeg failed to generate the fixture"
  [ -s "$FIXTURE" ] || infra "fixture generated empty at $FIXTURE"
  echo "[live-auto] fixture $(wc -c < "$FIXTURE" | tr -d ' ') B; keyframes at $(ffprobe -v error -select_streams v:0 -skip_frame nokey -show_entries frame=pts_time -of csv=p=0 "$FIXTURE" 2>/dev/null | head -4 | tr -d ',' | tr '\n' ' ')s ..."
}

lan_address() {
  local ip
  ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(ipconfig getifaddr en1 2>/dev/null || true)"
  # DHCP-assigned, discovered every run: NEVER hardcode it.
  [ -n "$ip" ] || infra "no LAN address on en0/en1. The fixture MUST be served from a
        NON-loopback address: the router, the engine gate and the remux candidacy all
        veto 127.0.0.1/localhost, so a loopback URL is silently demoted to libmpv and
        the run would test the wrong engine."
  echo "$ip"
}

# Media bytes per second of PLAYBACK for the current fixture. The read head advances
# at roughly this rate, which is what the eviction sizing turns on.
media_byte_rate() {
  local bytes
  bytes="$(wc -c < "$FIXTURE" | tr -d ' ')"
  echo $(( bytes / FIXTURE_SECS ))
}

# Soak long enough for the READ HEAD to travel EVICTION_MARGIN x the window floor, so
# point 4's active probe is aimed at segments that have genuinely been evicted rather
# than at a window that never slid. Derived from Contract.swift's windowFloorMiB and
# the fixture's own bitrate; the derivation is logged so it can be checked.
derive_soak() {
  local rate need soak
  rate="$(media_byte_rate)"
  need=$(( EVICTION_MARGIN_PERCENT * WINDOW_FLOOR_MIB * 1024 * 1024 / 100 ))
  soak=$(( need / rate ))
  [ "$soak" -gt 0 ] || soak=1
  echo "[live-auto] eviction sizing: buffer evicts at (readHead - ${WINDOW_FLOOR_MIB} MiB), read head advances" >&2
  echo "[live-auto]   at playback rate ${rate} B/s. Need read head past ${EVICTION_MARGIN_PERCENT}% of ${WINDOW_FLOOR_MIB} MiB" >&2
  echo "[live-auto]   = ${need} B, so soak = ${need} / ${rate} = ${soak}s (fixture is ${FIXTURE_SECS}s of media)." >&2
  if [ "$soak" -ge $(( FIXTURE_SECS - 30 )) ]; then
    echo "[live-auto]   WARNING: the fixture is too short to soak that long. Point 4's active" >&2
    echo "[live-auto]   strand may probe a window that never evicted. Raise VORTX_FIXTURE_SECS." >&2
  fi
  echo "$soak"
}

# Historical upper-bound estimate for delivery pacing. When a consumer advances the
# read head, the producer's SURPLUS over consumption accumulates in the buffer; once
# it reaches the park ceiling the source read blocks. Requiring
#     windowFloorBytes / surplus  >  soak x PARK_SAFETY
# estimates a rate that keeps the buffer from filling before the battery runs.
# `--no-reader` demonstrates why this estimate is not sufficient when AVPlayer stops
# consuming entirely. The default explicit reader makes progress deterministic.
safe_rate_percent() {
  local rate surplus_max percent
  rate="$(media_byte_rate)"
  surplus_max=$(( WINDOW_FLOOR_MIB * 1024 * 1024 / (SOAK_SECS * PARK_SAFETY) ))
  percent=$(( 100 + surplus_max * 100 / rate ))
  echo "$percent"
}

start_fixture_server() {
  local portfile="$WORK/port" bytes rate
  bytes="$(wc -c < "$FIXTURE" | tr -d ' ')"
  if [ "$MODE_STARVE" = "1" ]; then
    # Deliver the contract's cohort duration floor over STARVE_FACTOR x the point 6 SLO.
    rate=$(( bytes / FIXTURE_SECS * MIN_STARTUP_MS / (STARVE_FACTOR * SLO_MOUNT_READY_MS) ))
    [ "$rate" -gt 0 ] || rate=1
    echo "[starve] starving pace ${rate} B/s. Derivation: the contract's cohort floor is" >&2
    echo "[starve]   ${MIN_STARTUP_SEGS} segments AND ${MIN_STARTUP_MS} ms; delivering ${MIN_STARTUP_MS} ms of media" >&2
    echo "[starve]   at this rate takes $(( STARVE_FACTOR * SLO_MOUNT_READY_MS / 1000 ))s, i.e. ${STARVE_FACTOR}x the ${SLO_MOUNT_READY_MS} ms" >&2
    echo "[starve]   mount->ready SLO, so the cohort provably cannot fill before any startup deadline." >&2
  else
    local safe percent
    safe="$(safe_rate_percent)"
    percent="$FIXTURE_RATE_PERCENT"
    if [ "$percent" -gt "$safe" ]; then
      echo "[live-auto] pacing clamped ${percent}% -> ${safe}%: any faster and the producer's" >&2
      echo "[live-auto]   surplus fills the ${WINDOW_FLOOR_MIB} MiB buffer before the ${SOAK_SECS}s probe, which parks" >&2
      echo "[live-auto]   the source read and makes the app fail the remux ('live source read stalled')." >&2
      percent="$safe"
    fi
    # Pace as a percent of the fixture's OWN average bitrate, derived from the file
    # rather than hardcoded, so changing the fixture cannot silently unpace it.
    rate=$(( bytes / FIXTURE_SECS * percent / 100 ))
    # stderr: stdout of this function is the port, captured by the caller.
    echo "[live-auto] pacing delivery at ${rate} B/s (${percent}% of the fixture's own bitrate;" >&2
    echo "[live-auto]   above 100% so the producer stays ahead of playback, far enough below the" >&2
    echo "[live-auto]   park ceiling that the source read never stalls)" >&2
  fi
  python3 "$HERE/range-server.py" "$FIXTURE" "$portfile" 0.0.0.0 "$rate" >"$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  local waited=0
  while [ ! -s "$portfile" ]; do
    kill -0 "$SERVER_PID" 2>/dev/null || infra "fixture server died on startup: $(cat "$WORK/server.log")"
    sleep 0.2
    waited=$((waited + 1))
    [ $waited -lt 50 ] || infra "fixture server never reported a port"
  done
  FIXTURE_PORT="$(cat "$portfile")"
}

verify_range() {   # $1 = url
  local headers
  headers="$(curl -sS -o /dev/null -D - -r 0-99 --max-time 10 "$1" 2>&1)" \
    || infra "fixture server unreachable at $1 (curl failed): $headers"
  local size
  size="$(wc -c < "$FIXTURE" | tr -d ' ')"
  grep -qi '^HTTP/1.1 206' <<<"$headers" \
    || infra "fixture server did NOT answer Range with 206. A non-range server breaks
        the remux read path in a way that looks like a player bug. Got:
$headers"
  grep -qi "^Content-Range: bytes 0-99/$size" <<<"$headers" \
    || infra "fixture server returned a wrong Content-Range (expected bytes 0-99/$size). Got:
$headers"
  echo "[live-auto] range check OK: $(grep -i '^HTTP/1.1\|^Content-Range' <<<"$headers" | tr -d '\r' | tr '\n' ' ')"
}

slice_log() {   # $1 = full log, $2 = byte offset before launch, $3 = out
  if [ -f "$1" ]; then tail -c "+$(( $2 + 1 ))" "$1" > "$3" 2>/dev/null || : > "$3"; else : > "$3"; fi
}

# Slice a BOUNDED byte window [from, to) out of the container log.
#
# This exists for the observation-window correction. The harness's own probes hit the
# app's HLS server, and the app logs them exactly like AVPlayer's requests: our
# eviction control's `GET /seg0.m4s` lands in the log as `hls 404 /seg0.m4s`. Read back
# as session evidence that is FALSE EVIDENCE. It flips point 7's `saw a 404` to true,
# and `saw a 404` is one of the THREE conditions for point 7 going GREEN (the others
# being no readyToPlay and exactly one cohort-timeout event). The moment the rework
# emits that event, point 7 could go GREEN with one third of its proof supplied by our
# own probe rather than by the product: a false GREEN with a fuse on it, timed to fire
# exactly when the gate finally matters. It also mislabels harness traffic as playback
# evidence in point 4's latent line.
#
# The harness knows precisely when its own probing starts, so it records that byte
# boundary and cuts the trace there. Excluding by RECORDED BOUNDARY rather than by
# matching request paths is deliberate: a path pattern silently stops working the
# moment someone adds a probe that does not match it, and would fail open.
#
# No contract text, threshold or verdict mapping changes. This only makes the trace
# honest about which requests belong to the session under test.
slice_window() {   # $1 = full log, $2 = from byte, $3 = to byte (exclusive), $4 = out
  local count=$(( $3 - $2 ))
  if [ -f "$1" ] && [ "$count" -gt 0 ]; then
    tail -c "+$(( $2 + 1 ))" "$1" 2>/dev/null | head -c "$count" > "$4" || : > "$4"
  else
    : > "$4"
  fi
}

wait_for_ready() {   # $1 = full log, $2 = offset, $3 = slice path
  local slice="$3" elapsed=0 saw_accept=0 token=""
  while [ "$elapsed" -lt "$READY_TIMEOUT" ]; do
    slice_log "$1" "$2" "$slice"

    # --- fail fast: the hook refused the URL (vocabulary is fixed + actionable)
    if grep -q '\] debug-play reject ' "$slice"; then
      printf "\n"
      local rej
      rej="$(grep '\] debug-play reject ' "$slice" | tail -1)"
      infra "the DEBUG playback hook REJECTED the stream URL.
        $(sed -n 's/.*\(reason=[a-z-]*\).*/\1/p' <<<"$rej")
        marker: $rej"
    fi

    # --- readiness, in order: accept marker, THEN readyToPlay.
    if [ "$saw_accept" = "0" ] && grep -q '\] debug-play accept ' "$slice"; then
      saw_accept=1
      token="$(sed -n 's/.*token=\(<[^>]*>\).*/\1/p' <<<"$(grep '\] debug-play accept ' "$slice" | tail -1)")"
      printf "\r[live-auto] hook ACCEPTED the stream (token=%s); waiting for readyToPlay ...\n" "$token"
    fi

    # --- fail fast: silent libmpv demotion. Either the router never chose
    #     AVFoundation for THIS session's token, or the start watchdog flipped the
    #     engine mid-mount. Both mean the probe would have measured the WRONG
    #     engine; neither may present as a mystery timeout. Scoped to the accepted
    #     token so an unrelated title routing to libmpv cannot trip it.
    if [ "$saw_accept" = "1" ]; then
      if grep -q "route file=$token .*-> engine=mpv" "$slice"; then
        printf "\n"
        infra "the router sent THIS session to libmpv, not AVFoundation (silent demotion).
        marker: $(grep "route file=$token .*-> engine=mpv" "$slice" | tail -1)"
      fi
      if grep -q 'demote.*in place\|remux demoted' "$slice"; then
        printf "\n"
        infra "the AVPlayer session was demoted to libmpv before it became ready.
        marker: $(grep 'demote.*in place\|remux demoted' "$slice" | tail -1)"
      fi
    fi
    if [ "$saw_accept" = "1" ] && grep -q 'readyToPlay -> play' "$slice"; then
      echo "[live-auto] readyToPlay reached after ${elapsed}s: $(grep 'readyToPlay -> play' "$slice" | tail -1)"
      return 0
    fi

    printf "\r[live-auto] waiting for playback readiness ... %ds/%ds (accept=%s)   " \
      "$elapsed" "$READY_TIMEOUT" "$saw_accept"
    sleep 1
    elapsed=$((elapsed + 1))
  done
  printf "\n"

  # Timed out. Say WHICH of the two bars was missed, and use the honest build check.
  if ! grep -q '\[debughook\]' "$slice"; then
    infra "no [debughook] marker of ANY kind appeared in ${READY_TIMEOUT}s after launch.
        The installed build most likely does NOT carry the DEBUG playback hook (the
        hook is #if DEBUG only; a Release build ignores VORTX_DEBUG_PLAY_URL).
        Rebuild + install a Debug build: ./run-conformance.sh app-build"
  fi
  if [ "$saw_accept" = "0" ]; then
    infra "the hook logged [debughook] lines but never an accept marker within ${READY_TIMEOUT}s."
  fi
  infra "the hook accepted the stream but playback never reached readyToPlay within
        ${READY_TIMEOUT}s (no 'readyToPlay -> play' line). The session is not probeable.
        Last 8 session log lines:
$(tail -8 "$slice")"
}

# --- starve mode wait -------------------------------------------------------
# The success criterion here is the OPPOSITE of the normal one, and that difference
# has to be explicit or the mode will misreport its own intended outcome as a
# failure. On a starved start the contract WANTS the fail-soft to fire: exactly one
# `hls_startup_cohort_timeout`, a 404, and a demotion to libmpv. So a demotion is the
# EXPECTED terminal state here, NOT the INFRA exit-3 condition it is on a normal run.
# `readyToPlay` is the anomaly in this mode: it means the pace failed to starve.
starve_wait() {   # $1 = full log, $2 = offset, $3 = slice path
  local slice="$3" elapsed=0 saw_accept=0 outcome=""
  local event
  event="$(contract_str cohortTimeoutEvent)"
  while [ "$elapsed" -lt "$STARVE_TIMEOUT" ]; do
    slice_log "$1" "$2" "$slice"

    # A rejected URL is still INFRA in this mode: playback never started at all.
    if grep -q '\] debug-play reject ' "$slice"; then
      printf "\n"
      infra "the DEBUG playback hook REJECTED the stream URL.
        $(sed -n 's/.*\(reason=[a-z-]*\).*/\1/p' <<<"$(grep '\] debug-play reject ' "$slice" | tail -1)")"
    fi
    if [ "$saw_accept" = "0" ] && grep -q '\] debug-play accept ' "$slice"; then
      saw_accept=1
      printf "\r[starve] hook ACCEPTED the stream; starving the startup cohort ...\n"
    fi

    if [ "$saw_accept" = "1" ]; then
      # The contract's counted fail-soft. This is the outcome the mode exists for.
      if grep -q "$event" "$slice"; then
        outcome="cohort-timeout-event"; break
      fi
      # The beta's ACTUAL fail-soft: it demotes without emitting a counted event.
      if grep -q 'demote.*in place\|remux demoted' "$slice"; then
        outcome="demoted-without-event"; break
      fi
      # Starvation failed: the source still filled the cohort and playback started.
      if grep -q 'readyToPlay -> play' "$slice"; then
        outcome="reached-ready"; break
      fi
    fi
    printf "\r[starve] waiting for the fail-soft ... %ds/%ds (accept=%s)   " \
      "$elapsed" "$STARVE_TIMEOUT" "$saw_accept"
    sleep 1
    elapsed=$((elapsed + 1))
  done
  printf "\n"

  if [ -z "$outcome" ]; then
    if ! grep -q '\[debughook\]' "$slice"; then
      infra "no [debughook] marker of ANY kind appeared in ${STARVE_TIMEOUT}s after launch.
        The installed build most likely does NOT carry the DEBUG playback hook."
    fi
    outcome="no-terminal-state"
  fi

  echo ""
  case "$outcome" in
    cohort-timeout-event)
      echo "[starve] OUTCOME: the counted fail-soft FIRED. '$event' is present."
      echo "[starve]   Point 7's positive path is now exercisable end to end." ;;
    demoted-without-event)
      echo "[starve] OUTCOME: the session demoted to libmpv WITHOUT a counted '$event'."
      echo "[starve]   marker: $(grep 'demote.*in place\|remux demoted' "$slice" | tail -1)"
      echo "[starve]   This is the EXPECTED result against the current beta: the counted"
      echo "[starve]   fail-soft is part of the pending rework and does not exist yet. The"
      echo "[starve]   demotion is the contract's intended fail-soft behaviour, so it is NOT"
      echo "[starve]   an INFRA failure here. Point 7 stays PENDING/RED until the rework lands." ;;
    reached-ready)
      echo "[starve] OUTCOME: playback reached readyToPlay DESPITE the starving pace."
      echo "[starve]   The cohort filled anyway, so this run does NOT exercise point 7's"
      echo "[starve]   positive path. Lower the pace (raise VORTX_STARVE_FACTOR) and re-run." ;;
    no-terminal-state)
      echo "[starve] OUTCOME: no timeout event, no demotion and no readyToPlay within ${STARVE_TIMEOUT}s."
      echo "[starve]   The session is stalled rather than failing soft; point 7 is undecided." ;;
  esac
  echo ""
}

# Let the session actually stream before probing it, still watching for a demotion:
# a mid-soak flip to libmpv is exactly as much an INFRA failure as one before ready.
soak() {   # $1 = full log, $2 = offset, $3 = slice path
  local slice="$3" elapsed=0 advertised sessions
  [ "$SOAK_SECS" -gt 0 ] || return 0
  while [ "$elapsed" -lt "$SOAK_SECS" ]; do
    slice_log "$1" "$2" "$slice"
    # FIXTURE SERVER DEATH. If our own server exits, the app's source read fails and
    # the session collapses, which would otherwise surface as a confusing player-side
    # error. Name it as OUR fault, immediately, with the server's own stderr.
    if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
      printf "\n"
      infra "the FIXTURE SERVER (ours, not the app) died ${elapsed}s into the soak, so the app
        lost its source mid-session. This is a harness failure, not a player defect.
        last lines of the fixture server log:
$(tail -12 "$WORK/server.log" 2>/dev/null || echo '  (no server log)')"
    fi
    # SOURCE-READ STALL. The most specific failure on this path and the one worth
    # naming outright: the producer parked on the buffer ceiling, which blocks inside
    # the source read, so the app declared the remux failed. That is a PACING fault in
    # this harness, not a player defect, and the message has to say so or the next
    # person reads it as a regression.
    if grep -q 'live source read stalled' "$slice"; then
      printf "\n"
      infra "the app declared the SOURCE READ STALLED during the soak and failed the remux.
        marker: $(grep 'live source read stalled' "$slice" | tail -1)
        This is a harness PACING fault, not a player defect: the fixture was delivered
        faster than playback drained it, the producer parked on the ${WINDOW_FLOOR_MIB} MiB buffer
        ceiling, and parking blocks the source read. Lower VORTX_FIXTURE_RATE_PERCENT
        (or raise VORTX_PARK_SAFETY) so the surplus cannot fill the buffer before the probe."
    fi
    if grep -q 'demote.*in place\|remux demoted' "$slice"; then
      printf "\n"
      infra "the AVPlayer session was demoted to libmpv DURING the soak, so the battery
        would have probed a dead HLS server.
        marker: $(grep 'demote.*in place\|remux demoted' "$slice" | tail -1)"
    fi
    # SUPERSESSION. A second `hls server listening` means the app relaunched or
    # re-mounted, so the session we waited on is dead and its port is stale: the battery
    # would probe a server that no longer exists. Catch it AT THE MOMENT IT HAPPENS
    # rather than burning the rest of the soak and failing obscurely at probe time.
    sessions="$(grep -c 'hls server listening on 127\.0\.0\.1:' "$slice" || true)"
    if [ "${sessions:-0}" -gt 1 ]; then
      printf "\n"
      infra "the playback session was SUPERSEDED ${elapsed}s into the soak. The slice now holds
        ${sessions} 'hls server listening' lines, so the app relaunched or re-mounted and the
        session that was waited on and soaked is dead. Its port is stale, so the battery
        would have probed a server that no longer exists.
        listening lines: $(grep 'hls server listening on 127\.0\.0\.1:' "$slice" | sed 's/.*listening on/->/' | tr '\n' ' ')
        Most likely another process launched $BUNDLE_ID mid-run (a concurrent harness run,
        a manual launch, or Xcode). This run needs the simulator to itself."
    fi
    # Progress: how many segments the playlist currently ADVERTISES. Do NOT count
    # `hls media segment N published` lines: that log site is gated `if idx <= 1`
    # (VortXMKVRemuxStream.swift:2068), so it fires for segments 0 and 1 ONLY, and a
    # counter built on it sticks at 2 forever however the session actually progresses.
    advertised="$(grep -o 'hls resp /media\.m3u8 segs=[0-9]*' "$slice" | tail -1 | grep -o '[0-9]*$' || true)"
    printf "\r[live-auto] streaming before probe ... %ds/%ds (playlist advertises %s segs)   " \
      "$elapsed" "$SOAK_SECS" "${advertised:-0}"
    sleep 1
    elapsed=$((elapsed + 1))
  done
  printf "\n"
}

# Drive the real HLS buffer read head without depending on AVPlayer to survive the
# non-IDR defect point 2 is intentionally exposing. This is a TEST READER, not
# product traffic:
#   * the caller records the product-only byte boundary before entering;
#   * data is consumed only for segment ids in the latest successful manifest;
#     the separate retirement control deliberately probes seg0;
#   * ids are consumed strictly in order, never skipped and never raced ahead;
#   * manifest and reader transport failures remain INFRA, while the separate optional
#     stale-retirement observation can never block the acceptance battery;
#   * the beta defect is reported only after TWO complete HTTP 404/410 responses for
#     an advertised seg0 that this reader previously fetched with a complete 200;
#   * a server that keeps seg0 served or removes it from the playlist proceeds to the
#     same live battery instead of failing for lack of the defect;
#   * every synthetic request + status is counted in the stable reader sidecar.
synthetic_reader_for_window() {   # $1 = full log, $2 = offset, $3 = live slice
  local log="$1" offset="$2" slice="$3"
  local port elapsed=0 deadline next_id=0 highest=-1
  local manifest_gets=0 segment_gets=0 control_gets=0
  local manifest_failures=0 segment_failures=0 retired_streak=0
  local saw_seg0_200=0 seg0_advertised=0
  local manifest_file="$WORK/reader-media.m3u8" reader_log="$DD/last-reader-control.log"
  local manifest_code manifest_rc segment_code segment_rc control_code control_rc sessions advertised
  local window_complete decision

  port="$(grep -o 'hls server listening on 127\.0\.0\.1:[0-9]*' "$slice" | tail -1 | grep -o '[0-9]*$' || true)"
  [ -n "$port" ] || infra "synthetic reader could not find this session's HLS port in the product trace."
  deadline="$SOAK_SECS"
  [ "$deadline" -gt 0 ] || deadline=1
  : > "$reader_log"

  echo "[live-auto] synthetic reader ACTIVE on 127.0.0.1:$port after the product-only boundary."
  echo "[live-auto]   It will consume manifest-advertised segments in exact id order for ${deadline}s."
  echo "[live-auto]   Its optional seg0 control reports the stale-advertisement defect when proven;"
  echo "[live-auto]   absence of that defect never blocks the acceptance battery."

  while [ "$elapsed" -lt "$deadline" ]; do
    slice_log "$log" "$offset" "$slice"

    if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
      printf "\n"
      infra "the FIXTURE SERVER died ${elapsed}s into the synthetic-reader phase.
        last lines of the fixture server log:
$(tail -12 "$WORK/server.log" 2>/dev/null || echo '  (no server log)')"
    fi
    if grep -q 'live source read stalled' "$slice"; then
      printf "\n"
      infra "the app declared the SOURCE READ STALLED during the synthetic-reader phase.
        marker: $(grep 'live source read stalled' "$slice" | tail -1)"
    fi
    if grep -q 'demote.*in place\|remux demoted' "$slice"; then
      printf "\n"
      infra "the AVPlayer session demoted while the synthetic reader was advancing the
        HLS read head.
        marker: $(grep 'demote.*in place\|remux demoted' "$slice" | tail -1)"
    fi
    sessions="$(grep -c 'hls server listening on 127\.0\.0\.1:' "$slice" || true)"
    if [ "${sessions:-0}" -gt 1 ]; then
      printf "\n"
      infra "the playback session was SUPERSEDED ${elapsed}s into the synthetic-reader phase
        (${sessions} HLS listener markers in this launch slice)."
    fi

    curl_capture_complete "$manifest_file" 5 "http://127.0.0.1:$port/media.m3u8"
    manifest_rc="$CURL_RC"
    manifest_code="$CURL_STATUS"
    manifest_gets=$((manifest_gets + 1))
    printf 'manifest GET %d rc=%s status=%s\n' "$manifest_gets" "$manifest_rc" "$manifest_code" >> "$reader_log"
    if [ "$manifest_rc" != "0" ] || [ "$manifest_code" != "200" ]; then
      manifest_failures=$((manifest_failures + 1))
      retired_streak=0
      if [ "$manifest_failures" -ge 3 ]; then
        printf "\n"
        infra "the synthetic reader could not fetch /media.m3u8 three consecutive times
        (last transfer rc '$manifest_rc', HTTP status '$manifest_code'). No incomplete
        response was retained and no transport failure was treated as
        retirement.
        app process alive: $(app_alive)
        fixture server alive: $(server_alive)"
      fi
      printf "\r[live-auto] synthetic reader ... %ds/%ds (manifest rc=%s status=%s, retry %d/3)   " \
        "$elapsed" "$deadline" "$manifest_rc" "$manifest_code" "$manifest_failures"
      sleep 1
      elapsed=$((elapsed + 1))
      continue
    fi
    manifest_failures=0
    if grep -qx 'seg0\.m4s' "$manifest_file"; then seg0_advertised=1; else seg0_advertised=0; fi

    if [ "$seg0_advertised" = "0" ]; then
      retirement_observation_step "$saw_seg0_200" 0 0 000 "$retired_streak" 0
      printf "\n"
      echo "[live-auto] optional stale-retirement observation: seg0 is no longer advertised."
      echo "[live-auto]   This is a conforming removal shape, so no unadvertised path was probed."
      echo "[live-auto]   Continuing to the acceptance battery; requests: manifests=$manifest_gets segments=$segment_gets controls=$control_gets."
      return 0
    fi

    # Consume the contiguous advertised prefix from next_id. The exact grep is the
    # race guard: even if a later id appears, the reader never jumps over a missing
    # id and never asks for a path not present in THIS successfully fetched manifest.
    while grep -qx "seg${next_id}\.m4s" "$manifest_file"; do
      curl_probe_complete 10 "http://127.0.0.1:$port/seg${next_id}.m4s"
      segment_rc="$CURL_RC"
      segment_code="$CURL_STATUS"
      segment_gets=$((segment_gets + 1))
      printf 'segment GET id=%d rc=%s status=%s\n' "$next_id" "$segment_rc" "$segment_code" >> "$reader_log"
      if [ "$segment_rc" != "0" ]; then
        segment_failures=$((segment_failures + 1))
        retired_streak=0
        if [ "$segment_failures" -ge 3 ]; then
          printf "\n"
          infra "the synthetic reader failed to consume advertised seg${next_id} three
        consecutive times (last transfer rc '$segment_rc', HTTP status '$segment_code').
        It discarded every incomplete response, did not advance that id, and did not
        count transport failure as retirement."
        fi
        break
      fi
      case "$segment_code" in
        200)
          segment_failures=0
          if [ "$next_id" = "0" ]; then saw_seg0_200=1; fi
          highest="$next_id"
          next_id=$((next_id + 1)) ;;
        404|410)
          segment_failures=0
          # A manifest-advertised id retired before this sequential reader reached
          # it. Do not skip it; the independent seg0 control below decides whether
          # the required positive control has actually been reached.
          break ;;
        *)
          segment_failures=$((segment_failures + 1))
          if [ "$segment_failures" -ge 3 ]; then
            printf "\n"
            infra "the synthetic reader failed to consume advertised seg${next_id} three
        consecutive times (last transfer rc '$segment_rc', HTTP status '$segment_code'). It did not skip or
        race ahead of that manifest entry, and no transport failure counted as retirement."
          fi
          break ;;
      esac
    done

    # Optional defect observation. Proof requires this same reader to have received a
    # complete seg0 200 earlier, the current complete manifest still to advertise
    # seg0, and two consecutive complete 404/410 responses now. Absence of the beta
    # defect never blocks the full acceptance battery.
    curl_probe_complete 5 "http://127.0.0.1:$port/seg0.m4s"
    control_rc="$CURL_RC"
    control_code="$CURL_STATUS"
    control_gets=$((control_gets + 1))
    printf 'retirement GET %d rc=%s status=%s prior-seg0-200=%s currently-advertised=%s\n' \
      "$control_gets" "$control_rc" "$control_code" "$saw_seg0_200" "$seg0_advertised" >> "$reader_log"
    window_complete=0
    if [ $((elapsed + 1)) -ge "$deadline" ]; then window_complete=1; fi
    retirement_observation_step \
      "$saw_seg0_200" "$seg0_advertised" "$control_rc" "$control_code" \
      "$retired_streak" "$window_complete"
    retired_streak="$RETIREMENT_NEXT_STREAK"
    decision="$RETIREMENT_DECISION"

    advertised="$(grep -c '^seg[0-9][0-9]*\.m4s$' "$manifest_file" || true)"
    printf "\r[live-auto] synthetic reader ... %ds/%ds (advertised=%s, drained-through=%d, seg0-rc=%s, seg0-http=%s, retire-proof=%d/2)   " \
      "$elapsed" "$deadline" "${advertised:-0}" "$highest" "$control_rc" "$control_code" "$retired_streak"

    case "$decision" in
      defect-observed)
        printf "\n"
        echo "[live-auto] stale-advertisement defect OBSERVED after ${elapsed}s:"
        echo "[live-auto]   same-session seg0 first returned complete HTTP 200, remained advertised,"
        echo "[live-auto]   then returned complete HTTP $control_code twice; highest sequential id consumed=$highest."
        echo "[live-auto]   Continuing to the acceptance battery, which independently decides point 4."
        echo "[live-auto]   synthetic requests: manifests=$manifest_gets segments=$segment_gets retirement-controls=$control_gets."
        echo "[live-auto]   Full request/status sidecar: $DD/last-reader-control.log"
        return 0 ;;
      proceed-served)
        printf "\n"
        echo "[live-auto] optional stale-retirement observation: seg0 remained advertised and served."
        echo "[live-auto]   No defect was manufactured from its absence; continuing to the acceptance battery."
        return 0 ;;
      proceed-unobserved)
        printf "\n"
        echo "[live-auto] optional stale-retirement observation was inconclusive after ${deadline}s"
        echo "[live-auto]   (last transfer rc=$control_rc HTTP=$control_code, proof=$retired_streak/2)."
        echo "[live-auto]   Continuing to the acceptance battery; incomplete control evidence is not a verdict."
        return 0 ;;
    esac

    sleep 1
    elapsed=$((elapsed + 1))
  done

  printf "\n"
  echo "[live-auto] optional stale-retirement observation ended without defect proof."
  echo "[live-auto]   Continuing to the acceptance battery; requests: manifests=$manifest_gets segments=$segment_gets retirement-controls=$control_gets."
  return 0
}

# Force a REAL DiagnosticsLog rollover after the product snapshot. Unknown paths are
# ideal control traffic: the HLS listener logs one request + one 404, but touches no
# manifest, segment, read head, or verdict predicate. A long fixed-safe path reaches
# the rolling cap in hundreds rather than thousands of requests. This phase is
# explicit (`--rotation-control`), post-boundary, counted, and never part of the
# product trace. The caller checks the saved trace fingerprint again afterwards.
force_diagnostics_rollover() {   # $1 = diagnostics.log, $2 = HLS port
  local log="$1" port="$2" before after code rc requests=0 observed=0 padding
  local rotation_log="$DD/last-rotation-control.log"
  printf -v padding '%0900d' 0
  : > "$rotation_log"
  before="$(wc -c < "$log" | tr -d ' ')"
  while [ "$requests" -lt 2000 ]; do
    curl_probe_complete 5 "http://127.0.0.1:$port/rotation-control-${requests}-${padding}"
    rc="$CURL_RC"
    code="$CURL_STATUS"
    requests=$((requests + 1))
    printf 'rotation GET %d rc=%s status=%s\n' "$requests" "$rc" "$code" >> "$rotation_log"
    [ "$rc" = "0" ] && [ "$code" = "404" ] || infra "rotation control lost a complete
        404 response from the HLS listener at request $requests (transfer rc '$rc',
        HTTP status '$code'); no rollover claim was made."
    after="$(wc -c < "$log" | tr -d ' ')"
    if [ "$after" -lt "$before" ]; then
      observed=1
      break
    fi
    before="$after"
  done
  [ "$observed" = "1" ] || infra "rotation control issued $requests labeled post-boundary
        requests but never observed diagnostics.log shrink. The saved product trace
        was not claimed rollover-safe without a real rollover."
  echo "[rotation-control] REAL diagnostics.log rollover observed after $requests post-boundary requests."
  echo "[rotation-control] request/status sidecar -> $DD/last-rotation-control.log"
}

# POSITIVE CONTROL for point 4. The derived soak says eviction SHOULD have happened by
# now; this proves it actually did, by asking the server for the lowest advertised
# segment and seeing a real non-200. A timer alone is not enough: measured across four
# runs, three evicted 19 segments by probe time and a fourth (immediately after a fresh
# `simctl install`) had evicted nothing, which left point 4 resting on the latent
# prediction rather than proof. Polling for the actual eviction removes that variance.
confirm_eviction() {   # $1 = slice path
  local slice="$1" port elapsed=0 code rc manifest_code manifest_rc
  local saw_seg0_200=0 retired_streak=0 manifest_failures=0 control_failures=0
  local manifest="$WORK/eviction-media.m3u8"
  local control_log="$DD/last-no-reader-retirement-control.log" attempts=0
  port="$(grep -o 'hls server listening on 127\.0\.0\.1:[0-9]*' "$slice" | tail -1 | grep -o '[0-9]*$' || true)"
  if [ -z "$port" ]; then
    echo "[live-auto] eviction check skipped: no HLS port in the captured session yet." >&2
    return 0
  fi
  : > "$control_log"
  while [ "$elapsed" -lt "$EVICTION_CONFIRM_SECS" ]; do
    curl_capture_complete "$manifest" 5 "http://127.0.0.1:$port/media.m3u8"
    manifest_rc="$CURL_RC"
    manifest_code="$CURL_STATUS"
    attempts=$((attempts + 1))
    printf 'manifest GET %d rc=%s status=%s\n' "$attempts" "$manifest_rc" "$manifest_code" >> "$control_log"
    if [ "$manifest_rc" != "0" ] || [ "$manifest_code" != "200" ]; then
      manifest_failures=$((manifest_failures + 1))
      retired_streak=0
      [ "$manifest_failures" -lt 3 ] || infra "eviction control could not fetch a complete current
        manifest three times (transfer rc '$manifest_rc', HTTP status '$manifest_code')."
      sleep 5
      elapsed=$((elapsed + 5))
      continue
    fi
    manifest_failures=0
    if ! grep -qx 'seg0\.m4s' "$manifest"; then
      retired_streak=0
      control_failures=0
      printf "\r[live-auto] confirming eviction ... %ds/%ds (seg0 no longer advertised)   " \
        "$elapsed" "$EVICTION_CONFIRM_SECS"
      sleep 5
      elapsed=$((elapsed + 5))
      continue
    fi

    curl_probe_complete 5 "http://127.0.0.1:$port/seg0.m4s"
    rc="$CURL_RC"
    code="$CURL_STATUS"
    printf 'retirement GET %d rc=%s status=%s prior-seg0-200=%s currently-advertised=1\n' \
      "$attempts" "$rc" "$code" "$saw_seg0_200" >> "$control_log"
    if [ "$rc" != "0" ]; then
      control_failures=$((control_failures + 1))
      retired_streak=0
      [ "$control_failures" -lt 3 ] || infra "eviction control had three consecutive incomplete
        seg0 transfers (transfer rc '$rc', HTTP status '$code'). This is INFRA."
    else
      control_failures=0
    fi
    case "$rc:$code" in
      0:200)
        saw_seg0_200=1
        retired_streak=0 ;;
      0:404|0:410)
        if [ "$saw_seg0_200" = "1" ]; then retired_streak=$((retired_streak + 1)); else retired_streak=0; fi
        if [ "$retired_streak" -ge 2 ]; then
          echo ""
          echo "[live-auto] eviction CONFIRMED after ${elapsed}s: seg0 was observed complete HTTP 200,"
          echo "[live-auto]   remained advertised, then returned complete HTTP $code twice."
          echo "[live-auto]   Point 4's active strand now has something real to find."
          return 0
        fi ;;
      0:*)
        retired_streak=0 ;;
      *)
        : ;;
    esac
    printf "\r[live-auto] confirming eviction ... %ds/%ds (seg0 rc=%s HTTP=%s, proof=%d/2)   " \
      "$elapsed" "$EVICTION_CONFIRM_SECS" "$rc" "$code" "$retired_streak"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  printf "\n"
  infra "eviction was not confirmed within ${EVICTION_CONFIRM_SECS}s. Prior complete
        seg0 200 observed: $saw_seg0_200. A timeout or prediction is not retirement,
        so this control is INFRA rather than a product verdict."
}

live_auto_usage_error() {
  echo "live-auto usage error: $1" >&2
  echo "usage: $0 live-auto [--spool D] [--url U] [--timeout POSITIVE_SECONDS]" >&2
  echo "       [--soak POSITIVE_SECONDS] [--starve] [--no-reader] [--rotation-control]" >&2
  exit 2
}

require_positive_integer() {   # $1 = display name, $2 = value
  local name="$1" value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || live_auto_usage_error "$name must be a positive integer, got '$value'"
  [ "${#value}" -le 10 ] && [ "$value" -le 2147483647 ] \
    || live_auto_usage_error "$name is outside the supported range 1...2147483647: '$value'"
}

live_auto() {
  local spool="" url_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --spool)
        [ $# -ge 2 ] && [ -n "$2" ] || live_auto_usage_error "--spool requires a path"
        spool="$2"; shift 2 ;;
      --url)
        [ $# -ge 2 ] && [ -n "$2" ] || live_auto_usage_error "--url requires a URL"
        url_override="$2"; shift 2 ;;   # diagnostic escape hatch
      --timeout)
        [ $# -ge 2 ] || live_auto_usage_error "--timeout requires a value"
        require_positive_integer "--timeout" "$2"
        READY_TIMEOUT="$2"; shift 2 ;;
      --soak)
        [ $# -ge 2 ] || live_auto_usage_error "--soak requires a value"
        require_positive_integer "--soak" "$2"
        SOAK_SECS="$2"; shift 2 ;;
      --starve)  MODE_STARVE=1; shift ;;
      --no-reader) SYNTHETIC_READER=0; shift ;;
      --rotation-control) ROTATION_CONTROL=1; shift ;;
      *) echo "unknown live-auto flag: $1" >&2; exit 2 ;;
    esac
  done
  if [ "$ROTATION_CONTROL" = "1" ] && [ "$SYNTHETIC_READER" != "1" ]; then
    live_auto_usage_error "--rotation-control requires the default synthetic reader (do not combine with --no-reader)"
  fi
  require_positive_integer "VORTX_READY_TIMEOUT" "$READY_TIMEOUT"
  require_positive_integer "VORTX_FIXTURE_SECS" "$FIXTURE_SECS"
  require_positive_integer "VORTX_FIXTURE_RATE_PERCENT" "$FIXTURE_RATE_PERCENT"
  require_positive_integer "VORTX_EVICTION_MARGIN_PERCENT" "$EVICTION_MARGIN_PERCENT"
  require_positive_integer "VORTX_PARK_SAFETY" "$PARK_SAFETY"
  require_positive_integer "VORTX_EVICTION_CONFIRM_SECS" "$EVICTION_CONFIRM_SECS"
  require_positive_integer "VORTX_STARVE_FACTOR" "$STARVE_FACTOR"
  require_positive_integer "VORTX_STARVE_TIMEOUT" "$STARVE_TIMEOUT"
  if [ -n "$SOAK_SECS" ]; then require_positive_integer "VORTX_SOAK_SECS/--soak" "$SOAK_SECS"; fi

  trap cleanup EXIT INT TERM
  WORK="$(mktemp -d /tmp/live-auto.XXXXXX)"

  preflight
  build_harness

  local tag="live-auto"
  [ "$MODE_STARVE" = "1" ] && tag="starve"
  if [ "$MODE_STARVE" = "1" ]; then
    echo "[starve] point 7 positive-path mode. Success here is the FAIL-SOFT firing, not playback."
  fi

  local url
  if [ -n "$url_override" ]; then
    url="$url_override"
    echo "[$tag] using caller-supplied URL (fixture server NOT started): $url"
  else
    make_fixture
    # The soak must be derived BEFORE the rate: the safe delivery rate depends on how
    # long the producer has to avoid filling the buffer, which is the soak.
    if [ "$MODE_STARVE" != "1" ] && [ -z "$SOAK_SECS" ]; then
      SOAK_SECS="$(derive_soak)"
    fi
    [ -n "$SOAK_SECS" ] || SOAK_SECS=0
    if [ "$MODE_STARVE" != "1" ]; then require_positive_integer "derived soak" "$SOAK_SECS"; fi
    local ip port
    ip="$(lan_address)"
    # NOT `port="$(start_fixture_server)"`: a command substitution runs in a SUBSHELL,
    # so the `SERVER_PID=$!` inside it never reaches this shell. That left SERVER_PID
    # empty, which silently disabled BOTH the cleanup trap's kill and the soak's
    # server-liveness check, and made server_alive() report a permanent false "NO".
    # Nine fixture servers leaked across nine runs, several still streaming at full
    # rate, competing for CPU and bandwidth with every subsequent run.
    start_fixture_server
    port="$FIXTURE_PORT"
    url="http://$ip:$port/$FIXTURE_NAME"
    echo "[$tag] serving fixture at $url (bound 0.0.0.0:$port, non-loopback host $ip)"
    verify_range "$url"
  fi
  [ -n "$SOAK_SECS" ] || SOAK_SECS=0

  local log offset slice
  log="$(container_log)" || infra "cannot locate the app container log"
  offset=0
  [ -f "$log" ] && offset="$(wc -c < "$log" | tr -d ' ')"
  slice="$WORK/session.log"
  echo "[$tag] container log $log (watching from byte $offset)"

  echo "[$tag] launching $BUNDLE_ID with the DEBUG env trigger"
  SIMCTL_CHILD_VORTX_DEBUG_PLAY_URL="$url" \
  SIMCTL_CHILD_VORTX_DEBUG_PLAY_TITLE="Conformance Run" \
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" \
    || infra "xcrun simctl launch failed"
  APP_LAUNCHED=1

  local rc=0
  if [ "$MODE_STARVE" = "1" ]; then
    starve_wait "$log" "$offset" "$slice"
    slice_log "$log" "$offset" "$slice"
    cp "$slice" "$DD/last-starve-session.log" 2>/dev/null || true
    echo "[starve] captured session log -> $DD/last-starve-session.log"
    # The HLS server is gone once the session demotes, so the LIVE channel has
    # nothing to fetch. Point 7 is a trace-channel point anyway (`Live` only
    # forwards it from the trace), so evaluate the captured session with `trace`.
    set +e
    "$BIN" trace "$slice"
    rc=$?
    set -e
    [ "$rc" = "2" ] && infra "the harness could not read a plain-remux session out of the starved log"
  else
    wait_for_ready "$log" "$offset" "$slice"
    slice_log "$log" "$offset" "$slice"

    # OBSERVATION WINDOW. The default path starts a synthetic HLS reader next, so its
    # product-only boundary MUST be taken immediately after readiness and before that
    # reader's first manifest GET. The historical --no-reader control has no synthetic
    # traffic during soak, so it preserves the longer product-only timeline and takes
    # the boundary immediately before its old seg0 confirmation poll.
    local probe_start trace_slice="$WORK/product-session.log" trace_snapshot="$DD/last-session.log"
    local trace_fingerprint trace_after reader_port
    if [ "$SYNTHETIC_READER" = "1" ]; then
      probe_start="$(wc -c < "$log" | tr -d ' ')"
      echo "[live-auto] product-only observation boundary recorded at container byte $probe_start"
      echo "[live-auto]   BEFORE the synthetic reader's first request. Later reader traffic is counted"
      echo "[live-auto]   in a sidecar and excluded from trace/verdict evidence."
      # Snapshot NOW, not after the reader. diagnostics.log is a rolling cache; a
      # reader phase that crosses its rotation threshold can make the old absolute
      # byte range disappear. Deferring this copy produced an empty verdict trace
      # even though the live session and reader both completed successfully.
      slice_window "$log" "$offset" "$probe_start" "$trace_slice"
      [ -s "$trace_slice" ] || infra "the bounded product-only trace is empty before
        the synthetic reader has made a request. Refusing to run a verdict on no evidence."
      cp "$trace_slice" "$trace_snapshot" || infra "could not persist the product-only trace at $trace_snapshot."
      trace_fingerprint="$(cksum "$trace_snapshot")"
      if [ "$ROTATION_CONTROL" = "1" ]; then
        reader_port="$(grep -o 'hls server listening on 127\.0\.0\.1:[0-9]*' "$trace_slice" | tail -1 | grep -o '[0-9]*$' || true)"
        [ -n "$reader_port" ] || infra "rotation control could not resolve the HLS port from the saved product trace."
        force_diagnostics_rollover "$log" "$reader_port"
      fi
      synthetic_reader_for_window "$log" "$offset" "$slice"
    else
      echo "[no-reader] historical control ACTIVE: AVPlayer alone owns the HLS read head."
      echo "[no-reader] this intentionally preserves the old post-install failure chain for reproduction."
      soak "$log" "$offset" "$slice"
      slice_log "$log" "$offset" "$slice"
      probe_start="$(wc -c < "$log" | tr -d ' ')"
      slice_window "$log" "$offset" "$probe_start" "$trace_slice"
      [ -s "$trace_slice" ] || infra "the no-reader control produced an empty product trace."
      cp "$trace_slice" "$trace_snapshot" || infra "could not persist the no-reader product trace at $trace_snapshot."
      trace_fingerprint="$(cksum "$trace_snapshot")"
      confirm_eviction "$slice"
    fi

    trace_after="$(cksum "$trace_snapshot")"
    [ "$trace_after" = "$trace_fingerprint" ] || infra "the saved product-only trace changed after
        post-boundary harness traffic. Before: '$trace_fingerprint'; after: '$trace_after'."
    echo "[live-auto] product-only trace remained nonempty and byte-stable after post-boundary traffic."

    # Cut the trace at the product-only boundary, so the gate's trace evidence never
    # includes either the synthetic reader, confirm_eviction, or `live`'s own probes.
    # Refresh and preserve the full session separately for reliability diagnosis.
    slice_log "$log" "$offset" "$slice"
    echo "[live-auto] trace window: container bytes ${offset}..${probe_start}; harness probe traffic"
    echo "[live-auto]   after that boundary is EXCLUDED from verdict evidence (it is ours, not the app's)."
    # Keep both views at stable paths (WORK is deleted on exit): last-session.log is
    # the bounded product trace used for verdicts; last-full-session.log includes the
    # labeled synthetic traffic and exists only for reliability diagnosis.
    cp "$slice" "$DD/last-full-session.log" 2>/dev/null || true
    echo "[live-auto] captured product-only trace -> $DD/last-session.log"
    echo "[live-auto] captured full diagnostic timeline -> $DD/last-full-session.log"
    set +e
    if [ -n "$spool" ]; then
      "$BIN" live --log "$trace_snapshot" --spool "$spool"
    else
      "$BIN" live --log "$trace_snapshot"
    fi
    rc=$?
    set -e
    # The binary's 2 means "could not find/parse a live session" - infra, not product.
    [ "$rc" = "2" ] && infra "the harness could not read a live plain-remux session out of the captured log"
    # The binary's 3 means it could not OBSERVE the session (it has already explained
    # why). Pass it straight through as INFRA and add the one fact only the runner
    # knows: whether the app process was still alive when the probe ran.
    if [ "$rc" = "3" ]; then
      infra "the live channel could not observe the session (detail above).
        app process alive at probe time: $(app_alive)
        fixture server alive at probe time: $(server_alive)"
    fi
  fi

  # --- teardown, then the post-session half of point 5 -----------------------
  echo ""
  echo "[$tag] tearing down: terminating $BUNDLE_ID"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  APP_LAUNCHED=0
  sleep 2
  if [ "$MODE_STARVE" = "1" ]; then
    echo ""
    echo "[starve] EXIT $rc - point 7's positive-path CHANNEL ran end to end."
    echo "[starve]   The counted '$(contract_str cohortTimeoutEvent)' does not exist in the"
    echo "[starve]   current beta, so a PENDING or RED point 7 above is the correct result"
    echo "[starve]   today. Nothing was tuned to manufacture a GREEN. When the rework lands"
    echo "[starve]   its fail-soft, re-run this exact command to verify the positive path."
    exit "$rc"
  fi
  if [ -n "$spool" ]; then
    local bytes
    bytes="$("$BIN" spool "$spool" 2>/dev/null || echo "?")"
    echo "[live-auto] (5) post-session spool $spool = ${bytes} B (contract: reclaimed to ZERO)"
    if [ "$bytes" != "0" ]; then
      echo "[live-auto] (5) post-session RED: spool did not reclaim to zero"
      rc=1
    fi
  else
    echo "[live-auto] (5) post-session reclaimed-to-zero NOT MEASURED: no --spool given."
    echo "[live-auto]     There is no on-disk spool in the current tree - the store is the"
    echo "[live-auto]     IN-MEMORY VortXRemuxBuffer - so point 5 only becomes measurable"
    echo "[live-auto]     once the REQ-260722-09 rework lands a spool directory. Not faked,"
    echo "[live-auto]     not inferred; the point stays INDETERMINATE above."
  fi

  echo ""
  case "$rc" in
    0) echo "[live-auto] EXIT 0 - gate ran, every point GREEN/EXEMPT." ;;
    1) echo "[live-auto] EXIT 1 - gate ran and decided; at least one point is RED (product signal)." ;;
    *) echo "[live-auto] EXIT $rc - unexpected harness status." ;;
  esac
  exit "$rc"
}

MODE="${1:-all}"
case "$MODE" in
  selftest)
    build_harness
    "$BIN" selftest
    curl_transport_regressions
    retirement_acceptance_regressions ;;
  mutants)
    build_harness; run_mutants ;;
  trace)
    build_harness
    LOG="${2:-$(container_log)}"
    echo "[trace] $LOG"
    "$BIN" trace "$LOG" ;;
  live)
    build_harness
    shift || true
    LOG="$(container_log)"
    echo "[live] container log $LOG"
    "$BIN" live --log "$LOG" "$@" ;;
  live-auto)
    shift || true
    live_auto "$@" ;;
  app-build)
    app_build ;;
  all)
    build_harness
    "$BIN" selftest || true
    curl_transport_regressions || true
    retirement_acceptance_regressions || true
    LOG="$(container_log)" || LOG=""
    if [ -n "$LOG" ] && [ -f "$LOG" ]; then
      echo "[trace] $LOG"
      "$BIN" trace "$LOG" || true
    else
      echo "[trace] no container log yet - play a plain MKV, then re-run: ./run-conformance.sh trace"
    fi ;;
  *)
    echo "usage: $0 [selftest|mutants|trace [logfile]|live [--spool D]" >&2
    echo "       |live-auto [--spool D] [--timeout S] [--soak S] [--starve] [--no-reader]" >&2
    echo "                  [--rotation-control] [--url U]|app-build|all]" >&2
    echo "       live / live-auto exit: 0 = all points GREEN/EXEMPT, 1 = a point is RED (product)," >&2
    echo "       3 = INFRA (no probeable session; not a player regression), 2 = bad usage." >&2
    exit 2 ;;
esac
