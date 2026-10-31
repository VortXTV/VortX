#!/usr/bin/env bash
set -euo pipefail

# Root integration places this runner under scripts/ and fixtures under scripts/fixtures/pooled-subtitle/.
# This compiles actual maintained caller declarations against deterministic transport/engine doubles.
# It does not certify AVFoundation reference reads, MPV renderer settlement, or any device runtime.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$repo_root/scripts/fixtures/pooled-subtitle"
mkdir -p "$repo_root/app/build"
test_dir="$(mktemp -d "$repo_root/app/build/pooled-automatic-selection.XXXXXX")"
printf 'Evidence: %s\n' "$test_dir"
python3 "$fixture_root/extract-callers.py" "$repo_root" "$fixture_root/caller-fixture.swift" \
    "$test_dir/ActualPooledCallers.swift"
export SWIFT_NUM_THREADS=1
mkdir -p "$test_dir/module-cache"
nice -n 15 xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -warnings-as-errors -j 1 -num-threads 1 -module-cache-path "$test_dir/module-cache" \
    "$test_dir/ActualPooledCallers.swift" -o "$test_dir/callers" 2>&1 | tee "$test_dir/compile.log"
nice -n 15 "$test_dir/callers" 2>&1 | tee "$test_dir/run.log"
printf 'PASS extracted pooled automatic callers; receipts: %s\n' "$test_dir"
