#!/usr/bin/env bash
# Runtime conformance driver for the local HLS player path.
set -euo pipefail

UDID="${VORTX_SIM_UDID:-}"
BUNDLE_ID="${VORTX_BUNDLE_ID:-com.stremiox.tv}"
SCHEME="${VORTX_SCHEME:-VortXTV}"
DD="/tmp/dd-harness"
BIN="$DD/bin/player-conformance"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
POLICY="$REPO/app/Sources/Player/DVPlaybackPolicy.swift"
NORMAL_FIXTURE="$HERE/fixtures/post-rework-normal.trace.txt"
TIMEOUT_FIXTURE="$HERE/fixtures/forced-timeout.trace.txt"

FIXTURE_DIR="${VORTX_FIXTURE_DIR:-$DD/fixtures}"
FIXTURE_SECS="${VORTX_FIXTURE_SECS:-420}"
FIXTURE_GOP_SECS=6
FIXTURE_FPS=24
FIXTURE_VBITRATE=5000k
FIXTURE_SIZE=1280x720
FIXTURE_RATE_PERCENT="${VORTX_FIXTURE_RATE_PERCENT:-150}"
FIXTURE_NAME="conformance-gop${FIXTURE_GOP_SECS}s-${FIXTURE_SECS}s-2aac-eng-spa.mkv"
FIXTURE="$FIXTURE_DIR/$FIXTURE_NAME"
READY_TIMEOUT="${VORTX_READY_TIMEOUT:-90}"
SLIDE_TIMEOUT="${VORTX_SLIDE_TIMEOUT:-240}"
PROVENANCE_TIMEOUT="${VORTX_PROVENANCE_TIMEOUT:-45}"
STARVE_FACTOR="${VORTX_STARVE_FACTOR:-4}"
STARVE_TIMEOUT="${VORTX_STARVE_TIMEOUT:-180}"

contract_int() {
  sed -n "s/.*static let $1 = \([0-9_]*\).*/\1/p" "$HERE/Contract.swift" | head -1 | tr -d '_'
}
contract_str() {
  sed -n "s/.*static let $1 = \"\([^\"]*\)\".*/\1/p" "$HERE/Contract.swift" | head -1
}
MIN_STARTUP_MS="$(contract_int minStartupMs)"
MIN_STARTUP_SEGS="$(contract_int minStartupSegments)"
SLO_MOUNT_READY_MS="$(contract_int sloMountToReadyMs)"

build_harness() {
  mkdir -p "$DD/bin"
  echo "[build] swiftc -> $BIN"
  swiftc -O -o "$BIN" \
    "$HERE/Contract.swift" "$HERE/HLSWindow.swift" "$HERE/Playlist.swift" \
    "$HERE/FMP4.swift" "$HERE/FMP4Fixtures.swift" "$HERE/Trace.swift" \
    "$HERE/Live.swift" "$HERE/main.swift" "$POLICY"
}

assert_fixtures() {
  "$BIN" fixture-assert "$NORMAL_FIXTURE" "$TIMEOUT_FIXTURE"
}

