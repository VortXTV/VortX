#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Differential regression against the public importer shipped in build 266.
# Synthetic data only; neither variant launches an app or contacts an account.
reopen_baseline=952f7b7e12e102f4b2acaea480e2906a47f5ad24
reopen_sdk="$PWD/app/Vendor/VortxEngine.xcframework/macos-arm64"
reopen_library="$reopen_sdk/libvortx_ffi.a"
reopen_headers="$reopen_sdk/Headers/vortx"
test "$(shasum -a 256 "$reopen_library" | awk '{print $1}')" = 500b332657c5cd6e6f8cebb810e2c86141cf2e03dc56e3cfaa8da95dd70c009e
test "$(shasum -a 256 "$reopen_headers/vortx_ffi.h" | awk '{print $1}')" = f7e277e197c8c72d230be633db5395234a19ff73ec645f971b0d3e88da376672
test "$(shasum -a 256 "$reopen_headers/module.modulemap" | awk '{print $1}')" = e1d19b615b750414d8af325dea5f712d0c88d76f84ab32ee5406d3a4ccc3236b
test "$(git rev-parse "$reopen_baseline^{commit}")" = "$reopen_baseline"
mkdir -p app/build
reopen_gate=$(mktemp -d "$PWD/app/build/native-own-source-reopen.XXXXXX")
git show "$reopen_baseline:app/SourcesShared/VortxLegacyBootstrapMaterial.swift" > "$reopen_gate/BaselineMaterial.swift"
test "$(shasum -a 256 "$reopen_gate/BaselineMaterial.swift" | awk '{print $1}')" = 7e99691f4c54fd433461c960867e243495f6b19b3b2937622c22bc0816e52d57
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$reopen_gate/UserProfile.swift"
{
  printf '%s\n' 'import Foundation'
  sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$reopen_gate/Discovery.swift"
reopen_inputs=(
  "$reopen_gate/UserProfile.swift" "$reopen_gate/Discovery.swift"
  app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxProfileOverlayWitness.swift
  app/SourcesShared/LegacyWatchedBitfieldDecoder.swift app/SourcesShared/LegacyWatchedBitfieldMigrationEvidence.swift
  app/SourcesShared/VortxLegacyWatchedMigration.swift
)
shasum -a 256 "${reopen_inputs[@]}" app/SourcesShared/VortxLegacyBootstrapMaterial.swift \
  app/Tests/NativeOwnSourceReopenRegression.swift "$reopen_gate/BaselineMaterial.swift" \
  "$reopen_library" "$reopen_headers/vortx_ffi.h" "$reopen_headers/module.modulemap" > "$reopen_gate/source-sha256.txt"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  -I "$reopen_headers" "${reopen_inputs[@]}" "$reopen_gate/BaselineMaterial.swift" \
  app/Tests/NativeOwnSourceReopenRegression.swift "$reopen_library" -lz -o "$reopen_gate/adapter-red"
"$reopen_gate/adapter-red" | tee "$reopen_gate/red.log"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  -I "$reopen_headers" "${reopen_inputs[@]}" app/SourcesShared/VortxLegacyBootstrapMaterial.swift \
  app/Tests/NativeOwnSourceReopenRegression.swift "$reopen_library" -lz -o "$reopen_gate/adapter-green"
"$reopen_gate/adapter-green" --expect-green | tee "$reopen_gate/green.log"
shasum -a 256 --check "$reopen_gate/source-sha256.txt"
printf 'Retained actual-ABI source-reopen regression: %s\n' "$reopen_gate"
