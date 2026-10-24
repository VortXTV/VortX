#!/usr/bin/env bash
set -euo pipefail
# Source-only fixtures: no installed/live account, network, device or application launch.
# Default proof lanes: strict6 reader, then warnings-as-errors Swift5 full actual engine.
# Optional strict6 engine mode is diagnostic preparation, not a promised migration pass.
watched_project_root=${1:-"$PWD"}
watched_candidate_root=${2:-"$watched_project_root"}
watched_engine_lane="${VORTX_WATCHED_ENGINE_LANE:-swift5}"
case "$watched_engine_lane" in
  swift5) engine_mode_flags=(-swift-version 5 -warnings-as-errors) ;;
  strict6) engine_mode_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors) ;;
  *) echo "Unsupported engine proof lane: $watched_engine_lane" >&2; exit 2 ;;
esac
watched_script_path="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
cd "$watched_project_root"
repo_root="$PWD"
node_bin="${VORTX_WATCHED_NODE:-$(command -v node)}"
swift_bin="${VORTX_WATCHED_SWIFTC:-$(xcrun --find swiftc)}"
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
host_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) echo "Unsupported host architecture: $host_arch" >&2; exit 2 ;; esac
# Explicit project Mac floor: never infer a host-beta deployment target newer than this SDK.
host_target="$host_arch-apple-macosx14.0"
command -v rg >/dev/null
test -x "$node_bin"
test -x "$swift_bin"
test -f app/SourcesShared/TraktModels.swift
test -f "$watched_candidate_root/app/SourcesShared/TraktSyncEngine.swift"
supervisor="$repo_root/test/mpv-bounded-child.mjs"
expected_supervisor_sha=c83153feedd91bee93000305604d68772d4b7164716749f0a04605bbb2253f62
observed_supervisor_sha="$(shasum -a 256 "$supervisor")"
observed_supervisor_sha="${observed_supervisor_sha%% *}"
if [[ "$observed_supervisor_sha" != "$expected_supervisor_sha" ]]; then
  echo "Bounded-child helper changed; review and repin before running." >&2
  exit 90
fi
mkdir -p "$repo_root/app/build"

# Same reviewed supervisor/INT/TERM/re-wait protocol as test-mpv-preview-wakeup-adapter.sh.
# Async launch plus immediate wait permits forwarding; it never opens a parallel test lane.
# Root still allocates the global resource lane. This suite-specific slot only rejects duplicates.
slot_dir="$repo_root/app/build/.trakt-watched-snapshot.slot"
if ! mkdir "$slot_dir" 2>/dev/null; then
  echo "Trakt watched serial slot is occupied: $slot_dir" >&2
  echo "Do not delete an active slot; reconcile a stale slot explicitly." >&2
  exit 2
fi
active_pid=""
active_receipt=""
slot_releasable=1
interruption_status=0
interruption_signal=""
wait_interrupted=0

signal_supervisor() {
  local signal="$1"
  if [[ "$slot_releasable" -eq 0 && -n "$active_receipt" ]]; then
    # Publish before readiness check so a signal during Node startup cannot disappear.
    if ! : > "$active_receipt.cancel-$signal"; then
      echo "Cannot persist cancellation request for $active_receipt; cleanup must be reconciled." >&2
    fi
    if [[ -n "$active_pid" && -f "$active_receipt.active" ]]; then
      kill "-$signal" "$active_pid" 2>/dev/null || true
    fi
  fi
}
request_interrupt() {
  local signal="$1"
  local status="$2"
  if [[ "$interruption_status" -eq 0 ]]; then
    interruption_status="$status"
    interruption_signal="$signal"
  fi
  wait_interrupted=1
  signal_supervisor "$interruption_signal"
  # No exit/slot release here: supervisor must terminate and reap the owned child group.
}
trap 'request_interrupt INT 130' INT
trap 'request_interrupt TERM 143' TERM

wait_supervisor() {
  local status=0
  while :; do
    wait_interrupted=0
    status=0
    wait "$active_pid" || status=$?
    if [[ "$wait_interrupted" -eq 0 ]]; then break; fi
  done
  active_pid=""
  # A normal leader exit is insufficient. The receipt and a fresh group probe must confirm cleanup.
  if ! nice -n 15 "$node_bin" "$supervisor" check "$active_receipt" "$status"; then
    slot_releasable=0
    return 125
  fi
  slot_releasable=1
  return "$status"
}
release_slot() {
  local saved_status=$?
  trap - EXIT
  set +e
  if [[ -n "$active_pid" ]]; then
    signal_supervisor "${interruption_signal:-TERM}"
    wait_supervisor
  fi
  if [[ "$slot_releasable" -eq 1 && -z "$active_pid" ]]; then
    rmdir "$slot_dir" 2>/dev/null || true
  else
    echo "SERIAL SLOT RETAINED: cleanup is unconfirmed; reconcile $active_receipt and $slot_dir" >&2
  fi
  if [[ "$interruption_status" -ne 0 ]]; then exit "$interruption_status"; fi
  exit "$saved_status"
}
trap release_slot EXIT