run_production_contract() {
  local contract_bin="$DD/bin/player-live-contract"
  local mutant_source="$DD/bin/VortXRemuxBuffer-cap-mutant.swift"
  local mutant_bin="$DD/bin/player-live-contract-cap-mutant"
  local mutant_log="$DD/last-production-spool-mutant.log" mutant_rc
  local capacity_line='static let defaultCapacityBytes = 512 * 1024 * 1024'
  echo "[production-contract] compiling the production spool and HLS seams"
  xcrun swiftc -strict-concurrency=complete -warnings-as-errors -o "$contract_bin" \
    "$REPO/app/Sources/Player/DVPlaybackPolicy.swift" \
    "$REPO/app/Sources/Player/VortXRemuxBuffer.swift" \
    "$REPO/app/Sources/Player/MultiAudioPolicy.swift" \
    "$REPO/app/Sources/Player/SubtitleRenditionPolicy.swift" \
    "$REPO/app/Tests/PlayerLiveContractTests.swift"
  "$contract_bin" --spool-only
  "$contract_bin" --multi-audio-tolerance-only
  [ "$(grep -Fc "$capacity_line" "$REPO/app/Sources/Player/VortXRemuxBuffer.swift")" = "1" ] \
    || { echo "[production-contract] expected one exact production capacity invariant" >&2; return 1; }
  cp "$REPO/app/Sources/Player/VortXRemuxBuffer.swift" "$mutant_source"
  perl -0pi -e \
    's/static let defaultCapacityBytes = 512 \* 1024 \* 1024/static let defaultCapacityBytes = 511 * 1024 * 1024/' \
    "$mutant_source"
  grep -Fq 'static let defaultCapacityBytes = 511 * 1024 * 1024' "$mutant_source" \
    || { echo "[production-contract] failed to construct the exact temporary capacity mutant" >&2; return 1; }
  xcrun swiftc -strict-concurrency=complete -warnings-as-errors -o "$mutant_bin" \
    "$REPO/app/Sources/Player/DVPlaybackPolicy.swift" \
    "$mutant_source" \
    "$REPO/app/Sources/Player/MultiAudioPolicy.swift" \
    "$REPO/app/Sources/Player/SubtitleRenditionPolicy.swift" \
    "$REPO/app/Tests/PlayerLiveContractTests.swift"
  set +e
  "$mutant_bin" --spool-only > "$mutant_log" 2>&1
  mutant_rc=$?
  set -e
  if [ "$mutant_rc" != "1" ] \
      || ! grep -Fq 'FAIL  spool production: the default session admission cap is exactly 512 MiB' "$mutant_log"; then
    cat "$mutant_log" >&2
    echo "[production-contract] real broken-cap source mutant escaped with exit $mutant_rc" >&2
    return 1
  fi
  echo "[production-contract] PASS: real 511 MiB source mutant compiled and returned assertion-red exit 1"
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
    startup-readiness-or
    startup-minimality-disabled
  )
  local mutant rc failed=0
  for mutant in "${mutants[@]}"; do
    echo ""
    echo "[mutant] $mutant: selftest must turn RED"
    set +e
    "$BIN" selftest --mutant "$mutant"
    rc=$?
    set -e
    if [ "$rc" = "1" ]; then
      echo "[mutant] PASS: $mutant was killed"
    else
      echo "[mutant] FAIL: $mutant escaped with exit $rc" >&2
      failed=1
    fi
  done
  [ "$failed" = "0" ] || return 1
  echo "[mutant] ALL 11 LOAD-BEARING MUTANTS KILLED"
}

app_container() {
  xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null
}

app_build() {
  require_sim_udid
  command -v xcodegen >/dev/null || { echo "xcodegen not found" >&2; exit 1; }
  ( cd "$REPO/app" && xcodegen generate )
  xcodebuild -project "$REPO/app/VortX.xcodeproj" -scheme "$SCHEME" \
    -destination "id=$UDID" -derivedDataPath "$DD" -configuration Debug build
  xcrun simctl install "$UDID" "$DD/Build/Products/Debug-appletvsimulator/$SCHEME.app"
  xcodebuild -project "$REPO/app/VortX.xcodeproj" -scheme "$SCHEME" \
    -destination "id=$UDID" -derivedDataPath "$DD" -configuration Release \
    ONLY_ACTIVE_ARCH=YES ARCHS=arm64 EXCLUDED_ARCHS=x86_64 build
  local release_binary="$DD/Build/Products/Release-appletvsimulator/$SCHEME.app/$SCHEME"
  [ -f "$release_binary" ] || { echo "Release executable is missing: $release_binary" >&2; return 1; }
  if strings "$release_binary" \
      | grep -E 'VORTX_DEBUG_PLAY_URL|debug-play accept|DebugPlaybackHook' >/dev/null; then
    echo "Release executable contains DEBUG playback-hook markers" >&2
    return 1
  fi
  echo "[app-build] Release exclusion PASS: no DEBUG hook marker in $release_binary"
}

SERVER_PID=""
FIXTURE_PORT=""
WORK=""
APP_LAUNCHED=0
MODE_STARVE=0
CONTAINER=""
RUN_RECEIPT=""
SOURCE_TOKEN=""
HLS_PORT=""

infra() {
  echo "" >&2
  echo "[INFRA] $*" >&2
  echo "[INFRA] exit 3: the requested observation did not complete." >&2
  exit 3
}

require_sim_udid() {
  [ -n "$UDID" ] \
    || infra "VORTX_SIM_UDID must name the dedicated booted tvOS simulator"
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
  if [ -n "$WORK" ] && [[ "$WORK" == /tmp/live-auto.* ]] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
  exit "$rc"
}

app_alive() {
  if pgrep -f "$SCHEME.app/$SCHEME" >/dev/null 2>&1; then echo YES; else echo NO; fi
}

server_alive() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then echo YES; else echo NO; fi
}

require_positive_integer() {
  local name="$1" number="$2"
  [[ "$number" =~ ^[1-9][0-9]*$ ]] \
    || { echo "$name must be a positive integer, got '$number'" >&2; exit 2; }
  [ "${#number}" -le 10 ] && [ "$number" -le 2147483647 ] \
    || { echo "$name is outside 1...2147483647" >&2; exit 2; }
}

