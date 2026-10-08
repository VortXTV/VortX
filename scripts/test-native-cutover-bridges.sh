#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
mkdir -p app/build
native_test_dir=$(mktemp -d app/build/native-cutover.XXXXXX)
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$native_test_dir/UserProfile.swift"
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$native_test_dir/Discovery.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift \
  app/SourcesShared/VortxResourceProjection.swift app/Tests/VortxNativeBridgeTests.swift \
  -o "$native_test_dir/native-bridges"
"$native_test_dir/native-bridges" test/fixtures/native-resource-contract.json
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift \
  app/SourcesShared/VortxResourceProjection.swift app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxProfileOverlayWitness.swift \
  "$native_test_dir/UserProfile.swift" "$native_test_dir/Discovery.swift" app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxNativeProfileEditHost.swift \
  app/Tests/VortxNativeSessionTests.swift -o "$native_test_dir/native-session"
"$native_test_dir/native-session" "$native_test_dir"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/VortxNativeBootstrapArchive.swift app/Tests/VortxNativeBootstrapArchiveTests.swift -o "$native_test_dir/bootstrap-archive"
"$native_test_dir/bootstrap-archive"
xcrun swiftc -warnings-as-errors app/Tests/CoreBridgePublicationFenceContractTests.swift -o "$native_test_dir/publication-contract"
"$native_test_dir/publication-contract"
xcrun swiftc -warnings-as-errors app/SourcesShared/PlaybackMutationOwnershipPolicy.swift \
  app/Tests/PlaybackMutationOwnershipPolicyTests.swift -o "$native_test_dir/playback-ownership"
"$native_test_dir/playback-ownership"
bash test/build-mac-server-resolver.sh
