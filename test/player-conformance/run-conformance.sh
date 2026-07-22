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
# head passes windowFloorBytes; the read head advances at roughly playback rate. A
# margin of 1 would put the run exactly on that knife edge, which is how the earlier
# 92 MiB fixture produced 15 predicted-evicted ids that all still returned 200. The
# soak is DERIVED from this and the fixture's own bitrate, never hardcoded.
EVICTION_MARGIN_PERCENT="${VORTX_EVICTION_MARGIN_PERCENT:-120}"
# Explicit --soak wins; empty means "derive it" (see derive_soak).
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
#  UPPER BOUND (session survival): the producer parks in `VortXRemuxBuffer.append`
#    once resident bytes reach `windowFloorBytes + producerLead`. Parking blocks
#    inside the SOURCE READ path, so the app's own stall detector sees no source
#    progress and FAILS the remux. Measured at 4x: "live source read stalled 48.2s
#    (rc=-5, produced=125901614B)" then "hls 404 /media.m3u8 (remux failed)" and a
#    demotion, roughly 95 s in, killing the session before the probe.
#
# So the surplus rate (delivery minus playback) must be small enough that it cannot
# fill the buffer before the probe runs. That is derived in `safe_rate_percent`
# from windowFloorMiB and the soak, not chosen. This value is only the CEILING that
# derivation is allowed to clamp down from.
FIXTURE_RATE_PERCENT="${VORTX_FIXTURE_RATE_PERCENT:-150}"
# How much margin to keep between "buffer full" and "probe time".
# Measured, not modelled. A safety of 2 (delivery clamped to 125%) STILL parked the
# producer: the playlist froze at segs=70 for 40 s while AVPlayer polled /media.m3u8,
# then AVPlayer gave up with "mid-play AVPlayer endFileError (Playback Stopped) ->
# demote to libmpv in place". The read head evidently lags playback by more than the
# simple model assumes, so the surplus must be small enough that the producer never
# builds a meaningful lead at all. 5 clamps delivery to ~110%.
PARK_SAFETY="${VORTX_PARK_SAFETY:-1}"
# Extra bounded wait for the eviction positive control (see confirm_eviction).
EVICTION_CONFIRM_SECS="${VORTX_EVICTION_CONFIRM_SECS:-120}"

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
    "$HERE/Contract.swift" "$HERE/Playlist.swift" "$HERE/FMP4.swift" \
    "$HERE/Trace.swift" "$HERE/Live.swift" "$HERE/main.swift" "$POLICY"
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
  echo "[live-auto] eviction sizing: buffer evicts at (readHead - ${WINDOW_FLOOR_MIB} MiB), read head advances" >&2
  echo "[live-auto]   at playback rate ${rate} B/s. Need read head past ${EVICTION_MARGIN_PERCENT}% of ${WINDOW_FLOOR_MIB} MiB" >&2
  echo "[live-auto]   = ${need} B, so soak = ${need} / ${rate} = ${soak}s (fixture is ${FIXTURE_SECS}s of media)." >&2
  if [ "$soak" -ge $(( FIXTURE_SECS - 30 )) ]; then
    echo "[live-auto]   WARNING: the fixture is too short to soak that long. Point 4's active" >&2
    echo "[live-auto]   strand may probe a window that never evicted. Raise VORTX_FIXTURE_SECS." >&2
  fi
  echo "$soak"
}

# The largest delivery percent that cannot park the producer before the probe runs.
# The producer's SURPLUS over playback accumulates in the buffer; once it reaches the
# park ceiling the source read blocks and the app fails the remux (see the constraint
# note above). Requiring
#     windowFloorBytes / surplus  >  soak x PARK_SAFETY
# keeps the buffer from filling until well after the battery has run. windowFloorBytes
# is the conservative choice: the real ceiling is floor + producer lead, so this errs
# on the safe side. Derived from Contract.swift and the soak, never picked.
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
      if grep -q 'demote in place\|remux demoted' "$slice"; then
        printf "\n"
        infra "the AVPlayer session was demoted to libmpv before it became ready.
        marker: $(grep 'demote in place\|remux demoted' "$slice" | tail -1)"
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
      if grep -q 'demote in place\|remux demoted' "$slice"; then
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
      echo "[starve]   marker: $(grep 'demote in place\|remux demoted' "$slice" | tail -1)"
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
    if grep -q 'demote in place\|remux demoted' "$slice"; then
      printf "\n"
      infra "the AVPlayer session was demoted to libmpv DURING the soak, so the battery
        would have probed a dead HLS server.
        marker: $(grep 'demote in place\|remux demoted' "$slice" | tail -1)"
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

