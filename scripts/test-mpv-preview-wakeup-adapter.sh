#!/usr/bin/env bash
# Selected actual adapter proof only. No media/network/app/device launch or native mpv calls.
# DIFFERENT gates: Swift5/app-default-concurrency actual lifecycle; strict6 NEW scheduling.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
node_bin="${VORTX_WAKEUP_NODE:-$(command -v node)}"
swift_bin="${VORTX_WAKEUP_SWIFTC:-$(xcrun --find swiftc)}"
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) echo "Unsupported host architecture: $host_arch" >&2; exit 2 ;; esac
# Match the project's Mac floor, not a newer host beta unsupported by the selected SDK.
host_target="$host_arch-apple-macosx14.0"
command -v rg >/dev/null
test -x "$node_bin"
test -x "$swift_bin"
mkdir -p "$repo_root/app/build"
generator="$repo_root/test/mpv-preview-wakeup-adapter.mjs"
supervisor="$repo_root/test/mpv-bounded-child.mjs"

# One fail-fast serial slot. Only ONE owned supervisor/child group may exist at a time.
# The supervisor uses async launch + immediate wait only to allow shell INT/TERM forwarding;
# no parallel compiler lanes. Other builds still need the invoking task's resource coordination.
slot_dir="$repo_root/app/build/.mpv-preview-wakeup-adapter.slot"
if ! mkdir "$slot_dir" 2>/dev/null; then
  echo "Wakeup adapter serial slot is occupied: $slot_dir" >&2
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
    # Existence-only marker publication is atomic; no partially written signal text to parse.
    # Persist BEFORE checking readiness, closing the supervisor-startup signal-loss window.
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
  # Do not exit/release the slot here. The supervisor must terminate and reap its child group.
}
trap 'request_interrupt INT 130' INT
trap 'request_interrupt TERM 143' TERM

wait_supervisor() {
  local status=0
  # Bash wait can return early after a trapped signal while the supervisor is still cleaning up.
  # Re-wait after each such interruption; never mistake an interrupted wait for child completion.
  while :; do
    wait_interrupted=0
    status=0
    wait "$active_pid" || status=$?
    if [[ "$wait_interrupted" -eq 0 ]]; then break; fi
  done
  active_pid=""
  # Missing receipt, timeout without cleanup, or a still-existing process group retains the slot.
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
    # An unexpected shell failure still asks the owned supervisor to clean up, then reaps it.
    signal_supervisor "${interruption_signal:-TERM}"
    wait_supervisor
  fi
  if [[ "$slot_releasable" -eq 1 && -z "$active_pid" ]]; then
    rmdir "$slot_dir" 2>/dev/null || true
  else
    echo "SERIAL SLOT RETAINED: cleanup is unconfirmed; reconcile $active_receipt and $slot_dir" >&2
  fi
  # A caught interruption, including one during final output or EXIT cleanup, is never success.
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
    "$node_bin" "$supervisor" run "$seconds" "$active_receipt" -- "$@" &
  active_pid=$!
  # Cover a signal between the pre-launch check and recording the just-spawned supervisor PID.
  if [[ "$interruption_status" -ne 0 ]]; then
    signal_supervisor "$interruption_signal"
  fi
  wait_supervisor
}
normal_exit_receipt() {
  nice -n 15 "$node_bin" "$supervisor" check "$1" "$2" normal-exit
}
verify_inputs() {
  nice -n 15 "$node_bin" "$generator" verify "$repo_root" "$run_dir"
}

stop_if_interrupted
run_dir="$(mktemp -d "$repo_root/app/build/mpv-preview-wakeup-adapter.XXXXXX")"
echo "Wakeup adapter artifacts: $run_dir"
nice -n 15 "$node_bin" "$generator" generate "$repo_root" "$run_dir"
printf 'case\tlane\tcompile_status\truntime_status\tclassification\n' > "$run_dir/results.tsv"
printf 'swift=%s\nnode=%s\ncompiler_deadline_seconds=180\nruntime_deadline_seconds=15\n' \
  "$swift_bin" "$node_bin" > "$run_dir/toolchain.txt"
printf 'sdk=%s\ntarget=%s\n' "$host_sdk" "$host_target" >> "$run_dir/toolchain.txt"

