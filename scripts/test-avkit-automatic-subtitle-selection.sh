#!/usr/bin/env bash
set -euo pipefail

# Pure encoded-sample policy and actual-source wiring only. This does not exercise
# AVFoundation reading/settlement, account interleavings, the native query or UI rendering.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

policy=app/SourcesShared/AVSubtitleReferenceSamplePolicy.swift
policy_test=app/Tests/AVSubtitleReferenceSamplePolicyTests.swift
selection_test=app/Tests/AVKitAutomaticSubtitleSelectionContractTests.swift
engine=app/Sources/Player/AVPlayerEngine.swift
for input in "$policy" "$policy_test" "$selection_test" "$engine"; do
  test -f "$input" || fail "required source is missing: $input"
done
command -v xcrun >/dev/null 2>&1 || fail 'xcrun is required for the genuine macOS SDK gate'
command -v shasum >/dev/null 2>&1 || fail 'shasum is required for source receipts'

mkdir -p app/build
test_dir="$(mktemp -d "$repo_root/app/build/avkit-automatic-subtitle-selection.XXXXXX")"
printf 'Evidence: %s\n' "$test_dir"
shasum -a 256 scripts/test-avkit-automatic-subtitle-selection.sh \
  "$policy" "$policy_test" "$selection_test" "$engine" > "$test_dir/inputs.sha256"
git -C "$repo_root" rev-parse HEAD > "$test_dir/head.txt"

host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) fail "unsupported host architecture: $host_arch" ;; esac
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
test -d "$host_sdk" || fail 'macOS SDK path is not a directory'
mkdir -p "$test_dir/module-cache"
export SWIFT_NUM_THREADS=1
flags=(-parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors
  -j 1 -num-threads 1 -target "$host_arch-apple-macosx14.0" -sdk "$host_sdk"
  -module-cache-path "$test_dir/module-cache")

nice -n 15 xcrun swiftc "${flags[@]}" "$policy" "$policy_test" \
  -o "$test_dir/sample-policy" 2>&1 | tee "$test_dir/sample-policy.compile.log"
nice -n 15 "$test_dir/sample-policy" 2>&1 | tee "$test_dir/sample-policy.run.log"
nice -n 15 xcrun swiftc "${flags[@]}" "$selection_test" \
  -o "$test_dir/selection-contract" 2>&1 | tee "$test_dir/selection-contract.compile.log"
nice -n 15 "$test_dir/selection-contract" 2>&1 | tee "$test_dir/selection-contract.run.log"
shasum -a 256 -c "$test_dir/inputs.sha256" > "$test_dir/input-readback.log"
printf 'PASS AVKit sample policy and selection source contract; receipts: %s\n' "$test_dir"
