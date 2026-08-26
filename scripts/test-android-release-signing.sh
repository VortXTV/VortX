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
if [[ "${MOCK_JARSIGNER_PARTIAL:-0}" == "1" ]]; then
    printf '    ?      9 unsigned-entry.txt\n'
    printf '  ? = unsigned entry\n'
    printf 'jar verified, with signer errors.\n'
    printf 'Error: This jar contains unsigned entries which have not been integrity-checked.\n'
    exit 16
elif [[ "${MOCK_JARSIGNER_CHAIN_ERROR:-0}" == "1" ]]; then
    printf 'jar verified, with signer errors.\n'
    printf 'Error: This jar contains entries whose certificate chain is invalid.\n'
    exit 4
elif [[ "${MOCK_JARSIGNER_UNSIGNED:-0}" == "1" ]]; then
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

partial_output="$(expect_failure "partially unsigned AAB" env "${common_env[@]}" \
    MOCK_JARSIGNER_PARTIAL=1 "$VERIFY_SCRIPT" verify "$workdir/release.aab")"
grep -Fq 'contains unsigned entries' <<<"$partial_output" || fail "partially unsigned bundle error was not explicit"
printf 'ok: partially unsigned AAB is rejected\n'

strict_output="$(expect_failure "nonzero strict jarsigner status" env "${common_env[@]}" \
    MOCK_JARSIGNER_CHAIN_ERROR=1 "$VERIFY_SCRIPT" verify "$workdir/release.aab")"
grep -Fq 'strict verification failed' <<<"$strict_output" || fail "nonzero strict status was not rejected"
printf 'ok: every nonzero strict jarsigner status is rejected\n'

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

jdk_home="${JAVA_HOME:-}"
if [[ ! -x "$jdk_home/bin/java" && -x /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home/bin/java ]]; then
    jdk_home=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
fi
if [[ -x "$jdk_home/bin/jar" && -x "$jdk_home/bin/keytool" && -x "$jdk_home/bin/jarsigner" ]]; then
    real_dir="$workdir/real-aab"
    mkdir -p "$real_dir"
    printf 'signed payload\n' > "$real_dir/signed-entry.txt"
    "$jdk_home/bin/jar" --create --file "$real_dir/complete.aab" -C "$real_dir" signed-entry.txt
    "$jdk_home/bin/keytool" -genkeypair \
        -keystore "$real_dir/test.jks" \
        -storepass changeit \
        -keypass changeit \
        -alias release \
        -dname 'CN=VortX Test Release,O=VortXTV,C=US' \
        -keyalg RSA \
        -validity 365 >/dev/null 2>&1
    "$jdk_home/bin/jarsigner" \
        -keystore "$real_dir/test.jks" \
        -storepass changeit \
        -keypass changeit \
        "$real_dir/complete.aab" release >/dev/null 2>&1
    complete_output="$(expect_failure "real complete AAB with non-pinned signer" env \
        APKSIGNER_BIN="$workdir/bin/apksigner" \
        JARSIGNER_BIN="$jdk_home/bin/jarsigner" \
        KEYTOOL_BIN="$jdk_home/bin/keytool" \
        JAVA_HOME="$jdk_home" \
        "$VERIFY_SCRIPT" verify "$real_dir/complete.aab")"
    grep -Fq 'signer SHA-256 mismatch' <<<"$complete_output" || fail "real complete AAB did not pass strict entry verification before fingerprint rejection"
    printf 'ok: real fully signed AAB reaches pinned fingerprint gate\n'
    cp "$real_dir/complete.aab" "$real_dir/partial.aab"
    printf 'unsigned payload\n' > "$real_dir/unsigned-entry.txt"
    "$jdk_home/bin/jar" --update --file "$real_dir/partial.aab" -C "$real_dir" unsigned-entry.txt
    partial_output="$(expect_failure "real partially unsigned AAB" env \
        APKSIGNER_BIN="$workdir/bin/apksigner" \
        JARSIGNER_BIN="$jdk_home/bin/jarsigner" \
        KEYTOOL_BIN="$jdk_home/bin/keytool" \
        JAVA_HOME="$jdk_home" \
        "$VERIFY_SCRIPT" verify "$real_dir/partial.aab")"
    grep -Fq 'contains unsigned entries' <<<"$partial_output" || fail "real partially unsigned bundle error was not explicit"
    printf 'ok: real signed AAB with appended unsigned entry is rejected\n'
else
    printf 'skip: JDK tools unavailable for real partially unsigned AAB regression\n'
fi

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
