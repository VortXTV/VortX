#!/usr/bin/env bash
set -euo pipefail
# Complete production actor with a controlled TMDB fake. No network, app, playback or device.
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/landscape-backdrop-cache.XXXXXX)
cp app/SourcesShared/LandscapeBackdropCache.swift "$dir/cache.swift"
cp app/Tests/LandscapeBackdropCacheTests.swift "$dir/main.swift"
xcrun swiftc -swift-version 5 -o "$dir/run" "$dir/cache.swift" "$dir/main.swift"
"$dir/run"
