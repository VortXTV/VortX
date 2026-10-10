#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
test_dir=$(mktemp -d "$PWD/app/build/native-preference-intent.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
{ printf '%s\n' 'import Foundation'; sed -n '/^indirect enum VortxJSON:/,/^}$/p' app/SourcesShared/VortxResourceBridge.swift; } > "$test_dir/VortxJSON.swift"
xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    "$test_dir/VortxJSON.swift" app/SourcesShared/NativePreferenceIntentStore.swift \
    app/Tests/NativePreferenceIntentStoreTests.swift -o "$test_dir/native-preference-intent-tests"
"$test_dir/native-preference-intent-tests" "$test_dir/journal"