preflight() {
  require_sim_udid
  xcrun simctl list devices booted 2>/dev/null | grep -q "$UDID" \
    || infra "simulator $UDID is not booted"
  CONTAINER="$(app_container)" || infra "$BUNDLE_ID is not installed on $UDID"
  [ -d "$CONTAINER" ] || infra "resolved app container is not a directory: $CONTAINER"
  command -v ffmpeg >/dev/null || infra "ffmpeg not found"
  command -v ffprobe >/dev/null || infra "ffprobe not found"
  command -v python3 >/dev/null || infra "python3 not found"
  if pgrep -f "$HERE/range-server.py" >/dev/null 2>&1; then
    echo "[live-auto] stopping leaked fixture servers from earlier runs"
    pkill -f "$HERE/range-server.py" || true
  fi
}

validate_fixture() {
  [ -s "$FIXTURE" ] || return 1
  ffprobe -v error -show_streams -show_format -of json "$FIXTURE" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    document = json.load(sys.stdin)
    streams = document["streams"]
    expected_duration = float(sys.argv[1])
except Exception:
    raise SystemExit(1)
if len(streams) != 3:
    raise SystemExit(1)
video = [stream for stream in streams if stream.get("codec_type") == "video"]
audio = [stream for stream in streams if stream.get("codec_type") == "audio"]
if len(video) != 1 or len(audio) != 2:
    raise SystemExit(1)
v = video[0]
video_ok = (
    v.get("codec_name") == "h264"
    and v.get("width") == 1280
    and v.get("height") == 720
    and v.get("pix_fmt") == "yuv420p"
    and v.get("avg_frame_rate") == "24/1"
)
languages = [(stream.get("tags") or {}).get("language", "").lower() for stream in audio]
defaults = [int((stream.get("disposition") or {}).get("default", 0)) for stream in audio]
codecs = [stream.get("codec_name") for stream in audio]
channels = [stream.get("channels") for stream in audio]
sample_rates = [stream.get("sample_rate") for stream in audio]
try:
    duration = float(document["format"]["duration"])
except Exception:
    raise SystemExit(1)
audio_ok = (
    codecs == ["aac", "aac"]
    and languages == ["eng", "spa"]
    and defaults == [1, 0]
    and channels == [2, 2]
    and sample_rates == ["48000", "48000"]
)
ok = video_ok and audio_ok and abs(duration - expected_duration) <= 0.100
raise SystemExit(0 if ok else 1)
' "$FIXTURE_SECS" || return 1

  ffprobe -v error -select_streams v:0 -skip_frame nokey \
    -show_entries frame=best_effort_timestamp_time,key_frame -of csv=p=0 "$FIXTURE" 2>/dev/null \
    | python3 -c '
import csv, sys
rows = []
try:
    for row in csv.reader(sys.stdin):
        if len(row) >= 2 and row[0] == "1":
            rows.append(float(row[1]))
except Exception:
    raise SystemExit(1)
duration = int(sys.argv[1])
expected = [float(value) for value in range(0, duration, 6)]
ok = len(rows) == len(expected) and all(abs(a - b) <= 0.050 for a, b in zip(rows, expected))
raise SystemExit(0 if ok else 1)
' "$FIXTURE_SECS"
}

make_fixture() {
  mkdir -p "$FIXTURE_DIR"
  if validate_fixture; then
    echo "[live-auto] validated cached two-AAC fixture: $FIXTURE"
    return 0
  fi
  if [ -e "$FIXTURE" ]; then rm -f "$FIXTURE"; fi
  echo "[live-auto] generating H.264 plus primary eng AAC plus alternate spa AAC"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=$FIXTURE_SIZE:rate=$FIXTURE_FPS:duration=$FIXTURE_SECS" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$FIXTURE_SECS" \
    -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=$FIXTURE_SECS" \
    -map 0:v:0 -map 1:a:0 -map 2:a:0 \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v "$FIXTURE_VBITRATE" \
    -g $((FIXTURE_FPS * FIXTURE_GOP_SECS)) \
    -keyint_min $((FIXTURE_FPS * FIXTURE_GOP_SECS)) -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*$FIXTURE_GOP_SECS)" \
    -c:a aac -b:a 128k -ac 2 \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title=English \
    -metadata:s:a:1 language=spa -metadata:s:a:1 title=Spanish \
    -disposition:a:0 default -disposition:a:1 0 \
    -f matroska "$FIXTURE" \
    || infra "ffmpeg failed to generate the fixture"
  validate_fixture || infra "fixture validation failed: expected exact H.264/24fps/6s-GOP/420s plus AAC eng/spa topology"
  echo "[live-auto] fixture validated: $(wc -c < "$FIXTURE" | tr -d ' ') bytes"
}

lan_address() {
  local address
  address="$(ipconfig getifaddr en0 2>/dev/null || true)"
  [ -n "$address" ] || address="$(ipconfig getifaddr en1 2>/dev/null || true)"
  [ -n "$address" ] || infra "no non-loopback LAN address on en0/en1"
  echo "$address"
}

