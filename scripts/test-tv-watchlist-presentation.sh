#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p app/build
watchlist_test_dir=$(mktemp -d "$PWD/app/build/tv-watchlist-presentation.XXXXXX")
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct TVWatchlistPresentationFence</,/^}$/p' app/SourcesTV/TVWatchlistView.swift
} > "$watchlist_test_dir/PresentationFence.swift"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    "$watchlist_test_dir/PresentationFence.swift" app/Tests/TVWatchlistPresentationTests.swift \
    -o "$watchlist_test_dir/watchlist-presentation"
"$watchlist_test_dir/watchlist-presentation"
xcrun swiftc -frontend -parse -D VORTX_NATIVE_DATA_ENGINE \
    app/SourcesTV/LibraryView.swift app/SourcesTV/TVWatchlistView.swift
xcrun swiftc -frontend -parse app/SourcesTV/LibraryView.swift app/SourcesTV/TVWatchlistView.swift
printf 'Retained TV Watchlist presentation receipt: %s\n' "$watchlist_test_dir"
