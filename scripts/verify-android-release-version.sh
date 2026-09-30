#!/usr/bin/env bash
set -euo pipefail

# Inspect the packaged manifests, not Gradle output-metadata.json or an Apple build number.
# Production signing is checked separately before this evidence enters SIGNING_PROVENANCE.txt.
fail() { printf 'Android version verification: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 4 ]] || fail 'usage: <versionCode> <versionName> <artifact.apk|artifact.aab>...'
expected_code="$1"; expected_name="$2"; shift 2
[[ "$expected_code" =~ ^[1-9][0-9]*$ && ${#expected_code} -le 10 ]] || fail 'versionCode must be a positive decimal integer'
(( expected_code <= 2100000000 )) || fail 'versionCode exceeds the Android publishing limit'
[[ "$expected_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'versionName must be a numeric release version'
aapt2="${AAPT2_BIN:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}/build-tools/36.0.0/aapt2}"
java_bin="${JAVA_BIN:-java}"
apk_count=0; bundle_count=0
for artifact in "$@"; do
    [[ -s "$artifact" ]] || fail "missing or empty artifact: $artifact"
    case "$artifact" in
        *.apk)
            [[ -x "$aapt2" ]] || fail 'aapt2 is unavailable'
            badging="$("$aapt2" dump badging "$artifact")" || fail "could not inspect APK: $artifact"
            package_lines="$(printf '%s\n' "$badging" | sed -n '/^package: /p')"
            [[ "$(printf '%s\n' "$package_lines" | wc -l | tr -d ' ')" = 1 ]] || fail 'APK must contain one package identity'
            [[ "$package_lines" == "package: name='com.vortx.android' versionCode='$expected_code' versionName='$expected_name'"* ]] || fail "APK package/version mismatch: $artifact"
            apk_count=$((apk_count + 1))
            ;;
        *.aab)
            [[ -s "${BUNDLETOOL_JAR:-}" ]] || fail 'verified bundletool JAR is required for AAB inspection'
            bundle_code="$("$java_bin" -jar "$BUNDLETOOL_JAR" dump manifest --bundle="$artifact" --xpath='/manifest/@android:versionCode')" || fail 'could not inspect AAB versionCode'
            bundle_name="$("$java_bin" -jar "$BUNDLETOOL_JAR" dump manifest --bundle="$artifact" --xpath='/manifest/@android:versionName')" || fail 'could not inspect AAB versionName'
            bundle_package="$("$java_bin" -jar "$BUNDLETOOL_JAR" dump manifest --bundle="$artifact" --xpath='/manifest/@package')" || fail 'could not inspect AAB package'
            [[ "$bundle_code" = "$expected_code" && "$bundle_name" = "$expected_name" && "$bundle_package" = com.vortx.android ]] || fail "AAB package/version mismatch: $artifact"
            bundle_count=$((bundle_count + 1))
            ;;
        *) fail "unsupported artifact: $artifact" ;;
    esac
done
[[ "$apk_count" = 2 && "$bundle_count" = 1 ]] || fail 'release version evidence requires two APKs and one AAB'
printf 'Android versionCode: %s\nAndroid versionName: %s\n' "$expected_code" "$expected_name"
