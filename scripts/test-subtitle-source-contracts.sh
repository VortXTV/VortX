#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
build_dir="$repo_root/app/build/source-contracts"
mkdir -p "$build_dir"

swiftc -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/SubtitleRequestMetadata.swift app/SourcesShared/SubtitleAddons.swift \
  app/Tests/SubtitleAddonFileMatchingTests.swift -o "$build_dir/subtitle-file-matching"
"$build_dir/subtitle-file-matching"
swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/BatchMetaSlotPolicy.swift app/Tests/BatchMetaSlotPolicyTests.swift \
  -o "$build_dir/batch-meta-slot"
"$build_dir/batch-meta-slot"
swiftc -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/SourcePresentationPolicy.swift app/Tests/SourcePresentationPolicyTests.swift \
  -o "$build_dir/source-presentation"
"$build_dir/source-presentation"
swiftc -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/SourcePresentationPolicy.swift app/Tests/PhoneDetailHeroCompositionTests.swift \
  -o "$build_dir/phone-detail-hero"
"$build_dir/phone-detail-hero"
swiftc -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/MPVTrack.swift app/Sources/Player/AudioLanguagePolicy.swift \
  app/Sources/Player/TrackSelector.swift app/Tests/TrackSelectorAvailabilityTests.swift \
  -o "$build_dir/track-selector"
"$build_dir/track-selector"