stop_if_interrupted() {
  if [[ "$interruption_status" -ne 0 ]]; then exit "$interruption_status"; fi
}
bounded_run() {
  local seconds="$1"
  active_receipt="$2"
  shift 2
  stop_if_interrupted
  slot_releasable=0
  nice -n 15 env OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 \
    TMPDIR="$run_dir/tmp" CLANG_MODULE_CACHE_PATH="$run_dir/module-cache" \
    SWIFT_MODULE_CACHE_PATH="$run_dir/module-cache" \
    "$node_bin" "$supervisor" run "$seconds" "$active_receipt" -- "$@" &
  active_pid=$!
  if [[ "$interruption_status" -ne 0 ]]; then
    signal_supervisor "$interruption_signal"
  fi
  wait_supervisor
}
normal_exit_receipt() {
  nice -n 15 "$node_bin" "$supervisor" check "$1" "$2" normal-exit
}
verify_inputs() {
  shasum -a 256 --check "$run_dir/inputs.sha256"
}
run_component() {
  local name="$1"
  local seconds="$2"
  shift 2
  local status=0
  stop_if_interrupted
  verify_inputs || return 90
  bounded_run "$seconds" "$run_dir/$name.supervisor.json" "$@" \
    > "$run_dir/$name.log" 2>&1 || status=$?
  printf '%s\n' "$status" > "$run_dir/$name.status"
  # Input drift cannot be legitimized by a compiler failure, timeout or successful child exit.
  verify_inputs || return 90
  stop_if_interrupted
  if [[ "$status" -eq 0 ]]; then
    normal_exit_receipt "$run_dir/$name.supervisor.json" 0 || return 125
  fi
  return "$status"
}

stop_if_interrupted
run_dir="$(mktemp -d "$repo_root/app/build/trakt-watched-pagination.XXXXXX")"
mkdir "$run_dir/tmp" "$run_dir/module-cache"
printf 'Retained watched fixture %s\n' "$run_dir"
watched_reader="$watched_candidate_root/app/SourcesShared/TraktWatchedSnapshotReader.swift"
watched_cases="$watched_candidate_root/app/Tests/TraktWatchedSnapshotReaderTests.swift"
watched_engine="$watched_candidate_root/app/SourcesShared/TraktSyncEngine.swift"
watched_access="$watched_candidate_root/app/Tests/TraktWatchedEngineTestAccess.swift"
watched_fixtures="$watched_candidate_root/app/Tests/TraktWatchedEngineFixtures.swift"
watched_archive="$watched_candidate_root/app/SourcesShared/VortxNativeBootstrapArchive.swift"
watched_envelope="$watched_candidate_root/app/SourcesShared/TraktSyncSnapshotEnvelope.swift"
{
  sed '' "$watched_engine"
  printf '\n'
  sed '' "$watched_access"
} > "$run_dir/TraktSyncEngine.swift"
# Actual session identity and synchronous boundary declarations; no OAuth/Keychain runtime.
awk '/^\/\/\/ FIFO for Trakt/{exit} {print}' app/SourcesShared/TraktScrobbleProgressPolicy.swift \
  > "$run_dir/TraktSessionBoundary.swift"
test "$(rg -c '^struct TraktSessionID:' "$run_dir/TraktSessionBoundary.swift")" = 1
test "$(rg -c '^enum TraktAuthBoundary' "$run_dir/TraktSessionBoundary.swift")" = 1

# Compile CoreModels' actual Sendable parser handles, preserving its thread-private legacy
# formatter implementation. Retain the old fresh-instance OAuth donor as a separately pinned
# historical oracle, not as a replacement for the production parsing code.
formatter_donor="$repo_root/app/Tests/TraktOAuthBrokerContractTests.swift"
formatter_actual="$repo_root/app/SourcesShared/CoreModels.swift"
extract_formatter_extension() {
  awk '
    BEGIN { count = 0; closed = 0; emit = 0 }
    /^extension ISO8601DateFormatter \{$/ { count++; emit = 1 }
    emit { print }
    emit && /^\}$/ { emit = 0; closed++ }
    END { if (count != 1 || closed != 1) exit 2 }
  ' "$1"
}
extract_formatter_extension "$formatter_actual" > "$run_dir/CoreModelsEPGFormatter.actual.swift"
extract_formatter_extension "$formatter_donor" > "$run_dir/TraktEPGFormatter.donor.swift"
{
  printf 'import Foundation\n\n'
  sed '' "$run_dir/CoreModelsEPGFormatter.actual.swift"
} > "$run_dir/TraktEPGFormatter.swift"
printf '%s  %s\n' \
  b620fb48849415ca6bd2d888e7bc33ceea7fc03d1e141855c9976b791f48126e "$run_dir/CoreModelsEPGFormatter.actual.swift" \
  6de164e822df8c8feebf9ac67d2d2ceeb6f6fceac414401ed8fb735afbe5d38a "$run_dir/TraktEPGFormatter.donor.swift" \
  5a2b08a30e624f9bd1fabe438141113c930e7400840d7e906c77e8a19fcca9e3 "$run_dir/TraktEPGFormatter.swift" \
  > "$run_dir/formatter-extraction.sha256"
