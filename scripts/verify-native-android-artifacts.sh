#!/usr/bin/env bash
set -euo pipefail

# Inspect shipped archives. Default mode preserves the legacy two-engine comparison contract.
# Release workflows opt into --native-only to require just the reviewed VortX resource-host engine,
# prove its ABI/JNI surface, and compare it with fresh staged bytes after identical AGP strip handling.
mode=legacy-both
staged_dir=""
source_sha=""
artifacts=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --native-only) mode=native-only; shift ;;
        --staged-dir)
            [[ $# -ge 2 ]] || { echo "--staged-dir requires a path" >&2; exit 1; }
            staged_dir="$2"; shift 2 ;;
        --source-sha)
            [[ $# -ge 2 ]] || { echo "--source-sha requires a full commit SHA" >&2; exit 1; }
            source_sha="$2"; shift 2 ;;
        --*) echo "unknown option: $1" >&2; exit 1 ;;
        *) artifacts+=("$1"); shift ;;
    esac
done
[[ ${#artifacts[@]} -gt 0 ]] || { echo "APK/AAB paths required" >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
readelf="${READELF:?set READELF to the pinned NDK llvm-readelf}"
[[ -x "$readelf" ]] || { echo "NDK llvm-readelf unavailable: $readelf" >&2; exit 1; }
strip="${STRIP:-}"
if [[ "$mode" == native-only ]]; then
    [[ -n "$staged_dir" && -d "$staged_dir" ]] || { echo "native-only mode requires the staged jniLibs directory" >&2; exit 1; }
    [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "native-only mode requires the exact 40-character VortX engine source SHA" >&2; exit 1; }
    [[ -n "$strip" && -x "$strip" ]] || { echo "STRIP must point to the pinned NDK llvm-strip" >&2; exit 1; }
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

verify_elf() {
    local file="$1" abi="$2" artifact="$3" header class machine
    case "$abi" in
        arm64-v8a) class=ELF64; machine=AArch64 ;;
        armeabi-v7a) class=ELF32; machine=ARM ;;
        x86_64) class=ELF64; machine='Advanced Micro Devices X86-64' ;;
        *) echo "unexpected engine ABI: $abi ($artifact)" >&2; return 1 ;;
    esac
    header="$("$readelf" -h "$file")"
    grep -Eq "Class:[[:space:]]+$class([[:space:]]|$)" <<< "$header" || { echo "wrong ELF class for $abi: $artifact" >&2; return 1; }
    grep -Eq 'Data:.*little endian' <<< "$header" || { echo "not little-endian for $abi: $artifact" >&2; return 1; }
    grep -Eq 'Type:[[:space:]]+DYN\b' <<< "$header" || { echo "not ET_DYN for $abi: $artifact" >&2; return 1; }
    grep -Eq "Machine:[[:space:]]+$machine([[:space:]]|$)" <<< "$header" || { echo "wrong machine for $abi: $artifact" >&2; return 1; }
}

verify_vortx_abi() {
    local file="$1" artifact="$2" symbols symbol required
    READELF="$readelf" bash "$repo_root/scripts/verify-native-engine-abi.sh" android "$file" resource-host
    required="Java_com_vortx_android_engine_VortxServer_nativeStart Java_com_vortx_android_engine_VortxServer_nativePort Java_com_vortx_android_engine_VortxServer_nativeBaseUrl Java_com_vortx_android_engine_VortxServer_nativeStop"
    symbols="$("$readelf" --dyn-syms --wide "$file")"
    for symbol in $required; do
        awk -v wanted="$symbol" '$4 == "FUNC" && ($5 == "GLOBAL" || $5 == "WEAK") && ($6 == "DEFAULT" || $6 == "PROTECTED") && $7 ~ /^[0-9]+$/ && $7 > 0 && $8 == wanted { found=1 } END { exit !found }' <<< "$symbols" || {
            echo "missing callable $symbol in $artifact" >&2; return 1;
        }
    done
}

