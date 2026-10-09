#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_root/app/build/legacy-watched-bitfield"
mkdir -p "$build_dir"
xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  "$repo_root/app/SourcesShared/LegacyWatchedBitfieldDecoder.swift" \
  "$repo_root/app/Tests/LegacyWatchedBitfieldDecoderTests.swift" \
  -lz -o "$build_dir/legacy-watched-bitfield-tests"
"$build_dir/legacy-watched-bitfield-tests" "$repo_root/test/fixtures/legacy-watched-bitfield.json"
