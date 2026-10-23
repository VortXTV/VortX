#!/usr/bin/env bash
set -euo pipefail
# Type checks the real TV guide model, grid and screens per platform SDK (tvOS 18, iOS 16, macOS 14) against
# signature stubs. No app build, device or network.
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/live-guide-views.XXXXXX)
trap 'rm -rf "$dir"' EXIT
{
  printf '%s\n' 'import Foundation'
  sed -n '/^indirect enum VortxJSON/,/^}/p' app/SourcesShared/VortxResourceBridge.swift
  sed -n '/^enum VortxNativeError/,/^}/p' app/SourcesShared/VortxNativeRuntime.swift
  printf '%s\n' 'enum VortxNativeHostPreferences {'
  sed -n '/^    static let forYouPrefix = /,/^    }$/p' app/SourcesShared/VortxNativeHostPreferences.swift
  printf '%s\n' '}'
} > "$dir/support.swift"
shared=(
  "$dir/support.swift" app/Tests/ForYouViewStubs.swift app/Tests/NetworkShareViewStubs.swift app/Tests/LiveGuideViewStubs.swift
  app/SourcesShared/LiveGuide.swift app/SourcesShared/LiveGuideGrid.swift
)
check() {
  local sdk=$1 target=$2
  shift 2
  xcrun --sdk "$sdk" swiftc -typecheck -swift-version 5 -target "$target" "$@"
  printf 'type-checked: %s\n' "$target"
}
check appletvsimulator arm64-apple-tvos18.0-simulator "${shared[@]}" app/SourcesTV/TVLiveGuideView.swift
check iphonesimulator arm64-apple-ios16.0-simulator "${shared[@]}" app/SourcesiOS/iOSLiveGuideView.swift
check macosx arm64-apple-macos14.0 "${shared[@]}" app/SourcesiOS/iOSLiveGuideView.swift
echo "TV guide views: type-checked on tvOS, iOS and macOS"
