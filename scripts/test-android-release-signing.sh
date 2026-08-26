#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VERIFY_SCRIPT="$SCRIPT_DIR/verify-android-release-signing.sh"
readonly EXPECTED_COMPACT="90DD0859BE63569B31F40BF93D3E3629094535013F3489C22BEE3B4655E0006A"
readonly WRONG_COMPACT="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local description="$1"
    shift
    local output
    if output="$("$@" 2>&1)"; then
        fail "$description unexpectedly succeeded"
    fi
    printf 'ok: %s fails closed\n' "$description"
    printf '%s' "$output"
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
mkdir -p "$workdir/bin"
touch "$workdir/release.apk" "$workdir/release.aab"

cat > "$workdir/bin/apksigner" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
fingerprint="${MOCK_FINGERPRINT:-90DD0859BE63569B31F40BF93D3E3629094535013F3489C22BEE3B4655E0006A}"
subject="${MOCK_SUBJECT:-CN=VortX Release, O=VortXTV, C=US}"
printf 'Verifies\n'
printf 'Verified using v2 scheme (APK Signature Scheme v2): true\n'
printf 'Signer #1 certificate DN: %s\n' "$subject"
printf 'Signer #1 certificate SHA-256 digest: %s\n' "$fingerprint"
MOCK

cat > "$workdir/bin/jarsigner" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_JARSIGNER_UNSIGNED:-0}" == "1" ]]; then
    printf 'jar is unsigned.\n'
else
    printf 'jar verified.\n'
fi
MOCK

cat > "$workdir/bin/keytool" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
fingerprint="${MOCK_FINGERPRINT:-90DD0859BE63569B31F40BF93D3E3629094535013F3489C22BEE3B4655E0006A}"
subject="${MOCK_SUBJECT:-CN=VortX Release, O=VortXTV, C=US}"
printf 'Owner: %s\n' "$subject"
printf 'SHA256: %s\n' "$fingerprint"
MOCK
chmod +x "$workdir/bin/apksigner" "$workdir/bin/jarsigner" "$workdir/bin/keytool"

for missing in VORTX_KEYSTORE_PATH VORTX_KEYSTORE_PASSWORD VORTX_KEY_ALIAS VORTX_KEY_PASSWORD; do
    output="$(expect_failure "missing $missing" env \
        VORTX_KEYSTORE_PATH=keystore-sentinel \
        VORTX_KEYSTORE_PASSWORD=store-password-sentinel \
        VORTX_KEY_ALIAS=alias-sentinel \
        VORTX_KEY_PASSWORD=key-password-sentinel \
        bash -c 'unset "$1"; exec "$2" preflight' test-shell "$missing" "$VERIFY_SCRIPT")"
    grep -Fq "$missing" <<<"$output" || fail "missing-input error did not name $missing"
    printf 'ok: missing %s fails closed before build\n' "$missing"
done

preflight_output="$(
    VORTX_KEYSTORE_PATH=keystore-sentinel \
    VORTX_KEYSTORE_PASSWORD=store-password-sentinel \
    VORTX_KEY_ALIAS=alias-sentinel \
    VORTX_KEY_PASSWORD=key-password-sentinel \
    "$VERIFY_SCRIPT" preflight 2>&1
)"
for secret in keystore-sentinel store-password-sentinel alias-sentinel key-password-sentinel; do
    if grep -Fq "$secret" <<<"$preflight_output"; then
        fail "preflight printed secret material"
    fi
done
printf 'ok: complete preflight succeeds without printing secret values\n'

common_env=(
    APKSIGNER_BIN="$workdir/bin/apksigner"
    JARSIGNER_BIN="$workdir/bin/jarsigner"
    KEYTOOL_BIN="$workdir/bin/keytool"
)

env "${common_env[@]}" "$VERIFY_SCRIPT" verify "$workdir/release.apk" "$workdir/release.aab" >/dev/null
printf 'ok: pinned production signer is accepted for APK and AAB\n'

mismatch_output="$(expect_failure "APK fingerprint mismatch" env "${common_env[@]}" \
    MOCK_FINGERPRINT="$WRONG_COMPACT" "$VERIFY_SCRIPT" verify "$workdir/release.apk")"
grep -Fq 'signer SHA-256 mismatch' <<<"$mismatch_output" || fail "mismatch error was not explicit"
printf 'ok: APK fingerprint mismatch is rejected\n'

mismatch_output="$(expect_failure "AAB fingerprint mismatch" env "${common_env[@]}" \
    MOCK_FINGERPRINT="$WRONG_COMPACT" "$VERIFY_SCRIPT" verify "$workdir/release.aab")"
grep -Fq 'signer SHA-256 mismatch' <<<"$mismatch_output" || fail "bundle mismatch error was not explicit"
printf 'ok: AAB fingerprint mismatch is rejected\n'

unsigned_output="$(expect_failure "unsigned AAB" env "${common_env[@]}" \
    MOCK_JARSIGNER_UNSIGNED=1 "$VERIFY_SCRIPT" verify "$workdir/release.aab")"
grep -Fq 'does not contain a verified JAR signature' <<<"$unsigned_output" || fail "unsigned bundle error was not explicit"
printf 'ok: unsigned AAB is rejected\n'

debug_output="$(expect_failure "Android Debug APK signer" env "${common_env[@]}" \
    MOCK_SUBJECT='CN=Android Debug,O=Android,C=US' MOCK_FINGERPRINT="$EXPECTED_COMPACT" \
    "$VERIFY_SCRIPT" verify "$workdir/release.apk")"
grep -Fq 'Android Debug certificate' <<<"$debug_output" || fail "debug signer rejection was not explicit"
printf 'ok: Android Debug APK signer is rejected\n'

debug_output="$(expect_failure "Android Debug AAB signer" env "${common_env[@]}" \
    MOCK_SUBJECT='CN=Android Debug,O=Android,C=US' MOCK_FINGERPRINT="$EXPECTED_COMPACT" \
    "$VERIFY_SCRIPT" verify "$workdir/release.aab")"
grep -Fq 'Android Debug certificate' <<<"$debug_output" || fail "debug bundle signer rejection was not explicit"
printf 'ok: Android Debug AAB signer is rejected\n'

workflow="$REPO_ROOT/.github/workflows/android-release.yml"
gradle_build="$REPO_ROOT/android/app/build.gradle.kts"
if grep -Eq 'debug-signed|fail soft|signingConfigs\.getByName\("debug"\)' "$workflow" "$gradle_build"; then
    fail "a production debug-signing fallback remains"
fi
preflight_line="$(awk '/Preflight release signing inputs/{ print NR; exit }' "$workflow")"
build_line="$(awk '/\.\/gradlew :app:assembleFullRelease/{ print NR; exit }' "$workflow")"
verify_line="$(awk '/Verify pinned production signer/{ print NR; exit }' "$workflow")"
upload_line="$(awk '/gh release upload/{ print NR; exit }' "$workflow")"
[[ -n "$preflight_line" && -n "$build_line" && "$preflight_line" -lt "$build_line" ]] || fail "signing preflight is not before the release build"
[[ -n "$verify_line" && -n "$upload_line" && "$verify_line" -lt "$upload_line" ]] || fail "signer verification is not before release upload"
grep -Fq 'ref: ${{ inputs.release_tag }}' "$workflow" || fail "checkout is not bound to the requested release tag"
grep -Fq 'source_commit" != "$tag_commit' "$workflow" || fail "source and tag commit equality gate is absent"
printf 'ok: workflow ordering, tag binding, and no-debug-fallback invariants hold\n'

printf 'all Android release signing tests passed\n'
