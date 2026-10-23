#!/usr/bin/env bash
set -euo pipefail
# UNRUN candidate. One strictly serial model proof lane; no app, native engine, account or network.
curation_repo=${1:-"$PWD"}
curation_candidate=${2:-"$curation_repo"}
curation_runner="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
cd "$curation_repo"
repo_root="$PWD"
candidate_root="$(cd "$curation_candidate" && pwd -P)"
node_bin="${VORTX_CURATION_NODE:-$(command -v node)}"
swift_bin="${VORTX_CURATION_SWIFTC:-$(xcrun --find swiftc)}"
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
host_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) echo "Unsupported host architecture: $host_arch" >&2; exit 2 ;; esac
host_target="$host_arch-apple-macosx14.0"
command -v rg >/dev/null
test -x "$node_bin"
test -x "$swift_bin"
supervisor="$repo_root/test/mpv-bounded-child.mjs"
generator="$candidate_root/test/curation-actual-model.mjs"
expected_supervisor_sha=c83153feedd91bee93000305604d68772d4b7164716749f0a04605bbb2253f62
observed_supervisor_sha="$(shasum -a 256 "$supervisor")"
observed_supervisor_sha="${observed_supervisor_sha%% *}"
if [[ "$observed_supervisor_sha" != "$expected_supervisor_sha" ]]; then
  echo "Bounded-child helper changed; independent review and repinning required." >&2
  exit 90
fi
mkdir -p "$repo_root/app/build"
# Suite-specific fail-fast slot; root still coordinates the machine-wide resource lane.
slot_dir="$repo_root/app/build/.curation-actual-model.slot"
if ! mkdir "$slot_dir" 2>/dev/null; then
  echo "Curation serial slot occupied; reconcile rather than deleting: $slot_dir" >&2
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
    if ! : > "$active_receipt.cancel-$signal"; then
      echo "Cannot persist cancellation request; cleanup must be reconciled." >&2
    fi
    if [[ -n "$active_pid" && -f "$active_receipt.active" ]]; then
      kill "-$signal" "$active_pid" 2>/dev/null || true
    fi
  fi
}
request_interrupt() {
  local signal="$1"
  local status="$2"
  if [[ "$interruption_status" -eq 0 ]]; then interruption_status="$status"; interruption_signal="$signal"; fi
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
    echo "SERIAL SLOT RETAINED: cleanup unconfirmed; reconcile $active_receipt and $slot_dir" >&2
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
  if [[ "$interruption_status" -ne 0 ]]; then signal_supervisor "$interruption_signal"; fi
  wait_supervisor
}
normal_exit_receipt() {
  nice -n 15 "$node_bin" "$supervisor" check "$1" "$2" normal-exit
}
verify_inputs() {
  shasum -a 256 --check "$run_dir/manifest.sha256"
  nice -n 15 "$node_bin" "$generator" verify "$run_dir"
}
run_component() {
  local name="$1"
  local seconds="$2"
  shift 2
  local status=0
  verify_inputs || return 90
  bounded_run "$seconds" "$run_dir/$name.supervisor.json" "$@" > "$run_dir/$name.log" 2>&1 || status=$?
  printf '%s\n' "$status" > "$run_dir/$name.status"
  verify_inputs || return 90
  stop_if_interrupted
  if [[ "$status" -eq 0 ]]; then normal_exit_receipt "$run_dir/$name.supervisor.json" 0 || return 125; fi
  return "$status"
}
stop_if_interrupted
run_dir="$(mktemp -d "$repo_root/app/build/curation-actual-model.XXXXXX")"
mkdir "$run_dir/tmp" "$run_dir/module-cache"
printf 'Retained curation fixture: %s\n' "$run_dir"
bounded_run 30 "$run_dir/generate.supervisor.json" "$node_bin" "$generator" generate \
  "$repo_root" "$candidate_root" "$run_dir" "$curation_runner" > "$run_dir/generate.log" 2>&1
normal_exit_receipt "$run_dir/generate.supervisor.json" 0
shasum -a 256 "$run_dir/manifest.json" > "$run_dir/manifest.sha256"
printf 'swift=%s\nnode=%s\nsdk=%s\nsdk_version=%s\ntarget=%s\n' \
  "$swift_bin" "$node_bin" "$host_sdk" "$host_sdk_version" "$host_target" > "$run_dir/toolchain.txt"
printf 'compiler_deadline_seconds=180\nruntime_deadline_seconds=15\nnice=15\nswift=6\nstrict_concurrency=complete\nwarnings_as_errors=true\nwhole_module_optimization=true\njobs=1\nthreads=1\n' >> "$run_dir/toolchain.txt"
shasum -a 256 "$swift_bin" "$node_bin" >> "$run_dir/toolchain.txt"
run_component compiler-version 30 "$swift_bin" --version
run_component model.compile 180 "$swift_bin" \
  -sdk "$host_sdk" -target "$host_target" -module-cache-path "$run_dir/module-cache" \
  -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -whole-module-optimization -j 1 -num-threads 1 \
  "$run_dir/Support.swift" "$run_dir/ForYouInterests.swift" \
  "$run_dir/VortxNativeHostFieldMutation.swift" "$run_dir/CurationCollection.swift" \
  "$run_dir/CurationDocument.swift" "$run_dir/CurationEdit.swift" "$run_dir/main.swift" \
  -o "$run_dir/curation-model-tests"
run_component model.runtime 15 "$run_dir/curation-model-tests"
expected_pass='PASS: strict6 actual curation models and exact legacy field/CAS witnesses'
rg -Fxq -- "$expected_pass" "$run_dir/model.runtime.log"
stop_if_interrupted
verify_inputs
shasum -a 256 "$run_dir/manifest.json" "$run_dir/toolchain.txt" "$run_dir/curation-model-tests" \
  "$run_dir/generate.supervisor.json" "$run_dir/compiler-version.supervisor.json" \
  "$run_dir/model.compile.supervisor.json" "$run_dir/model.runtime.supervisor.json" > "$run_dir/final-receipt.sha256"
stop_if_interrupted
printf '%s\n' "$expected_pass"
printf '%s\n' 'EXCLUDED: Store/CoreBridge lifecycle, native checkpoint, complete app, UI, device, account/network proof.'
