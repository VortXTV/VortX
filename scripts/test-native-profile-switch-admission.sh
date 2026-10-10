#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/native-watched-swift-inputs.sh

# The caller supplies a reviewed, immutable macOS static SDK.  The harness never rebuilds or
# regenerates it; all three digests are retained in the output receipt and checked after compile.
switch_sdk="${VORTX_SYNC_TEST_SDK:?exact accepted macOS static SDK required}"
switch_library="$switch_sdk/libvortx_ffi.a"
switch_headers="$switch_sdk/Headers/vortx"
test -f "$switch_library"
test -f "$switch_headers/vortx_ffi.h"
test -f "$switch_headers/module.modulemap"
switch_library_hash=$(shasum -a 256 "$switch_library" | awk '{print $1}')
switch_header_hash=$(shasum -a 256 "$switch_headers/vortx_ffi.h" | awk '{print $1}')
switch_module_hash=$(shasum -a 256 "$switch_headers/module.modulemap" | awk '{print $1}')
test "$switch_library_hash" = "${VORTX_SYNC_TEST_LIBRARY_SHA256:?accepted immutable library hash required}"
test "$switch_header_hash" = "${VORTX_SYNC_TEST_HEADER_SHA256:?accepted immutable header hash required}"
test "$switch_module_hash" = "${VORTX_SYNC_TEST_MODULE_SHA256:?accepted immutable module hash required}"
export VORTX_PROFILE_SWITCH_SDK="$switch_sdk"
export VORTX_PROFILE_SWITCH_LIBRARY_SHA256="$switch_library_hash"
export VORTX_PROFILE_SWITCH_HEADER_SHA256="$switch_header_hash"
export VORTX_PROFILE_SWITCH_MODULE_SHA256="$switch_module_hash"
export VORTX_PROFILE_SWITCH_SDK_VERIFIED=1

baseline_args=()
extract_only=0
case "${1:-}" in
    "") ;;
    --extract-only) extract_only=1; shift; test "$#" -eq 0 ;;
    --baseline-ref)
        test "$#" -eq 2
        baseline_args=(--baseline-ref "$2")
        shift 2
        ;;
    *) echo "usage: $0 [--extract-only | --baseline-ref <commit>]" >&2; exit 2 ;;
esac

mkdir -p app/build
switch_dir=$(mktemp -d "$PWD/app/build/native-profile-switch-admission.XXXXXX")
export VORTX_PROFILE_SWITCH_SOURCE_HEAD
VORTX_PROFILE_SWITCH_SOURCE_HEAD=$(git rev-parse HEAD)
node test/native-profile-switch-admission.mjs --extract "$switch_dir" "${baseline_args[@]}"
if [[ $extract_only -eq 1 ]]; then
    printf 'Retained exact profile-switch extraction %s\n' "$switch_dir"
    exit 0
fi

switch_inputs=(
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift
    app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}"
    app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxNativeProfiles.swift
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxProfileOverlayWitness.swift
    app/SourcesShared/PlaybackMutationOwnershipPolicy.swift app/SourcesShared/NativeProfileActionPreparation.swift app/SourcesShared/NativePreferenceIntentStore.swift
    "$switch_dir/Combined.swift"
)

# Keep the compiler invocation intentionally identical in its strictness to the existing live
# native fixtures.  This is the only build step; no SDK generation or artifact mutation occurs.
xcrun swiftc -j 2 -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -D VORTX_NATIVE_DATA_ENGINE -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST \
    -I "$switch_headers" "${switch_inputs[@]}" "$switch_library" \
    -framework Security -framework SystemConfiguration -o "$switch_dir/native-profile-switch-admission"

node test/native-profile-switch-admission.mjs "$switch_dir/native-profile-switch-admission" "$switch_dir"
test "$switch_library_hash" = "$(shasum -a 256 "$switch_library" | awk '{print $1}')"
test "$switch_header_hash" = "$(shasum -a 256 "$switch_headers/vortx_ffi.h" | awk '{print $1}')"
test "$switch_module_hash" = "$(shasum -a 256 "$switch_headers/module.modulemap" | awk '{print $1}')"

switch_hash_inputs=("$switch_library" "$switch_headers/vortx_ffi.h" "$switch_headers/module.modulemap" "$switch_dir/native-profile-switch-admission")
for switch_source in "${switch_inputs[@]}"; do
    [[ "$switch_source" != -* && "$switch_source" == *.swift ]] && switch_hash_inputs+=("$switch_source")
done
shasum -a 256 "${switch_hash_inputs[@]}" > "$switch_dir/hashes.sha256"
printf 'Retained native profile-switch admission receipts %s\n' "$switch_dir"
