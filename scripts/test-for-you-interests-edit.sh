#!/usr/bin/env bash
set -euo pipefail
# Strict Swift 6 check of the interests picker's session rules (no app build, device or account).
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/for-you-interests-edit.XXXXXX)
trap 'rm -rf "$dir"' EXIT
{
  printf '%s\n' 'import Foundation'
  sed -n '/^indirect enum VortxJSON/,/^}/p' app/SourcesShared/VortxResourceBridge.swift
  sed -n '/^enum VortxNativeError/,/^}/p' app/SourcesShared/VortxNativeRuntime.swift
  printf '%s\n' 'enum VortxNativeHostPreferences {'
  sed -n '/^    static let forYouPrefix = /,/^    }$/p' app/SourcesShared/VortxNativeHostPreferences.swift
  printf '%s\n' '}'
} > "$dir/support.swift"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  -module-cache-path "$dir/module-cache" "$dir/support.swift" app/SourcesShared/ForYouInterests.swift \
  app/SourcesShared/ForYouInterestsEdit.swift app/Tests/ForYouInterestsEditTests.swift -o "$dir/interests-edit"
"$dir/interests-edit"
