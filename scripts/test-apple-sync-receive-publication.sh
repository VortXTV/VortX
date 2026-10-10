#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
receive_sdk="${VORTX_SYNC_TEST_SDK:?exact accepted macOS static SDK required}"
receive_library="$receive_sdk/libvortx_ffi.a"
receive_headers="$receive_sdk/Headers/vortx"
test "$(shasum -a 256 "$receive_library" | awk '{print $1}')" = "${VORTX_SYNC_TEST_LIBRARY_SHA256:?accepted immutable library hash required}"
test "$(shasum -a 256 "$receive_headers/vortx_ffi.h" | awk '{print $1}')" = "${VORTX_SYNC_TEST_HEADER_SHA256:?accepted immutable header hash required}"
receive_module_hash=$(shasum -a 256 "$receive_headers/module.modulemap" | awk '{print $1}')
mkdir -p app/build
receive_dir=$(mktemp -d "$PWD/app/build/apple-sync-receive-publication.XXXXXX")
export VORTX_RECEIVE_SOURCE_HEAD
VORTX_RECEIVE_SOURCE_HEAD=$(git -C "$PWD" rev-parse HEAD)
node test/apple-sync-receive-publication.mjs --extract "$receive_dir"
if [[ ${1:-} == --extract-only ]]; then
    printf 'Retained exact extraction %s\n' "$receive_dir"
    exit 0
fi
test $# -eq 0
receive_inputs=(
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift
    app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}"
    app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxNativeProfiles.swift
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxProfileOverlayWitness.swift
    app/SourcesShared/CatalogRowResolution.swift app/SourcesShared/VortXSyncCrypto.swift app/SourcesShared/NativeForegroundSyncPolicy.swift
    app/SourcesShared/AddonReorderMove.swift app/SourcesShared/ProfileRosterSyncPolicy.swift app/SourcesShared/PlaybackMutationOwnershipPolicy.swift
    app/SourcesShared/BecauseYouWatchedHistoryPolicy.swift app/SourcesShared/ContinueWatchingPreferences.swift app/SourcesShared/HomeContinueWatchingSelection.swift
    app/SourcesShared/VortXSyncManager.swift "$receive_dir/UserProfile.swift" "$receive_dir/Discovery.swift" "$receive_dir/Models.swift" "$receive_dir/Combined.swift"
)
xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -D CREDENTIAL_RETRY_COORDINATOR_STANDALONE -D VORTX_NATIVE_DATA_ENGINE -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -I "$receive_headers" "${receive_inputs[@]}" \
    "$receive_library" -framework Security -framework SystemConfiguration -o "$receive_dir/receive-peer"
node test/apple-sync-receive-publication.mjs "$receive_dir/receive-peer" "$receive_dir"
test "$(shasum -a 256 "$receive_library" | awk '{print $1}')" = "$VORTX_SYNC_TEST_LIBRARY_SHA256"
test "$(shasum -a 256 "$receive_headers/vortx_ffi.h" | awk '{print $1}')" = "$VORTX_SYNC_TEST_HEADER_SHA256"
test "$(shasum -a 256 "$receive_headers/module.modulemap" | awk '{print $1}')" = "$receive_module_hash"
receive_hash_inputs=("$receive_library" "$receive_headers/vortx_ffi.h" "$receive_headers/module.modulemap" "$receive_dir/receive-peer")
for receive_source in "${receive_inputs[@]}"; do
    [[ "$receive_source" != *.swift ]] || receive_hash_inputs+=("$receive_source")
done
shasum -a 256 "${receive_hash_inputs[@]}" > "$receive_dir/hashes.sha256"
printf 'Retained receive/publication receipts %s\n' "$receive_dir"
