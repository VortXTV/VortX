#!/usr/bin/env bash
set -euo pipefail
# Usage: verify-native-engine-abi.sh apple <xcframework> [resource-host]
#        verify-native-engine-abi.sh android <libvortx_ffi.so> [resource-host]
# This is an explicit new-bridge artifact gate; existing release pins are not changed by it.
platform="${1:?platform required}" artifact="${2:?artifact required}" mode="${3:-state}"
[[ "$mode" == state || "$mode" == resource-host ]] || { echo "invalid ABI mode" >&2; exit 1; }
state_symbols=(vortx_init_runtime vortx_init_from_state_json vortx_dispatch_json vortx_resolve_json vortx_get_state_json vortx_get_state_delta_json vortx_string_free vortx_engine_free)
resource_symbols=(vortx_resource_host_abi_version vortx_resource_host_new vortx_resource_host_load_json vortx_resource_host_free vortx_cancel_new vortx_cancel_cancel vortx_cancel_free)
if [[ "$platform" == apple ]]; then
    count=0
    for archive in "$artifact"/*/libvortx_ffi.a; do
        [[ -f "$archive" ]] || continue
        count=$((count + 1))
        header="$(dirname "$archive")/Headers/vortx/vortx_ffi.h"
        [[ -f "$header" ]] || { echo "missing native header: $header" >&2; exit 1; }
        # -j also prints member labels and includes N_PEXT definitions. Only
        # ordinary external definitions are the shared link-visible ABI.
        exports=$(nm -m -gU "$archive" | awk '/ external / && !/ private external / { print $NF }')
        unexpected=$(printf '%s\n' "$exports" | sed '/^_vortx_/d; /^$/d')
        [[ -z "$unexpected" ]] || { echo "unexpected public native exports: $archive: $unexpected" >&2; exit 1; }
        slice="$(basename "$(dirname "$archive")")"
        case "$slice" in
            ios-arm64) sdk=iphoneos; target=arm64-apple-ios16.0 ;;
            ios-arm64-simulator) sdk=iphonesimulator; target=arm64-apple-ios16.0-simulator ;;
            tvos-arm64) sdk=appletvos; target=arm64-apple-tvos18.0 ;;
            tvos-arm64-simulator) sdk=appletvsimulator; target=arm64-apple-tvos18.0-simulator ;;
            macos-arm64) sdk=macosx; target=arm64-apple-macos14.0 ;;
            *) echo "unsupported Apple native slice: $slice" >&2; exit 1 ;;
        esac
        sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
        expected=("${state_symbols[@]}")
        [[ "$mode" != resource-host ]] || expected+=("${resource_symbols[@]}")
        for symbol in "${expected[@]}"; do
            printf '%s\n' "$exports" | grep -Fxq "_$symbol" || { echo "missing export $symbol: $archive" >&2; exit 1; }
            # A present symbol with an absent header is still unusable from Swift.
            printf 'void probe(void) { (void)&%s; }\n' "$symbol" |
                xcrun --sdk "$sdk" clang -target "$target" -isysroot "$sysroot" \
                    -Werror -fsyntax-only -x c -include "$header" -
        done
    done
    [[ "$count" == 5 ]] || { echo "expected five Apple native slices; found $count" >&2; exit 1; }
elif [[ "$platform" == android ]]; then
    readelf="${READELF:-llvm-readelf}"
    exports=$($readelf --dyn-syms --wide "$artifact")
    expected=(nativeInitRuntime nativeInitFromStateJson nativeDispatchJson nativeResolveJson nativeGetStateJson nativeGetStateDeltaJson nativeEngineFree)
    [[ "$mode" != resource-host ]] || expected+=(nativeResourceHostAbiVersion nativeResourceHostNew nativeResourceHostLoadJson nativeResourceHostFree nativeCancelNew nativeCancelCancel nativeCancelFree)
    for symbol in "${expected[@]}"; do
        awk -v wanted="Java_com_vortx_android_engine_VortxCore_$symbol" '$7 != "UND" && $8 == wanted { found=1 } END { exit !found }' <<< "$exports" || {
            echo "missing JNI export $symbol: $artifact" >&2; exit 1;
        }
    done
else
    echo "unknown platform: $platform" >&2; exit 1
fi
echo "native $platform $mode ABI verified"
