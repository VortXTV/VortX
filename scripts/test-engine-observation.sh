#!/usr/bin/env bash
# Visible-only engine observation (EngineChangeGate) used by the tvOS tab roots and Home.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/engine-observation.XXXXXX)
trap 'rm -rf "$dir"' EXIT
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/EngineObservation.swift \
  app/Tests/EngineChangeGateTests.swift -o "$dir/gate"
"$dir/gate"
