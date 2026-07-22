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
EVICTION_MARGIN="${VORTX_EVICTION_MARGIN:-2}"
# Explicit --soak wins; empty means "derive it" (see derive_soak).
SOAK_SECS="${VORTX_SOAK_SECS:-}"
# Delivery pacing, as a multiple of the fixture's own average bitrate. See the
# header of range-server.py: an unpaced LAN server delivers the whole fixture
# before AVPlayer's first /media.m3u8 request, which turns the session into an
# instant ENDLIST VOD and hides the startup gate that point 1 measures. 4x keeps
# the producer comfortably ahead of 1x playback while still losing the race to
# AVPlayer's first playlist request, which is the real-world condition.
FIXTURE_RATE_MULTIPLE="${VORTX_FIXTURE_RATE_MULTIPLE:-4}"

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
  [ -n "$WORK" ] && rm -rf "$WORK"
  exit $rc
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
  need=$(( EVICTION_MARGIN * WINDOW_FLOOR_MIB * 1024 * 1024 ))
  soak=$(( need / rate ))
  echo "[live-auto] eviction sizing: buffer evicts at (readHead - ${WINDOW_FLOOR_MIB} MiB), read head advances" >&2
  echo "[live-auto]   at playback rate ${rate} B/s. Need read head past ${EVICTION_MARGIN} x ${WINDOW_FLOOR_MIB} MiB" >&2
  echo "[live-auto]   = ${need} B, so soak = ${need} / ${rate} = ${soak}s (fixture is ${FIXTURE_SECS}s of media)." >&2
  if [ "$soak" -ge $(( FIXTURE_SECS - 30 )) ]; then
    echo "[live-auto]   WARNING: the fixture is too short to soak that long. Point 4's active" >&2
    echo "[live-auto]   strand may probe a window that never evicted. Raise VORTX_FIXTURE_SECS." >&2
  fi
  echo "$soak"
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
    # Pace at FIXTURE_RATE_MULTIPLE x the fixture's OWN average bitrate, derived from
    # the file rather than hardcoded, so changing the fixture cannot silently unpace it.
    rate=$(( bytes / FIXTURE_SECS * FIXTURE_RATE_MULTIPLE ))
    # stderr: stdout of this function is the port, captured by the caller.
    echo "[live-auto] pacing delivery at ${rate} B/s (${FIXTURE_RATE_MULTIPLE}x the fixture's own bitrate)" >&2
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
  cat "$portfile"
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
  local slice="$3" elapsed=0
  [ "$SOAK_SECS" -gt 0 ] || return 0
  while [ "$elapsed" -lt "$SOAK_SECS" ]; do
    slice_log "$1" "$2" "$slice"
    if grep -q 'demote in place\|remux demoted' "$slice"; then
      printf "\n"
      infra "the AVPlayer session was demoted to libmpv DURING the soak, so the battery
        would have probed a dead HLS server.
        marker: $(grep 'demote in place\|remux demoted' "$slice" | tail -1)"
    fi
    printf "\r[live-auto] streaming before probe ... %ds/%ds (segments published: %s)   " \
      "$elapsed" "$SOAK_SECS" "$(grep -c 'hls media segment .* published' "$slice" || true)"
    sleep 1
    elapsed=$((elapsed + 1))
  done
  printf "\n"
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
    local ip port
    ip="$(lan_address)"
    port="$(start_fixture_server)"
    url="http://$ip:$port/$FIXTURE_NAME"
    echo "[$tag] serving fixture at $url (bound 0.0.0.0:$port, non-loopback host $ip)"
    verify_range "$url"
    # Derive the soak only for the normal mode; starve mode never gets that far.
    if [ "$MODE_STARVE" != "1" ] && [ -z "$SOAK_SECS" ]; then
      SOAK_SECS="$(derive_soak)"
    fi
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

    # Re-slice so the gate sees every line up to this instant, then run the battery.
    slice_log "$log" "$offset" "$slice"
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