# POSITIVE CONTROL for point 4. The derived soak says eviction SHOULD have happened by
# now; this proves it actually did, by asking the server for the lowest advertised
# segment and seeing a real non-200. A timer alone is not enough: measured across four
# runs, three evicted 19 segments by probe time and a fourth (immediately after a fresh
# `simctl install`) had evicted nothing, which left point 4 resting on the latent
# prediction rather than proof. Polling for the actual eviction removes that variance.
confirm_eviction() {   # $1 = slice path
  local slice="$1" port elapsed=0 code
  port="$(grep -o 'hls server listening on 127\.0\.0\.1:[0-9]*' "$slice" | tail -1 | grep -o '[0-9]*$' || true)"
  if [ -z "$port" ]; then
    echo "[live-auto] eviction check skipped: no HLS port in the captured session yet." >&2
    return 0
  fi
  while [ "$elapsed" -lt "$EVICTION_CONFIRM_SECS" ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/seg0.m4s" 2>/dev/null || echo 000)"
    case "$code" in
      200)
        : ;;   # still resident, keep waiting
      404|410)
        echo ""
        echo "[live-auto] eviction CONFIRMED after ${elapsed}s: GET /seg0.m4s -> HTTP $code."
        echo "[live-auto]   Point 4's active strand now has something real to find."
        return 0 ;;
      *)
        # 000 (or anything that is not a real HTTP status) means the request never
        # reached the server. That is NOT eviction. Treating "could not reach" as
        # "observed a 404" is the exact false-evidence class this lane exists to
        # remove, and it would hand point 4 a fabricated positive control.
        printf "\n"
        infra "the session's HLS server became UNREACHABLE while confirming eviction
        (${elapsed}s in): GET http://127.0.0.1:$port/seg0.m4s -> curl code '$code'.
        The session died before the battery could probe it. This is NOT eviction and is
        NOT a player verdict.
        app process alive: $(app_alive)
        fixture server alive: $(server_alive)" ;;
    esac
    printf "\r[live-auto] confirming eviction ... %ds/%ds (seg0 still HTTP %s)   " \
      "$elapsed" "$EVICTION_CONFIRM_SECS" "$code"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo ""
  echo "[live-auto] eviction NOT confirmed within ${EVICTION_CONFIRM_SECS}s: seg0 still returns 200."
  echo "[live-auto]   The window is retaining more than the ${WINDOW_FLOOR_MIB} MiB floor the estimate assumes."
  echo "[live-auto]   Point 4's ACTIVE strand will find nothing and the verdict will rest on the"
  echo "[live-auto]   latent arithmetic, which the output marks with an explicit NOTE. Reported,"
  echo "[live-auto]   not hidden."
  return 0
}

live_auto() {
  local spool="" url_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --spool)   spool="${2:-}"; shift 2 ;;
      --url)     url_override="${2:-}"; shift 2 ;;   # diagnostic escape hatch
      --timeout) READY_TIMEOUT="${2:-}"; shift 2 ;;
      --soak)    SOAK_SECS="${2:-}"; shift 2 ;;
      --starve)  MODE_STARVE=1; shift ;;
      *) echo "unknown live-auto flag: $1" >&2; exit 2 ;;
    esac
  done

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
    soak "$log" "$offset" "$slice"
    slice_log "$log" "$offset" "$slice"

    # OBSERVATION WINDOW. Everything the app logs from this byte onward may include the
    # harness's OWN probe traffic, which must never be read back as product evidence.
    # Record the boundary before the first probe fires. See slice_window.
    local probe_start
    probe_start="$(wc -c < "$log" | tr -d ' ')"
    confirm_eviction "$slice"

    # Cut the trace at the probe boundary, so the gate's evidence is session traffic
    # ONLY. `live`'s own segment probes cannot pollute it either: the binary reads this
    # file once, up front, before it issues a single request.
    slice_window "$log" "$offset" "$probe_start" "$slice"
    echo "[live-auto] trace window: container bytes ${offset}..${probe_start}; harness probe traffic"
    echo "[live-auto]   after that boundary is EXCLUDED from verdict evidence (it is ours, not the app's)."
    # Keep the captured session at a stable path (WORK is deleted on exit) so the
    # same run can be re-examined with `trace` without replaying it on the sim.
    cp "$slice" "$DD/last-session.log" 2>/dev/null || true
    echo "[live-auto] captured session log -> $DD/last-session.log"
    set +e
    if [ -n "$spool" ]; then
      "$BIN" live --log "$slice" --spool "$spool"
    else
      "$BIN" live --log "$slice"
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
    build_harness; "$BIN" selftest ;;
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
    LOG="$(container_log)" || LOG=""
    if [ -n "$LOG" ] && [ -f "$LOG" ]; then
      echo "[trace] $LOG"
      "$BIN" trace "$LOG" || true
    else
      echo "[trace] no container log yet - play a plain MKV, then re-run: ./run-conformance.sh trace"
    fi ;;
  *)
    echo "usage: $0 [selftest|trace [logfile]|live [--spool D]" >&2
    echo "       |live-auto [--spool D] [--timeout S] [--soak S] [--starve] [--url U]|app-build|all]" >&2
    echo "       live / live-auto exit: 0 = all points GREEN/EXEMPT, 1 = a point is RED (product)," >&2
    echo "       3 = INFRA (no probeable session; not a player regression), 2 = bad usage." >&2
    exit 2 ;;
esac
