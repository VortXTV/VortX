#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
accent_test_dir=$(mktemp -d app/build/player-accent-controls-tests.XXXXXX)
node scripts/prepare-player-accent-controls.cjs "$accent_test_dir"
nice -n 15 xcrun swiftc -Onone -j 1 -num-threads 1 -swift-version 6 -target "$(uname -m)-apple-macosx14.0" -parse-as-library "$accent_test_dir/accent.swift" -o "$accent_test_dir/accent-controls" 2>&1 | tee "$accent_test_dir/compiler.log"
nice -n 15 "$accent_test_dir/accent-controls" 2>&1 | tee "$accent_test_dir/runtime.log"
