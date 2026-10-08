#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
revision_test_dir=$(mktemp -d app/build/sync-derived-revisions.XXXXXX)
source_file=app/SourcesShared/VortXSyncManager.swift
swift_flags=()
if [[ ${1:-} == --baseline-ref ]]; then
    test $# -eq 2
    git show "$2:app/SourcesShared/VortXSyncManager.swift" > "$revision_test_dir/baseline.swift"
    source_file="$revision_test_dir/baseline.swift"
    swift_flags=(-D BASELINE_SYNC_UPLOAD)
fi
# Compile the production retry method and candidate type with a deterministic relay; only
# transport/account collaborators are substituted. The base and retry policy are not mirrored.
cp app/Tests/SyncDerivedDocumentRevisionTests.swift "$revision_test_dir/Combined.swift"
{
    printf '\n%s\n' 'extension UploadHarness {'
    if (( ${#swift_flags[@]} )); then
        sed -n '/^    private struct DerivedSyncDoc {/,/^    }/p' app/SourcesShared/VortXSyncManager.swift
    else
        sed -n '/^    private struct DerivedSyncDoc {/,/^    }/p' "$source_file"
    fi
    sed -n '/^    private func pushDerivedDoc(/,/^    }/p' "$source_file"
    printf '%s\n' '}'
} >> "$revision_test_dir/Combined.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    "${swift_flags[@]}" app/SourcesShared/SyncDocumentRevisionPolicy.swift \
    "$revision_test_dir/Combined.swift" -o "$revision_test_dir/revisions"
shasum -a 256 "$source_file" app/SourcesShared/SyncDocumentRevisionPolicy.swift
"$revision_test_dir/revisions"
