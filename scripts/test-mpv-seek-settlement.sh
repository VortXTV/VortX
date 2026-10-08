#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
build_dir="$repo_root/app/build/mpv-seek-settlement"
mkdir -p "$build_dir"
# Compile actual token/event declarations without the unrelated app models.
{
  printf 'import Foundation\n'
  sed -n '/^struct PlayerLoadToken: /,/^\/\/\/ Pure callback-provenance/{
    /^\/\/\/ Pure callback-provenance/d
    p
  }' app/SourcesShared/CoreModels.swift
} > "$build_dir/PlayerPositionEvent.swift"
swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift \
  "$build_dir/PlayerPositionEvent.swift" app/Tests/MPVSeekSettlementPolicyTests.swift \
  -o "$build_dir/policy"
"$build_dir/policy"
