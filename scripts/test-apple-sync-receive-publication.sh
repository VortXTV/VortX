#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
source scripts/xperience-observation-swift-inputs.sh
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
receive_inputs=(
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift
    app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}"
    "${xperience_observation_swift_inputs[@]}"
    app/SourcesShared/VortxNativeOwnAccountProducer.swift app/SourcesShared/AuthenticatedHTTPTransport.swift app/SourcesShared/LinkAuthService.swift
    app/SourcesShared/SyncDocumentRevisionPolicy.swift
    app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxNativePreviouslyWatched.swift app/SourcesShared/VortxNativeProfiles.swift
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxProfileOverlayWitness.swift
    app/SourcesShared/CatalogRowResolution.swift app/SourcesShared/VortXSyncCrypto.swift app/SourcesShared/NativeForegroundSyncPolicy.swift app/SourcesShared/SyncBackupUploadFailure.swift
    app/SourcesShared/AddonReorderMove.swift app/SourcesShared/ProfileRosterSyncPolicy.swift app/SourcesShared/PlaybackMutationOwnershipPolicy.swift
    app/SourcesShared/HomeCatalogLoadPolicy.swift app/SourcesShared/TabBarPrefs.swift
    app/SourcesShared/BecauseYouWatchedHistoryPolicy.swift app/SourcesShared/ContinueWatchingPreferences.swift app/SourcesShared/HomeContinueWatchingSelection.swift
    app/SourcesShared/CredentialRetryCoordinator.swift "$receive_dir/UserProfile.swift" "$receive_dir/Discovery.swift" "$receive_dir/Models.swift" "$receive_dir/CatalogConsumers.swift" "$receive_dir/HomeRails.swift" "$receive_dir/Combined.swift"
)
receive_conservation_inputs=(
    "$receive_library" "$receive_headers/vortx_ffi.h" "$receive_headers/module.modulemap"
    scripts/test-apple-sync-receive-publication.sh scripts/native-watched-swift-inputs.sh
    scripts/xperience-observation-swift-inputs.sh test/xperience-harness-inputs.cjs
    test/addon-guarded-presentation-inputs.cjs app/Tests/AppleHistoryFixture.swift test/mpv-bounded-child.mjs
    test/apple-sync-receive-publication.mjs app/Tests/AppleSyncReceivePublicationPeer.swift
    app/SourcesShared/Profiles.swift app/SourcesShared/CoreBridge.swift app/SourcesShared/VortXSyncManager.swift
    app/SourcesShared/ProfileDiscoveryPreferences.swift app/SourcesShared/CoreModels.swift
    app/SourcesShared/StremioAccount.swift app/SourcesShared/CatalogPreferences.swift app/SourcesShared/HomeRailPreferences.swift
)
for receive_source in "${receive_inputs[@]}"; do
    [[ "$receive_source" != app/SourcesShared/*.swift ]] || receive_conservation_inputs+=("$receive_source")
done
shasum -a 256 "${receive_conservation_inputs[@]}" > "$receive_dir/inputs.before.sha256"
receive_exit() {
    local terminal_status=$?
    trap - EXIT
    shasum -a 256 "${receive_conservation_inputs[@]}" > "$receive_dir/inputs.after.sha256" || terminal_status=2
    if ! cmp -s "$receive_dir/inputs.before.sha256" "$receive_dir/inputs.after.sha256"; then
        printf 'FAIL: source or accepted SDK inputs changed during verification.\n' >&2
        terminal_status=2
    fi
    printf 'Terminal status %s; retained %s\n' "$terminal_status" "$receive_dir"
    exit "$terminal_status"
}
trap receive_exit EXIT
nice -n 15 node test/apple-sync-receive-publication.mjs --extract "$receive_dir"
if [[ ${1:-} == --extract-only ]]; then
    printf 'Retained exact extraction %s\n' "$receive_dir"
    exit 0
fi
test $# -eq 0
if [[ -n ${VORTX_RECEIVE_PRODUCTION_REF:-} ]]; then
    # Bind every whole production compiler input, not only extracted functions.
    for receive_source in "${receive_inputs[@]}"; do
        [[ "$receive_source" == app/SourcesShared/*.swift ]] || continue
        receive_expected=$(git -C "$PWD" show "$VORTX_RECEIVE_PRODUCTION_REF:$receive_source" | shasum -a 256 | awk '{print $1}')
        test "$(shasum -a 256 "$receive_source" | awk '{print $1}')" = "$receive_expected"
    done
fi
receive_supervisor="$PWD/test/mpv-bounded-child.mjs"
nice -n 15 node "$receive_supervisor" run 60 "$receive_dir/compile-process.json" -- \
    /usr/bin/xcrun swiftc -j 1 -num-threads 1 -whole-module-optimization -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -D CREDENTIAL_RETRY_COORDINATOR_STANDALONE -D VORTX_NATIVE_DATA_ENGINE -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -I "$receive_headers" "${receive_inputs[@]}" \
    "$receive_library" -framework Security -framework SystemConfiguration -o "$receive_dir/receive-peer"
nice -n 15 node "$receive_supervisor" check "$receive_dir/compile-process.json" 0 normal-exit
nice -n 15 node "$receive_supervisor" run 120 "$receive_dir/runtime-process.json" -- \
    /usr/bin/env node test/apple-sync-receive-publication.mjs "$receive_dir/receive-peer" "$receive_dir"
nice -n 15 node "$receive_supervisor" check "$receive_dir/runtime-process.json" 0 normal-exit
test "$(shasum -a 256 "$receive_library" | awk '{print $1}')" = "$VORTX_SYNC_TEST_LIBRARY_SHA256"
test "$(shasum -a 256 "$receive_headers/vortx_ffi.h" | awk '{print $1}')" = "$VORTX_SYNC_TEST_HEADER_SHA256"
test "$(shasum -a 256 "$receive_headers/module.modulemap" | awk '{print $1}')" = "$receive_module_hash"
# Final receipt includes EVERY input already conserved across compile/runtime,
# including the runner, driver and whole peer, plus generated compiler inputs below.
receive_hash_inputs=("${receive_conservation_inputs[@]}" "$receive_dir/receive-peer")
for receive_source in "${receive_inputs[@]}"; do
    [[ "$receive_source" != *.swift ]] || receive_hash_inputs+=("$receive_source")
done
shasum -a 256 "${receive_hash_inputs[@]}" > "$receive_dir/hashes.sha256"
printf 'Retained receive/publication receipts %s\n' "$receive_dir"
