#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p app/build

source_file=app/SourcesShared/SyncSettingsView.swift
fixture_dir=$(mktemp -d "$PWD/app/build/move-seeding-status.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT

# Compile the real production helper and mechanically extract the real syncNow method. The harness
# supplies only the manager state and action results that the extracted method reads or calls.
method_file="$fixture_dir/SyncNowMethod.swift"
sed -n '/^[[:space:]]*private func syncNow()/,/^[[:space:]]*private func submit()/p' "$source_file" \
    | sed '$d; s/private func syncNow()/func syncNow()/' > "$method_file"
test "$(rg -c 'func syncNow\(\)' "$method_file")" -eq 1

harness_file="$fixture_dir/SyncNowHarness.swift"
{
    printf '%s\n' 'import Foundation'
    printf '%s\n' '@MainActor'
    printf '%s\n' 'final class SyncSettingsViewStatusHarness {'
    printf '%s\n' '    var sync = VortXSyncManager()'
    printf '%s\n' '    var syncing = false'
    printf '%s\n' '    var syncNote: String?'
    printf '%s\n' '    var showConflict = false'
    sed -n '1,240p' "$method_file"
    printf '%s\n' '}'
} > "$harness_file"

printf 'production source sha256: '
shasum -a 256 "$source_file" | awk '{print $1}'
printf 'extracted syncNow sha256: '
shasum -a 256 "$method_file" | awk '{print $1}'
printf 'status test sha256: '
shasum -a 256 app/Tests/MoveSeedingStatusTests.swift | awk '{print $1}'

xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    app/SourcesShared/MoveSeeding.swift \
    app/Tests/MoveSeedingStatusTests.swift \
    "$harness_file" \
    -o "$fixture_dir/move-seeding-status-tests"

"$fixture_dir/move-seeding-status-tests"
