#!/usr/bin/env bash
# Actual private-storage source and disposable real-file fixture; no app/provider/account calls.
# Root coordinates this serial job with the workspace's shared build slot before invocation.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
node_bin="$(command -v node)"
swift_bin="$(xcrun --sdk macosx --find swiftc)"
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) echo "Unsupported host architecture: $host_arch" >&2; exit 2 ;; esac
host_target="$host_arch-apple-macosx14.0"
[[ "$node_bin" == /* ]]
test -x "$node_bin"
test -x "$swift_bin"
test "$(id -u)" -ne 0
source_file="$repo_root/app/SourcesShared/PrivateExternalSyncStorage.swift"
test_file="$repo_root/app/Tests/PrivateExternalSyncStorageTests.swift"
supervisor="$repo_root/test/mpv-bounded-child.mjs"
runner="$repo_root/scripts/test-private-external-sync-storage.sh"
test -f "$source_file"
test -f "$test_file"
test -f "$supervisor"
test -f "$runner"
mkdir -p "$repo_root/app/build"
slot_dir="$repo_root/app/build/.private-external-sync-storage.slot"
if ! mkdir "$slot_dir" 2>/dev/null; then
  echo "Private-storage serial slot is occupied: $slot_dir" >&2
  echo "Do not remove an active slot; reconcile stale ownership explicitly." >&2
  exit 2
fi

# Same cancellation/readiness and cleanup-receipt protocol as the reviewed MPV runner.
active_pid=""
active_receipt=""
slot_releasable=1
interruption_status=0
interruption_signal=""
wait_interrupted=0
run_dir=""
inputs_recorded=0

signal_supervisor() {
  local signal="$1"
  if [[ "$slot_releasable" -eq 0 && -n "$active_receipt" ]]; then
    if ! : > "$active_receipt.cancel-$signal"; then
      echo "Cannot persist cancellation request; cleanup must be reconciled: $active_receipt" >&2
    fi
    if [[ -n "$active_pid" && -f "$active_receipt.active" ]]; then
      kill "-$signal" "$active_pid" 2>/dev/null || true
    fi
  fi
}
request_interrupt() {
  local signal="$1" status="$2"
  if [[ "$interruption_status" -eq 0 ]]; then
    interruption_status="$status"
    interruption_signal="$signal"
  fi
  wait_interrupted=1
  signal_supervisor "$interruption_signal"
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
  if ! nice -n 15 "$node_bin" "$supervisor" check "$active_receipt" "$status"; then
    slot_releasable=0
    return 125
  fi
  slot_releasable=1
  return "$status"
}
record_after() {
  shasum -a 256 "$source_file" "$test_file" "$supervisor" "$runner" | tee "$run_dir/inputs-after.sha256"
  if ! cmp -s "$run_dir/inputs-before.sha256" "$run_dir/inputs-after.sha256"; then
    echo "FAIL: actual source/test/runner/helper drifted during the fixture job" >&2
    return 90
  fi
}
finish() {
  local saved_status=$?
  trap - EXIT
  set +e
  if [[ -n "$active_pid" ]]; then
    signal_supervisor "${interruption_signal:-TERM}"
    wait_supervisor
    if [[ "$slot_releasable" -eq 0 ]]; then saved_status=125; fi
  fi
  if [[ "$inputs_recorded" -eq 1 ]]; then
    record_after || saved_status=90
  fi
  if [[ "$slot_releasable" -eq 1 && -z "$active_pid" ]]; then
    rmdir "$slot_dir" 2>/dev/null || true
  else
    echo "SERIAL SLOT RETAINED: reconcile $active_receipt and $slot_dir; cleanup is unconfirmed" >&2
    saved_status=125
  fi
  if [[ "$interruption_status" -ne 0 ]]; then exit "$interruption_status"; fi
  exit "$saved_status"
}
trap finish EXIT
stop_if_interrupted() {
  if [[ "$interruption_status" -ne 0 ]]; then exit "$interruption_status"; fi
}
bounded_run() {
  local seconds="$1"
  active_receipt="$2"
  shift 2
  stop_if_interrupted
  slot_releasable=0
  nice -n 15 "$node_bin" "$supervisor" run "$seconds" "$active_receipt" -- "$@" &
  active_pid=$!
  if [[ "$interruption_status" -ne 0 ]]; then signal_supervisor "$interruption_signal"; fi
  wait_supervisor
}

stop_if_interrupted
run_dir="$(mktemp -d "$repo_root/app/build/private-external-sync-storage.XXXXXX")"
mkdir "$run_dir/tmp"
export TMPDIR="$run_dir/tmp"
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1
export SWIFT_MAXIMUM_CONCURRENT_OPERATIONS=1
shasum -a 256 "$source_file" "$test_file" "$supervisor" "$runner" | tee "$run_dir/inputs-before.sha256"
inputs_recorded=1
echo "Private-storage disposable artifacts: $run_dir"

compile_status=0
bounded_run 60 "$run_dir/compiler.supervisor.json" \
  "$swift_bin" -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -sdk "$host_sdk" -target "$host_target" -whole-module-optimization -j 1 -num-threads 1 \
  -module-cache-path "$run_dir/module-cache" "$source_file" "$test_file" \
  -o "$run_dir/private-external-sync-storage-tests" \
  > "$run_dir/compiler.log" 2>&1 || compile_status=$?
if [[ "$compile_status" -ne 0 ]]; then exit "$compile_status"; fi
nice -n 15 "$node_bin" "$supervisor" check "$run_dir/compiler.supervisor.json" 0 normal-exit
stop_if_interrupted

fixture_status=0
bounded_run 30 "$run_dir/fixture.supervisor.json" \
  "$run_dir/private-external-sync-storage-tests" --fixture-root "$run_dir/fixtures" \
  > "$run_dir/fixture.log" 2>&1 || fixture_status=$?
if [[ "$fixture_status" -ne 0 ]]; then exit "$fixture_status"; fi
nice -n 15 "$node_bin" "$supervisor" check "$run_dir/fixture.supervisor.json" 0 normal-exit
stop_if_interrupted
echo "PASS: actual private-storage source/test completed normally with confirmed child cleanup"
