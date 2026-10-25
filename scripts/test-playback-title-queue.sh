#!/usr/bin/env bash
# Serial policy/source-capability checks; no app, media, account or network access.
set -euo pipefail
queue_script_dir="$(cd "$(dirname "$0")" && pwd -P)"
queue_root="$(cd "$queue_script_dir/.." && pwd -P)"
[[ "$(git -C "$queue_root" rev-parse --show-toplevel)" == "$queue_root" ]] || exit 2
mkdir -p "$queue_root/app/build"
queue_out="$(mktemp -d "$queue_root/app/build/playback-title-queue.XXXXXX")"
printf 'Receipt: %s\n' "$queue_out"
queue_inputs=(
  "$queue_root/app/SourcesShared/PlaybackTitleQueuePolicy.swift"
  "$queue_root/app/SourcesShared/RandomPickPlayIntent.swift"
  "$queue_root/app/Tests/PlaybackTitleQueuePolicyTests.swift"
  "$queue_root/app/Tests/PlaybackTitleQueueSourceAdmissionTests.swift"
  "$queue_root/scripts/test-playback-title-queue.sh"
)
queue_finish() {
  queue_status=$?
  trap - EXIT
  shasum -a 256 "${queue_inputs[@]}" > "$queue_out/after.sha256" || queue_status=3
  cmp -s "$queue_out/before.sha256" "$queue_out/after.sha256" || queue_status=3
  printf 'exit_code=%s\n' "$queue_status" > "$queue_out/result.txt"
  cat "$queue_out/result.txt"
  exit "$queue_status"
}
trap queue_finish EXIT
shasum -a 256 "${queue_inputs[@]}" > "$queue_out/before.sha256"
mkdir "$queue_out/module-cache"
export OMP_NUM_THREADS=1 SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS=1 SWIFT_FRONTEND_THREADS=1
export OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1
export CLANG_MODULE_CACHE_PATH="$queue_out/module-cache"
queue_target="$(uname -m)-apple-macosx14.0"
queue_sdk="$(xcrun --toolchain com.apple.dt.toolchain.XcodeDefault --sdk macosx --show-sdk-path)"
printf 'target=%s\nsdk=%s\n' "$queue_target" "$queue_sdk" > "$queue_out/toolchain-selection.txt"
# Copy the complete actual Foundation-only Token declaration verbatim, including
# its actor isolation. The rest of RandomPickPlayIntent needs the native app graph.
node - "$queue_root/app/SourcesShared/RandomPickPlayIntent.swift" > "$queue_out/ActualToken.swift" <<'NODE'
const fs = require('node:fs');
const text = fs.readFileSync(process.argv[2], 'utf8');
const start = '@MainActor\nfinal class PlaybackTitleQueueToken {';
const end = '/// Shared Apple intent:';
const first = text.indexOf(start), last = text.indexOf(end, first);
if (first < 0 || first !== text.lastIndexOf(start) || last <= first || last !== text.lastIndexOf(end))
  throw Error('Missing or duplicate actual queue Token extraction boundary');
const actual = text.slice(first, last);
if (!actual.trimEnd().endsWith('}')) throw Error('Incomplete actual Token declaration');
process.stdout.write('import Foundation\n' + actual);
NODE
shasum -a 256 "$queue_out/ActualToken.swift" > "$queue_out/generated-before.sha256"
queue_flags=(-target "$queue_target" -sdk "$queue_sdk" -swift-version 6
  -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1
  -whole-module-optimization -parse-as-library -module-cache-path "$queue_out/module-cache")
/usr/bin/nice -n 15 xcrun --toolchain com.apple.dt.toolchain.XcodeDefault --sdk macosx swiftc \
  "${queue_flags[@]}" "$queue_root/app/SourcesShared/PlaybackTitleQueuePolicy.swift" \
  "$queue_root/app/Tests/PlaybackTitleQueuePolicyTests.swift" -o "$queue_out/policy-tests" > "$queue_out/policy-compile.log" 2>&1
/usr/bin/nice -n 15 "$queue_out/policy-tests" > "$queue_out/policy-runtime.log" 2>&1
/usr/bin/nice -n 15 xcrun --toolchain com.apple.dt.toolchain.XcodeDefault --sdk macosx swiftc \
  "${queue_flags[@]}" "$queue_root/app/SourcesShared/PlaybackTitleQueuePolicy.swift" \
  "$queue_out/ActualToken.swift" "$queue_root/app/Tests/PlaybackTitleQueueSourceAdmissionTests.swift" \
  -o "$queue_out/source-tests" > "$queue_out/source-compile.log" 2>&1
/usr/bin/nice -n 15 "$queue_out/source-tests" > "$queue_out/source-runtime.log" 2>&1
shasum -a 256 "$queue_out/ActualToken.swift" > "$queue_out/generated-after.sha256"
cmp -s "$queue_out/generated-before.sha256" "$queue_out/generated-after.sha256"
cat "$queue_out/policy-runtime.log" "$queue_out/source-runtime.log"
