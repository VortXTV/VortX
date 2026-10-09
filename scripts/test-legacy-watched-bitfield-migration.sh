#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out="${TMPDIR:-/tmp}/vortx-legacy-watched-bitfield-migration-tests"
swiftc "$repo_root/app/SourcesShared/LegacyWatchedBitfieldDecoder.swift" \
  "$repo_root/app/SourcesShared/LegacyWatchedBitfieldMigrationEvidence.swift" \
  "$repo_root/app/Tests/LegacyWatchedBitfieldMigrationEvidenceTests.swift" \
  -o "$out" -lz
"$out"
