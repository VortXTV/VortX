#!/usr/bin/env bash
# =============================================================================
# run-conformance.sh — build + drive the player-rework acceptance harness.
#
# The harness verifies the local HLS server's RUNTIME behaviour against the
# REQ-260722-09 + REQ-260722-04 contract (7 points). It reads the server's own
# request log (Caches/diagnostics.log) the way the overnight run did, and — while
# a plain-remux MKV is playing — fetches playlists + segments over the simulator's
# shared loopback. It NEVER asserts on player source text.
#
# Modes:
#   ./run-conformance.sh selftest         Validate the oracle only (no sim needed).
#   ./run-conformance.sh trace [logfile]  Evaluate points 1,3,4,6,7 from a captured
#                                          trace. Defaults to the booted sim's live
#                                          container log.
#   ./run-conformance.sh live [--spool D] Full 7-point battery; needs a plain-remux
#                                          playback LIVE on the sim.
#   ./run-conformance.sh all              build + selftest + trace (default).
#   ./run-conformance.sh app-build        (Re)build VortXTV into /tmp/dd-harness so
#                                          a fresh trace can be generated.
#
# Everything builds under the STABLE derived-data path /tmp/dd-harness — never a
# random per-run path — so incremental rebuilds are cheap and reproducible.
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
      echo "[trace] no container log yet — play a plain MKV, then re-run: ./run-conformance.sh trace"
    fi ;;
  *)
    echo "usage: $0 [selftest|trace [logfile]|live [--spool D]|app-build|all]" >&2; exit 2 ;;
esac
