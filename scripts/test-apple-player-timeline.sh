#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
timeline_test_dir=$(mktemp -d app/build/player-timeline-tests.XXXXXX)
# Extract the actual production declarations. Only access control changes so the separate
# test file can name these private views; their bodies and callbacks are never rewritten.
{
  printf '%s\n' 'import SwiftUI'
  sed -n '/^private final class TimePosClock:/,/^\/\/\/ One provider refresh/p' \
    app/Sources/PlayerScreen.swift | sed '$d; s/^private //'
} > "$timeline_test_dir/timeline.swift"
xcrun swiftc -parse-as-library \
  "$timeline_test_dir/timeline.swift" app/Sources/Player/SkipSegments.swift \
  app/Tests/PlayerSeekTimelineConstructionTests.swift -o "$timeline_test_dir/construction"
"$timeline_test_dir/construction"
node --test test/apple-player-timeline-boundaries.test.js
