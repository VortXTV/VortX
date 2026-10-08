#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
bootstrap_test_dir=$(mktemp -d app/build/apple-legacy-bootstrap.XXXXXX)
# Compile the real shipping roster DTO and its Foundation dependencies, never a hand-written mock.
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$bootstrap_test_dir/UserProfile.swift"
{
  printf '%s\n' 'import Foundation'
  sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$bootstrap_test_dir/Discovery.swift"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -warnings-as-errors \
  "$bootstrap_test_dir/UserProfile.swift" "$bootstrap_test_dir/Discovery.swift" \
  app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxLegacyBootstrapMaterial.swift \
  app/Tests/VortxLegacyBootstrapMaterialTests.swift -o "$bootstrap_test_dir/bootstrap-tests"
"$bootstrap_test_dir/bootstrap-tests"