shasum -a 256 --check "$run_dir/formatter-extraction.sha256"
inputs=("$watched_script_path" "$supervisor" "$watched_reader" "$watched_cases" "$watched_engine"
  "$watched_access" "$watched_fixtures" "$watched_archive" "$watched_envelope"
  app/SourcesShared/WatchedFold.swift app/SourcesShared/TraktModels.swift
  app/SourcesShared/TraktScrobbleProgressPolicy.swift "$run_dir/TraktSyncEngine.swift"
  "$run_dir/TraktSessionBoundary.swift" "$formatter_actual" "$formatter_donor"
  "$run_dir/CoreModelsEPGFormatter.actual.swift" "$run_dir/TraktEPGFormatter.donor.swift"
  "$run_dir/TraktEPGFormatter.swift" "$run_dir/formatter-extraction.sha256")
shasum -a 256 "${inputs[@]}" > "$run_dir/inputs.sha256"
printf 'swift=%s\nnode=%s\nsdk=%s\nsdk_version=%s\ntarget=%s\n' \
  "$swift_bin" "$node_bin" "$host_sdk" "$host_sdk_version" "$host_target" > "$run_dir/toolchain.txt"
printf 'module_cache=%s\ntmpdir=%s\ncompiler_deadline_seconds=600\nruntime_deadline_seconds=120\n' \
  "$run_dir/module-cache" "$run_dir/tmp" >> "$run_dir/toolchain.txt"
printf 'engine_lane=%s\n' "$watched_engine_lane" >> "$run_dir/toolchain.txt"
shasum -a 256 "$swift_bin" "$node_bin" >> "$run_dir/toolchain.txt"

run_component swift-version 30 "$swift_bin" --version
run_component reader.compile 600 "$swift_bin" -parse-as-library \
  -sdk "$host_sdk" -target "$host_target" -module-cache-path "$run_dir/module-cache" \
  -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -whole-module-optimization -j 1 -num-threads 1 -D TRAKT_WATCHED_RAW_TESTS \
  "$watched_reader" "$watched_archive" app/SourcesShared/WatchedFold.swift \
  app/SourcesShared/TraktModels.swift "$run_dir/TraktSessionBoundary.swift" \
  "$run_dir/TraktEPGFormatter.swift" "$watched_cases" \
  -o "$run_dir/reader-tests"
run_component reader.runtime 120 "$run_dir/reader-tests"
expected_pass='PASS: Trakt watched complete-pagination, bounds, cursor and cancellation witnesses'
rg -Fxq -- "$expected_pass" "$run_dir/reader.runtime.log"
printf '%s\n' 'PASS: strict Swift6 reader/actual model/raw utility component lane only'

# Scoped locking removes async lock/unlock calls. Class-wide sendability remains separate;
# strict6 mode exposes that compiler gate without suppression or a fake expected-failure pass.
run_component engine.compile 600 "$swift_bin" -parse-as-library \
  -sdk "$host_sdk" -target "$host_target" -module-cache-path "$run_dir/module-cache" \
  "${engine_mode_flags[@]}" -D TRAKT_WATCHED_ENGINE_TESTS -D TRAKT_WATCHED_RAW_TESTS \
  -whole-module-optimization -j 1 -num-threads 1 \
  "$watched_reader" "$watched_archive" "$watched_envelope" \
  app/SourcesShared/WatchedFold.swift app/SourcesShared/TraktModels.swift \
  "$run_dir/TraktSessionBoundary.swift" "$run_dir/TraktEPGFormatter.swift" "$run_dir/TraktSyncEngine.swift" \
  "$watched_fixtures" "$watched_cases" -o "$run_dir/engine-tests"
run_component engine.runtime 120 "$run_dir/engine-tests"
rg -Fxq -- "$expected_pass" "$run_dir/engine.runtime.log"
stop_if_interrupted
verify_inputs
stop_if_interrupted
shasum -a 256 "$run_dir/inputs.sha256" "$run_dir/toolchain.txt" \
  "$run_dir/reader-tests" "$run_dir/engine-tests" \
  "$run_dir/swift-version.supervisor.json" \
  "$run_dir/reader.compile.supervisor.json" "$run_dir/reader.runtime.supervisor.json" \
  "$run_dir/engine.compile.supervisor.json" "$run_dir/engine.runtime.supervisor.json" \
  > "$run_dir/final-receipt.sha256"
stop_if_interrupted
printf 'PASS: %s full actual engine transaction fixtures with warnings-as-errors; not app/device/provider proof\n' \
  "$watched_engine_lane"
