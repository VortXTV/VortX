#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
continuity_test_dir=$(mktemp -d app/build/continuity-tests.XXXXXX)
# Mechanical extraction: execute the real Foundation-only production policy, not a copied mirror.
sed -n '/^enum ChosenReleaseContinuityPolicy {/,/^}$/p' app/SourcesShared/StreamRanking.swift > "$continuity_test_dir/ChosenReleasePolicy.swift"
xcrun swiftc -parse-as-library -warnings-as-errors "$continuity_test_dir/ChosenReleasePolicy.swift" app/Tests/ChosenReleaseContinuityTests.swift -o "$continuity_test_dir/chosen-release"
"$continuity_test_dir/chosen-release"
{
  printf '%s\n' 'import Foundation'
  sed -n '/^@MainActor func iOSResolveRankedEpisodeCandidate(/,/^}$/p' app/SourcesiOS/iOSDetailView.swift
} > "$continuity_test_dir/RankedEpisodeResolver.swift"
{
  printf '%s\n' 'import Foundation' 'enum EpisodePlaybackIdentity {'
  sed -n '/^    static func resolvedEpisodeMediaURL(/,/^    }/p' app/SourcesShared/CoreModels.swift
  printf '%s\n' '}'
} > "$continuity_test_dir/EpisodeMediaURLPolicy.swift"
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/SourceSettlementPolicy.swift app/SourcesShared/EpisodeResolutionBudget.swift app/SourcesShared/NextEpisodePreparationWork.swift "$continuity_test_dir/RankedEpisodeResolver.swift" "$continuity_test_dir/EpisodeMediaURLPolicy.swift" app/Tests/RankedEpisodeResolutionTests.swift -o "$continuity_test_dir/episode-candidates"
"$continuity_test_dir/episode-candidates"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors app/SourcesShared/SourceSettlementPolicy.swift app/SourcesShared/EpisodeResolutionBudget.swift app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift app/Tests/EpisodeResolutionBudgetTests.swift -o "$continuity_test_dir/episode-budget"
"$continuity_test_dir/episode-budget"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift app/Tests/ResumeSeekIntentContractTests.swift -o "$continuity_test_dir/seek-intent"
"$continuity_test_dir/seek-intent"
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/LibraryTombstones.swift app/SourcesShared/AddonTombstones.swift app/Tests/AddonOwnerStorageTests.swift -o "$continuity_test_dir/addon-owner"
"$continuity_test_dir/addon-owner"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors app/SourcesShared/MacWindowControls.swift app/Tests/MacWindowControlsTests.swift -o "$continuity_test_dir/mac-controls"
"$continuity_test_dir/mac-controls"