start_fixture_server() {
  local portfile="$WORK/port" bytes rate
  bytes="$(wc -c < "$FIXTURE" | tr -d ' ')"
  if [ "$MODE_STARVE" = "1" ]; then
    rate=$(( bytes / FIXTURE_SECS * MIN_STARTUP_MS / (STARVE_FACTOR * SLO_MOUNT_READY_MS) ))
    [ "$rate" -gt 0 ] || rate=1
    echo "[starve] rate=${rate}B/s: ${MIN_STARTUP_MS}ms of media takes $((STARVE_FACTOR * SLO_MOUNT_READY_MS / 1000))s"
  else
    rate=$(( bytes / FIXTURE_SECS * FIXTURE_RATE_PERCENT / 100 ))
    [ "$rate" -gt 0 ] || rate=1
    echo "[live-auto] delivery=${FIXTURE_RATE_PERCENT}% of measured fixture bitrate (${rate}B/s)"
  fi
  python3 "$HERE/range-server.py" "$FIXTURE" "$portfile" 0.0.0.0 "$rate" \
    >"$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  local waited=0
  while [ ! -s "$portfile" ]; do
    kill -0 "$SERVER_PID" 2>/dev/null || infra "fixture server died: $(cat "$WORK/server.log")"
    sleep 0.2
    waited=$((waited + 1))
    [ "$waited" -lt 50 ] || infra "fixture server did not report a port"
  done
  FIXTURE_PORT="$(cat "$portfile")"
}

verify_range() {
  local url="$1" headers size
  headers="$(curl -sS -o /dev/null -D - -r 0-99 --max-time 10 "$url" 2>&1)" \
    || infra "fixture server is unreachable at $url"
  size="$(wc -c < "$FIXTURE" | tr -d ' ')"
  grep -qi '^HTTP/1.1 206' <<<"$headers" || infra "fixture server did not return HTTP 206"
  grep -qi "^Content-Range: bytes 0-99/$size" <<<"$headers" \
    || infra "fixture server returned the wrong Content-Range"
}

slice_log() {
  if [ -f "$1" ]; then
    tail -c "+$(( $2 + 1 ))" "$1" > "$3" 2>/dev/null || : > "$3"
  else
    : > "$3"
  fi
}

slice_window() {
  local count=$(( $3 - $2 ))
  if [ -f "$1" ] && [ "$count" -gt 0 ]; then
    set +o pipefail
    tail -c "+$(( $2 + 1 ))" "$1" 2>/dev/null | head -c "$count" > "$4"
    set -o pipefail
  else
    : > "$4"
  fi
}

