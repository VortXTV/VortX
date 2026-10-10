#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
causal_sdk="${VORTX_SYNC_TEST_SDK:?exact accepted dd520 macOS static SDK required}"
causal_library="$causal_sdk/libvortx_ffi.a"
causal_headers="$causal_sdk/Headers/vortx"
causal_library_hash=500b332657c5cd6e6f8cebb810e2c86141cf2e03dc56e3cfaa8da95dd70c009e
causal_header_hash=f7e277e197c8c72d230be633db5395234a19ff73ec645f971b0d3e88da376672
causal_module_hash=e1d19b615b750414d8af325dea5f712d0c88d76f84ab32ee5406d3a4ccc3236b
test "$(shasum -a 256 "$causal_library" | awk '{print $1}')" = "$causal_library_hash"
test "$(shasum -a 256 "$causal_headers/vortx_ffi.h" | awk '{print $1}')" = "$causal_header_hash"
test "$(shasum -a 256 "$causal_headers/module.modulemap" | awk '{print $1}')" = "$causal_module_hash"
mkdir -p app/build
causal_dir=$(mktemp -d "$PWD/app/build/native-causal-repair.XXXXXX")
export VORTX_RECEIVE_SOURCE_HEAD VORTX_RECEIVE_PRODUCTION_REF
VORTX_RECEIVE_SOURCE_HEAD=$(git -C "$PWD" rev-parse HEAD)
VORTX_RECEIVE_PRODUCTION_REF="${VORTX_CAUSAL_PRODUCTION_REF:-$VORTX_RECEIVE_SOURCE_HEAD}"
node test/native-causal-repair.mjs --extract "$causal_dir"
causal_inputs=(
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift
    app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}"
    app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxNativeProfiles.swift
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxProfileOverlayWitness.swift
    app/SourcesShared/CatalogRowResolution.swift app/SourcesShared/VortXSyncCrypto.swift app/SourcesShared/NativeForegroundSyncPolicy.swift
    app/SourcesShared/AddonReorderMove.swift app/SourcesShared/ProfileRosterSyncPolicy.swift app/SourcesShared/PlaybackMutationOwnershipPolicy.swift
    app/SourcesShared/HomeCatalogLoadPolicy.swift app/SourcesShared/TabBarPrefs.swift
    app/SourcesShared/BecauseYouWatchedHistoryPolicy.swift app/SourcesShared/ContinueWatchingPreferences.swift app/SourcesShared/HomeContinueWatchingSelection.swift
    app/SourcesShared/SettingsDirtyKeys.swift app/SourcesShared/SyncDocumentRevisionPolicy.swift app/SourcesShared/NativePreferenceIntentStore.swift
    app/SourcesShared/VortXSyncManager.swift "$causal_dir/UserProfile.swift" "$causal_dir/Discovery.swift" "$causal_dir/Models.swift" "$causal_dir/CatalogConsumers.swift" "$causal_dir/HomeRails.swift" "$causal_dir/Combined.swift"
)
for causal_source in "${causal_inputs[@]}"; do
    [[ "$causal_source" == app/SourcesShared/*.swift ]] || continue
    causal_expected=$(git -C "$PWD" show "$VORTX_RECEIVE_PRODUCTION_REF:$causal_source" | shasum -a 256 | awk '{print $1}')
    test "$(shasum -a 256 "$causal_source" | awk '{print $1}')" = "$causal_expected"
done
causal_hash_inputs=("$causal_library" "$causal_headers/vortx_ffi.h" "$causal_headers/module.modulemap" app/Tests/NativeCausalRepairHarness.swift.in test/native-causal-repair.mjs scripts/test-native-causal-repair.sh)
for causal_source in "${causal_inputs[@]}"; do
    [[ "$causal_source" != *.swift ]] || causal_hash_inputs+=("$causal_source")
done
shasum -a 256 "${causal_hash_inputs[@]}" > "$causal_dir/source-hashes.sha256"
if [[ ${1:-} == --extract-only ]]; then
    printf 'Retained exact causal-repair extraction %s\n' "$causal_dir"
    exit 0
fi
test $# -eq 0
xcrun swiftc -j 2 -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -D CREDENTIAL_RETRY_COORDINATOR_STANDALONE -D VORTX_NATIVE_DATA_ENGINE -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -I "$causal_headers" "${causal_inputs[@]}" \
    "$causal_library" -framework Security -framework SystemConfiguration -o "$causal_dir/causal-peer" > "$causal_dir/compiler.log" 2>&1
node test/native-causal-repair.mjs "$causal_dir/causal-peer" "$causal_dir" 2>&1 | tee "$causal_dir/runtime.log"
test "$(shasum -a 256 "$causal_library" | awk '{print $1}')" = "$causal_library_hash"
test "$(shasum -a 256 "$causal_headers/vortx_ffi.h" | awk '{print $1}')" = "$causal_header_hash"
test "$(shasum -a 256 "$causal_headers/module.modulemap" | awk '{print $1}')" = "$causal_module_hash"
shasum -a 256 "$causal_dir/causal-peer" "$causal_dir/compiler.log" "$causal_dir/runtime.log" "$causal_dir/causal-runtime-receipt.json" "$causal_dir/causal-extraction.json" > "$causal_dir/result-hashes.sha256"
printf 'Retained actual causal-repair receipts %s\n' "$causal_dir"
