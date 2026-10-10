#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
sdk="${VORTX_SYNC_TEST_SDK:?exact reviewed macOS static SDK required}"
library="$sdk/libvortx_ffi.a"
headers="$sdk/Headers/vortx"
test "$(shasum -a 256 "$library" | awk '{print $1}')" = "${VORTX_SYNC_TEST_LIBRARY_SHA256:?immutable library hash required}"
test "$(shasum -a 256 "$headers/vortx_ffi.h" | awk '{print $1}')" = "${VORTX_SYNC_TEST_HEADER_SHA256:?immutable header hash required}"
mkdir -p app/build
fixture_dir=$(mktemp -d "$PWD/app/build/apple-sync-manager.XXXXXX")
source_file=app/SourcesShared/VortXSyncManager.swift
if [[ ${1:-} == --baseline-ref ]]; then
    test $# -eq 2
    git show "$2:app/SourcesShared/VortXSyncManager.swift" > "$fixture_dir/baseline.swift"
    source_file="$fixture_dir/baseline.swift"
fi
node test/apple-sync-manager.mjs --extract "$source_file" "$fixture_dir/Combined.swift"
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$fixture_dir/UserProfile.swift"
{ printf '%s\n' 'import Foundation'; sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift; } > "$fixture_dir/Discovery.swift"
xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -D VORTX_NATIVE_DATA_ENGINE -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -I "$headers" \
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift \
    app/SourcesShared/VortxResourceProjection.swift app/SourcesShared/VortxNativeBootstrapArchive.swift \
    app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" \
    app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeProfiles.swift app/SourcesShared/ProfileAddonPreferences.swift \
    app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxProfileOverlayWitness.swift app/SourcesShared/NativePreferenceIntentStore.swift \
    app/SourcesShared/VortXSyncCrypto.swift app/SourcesShared/NativeForegroundSyncPolicy.swift \
    app/SourcesShared/SyncDocumentRevisionPolicy.swift app/SourcesShared/SettingsDirtyKeys.swift \
    "$fixture_dir/UserProfile.swift" "$fixture_dir/Discovery.swift" "$fixture_dir/Combined.swift" \
    "$library" -framework Security -framework SystemConfiguration -o "$fixture_dir/manager-peer"
node test/apple-sync-manager.mjs "$fixture_dir/manager-peer" "$fixture_dir"
test "$(shasum -a 256 "$library" | awk '{print $1}')" = "$VORTX_SYNC_TEST_LIBRARY_SHA256"
test "$(shasum -a 256 "$headers/vortx_ffi.h" | awk '{print $1}')" = "$VORTX_SYNC_TEST_HEADER_SHA256"
