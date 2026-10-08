#!/usr/bin/env bash
set -euo pipefail

# Requires the normal Android SDK/JDK and cached Gradle dependencies. These are real Gradle
# configuration checks, not a reimplementation of the flag resolver; no app/native build runs.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/native-selection.XXXXXX")"
cd "$repo_root/android"
gradle_args=(--no-daemon --max-workers=1 -Dorg.gradle.jvmargs=-Xmx1g
    --init-script "$repo_root/scripts/fixtures/android-native-selection.gradle"
    :app:verifyNativeSelectionFixture)

accept() {
    local label="$1" expected="$2" engine_env="$3" host_env="$4"
    shift 4
    local environment=(env -u VORTX_NATIVE_ENGINE -u VORTX_NATIVE_RESOURCE_HOST)
    [[ "$engine_env" == absent ]] || environment+=("VORTX_NATIVE_ENGINE=$engine_env")
    [[ "$host_env" == absent ]] || environment+=("VORTX_NATIVE_RESOURCE_HOST=$host_env")
    if ! "${environment[@]}" ./gradlew "${gradle_args[@]}" "-Pfixture.expectedNative=$expected" "$@" > "$test_dir/$label.log" 2>&1; then
        tail -50 "$test_dir/$label.log"
        exit 1
    fi
    printf '%s: ' "$label"
    grep -F 'native-selection: BuildConfig=' "$test_dir/$label.log"
}

reject() {
    local label="$1" diagnostic="$2"
    shift 2
    if env -u VORTX_NATIVE_ENGINE -u VORTX_NATIVE_RESOURCE_HOST ./gradlew "${gradle_args[@]}" \
        -Pfixture.expectedNative=true "$@" > "$test_dir/$label.log" 2>&1; then
        printf 'FAIL: invalid configuration was accepted: %s\n' "$label" >&2
        exit 1
    fi
    grep -F "$diagnostic" "$test_dir/$label.log" >/dev/null
    printf 'rejected: %s\n' "$label"
}

# Environment entries prefixed ORG_GRADLE_PROJECT_ are Gradle properties themselves; leave the
# test fail-closed if the invoking environment injects such a native selection unexpectedly.
for key in ORG_GRADLE_PROJECT_vortx.nativeEngine ORG_GRADLE_PROJECT_vortx.nativeResourceHost; do
    if printenv "$key" >/dev/null; then
        printf 'Unset injected Gradle property %s before this fixture.\n' "$key" >&2
        exit 1
    fi
done

accept default true absent absent
accept environment-off false false absent
accept property-over-environment false true absent -Pvortx.nativeEngine=false
accept blank-property false true absent -Pvortx.nativeEngine=
accept property-on true false absent -Pvortx.nativeEngine=true
accept paired-comparison false absent absent -Pvortx.nativeEngine=0 -Pvortx.nativeResourceHost=0
reject missing-host 'requires vortx.nativeResourceHost=true' -Pvortx.nativeEngine=true -Pvortx.nativeResourceHost=false
reject malformed-engine 'must be true/false or 1/0' -Pvortx.nativeEngine=invalid
reject malformed-host 'must be true/false or 1/0' -Pvortx.nativeResourceHost=invalid
printf 'All nine real Gradle native-selection fixtures passed. Receipts: %s\n' "$test_dir"
