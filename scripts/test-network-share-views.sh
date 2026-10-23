#!/usr/bin/env bash
set -euo pipefail
# Type checks the real network share store and screens per platform SDK (tvOS 18, iOS 16, macOS 14) against
# signature stubs (ForYouViewStubs.swift + NetworkShareViewStubs.swift). No app build, device or network.
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/network-share-views.XXXXXX)
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
  "$dir/support.swift" app/Tests/ForYouViewStubs.swift app/Tests/NetworkShareViewStubs.swift
  app/SourcesShared/NetworkShares.swift app/SourcesShared/NetworkShareClient.swift app/SourcesShared/NetworkShareStore.swift
  app/SourcesShared/SMB/NetworkShareSMB.swift -import-objc-header app/SourcesShared/SMB/VortXSMBShim.h
)
check() {
  local sdk=$1 target=$2
  shift 2
  xcrun --sdk "$sdk" swiftc -typecheck -swift-version 5 -target "$target" "$@"
  printf 'type-checked: %s\n' "$target"
}
check appletvsimulator arm64-apple-tvos18.0-simulator "${shared[@]}" app/SourcesTV/TVNetworkSharesView.swift
check iphonesimulator arm64-apple-ios16.0-simulator "${shared[@]}" app/SourcesiOS/iOSNetworkSharesView.swift
check macosx arm64-apple-macos14.0 "${shared[@]}" app/SourcesiOS/iOSNetworkSharesView.swift
echo "network share views: type-checked on tvOS, iOS and macOS"