compile_case() {
  local name="$1"
  local lane="$2"
  local status=0
  local mode_flags=()
  if [[ "$lane" == "legacy5" ]]; then
    # Actual app language/default concurrency mode, NOT a pass of full strict6 migration.
    mode_flags=(-swift-version 5)
  elif [[ "$lane" == "strict6-scheduling" ]]; then
    mode_flags=(-swift-version 6 -strict-concurrency=complete)
  else
    echo "Unknown proof lane: $lane" >&2
    return 2
  fi
  verify_inputs || return 90
  bounded_run 180 "$run_dir/$name.compile.supervisor.json" \
    "$swift_bin" -parse-as-library -warnings-as-errors \
    -sdk "$host_sdk" -target "$host_target" \
    -whole-module-optimization -j 1 -num-threads 1 \
    -module-cache-path "$run_dir/module-cache" \
    "${mode_flags[@]}" "$run_dir/$name.swift" -o "$run_dir/$name" \
    > "$run_dir/$name.compile.log" 2>&1 || status=$?
  printf '%s\n' "$status" > "$run_dir/$name.compile.status"
  # Always verify after compilation, including timeout/failure. Drift is never a valid result.
  verify_inputs || return 90
  if [[ "$status" -eq 0 ]]; then
    normal_exit_receipt "$run_dir/$name.compile.supervisor.json" 0 || return 125
  fi
  return "$status"
}
run_case() {
  local name="$1"
  local status=0
  bounded_run 15 "$run_dir/$name.runtime.supervisor.json" "$run_dir/$name" \
    > "$run_dir/$name.runtime.log" 2>&1 || status=$?
  printf '%s\n' "$status" > "$run_dir/$name.runtime.status"
  verify_inputs || return 90
  return "$status"
}
fail_suite() {
  local failure_status="${1:-1}"
  stop_if_interrupted
  case "$failure_status" in
    90|124|125|127|130|143) exit "$failure_status" ;;
    *) exit 1 ;;
  esac
}
for baseline in legacy5 strict6-scheduling; do
  stop_if_interrupted
  compile_status=0
  compile_case "$baseline" "$baseline" || compile_status=$?
  if [[ "$compile_status" -ne 0 ]]; then
    printf '%s\t%s\t%s\tNOT_RUN\tBASELINE_COMPILE_FAILED_NO_PASS\n' \
      "$baseline" "$baseline" "$compile_status" >> "$run_dir/results.tsv"
    echo "Baseline compiler failure/timeout is not a pass: $run_dir/$baseline.compile.log" >&2
    fail_suite "$compile_status"
  fi
  runtime_status=0
  run_case "$baseline" || runtime_status=$?
  if [[ "$baseline" == "legacy5" ]]; then
    expected_pass='PASS: 42 project-Swift5 actual lifecycle adapter assertions; NOT full strict-Swift6/native/thread/device proof'
  else
    expected_pass='PASS: 18 strict-Swift6 NEW scheduling adapter assertions; production teardown/native/thread/device EXCLUDED'
  fi
  if [[ "$runtime_status" -ne 0 ]] ||
      ! normal_exit_receipt "$run_dir/$baseline.runtime.supervisor.json" 0 ||
      ! rg -Fxq -- "$expected_pass" "$run_dir/$baseline.runtime.log"; then
    printf '%s\t%s\t0\t%s\tBASELINE_RUNTIME_FAILED_NO_PASS\n' \
      "$baseline" "$baseline" "$runtime_status" >> "$run_dir/results.tsv"
    echo "Baseline runtime failed: $run_dir/$baseline.runtime.log" >&2
    fail_suite "$runtime_status"
  fi
  printf '%s\t%s\t0\t0\tPASS_SELECTED_LANE_ONLY\n' "$baseline" "$baseline" >> "$run_dir/results.tsv"
  echo "$expected_pass"
done

stop_if_interrupted
nice -n 15 "$node_bin" "$generator" mutants "$repo_root" "$run_dir" > "$run_dir/mutants.tsv"
mutant_count=0
while IFS=$'\t' read -r mutation source_name expected_assertion; do
  stop_if_interrupted
  mutant_count=$((mutant_count + 1))
  name="${source_name%.swift}"
  compile_status=0
  compile_case "$name" legacy5 || compile_status=$?
  if [[ "$compile_status" -ne 0 ]]; then
    printf '%s\tlegacy5\t%s\tNOT_RUN\tMUTANT_COMPILE_FAILED_NOT_KILLED\n' \
      "$mutation" "$compile_status" >> "$run_dir/results.tsv"
    echo "Mutant compiler failure/timeout is NOT a kill: $run_dir/$name.compile.log" >&2
    fail_suite "$compile_status"
  fi
  runtime_status=0
  run_case "$name" || runtime_status=$?
  expected_line="WAKEUP_ASSERTION_FAILED: $expected_assertion"
  if [[ "$runtime_status" -eq 1 ]] &&
      normal_exit_receipt "$run_dir/$name.runtime.supervisor.json" 1 &&
      rg -Fxq -- "$expected_line" "$run_dir/$name.runtime.log"; then
    printf '%s\tlegacy5\t0\t1\tKILLED_EXPECTED_RUNTIME_ASSERTION\n' \
      "$mutation" >> "$run_dir/results.tsv"
    echo "KILLED at expected runtime assertion: $mutation"
  else
    printf '%s\tlegacy5\t0\t%s\tSURVIVED_OR_UNEXPECTED_RUNTIME_FAILURE\n' \
      "$mutation" "$runtime_status" >> "$run_dir/results.tsv"
    echo "Mutant did not have the expected NORMAL runtime assertion exit: $run_dir/$name.runtime.log" >&2
    fail_suite "$runtime_status"
  fi
done < "$run_dir/mutants.tsv"
if [[ "$mutant_count" -ne 5 ]]; then
  echo "Expected five activated mutants, observed $mutant_count; no complete suite claim." >&2
  fail_suite
fi
stop_if_interrupted
verify_inputs
stop_if_interrupted
shasum -a 256 "$run_dir/manifest.json" "$run_dir/results.tsv" \
  "$run_dir/legacy5" "$run_dir/strict6-scheduling" \
  "$run_dir/"*.supervisor.json > "$run_dir/final-receipt.sha256"
stop_if_interrupted
echo "PASS: two distinct current-source proof lanes and five activated runtime mutants."
echo "Full strict6 teardown, whole Apple target, native/thread/device behavior remain separate OPEN gates."
