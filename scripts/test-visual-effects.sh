#!/usr/bin/env bash
# Settings > Effects and performance policy (Apple). Android twin: VisualEffectsTest.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/visual-effects.XXXXXX)
trap 'rm -rf "$dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/VisualEffects.swift app/Tests/VisualEffectsTests.swift -o "$dir/effects"
"$dir/effects"
