#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
generation_test_dir=$(mktemp -d "$PWD/app/build/source-index-publication-generations.XXXXXX")
printf 'Source SHA256 %s\nRetained synthetic output %s\n' \
    "$(shasum -a 256 app/SourcesShared/SourceIndexClient.swift | awk '{print $1}')" "$generation_test_dir"
# Extract unchanged lifecycle, coalescing, and per-view ownership methods, stopping before the
# unrelated stream merge/admission implementation. The fixture supplies only surrounding app types.
awk 'BEGIN {print "import Foundation"}
    /^struct SourceIndexLifecycleSnapshot:/ {lifecycle=1}
    /^\/\/\/ Client for VortX/ {lifecycle=0}
    lifecycle {print}
    /^actor SourceIndexFetchCoalescer/ {coalescer=1}
    /^\/\/ MARK: - Shared auxiliary-source caller/ {coalescer=0}
    coalescer {print}
    /^final class SourceIndexServeSource:/ {owner=1; print "@MainActor"}
    /^    \/\/\/ Merge the community sources into/ {owner=0; print "}"}
    owner {print}' app/SourcesShared/SourceIndexClient.swift > "$generation_test_dir/ActualOwnership.swift"
xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    "$generation_test_dir/ActualOwnership.swift" app/Tests/SourceIndexPublicationGenerationTests.swift \
    -o "$generation_test_dir/source-index-publication-generations"
"$generation_test_dir/source-index-publication-generations"
shasum -a 256 app/SourcesShared/SourceIndexClient.swift app/Tests/SourceIndexPublicationGenerationTests.swift \
    scripts/test-source-index-publication-generations.sh "$generation_test_dir/ActualOwnership.swift"
