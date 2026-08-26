#!/usr/bin/env bash
set -euo pipefail

readonly EXPECTED_SIGNER_SHA256="90:DD:08:59:BE:63:56:9B:31:F4:0B:F9:3D:3E:36:29:09:45:35:01:3F:34:89:C2:2B:EE:3B:46:55:E0:00:6A"
readonly EXPECTED_SIGNER_SHA256_COMPACT="90DD0859BE63569B31F40BF93D3E3629094535013F3489C22BEE3B4655E0006A"
readonly REQUIRED_SIGNING_INPUTS=(
    VORTX_KEYSTORE_PATH
    VORTX_KEYSTORE_PASSWORD
    VORTX_KEY_ALIAS
    VORTX_KEY_PASSWORD
)

error() {
    printf 'error: %s\n' "$*" >&2
}

normalize_fingerprint() {
    tr '[:lower:]' '[:upper:]' | tr -d ':[:space:]'
}

require_command() {
    local command_path="$1"
    local description="$2"
    if [[ ! -x "$command_path" ]] && ! command -v "$command_path" >/dev/null 2>&1; then
        error "$description is unavailable: $command_path"
        return 1
    fi
}

preflight() {
    local missing=()
    local name
    for name in "${REQUIRED_SIGNING_INPUTS[@]}"; do
        if [[ -z "${!name:-}" ]]; then
            missing+=("$name")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        for name in "${missing[@]}"; do
            error "required release signing input $name is not set"
        done
        error "release signing preflight failed before build or upload"
        return 1
    fi

    printf 'release signing preflight passed: all required inputs are present\n'
}

resolve_apksigner() {
    if [[ -n "${APKSIGNER_BIN:-}" ]]; then
        printf '%s\n' "$APKSIGNER_BIN"
        return
    fi
    if command -v apksigner >/dev/null 2>&1; then
        command -v apksigner
        return
    fi

    local candidates=()
    if [[ -n "${ANDROID_HOME:-}" ]]; then
        shopt -s nullglob
        candidates=("$ANDROID_HOME"/build-tools/*/apksigner)
        shopt -u nullglob
    fi
    if (( ${#candidates[@]} == 0 )); then
        error "apksigner was not found in PATH or ANDROID_HOME/build-tools"
        return 1
    fi
    printf '%s\n' "${candidates[@]}" | sort -V | tail -n 1
}

verify_expected_fingerprint() {
    local artifact="$1"
    local fingerprint="$2"
    local compact
    compact="$(printf '%s' "$fingerprint" | normalize_fingerprint)"
    if [[ "$compact" != "$EXPECTED_SIGNER_SHA256_COMPACT" ]]; then
        error "$artifact signer SHA-256 mismatch: expected $EXPECTED_SIGNER_SHA256, got ${fingerprint:-<missing>}"
        return 1
    fi
}

reject_debug_signer() {
    local artifact="$1"
    local certificate_output="$2"
    if grep -Eiq '(^|[,[:space:]])CN[[:space:]]*=[[:space:]]*Android Debug([,[:space:]]|$)|Android Debug' <<<"$certificate_output"; then
        error "$artifact is signed by an Android Debug certificate"
        return 1
    fi
}

verify_apk() {
    local apksigner="$1"
    local apk="$2"
    local output fingerprint subject fingerprint_count

    [[ -f "$apk" ]] || { error "APK does not exist: $apk"; return 1; }
    output="$("$apksigner" verify --verbose --print-certs "$apk")" || {
        error "apksigner verification failed for $apk"
        return 1
    }
    grep -Fq 'Verified using v2 scheme (APK Signature Scheme v2): true' <<<"$output" || {
        error "$apk is not verified with APK Signature Scheme v2"
        return 1
    }
    reject_debug_signer "$apk" "$output"

    fingerprint_count="$(sed -n 's/^Signer #[0-9][0-9]* certificate SHA-256 digest: //p' <<<"$output" | wc -l | tr -d '[:space:]')"
    if [[ "$fingerprint_count" != "1" ]]; then
        error "$apk must have exactly one reported signer SHA-256 digest, found $fingerprint_count"
        return 1
    fi
    fingerprint="$(sed -n 's/^Signer #[0-9][0-9]* certificate SHA-256 digest: //p' <<<"$output")"
    verify_expected_fingerprint "$apk" "$fingerprint"
    subject="$(sed -n 's/^Signer #[0-9][0-9]* certificate DN: //p' <<<"$output")"
    [[ -n "$subject" ]] || subject="<subject unavailable>"

    printf 'verified APK: %s\n' "$(basename "$apk")"
    printf '  signer: %s\n' "$subject"
    printf '  signer SHA-256: %s\n' "$EXPECTED_SIGNER_SHA256"
}

verify_bundle() {
    local jarsigner="$1"
    local keytool="$2"
    local bundle="$3"
    local output verification_output fingerprint subject fingerprint_count

    [[ -f "$bundle" ]] || { error "Android App Bundle does not exist: $bundle"; return 1; }
    verification_output="$(LC_ALL=C "$jarsigner" -verify "$bundle")" || {
        error "jarsigner verification failed for $bundle"
        return 1
    }
    grep -Fq 'jar verified.' <<<"$verification_output" || {
        error "$bundle does not contain a verified JAR signature"
        return 1
    }
    output="$(LC_ALL=C "$keytool" -printcert -jarfile "$bundle")" || {
        error "could not read the signing certificate from $bundle"
        return 1
    }
    reject_debug_signer "$bundle" "$output"

    fingerprint_count="$(sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' <<<"$output" | wc -l | tr -d '[:space:]')"
    if [[ "$fingerprint_count" != "1" ]]; then
        error "$bundle must have exactly one reported signer SHA-256 fingerprint, found $fingerprint_count"
        return 1
    fi
    fingerprint="$(sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' <<<"$output")"
    verify_expected_fingerprint "$bundle" "$fingerprint"
    subject="$(sed -n 's/^Owner:[[:space:]]*//p' <<<"$output")"
    [[ -n "$subject" ]] || subject="<subject unavailable>"

    printf 'verified AAB: %s\n' "$(basename "$bundle")"
    printf '  signer: %s\n' "$subject"
    printf '  signer SHA-256: %s\n' "$EXPECTED_SIGNER_SHA256"
}

verify_artifacts() {
    shift
    (( $# > 0 )) || { error "verify requires at least one APK or AAB"; return 1; }

    local apksigner jarsigner keytool artifact
    apksigner="$(resolve_apksigner)"
    jarsigner="${JARSIGNER_BIN:-jarsigner}"
    keytool="${KEYTOOL_BIN:-keytool}"
    require_command "$apksigner" "apksigner"
    require_command "$jarsigner" "jarsigner"
    require_command "$keytool" "keytool"

    for artifact in "$@"; do
        case "$artifact" in
            *.apk) verify_apk "$apksigner" "$artifact" ;;
            *.aab) verify_bundle "$jarsigner" "$keytool" "$artifact" ;;
            *) error "unsupported Android artifact type: $artifact"; return 1 ;;
        esac
    done
}

usage() {
    printf 'Usage: %s preflight | verify <artifact.apk|artifact.aab>...\n' "$0" >&2
}

case "${1:-}" in
    preflight) preflight ;;
    verify) verify_artifacts "$@" ;;
    *) usage; exit 2 ;;
esac
