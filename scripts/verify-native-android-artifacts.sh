#!/usr/bin/env bash
set -euo pipefail

# Inspect shipped archives: require just the reviewed VortX resource-host engine, prove its ABI/JNI
# surface, and compare it with fresh staged bytes after identical AGP strip handling. `--native-only`
# is accepted for existing callers; it is the only mode.
abi_mode=resource-host
staged_dir=""
source_sha=""
artifacts=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --native-only) shift ;;
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
[[ -n "$staged_dir" && -d "$staged_dir" ]] || { echo "native-only mode requires the staged jniLibs directory" >&2; exit 1; }
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "native-only mode requires the exact 40-character VortX engine source SHA" >&2; exit 1; }
[[ -n "$strip" && -x "$strip" ]] || { echo "STRIP must point to the pinned NDK llvm-strip" >&2; exit 1; }
# Normal source must prove its added owner-history JNI ABI. Explicit beta2 interpretation
# retains its real old surface; an arbitrary 40-character string is not an admitted mode.
case "$source_sha" in
    0c30f4782aee544a2b7e33169ad60d03630d4097) abi_mode=owner-history ;;
    a3169f338f3f05da4ad3adb39a1e557c3ddcac33) abi_mode=owner-history ;;
    af29b22e4c45740a1f5b6cb415b81f8430f55b9f) abi_mode=resource-host ;;
    *) echo "native-only ABI mode has no admitted source revision" >&2; exit 1 ;;
esac

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
    READELF="$readelf" bash "$repo_root/scripts/verify-native-engine-abi.sh" android "$file" "$abi_mode"
    required="Java_com_vortx_android_engine_VortxServer_nativeStart Java_com_vortx_android_engine_VortxServer_nativePort Java_com_vortx_android_engine_VortxServer_nativeBaseUrl Java_com_vortx_android_engine_VortxServer_nativeStop"
    symbols="$("$readelf" --dyn-syms --wide "$file")"
    for symbol in $required; do
        awk -v wanted="$symbol" '$4 == "FUNC" && ($5 == "GLOBAL" || $5 == "WEAK") && ($6 == "DEFAULT" || $6 == "PROTECTED") && $7 ~ /^[0-9]+$/ && $7 > 0 && $8 == wanted { found=1 } END { exit !found }' <<< "$symbols" || {
            echo "missing callable $symbol in $artifact" >&2; return 1;
        }
    done
}

verify_native_only() {
    local artifact="$1" prefix="$2" abi entry extracted staged normalized_package normalized_staged digest
    local expected_entries actual_entries listing
    expected_entries="$scratch/expected-$artifact_index"
    actual_entries="$scratch/actual-$artifact_index"
    listing="$scratch/listing-$artifact_index"
    # Consume a successful complete listing first. An early grep match in a pipe can cause unzip
    # to exit on SIGPIPE under pipefail, making an if rejection accidentally evaluate false.
    unzip -Z1 "$artifact" > "$listing" || {
        echo "could not list Android artifact: $artifact" >&2
        return 1
    }
    printf '%s\n' \
        "$prefix/arm64-v8a/libvortx_ffi.so" \
        "$prefix/armeabi-v7a/libvortx_ffi.so" \
        "$prefix/x86_64/libvortx_ffi.so" | LC_ALL=C sort > "$expected_entries"
    awk -F/ '$NF == "libvortx_ffi.so" { print }' "$listing" | LC_ALL=C sort > "$actual_entries"
    if ! cmp -s "$expected_entries" "$actual_entries"; then
        echo "native-only artifact must contain exactly one libvortx_ffi.so for each shipped ABI, with no extra engine ABI: $artifact" >&2
        diff -u "$expected_entries" "$actual_entries" >&2 || true
        return 1
    fi
    if grep -Eq '(^|/)libstremiox_core\.so$' "$listing"; then
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
    verify_native_only "$artifact" "$prefix"
done
