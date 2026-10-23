#!/usr/bin/env bash
set -euo pipefail

# Configure the real Android model and Cargo task with synthetic selection inputs. No native
# compilation or app assembly runs. The engine/resource host are mandatory; retired false/blank
# selections and malformed inputs must fail, while properties still take precedence over env.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/native-selection.XXXXXX")"
cd "$repo_root/android"
gradle_args=(--no-daemon --max-workers=1 -Dorg.gradle.jvmargs=-Xmx1g
    --init-script "$repo_root/scripts/fixtures/android-native-selection.gradle"
    :app:verifyNativeSelectionFixture)
cases=0

selection() {
    local engine_env="$1" host_env="$2"
    shift 2
    local environment=(env -u VORTX_NATIVE_ENGINE -u VORTX_NATIVE_RESOURCE_HOST)
    [[ "$engine_env" == absent ]] || environment+=("VORTX_NATIVE_ENGINE=$engine_env")
    [[ "$host_env" == absent ]] || environment+=("VORTX_NATIVE_RESOURCE_HOST=$host_env")
    "${environment[@]}" ./gradlew "${gradle_args[@]}" "$@"
}

accept() {
    local label="$1"
    shift
    if ! selection "$@" > "$test_dir/$label.log" 2>&1; then
        tail -50 "$test_dir/$label.log"
        exit 1
    fi
    printf '%s: ' "$label"
    grep -F 'native-selection: native-only, features=' "$test_dir/$label.log"
    cases=$((cases + 1))
}

reject() {
    local label="$1" diagnostic="$2"
    shift 2
    if selection "$@" > "$test_dir/$label.log" 2>&1; then
        printf 'FAIL: invalid configuration was accepted: %s\n' "$label" >&2
        exit 1
    fi
    grep -F "$diagnostic" "$test_dir/$label.log" >/dev/null
    printf 'rejected: %s\n' "$label"
    cases=$((cases + 1))
}

# ORG_GRADLE_PROJECT_ values are properties; do not let the caller silently change a fixture.
for key in ORG_GRADLE_PROJECT_vortx.nativeEngine ORG_GRADLE_PROJECT_vortx.nativeResourceHost; do
    if printenv "$key" >/dev/null; then
        printf 'Unset injected Gradle property %s before this fixture.\n' "$key" >&2
        exit 1
    fi
done

accept default absent absent
accept environment-on true 1
accept engine-property-over-environment false absent -Pvortx.nativeEngine=true
accept host-property-over-environment absent false -Pvortx.nativeResourceHost=true
accept paired-properties absent absent -Pvortx.nativeEngine=1 -Pvortx.nativeResourceHost=1
reject environment-engine-off 'selected the removed legacy engine build' false absent
reject environment-host-off 'selected the removed legacy engine build' absent false
reject property-engine-off 'selected the removed legacy engine build' true absent -Pvortx.nativeEngine=false
reject property-host-off 'selected the removed legacy engine build' absent true -Pvortx.nativeResourceHost=0
reject blank-engine-property 'selected the removed legacy engine build' true absent -Pvortx.nativeEngine=
reject blank-host-property 'selected the removed legacy engine build' absent true -Pvortx.nativeResourceHost=
reject paired-comparison 'selected the removed legacy engine build' absent absent -Pvortx.nativeEngine=0 -Pvortx.nativeResourceHost=0
reject malformed-engine-property 'must be true/false or 1/0' absent absent -Pvortx.nativeEngine=invalid
reject malformed-host-property 'must be true/false or 1/0' absent absent -Pvortx.nativeResourceHost=invalid
reject malformed-engine-environment 'must be true/false or 1/0' invalid absent
reject malformed-host-environment 'must be true/false or 1/0' absent invalid
printf 'All %s real Gradle native-only selection fixtures passed. Receipts: %s\n' "$cases" "$test_dir"