wait_for_provenance() {
  local log="$1" offset="$2" slice="$3" elapsed=0
  local accept_line route_line server_line mount_line
  local accept_count route_count server_count mount_count
  while [ "$elapsed" -lt "$PROVENANCE_TIMEOUT" ]; do
    slice_log "$log" "$offset" "$slice"
    if grep -Fq "debug-play reject trigger=env run=$RUN_RECEIPT " "$slice"; then
      echo "[live-auto] product RED: DEBUG hook rejected the generated source" >&2
      return 1
    fi

    accept_count="$(grep -Fc "debug-play accept trigger=env run=$RUN_RECEIPT " "$slice" || true)"
    if [ "$accept_count" -gt 1 ]; then
      echo "[live-auto] product RED: run receipt has $accept_count hook accepts" >&2
      return 1
    fi
    if [ "$accept_count" = "1" ]; then
      accept_line="$(grep -Fn "debug-play accept trigger=env run=$RUN_RECEIPT " "$slice" | cut -d: -f1)"
      SOURCE_TOKEN="$(sed -n "s/.*debug-play accept trigger=env run=$RUN_RECEIPT token=\([^ ]*\) engineOverride=avfoundation dvRemuxHLS=true plainRemux=true startFromZero=true.*/\1/p" "$slice")"
      if [ -z "$SOURCE_TOKEN" ]; then
        echo "[live-auto] product RED: accept receipt is malformed or does not prove all pinned controls" >&2
        return 1
      fi
      route_count="$(grep -F "route file=$SOURCE_TOKEN " "$slice" \
        | grep -Fc -- '-> engine=avfoundation' || true)"
      server_count="$(grep -c 'hls server listening on 127\.0\.0\.1:[0-9][0-9]*' "$slice" || true)"
      mount_count="$(grep -c 'plain-remux mount (local HLS).*127\.0\.0\.1:[0-9][0-9]*' "$slice" || true)"
      if [ "$route_count" -gt 1 ] || [ "$server_count" -gt 1 ] || [ "$mount_count" -gt 1 ]; then
        echo "[live-auto] product RED: ambiguous route/server/mount generation" >&2
        return 1
      fi
      if [ "$route_count" = "1" ] && [ "$server_count" = "1" ] && [ "$mount_count" = "1" ]; then
        route_line="$(grep -Fn "route file=$SOURCE_TOKEN " "$slice" \
          | grep -- '-> engine=avfoundation' | cut -d: -f1)"
        server_line="$(grep -n 'hls server listening on 127\.0\.0\.1:[0-9][0-9]*' "$slice" | cut -d: -f1)"
        mount_line="$(grep -n 'plain-remux mount (local HLS).*127\.0\.0\.1:[0-9][0-9]*' "$slice" | cut -d: -f1)"
        HLS_PORT="$(grep 'hls server listening on 127\.0\.0\.1:' "$slice" \
          | sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p')"
        local mount_port
        mount_port="$(grep 'plain-remux mount (local HLS)' "$slice" \
          | sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p')"
        if [ "$accept_line" -lt "$route_line" ] \
            && [ "$route_line" -lt "$server_line" ] \
            && [ "$server_line" -le "$mount_line" ] \
            && [ -n "$HLS_PORT" ] && [ "$HLS_PORT" = "$mount_port" ]; then
          {
            echo "provenance status=PASS"
            echo "run=$RUN_RECEIPT"
            echo "token=$SOURCE_TOKEN"
            echo "port=$HLS_PORT"
            echo "line-order=$accept_line,$route_line,$server_line,$mount_line"
          } > "$WORK/provenance.receipt"
          echo "[live-auto] provenance PASS run=$RUN_RECEIPT token=$SOURCE_TOKEN port=$HLS_PORT order=$accept_line,$route_line,$server_line,$mount_line"
          return 0
        fi
        echo "[live-auto] product RED: accept, matching route, server, and mount are not one ordered generation" >&2
        return 1
      fi
      if grep -q 'route file=.*-> engine=libmpv' "$slice" \
          || grep -q 'demote.*in place\|remux demoted\|mount build failed' "$slice"; then
        echo "[live-auto] product RED: accepted source did not reach the required AVFoundation remux mount" >&2
        return 1
      fi
    fi
    printf '\r[live-auto] waiting for accept -> route -> mount ... %ds/%ds   ' \
      "$elapsed" "$PROVENANCE_TIMEOUT"
    sleep 1
    elapsed=$((elapsed + 1))
  done
  printf '\n'
  slice_log "$log" "$offset" "$slice"
  if ! grep -q '\[debughook\]' "$slice"; then
    infra "installed Debug app emitted no playback-hook marker"
  fi
  echo "[live-auto] product RED: hook exists but one correlated accept -> route -> mount chain did not complete" >&2
  return 1
}

wait_for_ready() {
  local log="$1" offset="$2" slice="$3" elapsed=0
  while [ "$elapsed" -lt "$READY_TIMEOUT" ]; do
    slice_log "$log" "$offset" "$slice"
    if grep -q 'demote.*in place\|remux demoted\|mount build failed' "$slice"; then
      echo "[live-auto] product RED: normal session demoted before ready" >&2
      return 1
    fi
    if grep -q 'readyToPlay -> play' "$slice"; then
      echo "[live-auto] readyToPlay after ${elapsed}s"
      return 0
    fi
    if [ "$(app_alive)" = "NO" ]; then
      echo "[live-auto] product RED: app exited after the accepted mount" >&2
      return 1
    fi
    printf '\r[live-auto] waiting for ready ... %ds/%ds   ' "$elapsed" "$READY_TIMEOUT"
    sleep 1
    elapsed=$((elapsed + 1))
  done
  printf '\n'
  echo "[live-auto] product RED: playback did not reach readyToPlay in ${READY_TIMEOUT}s" >&2
  return 1
}

starve_wait() {
  local log="$1" offset="$2" slice="$3" elapsed=0 event events
  event="$(contract_str cohortTimeoutEvent)"
  while [ "$elapsed" -lt "$STARVE_TIMEOUT" ]; do
    slice_log "$log" "$offset" "$slice"
    if grep -q 'readyToPlay -> play' "$slice"; then
      echo "[starve] readyToPlay appeared; the point7-only oracle will reject this run"
      return 1
    fi
    if grep -q 'demote.*in place\|remux demoted\|mount build failed' "$slice"; then
      echo "[starve] product RED: another watchdog preempted the required point7 timeout tuple"
      return 1
    fi
    if [ "$(app_alive)" = "NO" ]; then
      echo "[starve] product RED: app exited before the required point7 timeout tuple"
      return 1
    fi
    events="$(grep -c "$event" "$slice" || true)"
    if [ "${events:-0}" -gt 1 ]; then
      echo "[starve] duplicate timeout events observed"
      return 0
    fi
    if [ "${events:-0}" = "1" ] && grep -q 'hls 404 /master\.m3u8' "$slice"; then
      echo "[starve] complete event + /master 404 tuple observed"
      return 0
    fi
    printf '\r[starve] waiting for complete point7 tuple ... %ds/%ds (events=%s)   ' \
      "$elapsed" "$STARVE_TIMEOUT" "${events:-0}"
    sleep 1
    elapsed=$((elapsed + 1))
  done
  printf '\n'
  echo "[starve] terminal tuple did not complete; point7-only oracle will reject this run"
  return 1
}

