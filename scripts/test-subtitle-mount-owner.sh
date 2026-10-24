#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; cd "$repo_root"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
test "$(uname -s)" = Darwin || fail 'macOS is required'
node_bin="$(command -v node)"; [[ "$node_bin" == /* ]] || fail 'absolute node executable is required'; test -x "$node_bin" || fail 'node is required'
command -v xcrun >/dev/null 2>&1 || fail 'xcrun is required'
command -v rg >/dev/null 2>&1 || fail 'rg is required'
test -d app/build || fail 'app/build must exist'
build_root="$(cd app/build && pwd -P)"
"$node_bin" - "$repo_root" "$build_root" <<'NODE'
const path = require('node:path'); const [root, build] = process.argv.slice(2); const relative = path.relative(root, build);
if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) throw Error('real app/build must be strictly inside real repo root');
NODE
supervisor="$repo_root/test/mpv-bounded-child.mjs"; expected_supervisor_sha='c83153feedd91bee93000305604d68772d4b7164716749f0a04605bbb2253f62'
observed_supervisor_sha="$(shasum -a 256 "$supervisor")"; observed_supervisor_sha="${observed_supervisor_sha%% *}"
[[ "$observed_supervisor_sha" == "$expected_supervisor_sha" ]] || fail 'supervisor changed; repinning requires review'
host_arch="$(uname -m)"; case "$host_arch" in arm64|x86_64) ;; *) fail "unsupported architecture $host_arch" ;; esac
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"; test -d "$host_sdk" || fail 'macOS SDK unavailable'; host_target="$host_arch-apple-macosx14.0"
slot_dir="$build_root/.subtitle-mount-owner.slot"; mkdir "$slot_dir" 2>/dev/null || fail "serial slot occupied: $slot_dir"
active_pid=''; active_receipt=''; slot_releasable=1; interrupt_status=0; interrupt_signal=''; wait_interrupted=0
signal_supervisor() {
 [[ "$slot_releasable" -eq 0 && -n "$active_receipt" ]] || return 0
 : > "$active_receipt.cancel-$1" || return 0
 [[ -n "$active_pid" && -f "$active_receipt.active" ]] && kill "-$1" "$active_pid" 2>/dev/null || true
}
request_interrupt() { [[ "$interrupt_status" -ne 0 ]] || { interrupt_status="$2"; interrupt_signal="$1"; }; wait_interrupted=1; signal_supervisor "$interrupt_signal"; }
trap 'request_interrupt INT 130' INT; trap 'request_interrupt TERM 143' TERM
wait_supervisor() {
 local status=0
 while :; do wait_interrupted=0; status=0; wait "$active_pid" || status=$?; [[ "$wait_interrupted" -eq 0 ]] && break; done
 active_pid=''
 if ! nice -n 15 "$node_bin" "$supervisor" check "$active_receipt" "$status"; then slot_releasable=0; return 125; fi
 slot_releasable=1; return "$status"
}
release_slot() {
 local saved=$?; trap - EXIT; set +e
 if [[ -n "$active_pid" ]]; then signal_supervisor "${interrupt_signal:-TERM}"; wait_supervisor; fi
 if [[ "$slot_releasable" -eq 1 && -z "$active_pid" ]]; then rmdir "$slot_dir" 2>/dev/null || true; else printf 'SERIAL SLOT RETAINED: reconcile %s and %s\n' "$active_receipt" "$slot_dir" >&2; fi
 [[ "$interrupt_status" -eq 0 ]] || exit "$interrupt_status"; exit "$saved"
}
trap release_slot EXIT
run_dir="$(mktemp -d "$build_root/subtitle-mount-owner.XXXXXX")"; mkdir "$run_dir/tmp" "$run_dir/module-cache"
printf 'Retained subtitle mount owner evidence: %s\n' "$run_dir"
stop_if_interrupted() { [[ "$interrupt_status" -eq 0 ]] || exit "$interrupt_status"; }
bounded_run() {
 local seconds="$1" receipt="$2"; shift 2; stop_if_interrupted; active_receipt="$receipt"; slot_releasable=0
 nice -n 15 env OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 TMPDIR="$run_dir/tmp" \
  CLANG_MODULE_CACHE_PATH="$run_dir/module-cache" SWIFT_MODULE_CACHE_PATH="$run_dir/module-cache" \
  "$node_bin" "$supervisor" run "$seconds" "$receipt" -- "$@" > "${receipt%.supervisor.json}.log" 2>&1 &
 active_pid=$!; [[ "$interrupt_status" -eq 0 ]] || signal_supervisor "$interrupt_signal"; wait_supervisor
}
normal_exit() { nice -n 15 "$node_bin" "$supervisor" check "$1" "$2" normal-exit; }
sources=(app/SourcesShared/CredentialScope.swift app/SourcesShared/CoreBridge.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/LegacyWatchOwnership.swift app/Tests/SubtitleMountOwnerTests.swift test/subtitle-mount-owner-fixture.cjs scripts/test-subtitle-mount-owner.sh test/mpv-bounded-child.mjs)
shasum -a 256 "${sources[@]}" > "$run_dir/source-conservation.sha256"
bounded_run 30 "$run_dir/extract.supervisor.json" "$node_bin" "$repo_root/test/subtitle-mount-owner-fixture.cjs" "$repo_root" "$run_dir/extracted" || fail 'extraction failed; inspect retained receipt/log'
normal_exit "$run_dir/extract.supervisor.json" 0
shasum -a 256 --check "$run_dir/source-conservation.sha256"
inputs=("$run_dir/extracted/ActualSubtitleOwnerFixture.swift" "$run_dir/extracted/ActualLegacyWatchOwnership.swift" app/Tests/SubtitleMountOwnerTests.swift)
evidence=("$run_dir/extracted/ActualSubtitleOwnerFixture.swift" "$run_dir/extracted/ActualLegacyWatchOwnership.swift" "$run_dir/extracted/ActualFIFOAdmission.swift.txt" app/Tests/SubtitleMountOwnerTests.swift)
shasum -a 256 "${evidence[@]}" > "$run_dir/generated-inputs.sha256"
bounded_run 240 "$run_dir/compile.supervisor.json" /usr/bin/xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors -whole-module-optimization \
 -j 1 -num-threads 1 -sdk "$host_sdk" -target "$host_target" -module-cache-path "$run_dir/module-cache" "${inputs[@]}" -o "$run_dir/subtitle-mount-owner-tests" || fail 'compile failed; inspect retained receipt/log'
normal_exit "$run_dir/compile.supervisor.json" 0
shasum -a 256 --check "$run_dir/source-conservation.sha256"; shasum -a 256 --check "$run_dir/generated-inputs.sha256"
bounded_run 60 "$run_dir/runtime.supervisor.json" "$run_dir/subtitle-mount-owner-tests" || fail 'runtime failed; inspect retained receipt/log'
normal_exit "$run_dir/runtime.supervisor.json" 0
rg -q '^ALL PASS [1-9][0-9]*$' "$run_dir/runtime.log" || fail 'missing positive assertion receipt'
shasum -a 256 --check "$run_dir/source-conservation.sha256"; shasum -a 256 --check "$run_dir/generated-inputs.sha256"
shasum -a 256 "$run_dir/extracted/extraction.json" "$run_dir/extract.supervisor.json" "$run_dir/compile.supervisor.json" "$run_dir/runtime.supervisor.json" "$run_dir/subtitle-mount-owner-tests" > "$run_dir/final-receipt.sha256"
printf 'PASS subtitle mount owner regression (actual coordinator; synthetic storage/session only)\nRetained receipt: %s/final-receipt.sha256\n' "$run_dir"
