#!/usr/bin/env bash
set -euo pipefail
# Complete production actor with a controlled recording actor seam. No network, app, playback or device.
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/landscape-backdrop-cache.XXXXXX)
host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) echo "Unsupported host architecture: $host_arch" >&2; exit 2 ;; esac
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
echo "Evidence: $PWD/$dir"
cp app/SourcesShared/LandscapeBackdropCache.swift "$dir/cache.swift"
cp app/Tests/LandscapeBackdropCacheTests.swift "$dir/main.swift"
nice -n 15 xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -j 1 -num-threads 1 -target "$host_arch-apple-macosx14.0" -sdk "$host_sdk" \
  -module-cache-path "$dir/module-cache" -o "$dir/run" "$dir/cache.swift" "$dir/main.swift"
"$dir/run"
shasum -a 256 app/SourcesShared/LandscapeBackdropCache.swift app/Tests/LandscapeBackdropCacheTests.swift \
  scripts/test-landscape-backdrop-cache.sh "$dir/cache.swift" "$dir/main.swift"
