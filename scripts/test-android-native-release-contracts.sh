#!/usr/bin/env bash
set -euo pipefail

# Focused source contract for the staged Android native 0.5 selection. This test intentionally does
# not configure Gradle, fetch private repositories, build Rust, or inspect a local APK. The release
# workflows perform the content-level BuildConfig/JNI/resource-host checks after producing each
# artifact; this script binds those gates to the source selection and the existing Kotlin call graph.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly GRADLE_BUILD="$REPO_ROOT/android/app/build.gradle.kts"
readonly ANDROID_CI_WF="$REPO_ROOT/.github/workflows/android.yml"
readonly ANDROID_RELEASE_WF="$REPO_ROOT/.github/workflows/android-release.yml"
readonly APP_SOURCE="$REPO_ROOT/android/app/src/main/kotlin/com/vortx/android/VortXApplication.kt"
readonly LEGACY_REPOSITORY="$REPO_ROOT/android/app/src/main/kotlin/com/vortx/android/engine/EngineStremioRepository.kt"
readonly RESOURCE_BRIDGE="$REPO_ROOT/android/app/src/main/kotlin/com/vortx/android/engine/VortxResourceBridge.kt"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

ok() {
    printf 'ok: %s\n' "$1"
}

require_literal() {
    local description="$1" literal="$2" file="$3"
    grep -qF -- "$literal" "$file" || fail "$description"
    ok "$description"
}

require_regex() {
    local description="$1" pattern="$2" file="$3"
    grep -Eq -- "$pattern" "$file" || fail "$description"
    ok "$description"
}

[[ -f "$GRADLE_BUILD" && -f "$ANDROID_CI_WF" && -f "$ANDROID_RELEASE_WF" ]] \
    || fail "Android native release contract inputs are missing"

# One resolver drives both BuildConfig and Cargo feature selection. Gradle properties take
# precedence over environment values, malformed values fail during configuration, and native=true
# cannot reach compilation without resource-host=true.
require_literal "Gradle owns one native boolean resolver" 'fun nativeBooleanFlag(propertyName: String, environmentName: String)' "$GRADLE_BUILD"
require_literal "Gradle resolves the native application mode once" 'val nativeEngineEnabled = nativeBooleanFlag("vortx.nativeEngine", "VORTX_NATIVE_ENGINE")' "$GRADLE_BUILD"
require_literal "Gradle resolves the resource-host mode once" 'val nativeResourceHostEnabled = nativeBooleanFlag("vortx.nativeResourceHost", "VORTX_NATIVE_RESOURCE_HOST")' "$GRADLE_BUILD"
require_literal "native mode fails closed without resource-host" 'if (nativeEngineEnabled && !nativeResourceHostEnabled)' "$GRADLE_BUILD"
require_literal "BuildConfig is derived from the resolved native mode" 'buildConfigField("boolean", "NATIVE_ENGINE_ENABLED", nativeEngineEnabled.toString())' "$GRADLE_BUILD"
require_literal "resource-host compilation is an explicit Cargo feature" '"jni,server,resource-host"' "$GRADLE_BUILD"
require_literal "legacy JNI/server feature remains explicit for non-native builds" '"jni,server"' "$GRADLE_BUILD"
require_regex "native feature selection uses the shared resource-host decision" 'if \(nativeResourceHostEnabled\) "jni,server,resource-host" else "jni,server"' "$GRADLE_BUILD"
if grep -qF 'providers.gradleProperty("vortx.nativeEngine").orNull == "true"' "$GRADLE_BUILD"; then
    fail "BuildConfig still has an independent provider-only native selector"
fi
ok "BuildConfig and Cargo selection cannot silently disagree"

