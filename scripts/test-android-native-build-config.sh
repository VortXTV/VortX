#!/usr/bin/env bash
set -euo pipefail

# Parser and archive-level regression tests for verify-android-native-build-config.sh. The text
# fixtures exercise rejection boundaries only; a positive artifact test below uses the real Android
# SDK d8/dexdump pair when the pinned SDK is available. This prevents a fabricated dexdump fixture
# from being the only evidence that the production archive path works.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HELPER="$SCRIPT_DIR/verify-android-native-build-config.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

ok() {
    printf 'ok: %s\n' "$1"
}

[[ -x "$HELPER" ]] || fail "BuildConfig verifier helper is missing or not executable"

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

write_fixture() {
    local name="$1"
    shift
    printf '%s\n' "$@" > "$fixture_dir/$name"
}

expect_accept() {
    local name="$1"
    DEXDUMP= "$HELPER" --dump "$fixture_dir/$name" >/dev/null \
        || fail "expected BuildConfig parser acceptance: $name"
    ok "parser accepts field-local native=true fixture: $name"
}

expect_reject() {
    local name="$1"
    if DEXDUMP= "$HELPER" --dump "$fixture_dir/$name" >/dev/null 2>&1; then
        fail "expected BuildConfig parser rejection: $name"
    fi
    ok "parser rejects negative BuildConfig fixture: $name"
}

write_fixture native_static_value.dump \
    "Class descriptor  : 'Lcom/vortx/android/BuildConfig;'" \
    "Static fields     -" \
    "  #0              : (in Lcom/vortx/android/BuildConfig;)" \
    "    name          : 'DEBUG'" \
    "  #1              : (in Lcom/vortx/android/BuildConfig;)" \
    "    name          : 'NATIVE_ENGINE_ENABLED'" \
    "Static values     -" \
    "  #0              : (in Lcom/vortx/android/BuildConfig;)" \
    "    value         : false" \
    "  #1              : (in Lcom/vortx/android/BuildConfig;)" \
    "    value         : 0x00000001"
expect_accept native_static_value.dump

write_fixture native_field_local.dump \
    "Class descriptor  : 'Lcom/vortx/android/BuildConfig;'" \
    "Static fields     -" \
    "  #0              : (in Lcom/vortx/android/BuildConfig;)" \
    "    name          : 'NATIVE_ENGINE_ENABLED'" \
    "    type          : 'Z'" \
    "    value         : true"
expect_accept native_field_local.dump

write_fixture native_false_other_true.dump \
    "Class descriptor  : 'Lcom/vortx/android/BuildConfig;'" \
    "Static fields     -" \
    "  #0              : (in Lcom/vortx/android/BuildConfig;)" \
    "    name          : 'DEBUG'" \
    "    value         : true" \
    "  #1              : (in Lcom/vortx/android/BuildConfig;)" \
    "    name          : 'NATIVE_ENGINE_ENABLED'" \
    "    value         : false"
expect_reject native_false_other_true.dump

write_fixture native_wrong_static_value_index.dump \
    "Class descriptor  : 'Lcom/vortx/android/BuildConfig;'" \
    "Static fields     -" \
    "  #0              : (in Lcom/vortx/android/BuildConfig;)" \
    "    name          : 'NATIVE_ENGINE_ENABLED'" \
    "  #1              : (in Lcom/vortx/android/BuildConfig;)" \
    "    name          : 'DEBUG'" \
    "Static values     -" \
    "  #0              : (in Lcom/vortx/android/BuildConfig;)" \
    "    value         : false" \
    "  #1              : (in Lcom/vortx/android/BuildConfig;)" \
    "    value         : true"
expect_reject native_wrong_static_value_index.dump

write_fixture native_whitespace_class_boundary.dump \
    "  Class descriptor  : 'Lcom/vortx/android/BuildConfig;'" \
    "Static fields     -" \
    "  #0              : (in Lcom/vortx/android/BuildConfig;)" \
    "    name          : 'NATIVE_ENGINE_ENABLED'" \
    "    value         : false" \
    "    Class descriptor  : 'Lcom/vortx/android/BuildConfigExtra;'" \
    "Static fields     -" \
    "  #0              : (in Lcom/vortx/android/BuildConfigExtra;)" \
    "    name          : 'NATIVE_ENGINE_ENABLED'" \
    "    value         : true"
expect_reject native_whitespace_class_boundary.dump

ok "negative fixtures prove field-local and whitespace-safe class boundaries"

# Real SDK-generated positive fixture. This intentionally does not invoke Gradle. d8 converts a
# tiny javac-produced BuildConfig class into actual DEX, then zip packages that DEX at the exact APK
# and AAB locations used by the production helper. If the pinned SDK is absent on this host, report
# that fact explicitly; CI's setup-android step supplies both tools and executes this branch.
sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
build_tools="$sdk_root/build-tools/36.0.0"
d8="$build_tools/d8"
dexdump="$build_tools/dexdump"
javac="$(command -v javac || true)"
zip_bin="$(command -v zip || true)"
if [[ -n "$sdk_root" && -x "$d8" && -x "$dexdump" && -n "$javac" && -n "$zip_bin" ]]; then
    real_root="$fixture_dir/real-sdk"
    mkdir -p "$real_root/src/com/vortx/android" "$real_root/classes" "$real_root/dex"
    printf '%s\n' \
        'package com.vortx.android;' \
        'public final class BuildConfig {' \
        '  public static final boolean DEBUG = false;' \
        '  public static final boolean NATIVE_ENGINE_ENABLED = true;' \
        '  private BuildConfig() {}' \
        '}' > "$real_root/src/com/vortx/android/BuildConfig.java"
    "$javac" -source 8 -target 8 -d "$real_root/classes" "$real_root/src/com/vortx/android/BuildConfig.java"
    "$d8" --min-api 26 --output "$real_root/dex" "$real_root/classes/com/vortx/android/BuildConfig.class"
    [[ -s "$real_root/dex/classes.dex" ]] || fail "SDK d8 did not produce classes.dex"

    apk="$real_root/native.apk"
    aab="$real_root/native.aab"
    (cd "$real_root/dex" && "$zip_bin" -q "$apk" classes.dex)
    mkdir -p "$real_root/base/dex"
    cp "$real_root/dex/classes.dex" "$real_root/base/dex/classes.dex"
    (cd "$real_root" && "$zip_bin" -q -r "$aab" base/dex/classes.dex)
    DEXDUMP="$dexdump" "$HELPER" "$apk" "$aab"
    ok "real SDK d8/dexdump fixture proves APK classes.dex and AAB base/dex/classes.dex"
else
    printf 'SKIP: real SDK BuildConfig archive fixture unavailable (need ANDROID_HOME/ANDROID_SDK_ROOT with build-tools/36.0.0 d8+dexdump, javac, and zip)\n'
fi

printf 'PASS: Android native BuildConfig parser/archive contract\n'
