#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
build_dir="$repo_root/app/build/source-contracts"
mkdir -p "$build_dir"

{
  printf '%s\n' 'import Foundation' 'enum MPVSubtitleAdmission {'
  sed -n '/^    private nonisolated static func acceptsExternalSubtitleURL(/,/^    }/p' \
    app/Sources/Player/MPVMetalViewController.swift | sed 's/private nonisolated static func/nonisolated static func/'
  printf '%s\n' '}'
} > "$build_dir/mpv-subtitle-url-admission.swift"
# Fail at the declaration boundary if the current source shape changes; never compile an empty facade.
grep -Fq '    nonisolated static func acceptsExternalSubtitleURL(' "$build_dir/mpv-subtitle-url-admission.swift" || {
  printf '%s\n' 'Missing current production subtitle URL prefilter' >&2
  exit 1
}
swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "$build_dir/mpv-subtitle-url-admission.swift" app/Tests/MPVSubtitleURLAdmissionTests.swift \
  -o "$build_dir/mpv-subtitle-url-admission"
"$build_dir/mpv-subtitle-url-admission"

swiftc -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/SubtitleStyle.swift app/Tests/SubtitleStyleBackgroundTests.swift \
  -o "$build_dir/subtitle-style-background"
"$build_dir/subtitle-style-background"
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
swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Tests/TraktCheckinVisibilityContractTests.swift -o "$build_dir/trakt-checkin-visibility"
"$build_dir/trakt-checkin-visibility"
swiftc -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/AVPlayerRecoverySettlementPolicy.swift \
  app/Sources/Player/VortXHLSSeekAnchorState.swift app/Sources/Player/RemuxResumePolicy.swift \
  app/Tests/AVPlayerRecoverySettlementPolicyTests.swift -o "$build_dir/avplayer-recovery-settlement"
"$build_dir/avplayer-recovery-settlement"
swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Tests/SubtitleSelectionSettlementContractTests.swift -o "$build_dir/subtitle-selection-settlement"
"$build_dir/subtitle-selection-settlement"
swiftc -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/MPVTrack.swift app/Sources/Player/AudioLanguagePolicy.swift \
  app/Sources/Player/TrackSelector.swift app/Tests/TrackSelectorAvailabilityTests.swift \
  -o "$build_dir/track-selector"
"$build_dir/track-selector"
