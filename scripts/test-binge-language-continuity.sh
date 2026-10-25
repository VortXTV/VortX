#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
binge_test_dir=$(mktemp -d app/build/binge-language.XXXXXX)
nice -n 15 xcrun swiftc -j 1 -num-threads 1 -whole-module-optimization -parse-as-library -warnings-as-errors \
  app/Sources/Player/AudioLanguagePolicy.swift \
  app/SourcesShared/SeriesSourceSticky.swift \
  app/Tests/SeriesStickyFixtureSupport.swift \
  app/Tests/BingeLanguageContinuityTests.swift -o "$binge_test_dir/choice"
"$binge_test_dir/choice"
nice -n 15 xcrun swiftc -j 1 -num-threads 1 -whole-module-optimization -parse-as-library -warnings-as-errors \
  app/SourcesShared/DetailMetaRecoveryPolicy.swift \
  app/SourcesShared/CatalogRowResolution.swift \
  app/SourcesShared/SubtitleReleaseFingerprint.swift \
  app/SourcesShared/UsenetStreamValidation.swift \
  app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift \
  app/SourcesShared/ProfileAddonPreferences.swift \
  app/SourcesShared/CoreModels.swift \
  app/SourcesShared/SourceSettlementPolicy.swift \
  app/Sources/Player/AudioLanguagePolicy.swift \
  app/SourcesShared/RankingMemo.swift \
  app/SourcesShared/StreamRanking.swift \
  app/Tests/BingeSourceMemoryRaceContractTests.swift -o "$binge_test_dir/ranking"
"$binge_test_dir/ranking"
nice -n 15 xcrun swiftc -frontend -parse -num-threads 1 \
  app/Sources/PlayerScreen.swift app/SourcesTV/TVPlayerView.swift \
  app/SourcesTV/DetailView.swift app/SourcesTV/RootTabView.swift \
  app/SourcesiOS/iOSDetailView.swift app/SourcesiOS/iOSBatchDownloadCoordinator.swift
