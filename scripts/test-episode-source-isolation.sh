#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
episode_test_dir=$(mktemp -d app/build/episode-source-isolation.XXXXXX)
xcrun swiftc --version
xcodebuild -version
sw_vers -productVersion
uname -m
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/SourceSettlementPolicy.swift app/SourcesShared/NextEpisodePreparationWork.swift \
  app/SourcesShared/SourceIndexContract.swift app/SourcesShared/SourceIndexIdentity.swift \
  app/SourcesShared/EpisodeEngineBindingRequest.swift app/SourcesShared/EpisodeSourceCollection.swift app/Tests/EpisodeSourceCollectionTests.swift \
  -o "$episode_test_dir/collection"
"$episode_test_dir/collection"
xcrun swiftc -D VORTX_NATIVE_DATA_ENGINE -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/SourceSettlementPolicy.swift app/SourcesShared/NextEpisodePreparationWork.swift \
  app/SourcesShared/SourceIndexContract.swift app/SourcesShared/SourceIndexIdentity.swift \
  app/SourcesShared/EpisodeEngineBindingRequest.swift app/SourcesShared/EpisodeSourceCollection.swift app/Tests/EpisodeSourceCollectionTests.swift \
  -o "$episode_test_dir/native-collection"
"$episode_test_dir/native-collection"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/NextEpisodePreparationWork.swift app/SourcesTV/NextEpisodePreloadPolicy.swift \
  app/Tests/NextEpisodePreloadPolicyTests.swift -o "$episode_test_dir/preload"
"$episode_test_dir/preload"
xcrun swiftc -frontend -parse app/SourcesTV/TVPlayerView.swift app/SourcesTV/TVEpisodePanel.swift app/SourcesiOS/iOSDetailView.swift app/SourcesiOS/iOSNextEpisodePreparer.swift app/SourcesiOS/iOSRootView.swift app/Sources/PlayerScreen.swift
