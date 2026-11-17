#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
bootstrap_test_dir=$(mktemp -d app/build/apple-legacy-bootstrap.XXXXXX)
# Compile the real shipping roster DTO and its Foundation dependencies, never a hand-written mock.
{ printf '%s\n' 'import Foundation' 'import CryptoKit'; sed -n '/^struct UserProfile: /,/^}$/p' app/SourcesShared/Profiles.swift; } > "$bootstrap_test_dir/UserProfile.swift"
grep -q '^}$' "$bootstrap_test_dir/UserProfile.swift"
{
  printf '%s\n' 'import Foundation'
  sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$bootstrap_test_dir/Discovery.swift"
/usr/bin/nice -n 15 xcrun swiftc -j 1 -num-threads 1 -swift-version 6 -strict-concurrency=complete -parse-as-library -warnings-as-errors \
  "$bootstrap_test_dir/UserProfile.swift" "$bootstrap_test_dir/Discovery.swift" \
  app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxProfileOverlayWitness.swift \
  app/SourcesShared/LegacyWatchedBitfieldDecoder.swift app/SourcesShared/LegacyWatchedBitfieldMigrationEvidence.swift \
  app/SourcesShared/VortxLegacyWatchedMigration.swift app/SourcesShared/VortxLegacyBootstrapMaterial.swift \
  app/SourcesShared/VortxNativeBootstrapArchive.swift \
  app/Tests/VortxLegacyBootstrapMaterialTests.swift -o "$bootstrap_test_dir/bootstrap-tests" -lz
"$bootstrap_test_dir/bootstrap-tests"
