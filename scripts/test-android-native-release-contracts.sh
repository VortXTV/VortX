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
require_literal "Gradle owns one native boolean resolver" 'fun nativeBooleanFlag(propertyName: String, environmentName: String, defaultValue: Boolean)' "$GRADLE_BUILD"
require_literal "only an absent selection adopts the default" 'null -> defaultValue' "$GRADLE_BUILD"
require_literal "explicit false or blank retains non-native comparison mode" '"", "false", "0" -> false' "$GRADLE_BUILD"
require_literal "an explicit Gradle property precedes the environment" 'val raw = property?.trim() ?: System.getenv(environmentName)?.trim()' "$GRADLE_BUILD"
require_literal "Gradle defaults the native application mode on" 'val nativeEngineEnabled = nativeBooleanFlag("vortx.nativeEngine", "VORTX_NATIVE_ENGINE", defaultValue = true)' "$GRADLE_BUILD"
require_literal "the resource-host default follows the resolved application mode" 'val nativeResourceHostEnabled = nativeBooleanFlag("vortx.nativeResourceHost", "VORTX_NATIVE_RESOURCE_HOST", defaultValue = nativeEngineEnabled)' "$GRADLE_BUILD"
require_literal "native mode fails closed without resource-host" 'if (nativeEngineEnabled && !nativeResourceHostEnabled)' "$GRADLE_BUILD"
require_literal "BuildConfig is derived from the resolved native mode" 'buildConfigField("boolean", "NATIVE_ENGINE_ENABLED", nativeEngineEnabled.toString())' "$GRADLE_BUILD"
require_literal "resource-host compilation is an explicit Cargo feature" '"jni,server,resource-host"' "$GRADLE_BUILD"
require_literal "legacy JNI/server feature remains explicit for non-native builds" '"jni,server"' "$GRADLE_BUILD"
require_regex "native feature selection uses the shared resource-host decision" 'if \(nativeResourceHostEnabled\) "jni,server,resource-host" else "jni,server"' "$GRADLE_BUILD"
require_literal "legacy Stremio JNI task is a non-native comparison dependency only" 'if (!nativeEngineEnabled) dependsOn(cargoNdkBuild)' "$GRADLE_BUILD"
require_literal "native mode excludes the legacy Stremio jniLibs directory" 'if (!nativeEngineEnabled) jniLibs.srcDir(jniLibsOutDir)' "$GRADLE_BUILD"
require_literal "native mode excludes stale legacy Stremio JNI packages" 'if (nativeEngineEnabled) excludes += "**/libstremiox_core.so"' "$GRADLE_BUILD"
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
    require_literal "$(basename "$workflow") invokes native-only artifact verification" '--native-only --staged-dir android/app/src/main/jniLibs' "$workflow"
    require_literal "$(basename "$workflow") uses the pinned NDK strip normalizer" 'llvm-strip' "$workflow"
    require_literal "$(basename "$workflow") pins stremiox-core immutably" 'repository: VortXTV/stremiox-core' "$workflow"
    require_regex "$(basename "$workflow") stremiox-core ref is a full SHA" 'ref: [0-9a-f]{40}' "$workflow"
    require_literal "$(basename "$workflow") pins vortx-core immutably" 'repository: VortXTV/vortx-core' "$workflow"
    require_literal "$(basename "$workflow") enforces the reviewed vortx-core SHA" 'feaa0e074133137625e5e143c80715d5cb2a5ffe' "$workflow"
    require_literal "$(basename "$workflow") records the exact fetched Vortx source SHA" 'VORTX_ENGINE_SOURCE_SHA=$vortx_sha' "$workflow"
    require_literal "$(basename "$workflow") verifies artifacts against the source SHA" '--source-sha "$VORTX_ENGINE_SOURCE_SHA"' "$workflow"
    # rust-cache's explicit key survives its lockfile-prefix fallback. Bind that key to the
    # private source, not only the branch, so updating engine code cannot restore older targets.
    cache_key="$(awk '/^[[:space:]]*key:.*github.ref_name/{print; exit}' "$workflow")"
    [[ "$cache_key" == *"hashFiles("* ]] || fail "$(basename "$workflow") private cache is not content-addressed"
    for input in 'core/src/**' 'core/Cargo.*' 'vortx-core/crates/**' 'vortx-core/Cargo.*' \
                 'vortx-core/rust-toolchain.toml' 'vortx-core/.cargo/**' 'android/app/build.gradle.kts'; do
        [[ "$cache_key" == *"'$input'"* ]] || fail "$(basename "$workflow") cache key omits $input"
    done
    ok "$(basename "$workflow") private-source content is retained in the restore prefix"
done
ok "debug/release Android workflow invocations select native mode and resource-host together"

