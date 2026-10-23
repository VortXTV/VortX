#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
reader_test_dir=$(mktemp -d "$PWD/app/build/simkl-reader-cancellation.XXXXXX")
printf 'Retained reader fixture %s\n' "$reader_test_dir"
# The isolated fixture uses the actual credential-set identity declaration, not the OAuth runtime.
{
  printf '%s\n' 'import Foundation'
  sed -n '/^struct SIMKLSessionID: /,/^}$/p' app/SourcesShared/SIMKLAuth.swift
} > "$reader_test_dir/SIMKLSessionID.swift"
test "$(rg -c '^struct SIMKLSessionID:' "$reader_test_dir/SIMKLSessionID.swift")" = 1
inputs=(app/SourcesShared/SIMKLModels.swift app/SourcesShared/ContinueWatchingPreferences.swift
  app/SourcesShared/SIMKLContinueWatching.swift "$reader_test_dir/SIMKLSessionID.swift"
  app/Tests/SIMKLContinueWatchingReaderCancellationTests.swift)
shasum -a 256 "$0" app/SourcesShared/SIMKLAuth.swift "${inputs[@]}" > "$reader_test_dir/inputs.sha256"
nice -n 15 xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -warnings-as-errors -whole-module-optimization -j 1 -num-threads 1 \
  "${inputs[@]}" -o "$reader_test_dir/reader-tests"
nice -n 15 "$reader_test_dir/reader-tests"
shasum -a 256 --check "$reader_test_dir/inputs.sha256"
