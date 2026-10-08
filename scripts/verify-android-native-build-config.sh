#!/usr/bin/env bash
set -euo pipefail

# Verify the generated BuildConfig inside the archive that will actually be shipped. This is kept
# separate from the ELF/JNI verifier because BuildConfig is DEX data, not a native symbol. The
# release workflows provide DEXDUMP from the pinned Android build-tools installation; accepting an
# arbitrary host dexdump would detach this proof from the toolchain used to package the artifact.

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[[ $# -gt 0 ]] || fail "APK/AAB path required"
if [[ "${1:-}" != "--dump" ]]; then
    [[ -n "${DEXDUMP:-}" ]] || fail "DEXDUMP must point to the pinned Android build-tools dexdump"
    [[ -x "$DEXDUMP" ]] || fail "DEXDUMP is not executable: $DEXDUMP"
fi

# The BuildConfig class is static-field data in DEX. dexdump has emitted two closely related forms
# across Android build-tools releases: a value directly inside a field block, and an indexed
# `Static values` table. Track the field number/name and value number together so a true value from
# DEBUG or another BuildConfig field can never satisfy NATIVE_ENGINE_ENABLED. Class boundaries are
# whitespace-tolerant but descriptor-exact; BuildConfigExtra and a later class are not accepted.
verify_dump() {
    local dump="$1"
    awk '
        function true_value(line) {
            return line ~ /(^|[=:])[[:space:]]*(true|0x0*1)([[:space:]]|$)/
        }
        function class_descriptor(line) {
            return line ~ /^[[:space:]]*Class descriptor[[:space:]]*:[[:space:]]*\047Lcom\/vortx\/android\/BuildConfig;\047[[:space:]]*$/
        }
        function any_class_descriptor(line) {
            return line ~ /^[[:space:]]*Class descriptor[[:space:]]*:/
        }
        function field_number(line, number) {
            if (line !~ /^[[:space:]]*#[[:space:]]*[0-9]+[[:space:]]*:/) return -1
            number=line
            sub(/^[[:space:]]*#[[:space:]]*/, "", number)
            sub(/[[:space:]]*:.*$/, "", number)
            return number + 0
        }
        class_descriptor($0) { in_build=1; in_fields=0; in_values=0; next }
        in_build && any_class_descriptor($0) { exit }
        in_build && /Static fields[[:space:]]*-/ { in_fields=1; in_values=0; current_field=-1; next }
        in_build && /Static values[[:space:]]*-/ { in_fields=0; in_values=1; current_value=-1; next }
        in_build && in_fields {
            parsed=field_number($0)
            if (parsed >= 0) current_field=parsed
            if ($0 ~ /name[[:space:]]*:[[:space:]]*\047NATIVE_ENGINE_ENABLED\047([[:space:]]|$)/) {
                target_field=current_field
                target_seen=1
            }
            if (target_seen && current_field == target_field && true_value($0)) found=1
            next
        }
        in_build && in_values {
            parsed=field_number($0)
            if (parsed >= 0) current_value=parsed
            if (target_seen && current_value == target_field && true_value($0)) found=1
            next
        }
        END {
            # A target is required; a true value from a class with the same substring or another
            # field is not enough. target_field==0 is valid, hence the explicit found check.
            exit !(in_build && target_seen && target_field >= 0 && found)
        }
    ' "$dump"
}

# Focused parser tests may pass --dump with dexdump text fixtures. This mode never accepts an
# archive and is deliberately separate from the production artifact path below; positive archive
# coverage uses a real SDK-generated DEX whenever the pinned SDK is available on the host.
if [[ "${1:-}" == "--dump" ]]; then
    shift
    [[ $# -gt 0 ]] || fail "dexdump text fixture required after --dump"
    for dump in "$@"; do
        [[ -s "$dump" ]] || fail "missing or empty dexdump fixture: $dump"
        verify_dump "$dump" || fail "fixture does not prove BuildConfig.NATIVE_ENGINE_ENABLED=true: $dump"
        printf 'ok: %s BuildConfig.NATIVE_ENGINE_ENABLED=true\n' "$dump"
    done
    exit 0
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

for artifact in "$@"; do
    [[ -s "$artifact" ]] || fail "missing or empty artifact: $artifact"
    case "$artifact" in
        *.apk) dex_prefix="" ;;
        *.aab) dex_prefix="base/dex/" ;;
        *) fail "unsupported Android artifact: $artifact" ;;
    esac

    found=0
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        dex="$scratch/$(basename "$artifact").${entry##*/}"
        dump="$dex.dump"
        unzip -p "$artifact" "$entry" > "$dex" || fail "unable to extract $entry from $artifact"
        "$DEXDUMP" -d "$dex" > "$dump"
        if verify_dump "$dump"; then
            found=1
            break
        fi
    done < <(unzip -Z1 "$artifact" | awk -v prefix="$dex_prefix" '$0 ~ ("^" prefix "classes[0-9]*\\.dex$")')

    [[ "$found" -eq 1 ]] || fail "$artifact does not prove BuildConfig.NATIVE_ENGINE_ENABLED=true"
    printf 'ok: %s BuildConfig.NATIVE_ENGINE_ENABLED=true\n' "$artifact"
done