curl_complete() {
  local destination="$1" timeout="$2" url="$3" partial="${1}.partial.$$" status rc
  rm -f "$partial" "$destination"
  set +e
  status="$(curl -sS -o "$partial" -w '%{http_code}' --max-time "$timeout" "$url" 2>/dev/null)"
  rc=$?
  set -e
  CURL_RC="$rc"
  CURL_STATUS="${status:-000}"
  if [ "$rc" = "0" ]; then mv "$partial" "$destination"; else rm -f "$partial"; fi
}

synthetic_reader_until_sliding() {
  local log="$1" offset="$2" slice="$3" port elapsed=0 saw_zero=0 variant_uri
  local manifest="$WORK/reader-media.m3u8" uris="$WORK/reader-uris.txt"
  port="$HLS_PORT"
  variant_uri="$(awk '
    /^#EXT-X-STREAM-INF:/ { waiting=1; next }
    waiting && $0 !~ /^#/ && length($0)>0 { print; exit }
  ' "$WORK/startup/master.m3u8")"
  [ -n "$variant_uri" ] && [[ "$variant_uri" != */* ]] \
    || { echo "[live-auto] product RED: captured master has no flat variant URI"; return 1; }
  if grep -q "hls resp /$variant_uri seq=0 segs=" "$slice"; then saw_zero=1; fi

  while [ "$elapsed" -lt "$SLIDE_TIMEOUT" ]; do
    slice_log "$log" "$offset" "$slice"
    if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
      infra "fixture server died during the sliding-reader phase"
    fi
    grep -q 'live source read stalled' "$slice" \
      && { echo "[live-auto] product RED: source read stalled during sliding"; return 1; }
    grep -q 'demote.*in place\|remux demoted' "$slice" \
      && { echo "[live-auto] product RED: session demoted during sliding"; return 1; }
    [ "$(grep -c 'hls server listening on 127\.0\.0\.1:' "$slice" || true)" -le 1 ] \
      || { echo "[live-auto] product RED: session was superseded during sliding"; return 1; }

    curl_complete "$manifest" 8 "http://127.0.0.1:$port/$variant_uri"
    [ "$CURL_RC" = "0" ] \
      || { echo "[live-auto] product RED: reader manifest transport incomplete (rc=$CURL_RC)"; return 1; }
    [ "$CURL_STATUS" = "200" ] || { echo "[live-auto] manifest returned HTTP $CURL_STATUS"; return 1; }
    grep -q '^#EXT-X-PLAYLIST-TYPE:EVENT$' "$manifest" \
      && { echo "[live-auto] reader observed retired EVENT playlist"; return 1; }
    local sequence
    sequence="$(sed -n 's/^#EXT-X-MEDIA-SEQUENCE:\([0-9][0-9]*\)$/\1/p' "$manifest" | head -1)"
    [ -n "$sequence" ] || { echo "[live-auto] reader observed missing/invalid MEDIA-SEQUENCE"; return 1; }
    awk '/^#EXTINF:/{pending=1; next} pending && $0 !~ /^#/ && length($0)>0 {print; pending=0}' \
      "$manifest" > "$uris"
    [ -s "$uris" ] || { echo "[live-auto] reader observed no media URIs"; return 1; }

    local expected="$sequence" count=0 uri id
    while IFS= read -r uri; do
      case "$uri" in
        seg[0-9]*.m4s) ;;
        *) echo "[live-auto] reader observed non-production video URI: $uri"; return 1 ;;
      esac
      id="${uri#seg}"; id="${id%.m4s}"
      [ "$id" = "$expected" ] \
        || { echo "[live-auto] reader range mismatch: seq=$sequence expected=$expected URI=$uri"; return 1; }
      curl_complete "$WORK/reader-segment" 12 "http://127.0.0.1:$port/$uri"
      [ "$CURL_RC" = "0" ] \
        || { echo "[live-auto] product RED: incomplete response for advertised $uri"; return 1; }
      [ "$CURL_STATUS" = "200" ] \
        || { echo "[live-auto] advertised $uri returned complete HTTP $CURL_STATUS"; return 1; }
      expected=$((expected + 1))
      count=$((count + 1))
    done < "$uris"

    if [ "$sequence" = "0" ]; then saw_zero=1; fi
    if [ "$sequence" -gt 0 ] && [ "$saw_zero" = "1" ]; then
      echo "[live-auto] sliding window proven: seq=$sequence cardinality=$count, all actual URIs returned 200"
      return 0
    fi
    printf '\r[live-auto] driving exact advertised range ... %ds/%ds (seq=%s segs=%s)   ' \
      "$elapsed" "$SLIDE_TIMEOUT" "$sequence" "$count"
    sleep 1
    elapsed=$((elapsed + 1))
  done
  printf '\n'
  echo "[live-auto] product RED: playlist did not reach a valid nonzero MEDIA-SEQUENCE in ${SLIDE_TIMEOUT}s"
  return 1
}

wait_for_spool_cleanup() {
  local attempt=0 rc
  while [ "$attempt" -lt 20 ]; do
    set +e
    "$BIN" spool --container "$CONTAINER" --expect-empty >/dev/null
    rc=$?
    set -e
    [ "$rc" = "0" ] && return 0
    [ "$rc" = "2" ] && infra "whole-root cleanup inspection failed"
    sleep 0.5
    attempt=$((attempt + 1))
  done
  "$BIN" spool --container "$CONTAINER" --expect-empty || true
  return 1
}

live_auto() {
  local url_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --url) [ $# -ge 2 ] || exit 2; url_override="$2"; shift 2 ;;
      --timeout) [ $# -ge 2 ] || exit 2; require_positive_integer --timeout "$2"; READY_TIMEOUT="$2"; shift 2 ;;
      --starve) MODE_STARVE=1; shift ;;
      *) echo "unknown live-auto flag: $1" >&2; exit 2 ;;
    esac
  done
  require_positive_integer VORTX_READY_TIMEOUT "$READY_TIMEOUT"
  require_positive_integer VORTX_SLIDE_TIMEOUT "$SLIDE_TIMEOUT"
  require_positive_integer VORTX_PROVENANCE_TIMEOUT "$PROVENANCE_TIMEOUT"
  require_positive_integer VORTX_FIXTURE_SECS "$FIXTURE_SECS"
  require_positive_integer VORTX_FIXTURE_RATE_PERCENT "$FIXTURE_RATE_PERCENT"
  require_positive_integer VORTX_STARVE_FACTOR "$STARVE_FACTOR"
  require_positive_integer VORTX_STARVE_TIMEOUT "$STARVE_TIMEOUT"

  trap cleanup EXIT INT TERM
  WORK="$(mktemp -d /tmp/live-auto.XXXXXX)"
  preflight
  build_harness
  assert_fixtures

  local url tag=live-auto
  [ "$MODE_STARVE" = "1" ] && tag=starve
  if [ -n "$url_override" ]; then
    url="$url_override"
  else
    make_fixture
    start_fixture_server
    local address
    address="$(lan_address)"
    url="http://$address:$FIXTURE_PORT/$FIXTURE_NAME"
    verify_range "$url"
  fi

  local log="$CONTAINER/Library/Caches/diagnostics.log" offset=0 slice="$WORK/session.log"
  [ -f "$log" ] && offset="$(wc -c < "$log" | tr -d ' ')"
  echo "[$tag] container=$CONTAINER"
  echo "[$tag] log=$log offset=$offset"
  RUN_RECEIPT="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  SIMCTL_CHILD_VORTX_DEBUG_PLAY_URL="$url" \
  SIMCTL_CHILD_VORTX_DEBUG_PLAY_TITLE="Conformance Run" \
  SIMCTL_CHILD_VORTX_DEBUG_PLAY_RUN="$RUN_RECEIPT" \
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" \
    || infra "simctl launch failed"
  APP_LAUNCHED=1

  local rc=0
  if ! wait_for_provenance "$log" "$offset" "$slice"; then
    rc=1
  elif [ "$MODE_STARVE" = "1" ]; then
    local master_body="$WORK/starve-master.body" bytes=0 starve_wait_rc=0
    curl_complete "$master_body" "$STARVE_TIMEOUT" "http://127.0.0.1:$HLS_PORT/master.m3u8"
    [ -f "$master_body" ] && bytes="$(wc -c < "$master_body" | tr -d ' ')"
    if [ "$CURL_RC" != "0" ]; then
      echo "[starve] product RED: /master.m3u8 did not complete (curl rc=$CURL_RC)"
      rc=1
    elif [ "$CURL_STATUS" != "404" ] || [ "$bytes" != "0" ]; then
      echo "[starve] product RED: expected complete empty HTTP 404, got status=$CURL_STATUS bytes=$bytes"
      rc=1
    fi
    if ! starve_wait "$log" "$offset" "$slice"; then starve_wait_rc=1; fi
    slice_log "$log" "$offset" "$slice"
    echo "[harness] complete-http path=/master.m3u8 status=$CURL_STATUS bytes=$bytes curl_rc=$CURL_RC" \
      >> "$slice"
    cp "$slice" "$DD/last-starve-session.log"
    set +e
    "$BIN" trace "$slice" --only-point7
    local trace_rc=$?
    set -e
    [ "$trace_rc" = "0" ] && [ "$starve_wait_rc" = "0" ] || rc=1
  else
    if ! "$BIN" capture-startup --port "$HLS_PORT" --output "$WORK/startup"; then
      if [ -f "$WORK/startup/master.failed.m3u8" ]; then
        cp "$WORK/startup/master.failed.m3u8" "$DD/last-startup-master.m3u8"
        echo "[live-auto] preserved rejected master at $DD/last-startup-master.m3u8"
      fi
      echo "[live-auto] product RED: immutable sequence-zero startup capture failed"
      rc=1
    fi
    if [ "$rc" = "0" ] && ! wait_for_ready "$log" "$offset" "$slice"; then rc=1; fi
    if [ "$rc" = "0" ]; then
      slice_log "$log" "$offset" "$slice"
      local boundary trace="$WORK/product-session.log" reader_rc=0 retained_rc=0 live_rc=0
      boundary="$(wc -c < "$log" | tr -d ' ')"
      slice_window "$log" "$offset" "$boundary" "$trace"
      if [ ! -s "$trace" ]; then
        echo "[live-auto] product RED: product-only trace is empty"
        rc=1
      else
        cp "$trace" "$DD/last-session.log"
        if ! synthetic_reader_until_sliding "$log" "$offset" "$slice"; then reader_rc=1; fi
        if [ "$reader_rc" = "0" ]; then
          set +e
          "$BIN" verify-captured --port "$HLS_PORT" --capture "$WORK/startup" \
            --receipt "$WORK/retained.receipt"
          retained_rc=$?
          set -e
        else
          retained_rc=1
        fi
        set +e
        "$BIN" live --container "$CONTAINER" --port "$HLS_PORT" \
          --log "$DD/last-session.log" --startup "$WORK/startup" \
          --retained-receipt "$WORK/retained.receipt"
        live_rc=$?
        set -e
        if [ "$live_rc" = "3" ]; then
          infra "live oracle could not inspect the authoritative spool; app=$(app_alive) server=$(server_alive)"
        fi
        [ "$reader_rc" = "0" ] && [ "$retained_rc" = "0" ] && [ "$live_rc" = "0" ] || rc=1
      fi
    fi
  fi

  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  APP_LAUNCHED=0
  if ! wait_for_spool_cleanup; then
    echo "[$tag] point 5 RED: VortXHLS root did not reach zero bytes and zero active sessions"
    rc=1
  fi
  if [ "$MODE_STARVE" = "1" ]; then
    [ "$rc" = "0" ] \
      && echo "[starve] EXIT 0: point7 full tuple proven" \
      || echo "[starve] EXIT $rc: point7 full tuple not proven"
  fi
  exit "$rc"
}

MODE="${1:-all}"
case "$MODE" in
  selftest)
    build_harness
    "$BIN" selftest
    assert_fixtures
    run_production_contract ;;
  fixture-assert)
    build_harness
    assert_fixtures ;;
  media-fixture)
    command -v ffmpeg >/dev/null || infra "ffmpeg not found"
    command -v ffprobe >/dev/null || infra "ffprobe not found"
    command -v python3 >/dev/null || infra "python3 not found"
    make_fixture ;;
  mutants)
    build_harness
    run_mutants ;;
  production-contract)
    mkdir -p "$DD/bin"
    run_production_contract ;;
  trace)
    build_harness
    shift || true
    if [ $# -gt 0 ]; then
      "$BIN" trace "$@"
    else
      CONTAINER="$(app_container)" || infra "cannot resolve app container"
      "$BIN" trace "$CONTAINER/Library/Caches/diagnostics.log"
    fi ;;
  live)
    build_harness
    shift || true
    CONTAINER="$(app_container)" || infra "cannot resolve app container"
    echo "[live] container=$CONTAINER"
    "$BIN" live --container "$CONTAINER" "$@" ;;
  live-auto)
    shift || true
    live_auto "$@" ;;
  app-build)
    app_build ;;
  all)
    build_harness
    "$BIN" selftest
    assert_fixtures
    run_mutants
    run_production_contract ;;
  *)
    echo "usage: $0 {selftest|fixture-assert|media-fixture|mutants|production-contract|trace [log] [--only-point7]|live|live-auto [--starve]|app-build|all}" >&2
    exit 2 ;;
esac
