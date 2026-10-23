#!/usr/bin/env bash
# TV guide policy: schedules from channel metas, the time window, the cell layout, URLs and channel list.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/live-guide.XXXXXX)
trap 'rm -rf "$dir"' EXIT
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/LiveGuide.swift app/Tests/LiveGuideTests.swift -o "$dir/guide"
"$dir/guide"
