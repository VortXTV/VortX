#!/usr/bin/env bash
set -euo pipefail
# Real ForYouInterests.swift and ForYouDiscover.swift, with VortxJSON and VortxNativeError extracted
# from production sources. No app build, network, account or device.
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/for-you-model.XXXXXX)
trap 'rm -rf "$dir"' EXIT
{
  printf '%s\n' 'import Foundation'
  sed -n '/^indirect enum VortxJSON/,/^}/p' app/SourcesShared/VortxResourceBridge.swift
  sed -n '/^enum VortxNativeError/,/^}/p' app/SourcesShared/VortxNativeRuntime.swift
  # The real For You validator every peer runs, lifted out of the host preference carrier.
  printf '%s\n' 'enum VortxNativeHostPreferences {'
  sed -n '/^    static let forYouPrefix = /,/^    }$/p' app/SourcesShared/VortxNativeHostPreferences.swift
  printf '%s\n' '}'
} > "$dir/support.swift"
grep -q 'static func validateForYouField' "$dir/support.swift"
sed -n '/^struct MetaPreview: Identifiable, Decodable, Hashable {/,/^}/p' app/SourcesShared/Addon.swift > "$dir/preview.swift"
mkdir -p "$dir/model" "$dir/rows"
for target in model rows; do
  cp "$dir/support.swift" app/SourcesShared/ForYouInterests.swift app/SourcesShared/ForYouDiscover.swift "$dir/$target/"
done
cp app/SourcesShared/HomeRailPreferences.swift "$dir/model/"
cp app/Tests/ForYouModelTests.swift "$dir/model/main.swift"
# The rows model runs against a recording TMDBClient fake defined in its test file.
cp "$dir/preview.swift" app/SourcesShared/ForYouRowsModel.swift "$dir/rows/"
cp app/Tests/ForYouRowsModelTests.swift "$dir/rows/main.swift"
for target in model rows; do
  xcrun swiftc -swift-version 5 -o "$dir/$target/run" "$dir/$target"/*.swift
  "$dir/$target/run"
done
