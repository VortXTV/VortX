#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
migration_test_dir=$(mktemp -d app/build/apple-watched-migration.XXXXXX)

# Compile the production profile and migration sources. The owner DTO excerpt avoids pulling the
# app UI into this Foundation-only contract test; the adapter, witness, decoder, producer, and
# material encoder below are the real shipping implementations.
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' \
  app/SourcesShared/Profiles.swift > "$migration_test_dir/UserProfile.swift"
{
  printf '%s\n' 'import Foundation'
  sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$migration_test_dir/Discovery.swift"

xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -warnings-as-errors \
  "$migration_test_dir/UserProfile.swift" "$migration_test_dir/Discovery.swift" \
  app/SourcesShared/ProfileAddonPreferences.swift \
  app/SourcesShared/VortxProfileOverlayWitness.swift \
  app/SourcesShared/LegacyWatchedBitfieldDecoder.swift \
  app/SourcesShared/LegacyWatchedBitfieldMigrationEvidence.swift \
  app/SourcesShared/AuthenticatedHTTPTransport.swift \
  app/SourcesShared/VortxLegacyWatchedMetadataTransport.swift \
  app/SourcesShared/VortxLegacyWatchedMigration.swift \
  app/SourcesShared/VortxLegacyBootstrapMaterial.swift \
  app/Tests/VortxLegacyWatchedMigrationTests.swift \
  -lz -o "$migration_test_dir/watched-migration-tests"
"$migration_test_dir/watched-migration-tests"