# Artifact checks are content-level, not path-level: every produced APK/AAB must prove the generated
# BuildConfig and inspect each shipped ABI's JNI/resource-host surface with the pinned tools.
for workflow in "$ANDROID_CI_WF" "$ANDROID_RELEASE_WF"; do
    require_literal "$(basename "$workflow") uses the pinned dexdump for BuildConfig proof" 'DEXDUMP="$ANDROID_HOME/build-tools/36.0.0/dexdump"' "$workflow"
    require_literal "$(basename "$workflow") delegates BuildConfig proof to the reusable archive helper" 'scripts/verify-android-native-build-config.sh' "$workflow"
    require_literal "$(basename "$workflow") names the native BuildConfig field in its artifact gate" 'NATIVE_ENGINE_ENABLED' "$REPO_ROOT/scripts/verify-android-native-build-config.sh"
    require_literal "$(basename "$workflow") rejects an artifact without native BuildConfig=true" 'does not prove BuildConfig.NATIVE_ENGINE_ENABLED=true' "$REPO_ROOT/scripts/verify-android-native-build-config.sh"
    require_literal "$(basename "$workflow") checks the AAB base dex path" 'dex_prefix="base/dex/"' "$REPO_ROOT/scripts/verify-android-native-build-config.sh"
    require_literal "$(basename "$workflow") delegates all-ABI checks to the shared verifier" 'scripts/verify-native-android-artifacts.sh' "$workflow"
    require_literal "$(basename "$workflow") checks the resource-host JNI ABI" 'verify-native-engine-abi.sh' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
done
candidate_artifact_gate="$(awk '/name: Verify signed release artifacts against the pinned production signer/{active=1; next}
    active && /^[[:space:]]+- name:/{exit} active{print}' "$ANDROID_CI_WF")"
require_regex "candidate signed APK/AAB verification uses native-only package comparison" \
    'verify-native-android-artifacts\.sh.*--native-only|--native-only --staged-dir android/app/src/main/jniLibs' \
    <(printf '%s\n' "$candidate_artifact_gate")
require_literal "artifact verifier retains its default legacy-both mode" 'mode=legacy-both' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "native-only verifier rejects the legacy Stremio library" 'native-only artifact still contains legacy libstremiox_core.so' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "native-only verifier compares staged and packaged bytes after strip normalization" '"$strip" --strip-debug --strip-unneeded "$normalized_package"' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "native-only verifier records normalized packaged hashes with exact source and features" 'native-engine source=%s features=jni,server,resource-host' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "resource-host ABI helper requires the native host surface" 'nativeResourceHostAbiVersion' "$REPO_ROOT/scripts/verify-native-engine-abi.sh"
require_literal "release provenance records normalized package hashes" 'normalized-sha256=%s' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
ok "APK/AAB gates prove native-only BuildConfig, exact staged engine bytes, and resource-host ABI"

require_literal "BuildConfig helper tracks static field numbers" 'target_field=current_field' "$REPO_ROOT/scripts/verify-android-native-build-config.sh"
require_literal "BuildConfig helper tracks static value numbers" 'current_value == target_field' "$REPO_ROOT/scripts/verify-android-native-build-config.sh"
require_literal "BuildConfig helper uses a whitespace-safe exact class boundary" '^[[:space:]]*Class descriptor' "$REPO_ROOT/scripts/verify-android-native-build-config.sh"
require_literal "BuildConfig parser negative fixtures are executable" 'native_whitespace_class_boundary.dump' "$REPO_ROOT/scripts/test-android-native-build-config.sh"

# Native mode must not be able to fall back through the old repository or sync seams. Legacy JNI and
# repository code remain available to the explicit non-native comparison build, but native artifacts
# package only the resource-host engine.
require_literal "application selects NativeCatalogRepository in native mode" 'if (BuildConfig.NATIVE_ENGINE_ENABLED) nativeRepository' "$APP_SOURCE"
require_literal "application does not attach legacy sync seams in native mode" 'if (!BuildConfig.NATIVE_ENGINE_ENABLED) manager.attachSyncSeams(store)' "$APP_SOURCE"
require_literal "legacy repository rejects native construction" 'check(!com.vortx.android.BuildConfig.NATIVE_ENGINE_ENABLED)' "$LEGACY_REPOSITORY"
require_literal "native resource bridge requires the resource-host ABI" 'nativeResourceHostAbiVersion()' "$RESOURCE_BRIDGE"
require_literal "native resource bridge rejects an unavailable host" 'nativeResourceHostNew()' "$RESOURCE_BRIDGE"
ok "native mode selects the resource-host repository without packaging the legacy engine"

# The parent-approved source revision remains an exact contract, not a mutable branch or
# a declaration that its separate private CI, SDK and whole-app gates have passed.
for workflow in "$ANDROID_CI_WF" "$ANDROID_RELEASE_WF"; do
    stremio_pin="$(awk '/repository: VortXTV\/stremiox-core/{seen=1; next} seen && /ref:/{print $2; exit}' "$workflow")"
    vortx_pin="$(awk '/repository: VortXTV\/vortx-core/{seen=1; next} seen && /ref:/{print $2; exit}' "$workflow")"
    [[ "$stremio_pin" = "31c66611822043e089f5819ad232a5df93975873" ]] \
      || fail "$(basename "$workflow") changed the retained stremiox-core comparison pin"
    [[ "$vortx_pin" = "feaa0e074133137625e5e143c80715d5cb2a5ffe" ]] \
      || fail "$(basename "$workflow") changed the reviewed vortx-core pin"
    printf 'pin: %s stremiox-core=%s vortx-core=%s (parent approval owns replacement)\n' "$(basename "$workflow")" "$stremio_pin" "$vortx_pin"
done

"$SCRIPT_DIR/test-android-native-build-config.sh"
printf 'PASS: Android native 0.5 release selection/package contract\n'
