#!/usr/bin/env bash
# The Library keeps every title watched or started unless the viewer removed it after its last watch.
set -euo pipefail
cd "$(dirname "$0")/.."
dir=$(mktemp -d "${TMPDIR:-/tmp}/library-previously-watched.XXXXXX")
trap 'rm -rf "$dir"' EXIT
{ echo 'import Foundation'; sed -n '/^indirect enum VortxJSON/,/^}$/p' app/SourcesShared/VortxResourceBridge.swift; } > "$dir/VortxJSON.swift"
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors "$dir/VortxJSON.swift" \
  app/SourcesShared/VortxNativePreviouslyWatched.swift app/Tests/VortxNativePreviouslyWatchedTests.swift -o "$dir/tests"
"$dir/tests"
