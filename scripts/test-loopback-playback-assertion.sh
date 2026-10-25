#!/usr/bin/env bash
set -euo pipefail
# Whole actual helper + explicit RAM UIKit seam; no real UIKit runtime claim.
loopback_runner="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
loopback_repo="${1:-"$(dirname "$(dirname "$loopback_runner")")"}"
loopback_candidate="${2:-"$loopback_repo"}"
test "$#" -le 2
cd "$loopback_repo"
loopback_repo="$PWD"
case "$loopback_repo" in
  /Users/daksh/VortXTV/VortX|/Users/daksh/VortXTV/.worktrees/VortX/*) ;;
  *)
    # Hosted checkout paths differ from the local canonical workspace. Admit only this repository's
    # actual Actions workspace, never an arbitrary caller-provided directory or recovery copy.
    if [[ "${GITHUB_ACTIONS:-}" != true || "${GITHUB_REPOSITORY:-}" != VortXTV/VortX \
       || -z "${GITHUB_WORKSPACE:-}" || "$loopback_repo" != "$GITHUB_WORKSPACE" \
       || "$(git -C "$loopback_repo" rev-parse --show-toplevel)" != "$loopback_repo" ]]; then
      printf 'Expected the canonical VortX workspace or its exact hosted checkout.\n' >&2; exit 2
    fi
    case "$(git -C "$loopback_repo" remote get-url origin)" in
      https://github.com/VortXTV/VortX|https://github.com/VortXTV/VortX.git) ;;
      *) printf 'Unexpected hosted VortX origin.\n' >&2; exit 2 ;;
    esac
    ;;
esac
loopback_candidate="$(cd "$loopback_candidate" && pwd -P)"
loopback_source="$loopback_repo/app/SourcesShared/LoopbackPlaybackAssertion.swift"
loopback_fixture="$loopback_candidate/app/Tests/LoopbackPlaybackAssertionTests.swift"
loopback_supervisor="$loopback_repo/test/mpv-bounded-child.mjs"
loopback_node="$(command -v node)"
loopback_expected_supervisor=c83153feedd91bee93000305604d68772d4b7164716749f0a04605bbb2253f62
loopback_observed_supervisor="$(shasum -a 256 "$loopback_supervisor")"
test "${loopback_observed_supervisor%% *}" = "$loopback_expected_supervisor"
mkdir -p app/build
loopback_dir="$(mktemp -d "$PWD/app/build/loopback-assertion-ram.XXXXXX")"
loopback_inputs=("$loopback_runner" "$loopback_supervisor" "$loopback_source" "$loopback_fixture")
loopback_phase=source
loopback_active_pid=""
loopback_active_receipt=""
loopback_interrupted=0
loopback_signal=""
loopback_wait_interrupted=0
loopback_cleanup_confirmed=1
loopback_cancel() {
  if [[ -n "$loopback_active_receipt" ]]; then
    : > "$loopback_active_receipt.cancel-$1"
    if [[ -n "$loopback_active_pid" && -f "$loopback_active_receipt.active" ]]; then
      kill "-$1" "$loopback_active_pid" 2>/dev/null || true
    fi
  fi
}
loopback_interrupt() {
  if [[ "$loopback_interrupted" -eq 0 ]]; then loopback_interrupted="$2"; loopback_signal="$1"; fi
  loopback_wait_interrupted=1
  loopback_cancel "$loopback_signal"
}
trap 'loopback_interrupt INT 130' INT
trap 'loopback_interrupt TERM 143' TERM
loopback_wait() {
  local status=0
  while :; do
    loopback_wait_interrupted=0
    status=0
    wait "$loopback_active_pid" || status=$?
    [[ "$loopback_wait_interrupted" -ne 0 ]] || break
  done
  loopback_active_pid=""
  if ! /usr/bin/nice -n 15 "$loopback_node" "$loopback_supervisor" check "$loopback_active_receipt" "$status"; then
    loopback_cleanup_confirmed=0
    return 125
  fi
  loopback_cleanup_confirmed=1
  if [[ "$loopback_interrupted" -ne 0 ]]; then return "$loopback_interrupted"; fi
  if [[ "$status" -eq 0 ]]; then
    /usr/bin/nice -n 15 "$loopback_node" "$loopback_supervisor" check "$loopback_active_receipt" 0 normal-exit
  fi
  return "$status"
}
loopback_run() {
  local seconds="$1"
  loopback_active_receipt="$2"
  shift 2
  [[ "$loopback_interrupted" -eq 0 ]] || return "$loopback_interrupted"
  loopback_cleanup_confirmed=0
  /usr/bin/nice -n 15 "$loopback_node" "$loopback_supervisor" run "$seconds" "$loopback_active_receipt" -- "$@" &
  loopback_active_pid=$!
  if [[ "$loopback_interrupted" -ne 0 ]]; then loopback_cancel "$loopback_signal"; fi
  loopback_wait
}
loopback_finish() {
  local status=$?
  trap - EXIT
  set +e
  if [[ -n "$loopback_active_pid" ]]; then
    loopback_cancel "${loopback_signal:-TERM}"
    loopback_wait
  fi
  [[ "$loopback_cleanup_confirmed" -eq 1 ]] || status=125
  shasum -a 256 "${loopback_inputs[@]}" > "$loopback_dir/source-after.sha256" || status=3
  cmp -s "$loopback_dir/source-before.sha256" "$loopback_dir/source-after.sha256" || status=3
  if [[ -f "$loopback_dir/generated-before.sha256" ]]; then
    shasum -a 256 --check "$loopback_dir/generated-before.sha256" > "$loopback_dir/generated-after.log" 2>&1 || status=3
  fi
  if [[ -f "$loopback_dir/executable-before.sha256" ]]; then
    shasum -a 256 --check "$loopback_dir/executable-before.sha256" > "$loopback_dir/executable-after.log" 2>&1 || status=3
  fi
  if [[ "$loopback_interrupted" -ne 0 && "$loopback_cleanup_confirmed" -eq 1 ]]; then status="$loopback_interrupted"; fi
  printf 'exit_code=%s\nphase=%s\ncleanup_confirmed=%s\nscope=whole-actual-loopback-state-RAM-UIKit-only-not-real-UIKit-availability-or-runtime\n' \
    "$status" "$loopback_phase" "$loopback_cleanup_confirmed" > "$loopback_dir/result.txt"
  printf 'Loopback RAM exit %s; retained %s\n' "$status" "$loopback_dir"
  exit "$status"
}
trap loopback_finish EXIT
shasum -a 256 "${loopback_inputs[@]}" > "$loopback_dir/source-before.sha256"
# No method extraction. Only the exact UIKit import and three conditional selectors change.
"$loopback_node" - "$loopback_source" "$loopback_dir" <<'NODE'
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const [sourcePath, output] = process.argv.slice(2);
const bytes = fs.readFileSync(sourcePath), source = bytes.toString('utf8');
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
if (sha(bytes) !== '93dbeab9d98a9293ddc9142a1edae531ece2e87d5f3f11a5762555eaa86ffd2f')
  throw new Error('Actual helper changed: review complete source and deliberately repin, never rewrite methods');
const selector = '#if canImport(UIKit)', selected = '#if LOOPBACK_PLAYBACK_ASSERTION_RAM_UIKIT';
const importLine = 'import UIKit\n', seamLine = '// UIKit supplied only by the explicit RAM test seam.\n';
if (source.split(selector).length !== 4 || source.split(importLine).length !== 2)
  throw new Error('Exact whole-source UIKit transformation frontier changed');
const transformed = source.replaceAll(selector, selected).replace(importLine, seamLine);
if (transformed.replaceAll(selected, selector).replace(seamLine, importLine) !== source)
  throw new Error('Whole-source reverse conservation failed');
fs.writeFileSync(path.join(output, 'source-original.swift'), bytes, { flag: 'wx' });
fs.writeFileSync(path.join(output, 'WholeLoopbackPlaybackAssertion.swift'), transformed, { flag: 'wx' });
fs.writeFileSync(path.join(output, 'source-transform.json'), JSON.stringify({
  schema: 1, sourcePath, originalSHA256: sha(bytes), transformedSHA256: sha(transformed),
  completeSource: true, conditionalSubstitutions: 3, importSubstitutions: 1,
  methodTransformations: [], scope: 'explicit RAM UIKit only; real UIKit compile remains separate'
}, null, 2) + '\n', { flag: 'wx' });
NODE
shasum -a 256 "$loopback_dir/source-original.swift" "$loopback_dir/WholeLoopbackPlaybackAssertion.swift" \
  "$loopback_dir/source-transform.json" > "$loopback_dir/generated-before.sha256"
mkdir "$loopback_dir/module-cache"
loopback_verify() {
  shasum -a 256 "${loopback_inputs[@]}" > "$loopback_dir/source-check.sha256"
  cmp -s "$loopback_dir/source-before.sha256" "$loopback_dir/source-check.sha256"
  shasum -a 256 --check "$loopback_dir/generated-before.sha256" > "$loopback_dir/generated-check.log" 2>&1
}
loopback_verify
loopback_phase=compile
loopback_run 60 "$loopback_dir/compile-process.json" /usr/bin/xcrun swiftc \
  -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -j 1 -num-threads 1 -whole-module-optimization -D LOOPBACK_PLAYBACK_ASSERTION_RAM_UIKIT \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$loopback_dir/module-cache" \
  "$loopback_dir/WholeLoopbackPlaybackAssertion.swift" "$loopback_fixture" \
  -o "$loopback_dir/loopback-tests" > "$loopback_dir/compiler.log" 2>&1
shasum -a 256 "$loopback_dir/loopback-tests" > "$loopback_dir/executable-before.sha256"
loopback_verify
loopback_phase=runtime
loopback_run 15 "$loopback_dir/runtime-process.json" "$loopback_dir/loopback-tests" \
  > "$loopback_dir/runtime.log" 2>&1
grep -Fxq 'PASS loopback assertion: 9 groups, 4 host spellings; whole actual state with RAM UIKit only' "$loopback_dir/runtime.log"
loopback_phase=complete
