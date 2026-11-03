#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
build_dir="$repo_root/app/build/source-title-match"
mkdir -p "$build_dir"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  app/SourcesShared/SourceTitleMatch.swift app/Tests/SourceTitleMatchTests.swift \
  -o "$build_dir/source-title-match"
"$build_dir/source-title-match" test/fixtures/source-title-match.json
