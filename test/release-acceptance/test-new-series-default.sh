#!/usr/bin/env bash
set -euo pipefail

fixture_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${1:-$fixture_root}"
source_root="$(cd "$source_root" && pwd)"
build_dir="$fixture_root/app/build/release-acceptance"
mkdir -p "$build_dir"

printf 'Acceptance source revision: %s\n' "$(git -C "$source_root" rev-parse HEAD)"
shasum -a 256 \
  "$source_root/app/SourcesShared/EpisodeDefaultSelectionPolicy.swift" \
  "$source_root/app/SourcesShared/AppleCWSeasonRolloverPolicy.swift" \
  "$source_root/app/SourcesTV/DetailView.swift" \
  "$source_root/app/SourcesiOS/iOSDetailView.swift"

xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  "$source_root/app/SourcesShared/EpisodeDefaultSelectionPolicy.swift" \
  "$source_root/app/SourcesShared/AppleCWSeasonRolloverPolicy.swift" \
  "$fixture_root/app/Tests/NewSeriesDefaultEpisodePolicyTests.swift" \
  -o "$build_dir/new-series-default"
"$build_dir/new-series-default" "$source_root"