# Every engine-required workflow build must opt into both halves of the native contract. Keep the
# host env assertion as an additional compatibility signal, but do not allow it to substitute for
# the explicit Gradle property that controls generated BuildConfig.
for workflow in "$ANDROID_CI_WF" "$ANDROID_RELEASE_WF"; do
    build_runs="$(grep -E '^[[:space:]]*run: \./gradlew .*assemble|^[[:space:]]*run: \./gradlew .*bundle' "$workflow" || true)"
    [[ -n "$build_runs" ]] || fail "$(basename "$workflow") has no Gradle engine build invocation"
    while IFS= read -r run; do
        [[ "$run" == *'-Pvortx.nativeEngine=true'* ]] \
            || fail "$(basename "$workflow") Gradle build does not select nativeEngine=true: $run"
        [[ "$run" == *'-Pvortx.nativeResourceHost=true'* ]] \
            || fail "$(basename "$workflow") Gradle build does not select nativeResourceHost=true: $run"
    done <<< "$build_runs"
    require_literal "$(basename "$workflow") keeps the engine-required host env" 'VORTX_NATIVE_RESOURCE_HOST: "1"' "$workflow"
    require_literal "$(basename "$workflow") keeps the native mode env aligned" 'VORTX_NATIVE_ENGINE: "1"' "$workflow"
    require_regex "$(basename "$workflow") verifies the resource-host ABI" 'verify-native-engine-abi\.sh android .* resource-host' "$workflow"
    require_literal "$(basename "$workflow") pins stremiox-core immutably" 'repository: VortXTV/stremiox-core' "$workflow"
    require_regex "$(basename "$workflow") stremiox-core ref is a full SHA" 'ref: [0-9a-f]{40}' "$workflow"
    require_literal "$(basename "$workflow") pins vortx-core immutably" 'repository: VortXTV/vortx-core' "$workflow"
done
ok "debug/release Android workflow invocations select native mode and resource-host together"

# Artifact checks are content-level, not path-level: every produced APK/AAB must prove the generated
# BuildConfig and inspect each shipped ABI's JNI/resource-host surface with the pinned tools.
for workflow in "$ANDROID_CI_WF" "$ANDROID_RELEASE_WF"; do
    require_literal "$(basename "$workflow") uses the pinned dexdump for BuildConfig proof" 'DEXDUMP="$ANDROID_HOME/build-tools/36.0.0/dexdump"' "$workflow"
    require_literal "$(basename "$workflow") names the native BuildConfig field in its artifact gate" 'NATIVE_ENGINE_ENABLED' "$workflow"
    require_literal "$(basename "$workflow") rejects an artifact without native BuildConfig=true" 'does not prove BuildConfig.NATIVE_ENGINE_ENABLED=true' "$workflow"
    require_literal "$(basename "$workflow") checks the AAB base dex path" 'prefix="base/"' "$workflow"
    require_literal "$(basename "$workflow") checks all shipped Android ABIs" 'for abi in arm64-v8a armeabi-v7a x86_64' "$workflow"
    require_literal "$(basename "$workflow") checks callable resource-host JNI exports" 'resource-host' "$workflow"
done
require_literal "candidate signed artifacts still run the complete native ABI verifier" 'bash scripts/verify-native-android-artifacts.sh "${apks[@]}" "${bundles[@]}"' "$ANDROID_CI_WF"
ok "APK/AAB gates prove BuildConfig native mode and JNI/resource-host content"

# Native mode must not be able to fall back through the old repository or sync seams. This is a
# read-only call-graph contract; the legacy implementation remains compiled and packaged for the
# explicitly selected non-native variant until an independently reviewed link-removal gate exists.
require_literal "application selects NativeCatalogRepository in native mode" 'if (BuildConfig.NATIVE_ENGINE_ENABLED) nativeRepository' "$APP_SOURCE"
require_literal "application does not attach legacy sync seams in native mode" 'if (!BuildConfig.NATIVE_ENGINE_ENABLED) manager.attachSyncSeams(store)' "$APP_SOURCE"
require_literal "legacy repository rejects native construction" 'check(!com.vortx.android.BuildConfig.NATIVE_ENGINE_ENABLED)' "$LEGACY_REPOSITORY"
require_literal "native resource bridge requires the resource-host ABI" 'nativeResourceHostAbiVersion()' "$RESOURCE_BRIDGE"
require_literal "native resource bridge rejects an unavailable host" 'nativeResourceHostNew()' "$RESOURCE_BRIDGE"
ok "native mode has no legacy repository fallback path"

# Report, but do not alter, the private engine pins. The approved CI replacement is intentionally
# supplied by the parent after this contract lane; changing a pin here would make this source review
# conflate selection behavior with a private dependency approval.
for workflow in "$ANDROID_CI_WF" "$ANDROID_RELEASE_WF"; do
    stremio_pin="$(awk '/repository: VortXTV\/stremiox-core/{seen=1; next} seen && /ref:/{print $2; exit}' "$workflow")"
    vortx_pin="$(awk '/repository: VortXTV\/vortx-core/{seen=1; next} seen && /ref:/{print $2; exit}' "$workflow")"
    printf 'pin: %s stremiox-core=%s vortx-core=%s (parent approval owns replacement)\n' "$(basename "$workflow")" "$stremio_pin" "$vortx_pin"
done

printf 'PASS: Android native 0.5 release selection/package contract\n'
