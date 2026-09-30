#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
build_dir="$repo_root/app/build/apple-parity-contracts"
mkdir -p "$build_dir"

swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift \
  app/Tests/DeferredResumeSeekReconciliationPolicyTests.swift -o "$build_dir/deferred-resume"
"$build_dir/deferred-resume"
swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Tests/TVDeferredResumeRecoveryWiringContractTests.swift -o "$build_dir/deferred-resume-wiring"
"$build_dir/deferred-resume-wiring" "$repo_root"

swiftc -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/SkipSegments.swift app/Tests/AutoSkipCountdownPolicyTests.swift \
  -o "$build_dir/auto-skip-policy"
"$build_dir/auto-skip-policy"
swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Tests/AutoSkipCountdownWiringContractTests.swift -o "$build_dir/auto-skip-wiring"
"$build_dir/auto-skip-wiring"
swiftc -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/TraktArtworkPolicy.swift app/SourcesShared/TraktContinueWatchingFold.swift \
  app/Tests/TraktArtworkPolicyTests.swift -o "$build_dir/trakt-artwork"
"$build_dir/trakt-artwork"
swiftc -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/TopShelfSnapshot.swift app/Tests/TopShelfSnapshotTests.swift \
  -o "$build_dir/top-shelf"
"$build_dir/top-shelf"
swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Tests/BecauseYouWatchedOwnerBoundaryContractTests.swift -o "$build_dir/watch-owner"
"$build_dir/watch-owner" "$repo_root"
swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Tests/BecauseYouWatchedAccountOwnerCallsiteContractTests.swift -o "$build_dir/watch-account"
"$build_dir/watch-account" "$repo_root"
swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/BecauseYouWatchedHistoryPolicy.swift \
  app/Tests/BecauseYouWatchedHistoryPolicyContractTests.swift -o "$build_dir/watch-history"
"$build_dir/watch-history" "$repo_root"
swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/BecauseYouWatchedHistoryPolicy.swift \
  app/Tests/BecauseYouWatchedHistoryReceiptContractTests.swift -o "$build_dir/watch-history-receipt"
"$build_dir/watch-history-receipt" "$repo_root"
swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Tests/BecauseYouWatchedCredentialBoundaryContractTests.swift -o "$build_dir/watch-credentials"
"$build_dir/watch-credentials" "$repo_root"
swiftc -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/AVNativeSubtitleOverlayBridge.swift \
  app/Tests/AVNativeSubtitleOverlayBridgeTests.swift -o "$build_dir/native-subtitle-bridge"
"$build_dir/native-subtitle-bridge"
swiftc -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/AVEmbeddedSubtitleBackground.swift \
  app/Tests/AVEmbeddedSubtitleBackgroundTests.swift -o "$build_dir/native-subtitle-background"
"$build_dir/native-subtitle-background"
swiftc -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/DVPlaybackPolicy.swift app/Sources/Player/VortXRemuxBuffer.swift \
  app/Sources/Player/PlayerStallPolicy.swift app/Sources/Player/VortXHLSSeekAnchorState.swift \
  app/Sources/Player/AudioLanguagePolicy.swift app/Sources/Player/MultiAudioPolicy.swift \
  app/Sources/Player/SubtitleRenditionPolicy.swift app/Tests/PlayerLiveContractTests.swift \
  -o "$build_dir/player-live"
"$build_dir/player-live"
