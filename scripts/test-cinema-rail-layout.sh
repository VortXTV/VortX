#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
layout_test_dir=$(mktemp -d "$PWD/app/build/cinema-rail-layout.XXXXXX")
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/CinemaRailLayout.swift app/Tests/CinemaRailLayoutTests.swift -o "$layout_test_dir/rail-layout"
"$layout_test_dir/rail-layout"
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/CinemaPreviewSynopsis.swift app/Tests/CinemaPreviewSynopsisTests.swift -o "$layout_test_dir/synopsis"
"$layout_test_dir/synopsis"
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/EpisodeReturnIdentityPolicy.swift app/Tests/EpisodeReturnIdentityPolicyTests.swift -o "$layout_test_dir/episode-return"
"$layout_test_dir/episode-return"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors -D VORTX_NATIVE_DATA_ENGINE \
    app/SourcesShared/EpisodeReturnIdentityPolicy.swift app/SourcesShared/PlaybackNavigationOwner.swift \
    app/Tests/PlaybackNavigationOwnerTests.swift -o "$layout_test_dir/navigation-owner"
"$layout_test_dir/navigation-owner"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    app/SourcesShared/EpisodeEngineBindingRequest.swift app/Tests/EpisodeEngineBindingRequestTests.swift \
    -o "$layout_test_dir/engine-binding"
"$layout_test_dir/engine-binding"
swift app/Tests/MacSettingsShellContractTests.swift
swift app/Tests/CinemaNativePresentationContractTests.swift