verify_legacy_pair() {
    local artifact="$1" prefix="$2" abi="$3" lib="$4" entry extracted symbols required symbol
    entry="$prefix/$abi/$lib"
    extracted="$scratch/legacy-${artifact_index}-$(basename "$artifact").$abi.$lib"
    unzip -p "$artifact" "$entry" > "$extracted" || { echo "missing $entry: $artifact" >&2; return 1; }
    [[ -s "$extracted" ]] || { echo "empty $entry: $artifact" >&2; return 1; }
    verify_elf "$extracted" "$abi" "$artifact"
    if [[ "$lib" == libvortx_ffi.so ]]; then
        verify_vortx_abi "$extracted" "$artifact"
    else
        required="JNI_OnLoad Java_com_vortx_android_engine_StremioCoreNative_nativeInit Java_com_vortx_android_engine_StremioCoreNative_nativeDispatch Java_com_vortx_android_engine_StremioCoreNative_nativeGetState Java_com_vortx_android_engine_StremioCoreNative_nativeSchemaVersion Java_com_vortx_android_engine_StremioCoreNative_nativeRestoreLibrary Java_com_vortx_android_engine_StremioCoreNative_nativeReadLibraryEvents"
        symbols="$("$readelf" --dyn-syms --wide "$extracted")"
        for symbol in $required; do
            awk -v wanted="$symbol" '$4 == "FUNC" && ($5 == "GLOBAL" || $5 == "WEAK") && ($6 == "DEFAULT" || $6 == "PROTECTED") && $7 ~ /^[0-9]+$/ && $7 > 0 && $8 == wanted { found=1 } END { exit !found }' <<< "$symbols" || {
                echo "missing callable $symbol in $artifact ($abi)" >&2; return 1;
            }
        done
    fi
}

verify_native_only() {
    local artifact="$1" prefix="$2" abi entry extracted staged normalized_package normalized_staged digest
    local expected_entries actual_entries
    expected_entries="$scratch/expected-$artifact_index"
    actual_entries="$scratch/actual-$artifact_index"
    printf '%s\n' \
        "$prefix/arm64-v8a/libvortx_ffi.so" \
        "$prefix/armeabi-v7a/libvortx_ffi.so" \
        "$prefix/x86_64/libvortx_ffi.so" | LC_ALL=C sort > "$expected_entries"
    unzip -Z1 "$artifact" | awk -F/ '$NF == "libvortx_ffi.so" { print }' | LC_ALL=C sort > "$actual_entries"
    if ! cmp -s "$expected_entries" "$actual_entries"; then
        echo "native-only artifact must contain exactly one libvortx_ffi.so for each shipped ABI, with no extra engine ABI: $artifact" >&2
        diff -u "$expected_entries" "$actual_entries" >&2 || true
        return 1
    fi
    if unzip -Z1 "$artifact" | grep -Eq '(^|/)libstremiox_core\.so$'; then
        echo "native-only artifact still contains legacy libstremiox_core.so: $artifact" >&2
        return 1
    fi

    for abi in arm64-v8a armeabi-v7a x86_64; do
        entry="$prefix/$abi/libvortx_ffi.so"
        extracted="$scratch/native-$artifact_index-$abi.so"
        unzip -p "$artifact" "$entry" > "$extracted" || { echo "missing $entry: $artifact" >&2; return 1; }
        [[ -s "$extracted" ]] || { echo "empty $entry: $artifact" >&2; return 1; }
        verify_elf "$extracted" "$abi" "$artifact"
        verify_vortx_abi "$extracted" "$artifact"

        staged="$staged_dir/$abi/libvortx_ffi.so"
        [[ -s "$staged" ]] || { echo "fresh staged engine missing or empty: $staged" >&2; return 1; }
        normalized_staged="$scratch/staged-$artifact_index-$abi.so"
        normalized_package="$scratch/package-$artifact_index-$abi.so"
        cp "$staged" "$normalized_staged"
        cp "$extracted" "$normalized_package"
        # Normalize both copies with the same pinned strip tool because AGP strips packaged JNI
        # libraries. This compares the staged source to the actual archive payload after that step.
        "$strip" --strip-debug --strip-unneeded "$normalized_staged"
        "$strip" --strip-debug --strip-unneeded "$normalized_package"
        if ! cmp -s "$normalized_staged" "$normalized_package"; then
            echo "packaged $entry differs from staged source after pinned llvm-strip normalization: $artifact" >&2
            return 1
        fi
        digest="$(shasum -a 256 "$normalized_package" | awk '{print $1}')"
        printf 'native-engine source=%s features=jni,server,resource-host artifact=%s abi=%s normalized-sha256=%s\n' \
            "$source_sha" "$artifact" "$abi" "$digest"
    done
    echo "verified native-only engine package: $artifact"
}

artifact_index=0
for artifact in "${artifacts[@]}"; do
    artifact_index=$((artifact_index + 1))
    [[ -s "$artifact" ]] || { echo "missing artifact: $artifact" >&2; exit 1; }
    case "$artifact" in
        *.apk) prefix=lib ;;
        *.aab) prefix=base/lib ;;
        *) echo "unsupported Android artifact: $artifact" >&2; exit 1 ;;
    esac
    if [[ "$mode" == native-only ]]; then
        verify_native_only "$artifact" "$prefix"
    else
        for abi in arm64-v8a armeabi-v7a x86_64; do
            for lib in libvortx_ffi.so libstremiox_core.so; do
                verify_legacy_pair "$artifact" "$prefix" "$abi" "$lib"
            done
        done
        echo "verified packaged native engines: $artifact"
    fi
done
