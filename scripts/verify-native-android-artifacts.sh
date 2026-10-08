#!/usr/bin/env bash
set -euo pipefail
# Inspect the shipped archive, never a staging directory or a previous variant.
[[ $# -gt 0 ]] || { echo "APK/AAB paths required" >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
readelf="${READELF:?set READELF to the pinned NDK llvm-readelf}"
[[ -x "$readelf" ]] || { echo "NDK llvm-readelf unavailable" >&2; exit 1; }
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
for artifact in "$@"; do
    [[ -s "$artifact" ]] || { echo "missing artifact: $artifact" >&2; exit 1; }
    case "$artifact" in
        *.apk) prefix=lib ;;
        *.aab) prefix=base/lib ;;
        *) echo "unsupported Android artifact: $artifact" >&2; exit 1 ;;
    esac
    for abi in arm64-v8a armeabi-v7a x86_64; do
        case "$abi" in
            arm64-v8a) class=ELF64; machine=AArch64 ;;
            armeabi-v7a) class=ELF32; machine=ARM ;;
            x86_64) class=ELF64; machine='Advanced Micro Devices X86-64' ;;
        esac
        for lib in libvortx_ffi.so libstremiox_core.so; do
            extracted="$scratch/$abi-$lib"
            unzip -p "$artifact" "$prefix/$abi/$lib" > "$extracted"
            [[ -s "$extracted" ]] || { echo "empty $abi/$lib: $artifact" >&2; exit 1; }
            header="$("$readelf" -h "$extracted")"
            grep -Eq "Class:[[:space:]]+$class([[:space:]]|$)" <<< "$header"
            grep -Eq 'Data:.*little endian' <<< "$header"
            grep -Eq 'Type:[[:space:]]+DYN\b' <<< "$header"
            grep -Eq "Machine:[[:space:]]+$machine([[:space:]]|$)" <<< "$header"
            if [[ "$lib" == libvortx_ffi.so ]]; then
                READELF="$readelf" bash "$repo_root/scripts/verify-native-engine-abi.sh" android "$extracted" resource-host
                required="Java_com_vortx_android_engine_VortxServer_nativeStart Java_com_vortx_android_engine_VortxServer_nativePort Java_com_vortx_android_engine_VortxServer_nativeBaseUrl Java_com_vortx_android_engine_VortxServer_nativeStop"
            else
                required="JNI_OnLoad Java_com_vortx_android_engine_StremioCoreNative_nativeInit Java_com_vortx_android_engine_StremioCoreNative_nativeDispatch Java_com_vortx_android_engine_StremioCoreNative_nativeGetState Java_com_vortx_android_engine_StremioCoreNative_nativeSchemaVersion Java_com_vortx_android_engine_StremioCoreNative_nativeRestoreLibrary Java_com_vortx_android_engine_StremioCoreNative_nativeReadLibraryEvents"
            fi
            symbols="$("$readelf" --dyn-syms --wide "$extracted")"
            for symbol in $required; do
                awk -v wanted="$symbol" '$4 == "FUNC" && ($5 == "GLOBAL" || $5 == "WEAK") && ($6 == "DEFAULT" || $6 == "PROTECTED") && $7 ~ /^[0-9]+$/ && $7 > 0 && $8 == wanted { found=1 } END { exit !found }' <<< "$symbols" || {
                    echo "missing callable $symbol in $artifact ($abi)" >&2; exit 1;
                }
            done
        done
    done
    echo "verified packaged native engines: $artifact"
done
