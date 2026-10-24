#!/usr/bin/env bash
set -euo pipefail

# Focused source contract for the Android VortX-engine-only build. This test intentionally does not
# configure Gradle, fetch private repositories, build Rust, or inspect a local APK. The release
# workflows perform the content-level JNI/resource-host checks after producing each artifact; this
# script binds those gates to the source and the Kotlin call graph.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly GRADLE_BUILD="$REPO_ROOT/android/app/build.gradle.kts"
readonly ANDROID_CI_WF="$REPO_ROOT/.github/workflows/android.yml"
readonly ANDROID_RELEASE_WF="$REPO_ROOT/.github/workflows/android-release.yml"
readonly REVIEWED_NATIVE_SHA='2ea2e0f27dd2e53b7b28228435ca35a70f92831f'
readonly APP_SOURCE="$REPO_ROOT/android/app/src/main/kotlin/com/vortx/android/VortXApplication.kt"
readonly KOTLIN_ROOT="$REPO_ROOT/android/app/src/main/kotlin"
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

require_absent() {
    local description="$1" pattern="$2"
    shift 2
    if grep -rEq -- "$pattern" "$@"; then
        grep -rEn -- "$pattern" "$@" >&2 || true
        fail "$description"
    fi
    ok "$description"
}

[[ -f "$GRADLE_BUILD" && -f "$ANDROID_CI_WF" && -f "$ANDROID_RELEASE_WF" ]] \
    || fail "Android release contract inputs are missing"

# The VortX engine is the only engine. The retired selection switches still parse so an explicit
# request for the removed legacy build fails during configuration instead of being ignored.
require_literal "Gradle keeps one boolean resolver for the retired switches" 'fun nativeBooleanFlag(propertyName: String, environmentName: String, defaultValue: Boolean)' "$GRADLE_BUILD"
require_literal "an explicit Gradle property precedes the environment" 'val raw = property?.trim() ?: System.getenv(environmentName)?.trim()' "$GRADLE_BUILD"
require_literal "the retired engine switch is rejected when false" '"vortx.nativeEngine" to "VORTX_NATIVE_ENGINE"' "$GRADLE_BUILD"
require_literal "the retired resource-host switch is rejected when false" '"vortx.nativeResourceHost" to "VORTX_NATIVE_RESOURCE_HOST"' "$GRADLE_BUILD"
require_literal "a false switch names the removed build" 'selected the removed legacy engine build' "$GRADLE_BUILD"
require_literal "the engine always carries the resource host" 'add("jni,server,resource-host")' "$GRADLE_BUILD"
require_absent "Gradle no longer selects an engine through BuildConfig" 'NATIVE_ENGINE_ENABLED' "$GRADLE_BUILD"
require_absent "Gradle no longer builds or packages the Stremio engine" 'cargoNdkBuild"\)|libstremiox_core|STREMIOX_CORE_DIR|stremiox\.core\.dir' "$GRADLE_BUILD"
require_absent "no Kotlin source reads a removed engine selection" 'NATIVE_ENGINE_ENABLED|StremioCoreNative|EngineStremioRepository\(' "$KOTLIN_ROOT"

for workflow in "$ANDROID_CI_WF" "$ANDROID_RELEASE_WF"; do
    build_runs="$(grep -E '^[[:space:]]*run: \./gradlew .*assemble|^[[:space:]]*run: \./gradlew .*bundle' "$workflow" || true)"
    [[ -n "$build_runs" ]] || fail "$(basename "$workflow") has no Gradle engine build invocation"
    require_absent "$(basename "$workflow") never selects a removed engine mode" 'vortx\.native(Engine|ResourceHost)=false' "$workflow"
    require_absent "$(basename "$workflow") never fetches or builds the Stremio engine" 'stremiox-core|STREMIOX_CORE|path: core$' "$workflow"
    require_literal "$(basename "$workflow") requires a freshly built engine" 'VORTX_REQUIRE_ENGINE: "1"' "$workflow"
    require_literal "$(basename "$workflow") invokes native-only artifact verification" '--native-only --staged-dir android/app/src/main/jniLibs' "$workflow"
    require_literal "$(basename "$workflow") uses the pinned NDK strip normalizer" 'llvm-strip' "$workflow"
    require_literal "$(basename "$workflow") pins vortx-core immutably" 'repository: VortXTV/vortx-core' "$workflow"
    require_literal "$(basename "$workflow") enforces the reviewed vortx-core SHA" \
        "test \"\$vortx_sha\" = \"$REVIEWED_NATIVE_SHA\"" "$workflow"
    require_literal "$(basename "$workflow") records the exact fetched Vortx source SHA" 'VORTX_ENGINE_SOURCE_SHA=$vortx_sha' "$workflow"
    require_literal "$(basename "$workflow") admits host JNI only for the reviewed native source" \
        "test \"\$VORTX_ENGINE_SOURCE_SHA\" = $REVIEWED_NATIVE_SHA" "$workflow"
    require_literal "$(basename "$workflow") verifies artifacts against the source SHA" '--source-sha "$VORTX_ENGINE_SOURCE_SHA"' "$workflow"
    # rust-cache's explicit key survives its lockfile-prefix fallback. Bind that key to the
    # private source, not only the branch, so updating engine code cannot restore older targets.
    cache_key="$(awk '/^[[:space:]]*key:.*github.ref_name/{print; exit}' "$workflow")"
    [[ "$cache_key" == *'${{ env.VORTX_ENGINE_SOURCE_SHA }}'* ]] \
      || fail "$(basename "$workflow") private cache omits the verified source revision"
    [[ "$cache_key" == *"hashFiles("* ]] || fail "$(basename "$workflow") private cache is not content-addressed"
    for input in 'vortx-core/crates/**' 'vortx-core/Cargo.*' 'vortx-core/rust-toolchain.toml' \
                 'vortx-core/.cargo/**' 'android/app/build.gradle.kts'; do
        [[ "$cache_key" == *"'$input'"* ]] || fail "$(basename "$workflow") cache key omits $input"
    done
    ok "$(basename "$workflow") private-source content is retained in the restore prefix"
    require_literal "$(basename "$workflow") delegates all-ABI checks to the shared verifier" 'scripts/verify-native-android-artifacts.sh' "$workflow"
done

for hosted_init in owner-history-hosted.init.gradle native-sync-hosted.init.gradle; do
    require_literal "$hosted_init binds real JNI receipts to the reviewed native source" \
        "receipt.engineSource != \"$REVIEWED_NATIVE_SHA\"" "$REPO_ROOT/android/$hosted_init"
done

candidate_artifact_gate="$(awk '/name: Verify signed release artifacts against the pinned production signer/{active=1; next}
    active && /^[[:space:]]+- name:/{exit} active{print}' "$ANDROID_CI_WF")"
require_regex "candidate signed APK/AAB verification uses native-only package comparison" \
    'verify-native-android-artifacts\.sh.*--native-only|--native-only --staged-dir android/app/src/main/jniLibs' \
    <(printf '%s\n' "$candidate_artifact_gate")
require_absent "artifact verifier has no legacy two-engine mode" 'legacy-both|verify_legacy_pair' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "artifact verifier rejects the legacy Stremio library" 'native-only artifact still contains legacy libstremiox_core.so' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "artifact verifier checks the resource-host JNI ABI" 'verify-native-engine-abi.sh' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "artifact verifier compares staged and packaged bytes after strip normalization" '"$strip" --strip-debug --strip-unneeded "$normalized_package"' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "artifact verifier records normalized packaged hashes with exact source and features" 'native-engine source=%s features=jni,server,resource-host' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "resource-host ABI helper requires the native host surface" 'nativeResourceHostAbiVersion' "$REPO_ROOT/scripts/verify-native-engine-abi.sh"
require_literal "normal Android source selects owner-history ABI" "$REVIEWED_NATIVE_SHA) abi_mode=owner-history ;;" "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "previous D2 source retains its explicit ABI admission" 'd2ca37b89556c732da6edc1e5ca1f5908cf5d508) abi_mode=owner-history ;;' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "historical owner-history source retains its explicit ABI admission" '0c30f4782aee544a2b7e33169ad60d03630d4097) abi_mode=owner-history ;;' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "historical beta2 keeps resource-host ABI" 'af29b22e4c45740a1f5b6cb415b81f8430f55b9f) abi_mode=resource-host ;;' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "unadmitted Android source fails closed" 'native-only ABI mode has no admitted source revision' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_literal "all shipped ABI checks invoke the source-selected mode" 'android "$file" "$abi_mode"' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
for method in nativeOwnerHistoryCanonicalize nativeOwnerHistoryOpen nativeOwnerHistoryFork nativeOwnerHistoryRequest nativeOwnerHistoryClose; do
    require_literal "owner-history JNI requires $method" "$method" "$REPO_ROOT/scripts/verify-native-engine-abi.sh"
done
require_literal "owner-history JNI extends resource requirements" '[[ "$mode" == state ]] || expected+=(nativeResourceHostAbiVersion' "$REPO_ROOT/scripts/verify-native-engine-abi.sh"
require_literal "owner-history JNI is an explicit additional requirement" '[[ "$mode" != owner-history ]] || expected+=(nativeOwnerHistoryCanonicalize' "$REPO_ROOT/scripts/verify-native-engine-abi.sh"
require_literal "release provenance records normalized package hashes" 'normalized-sha256=%s' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
ok "APK/AAB gates prove the VortX engine only, exact staged engine bytes, and resource-host ABI"

# The application has one repository: the VortX engine's resource-host repository.
require_literal "application serves catalogs from the VortX engine repository" 'val catalogRepository: CatalogRepository get() = nativeRepository' "$APP_SOURCE"
require_literal "application serves auth from the VortX engine session" 'val authRepository: AuthRepository get() = nativeStreamingAuth' "$APP_SOURCE"
require_literal "native resource bridge requires the resource-host ABI" 'nativeResourceHostAbiVersion()' "$RESOURCE_BRIDGE"
require_literal "native resource bridge rejects an unavailable host" 'nativeResourceHostNew()' "$RESOURCE_BRIDGE"
ok "the application selects the resource-host repository and packages no other engine"

# The parent-approved source revision remains an exact contract, not a mutable branch or
# a declaration that its separate private CI, SDK and whole-app gates have passed.
for workflow in "$ANDROID_CI_WF" "$ANDROID_RELEASE_WF"; do
    vortx_pin="$(awk '/repository: VortXTV\/vortx-core/{seen=1; next} seen && /ref:/{print $2; exit}' "$workflow")"
    [[ "$vortx_pin" = "$REVIEWED_NATIVE_SHA" ]] \
      || fail "$(basename "$workflow") changed the reviewed vortx-core pin"
    printf 'pin: %s vortx-core=%s (parent approval owns replacement)\n' "$(basename "$workflow")" "$vortx_pin"
done

readonly NATIVE_SYNC_HOST_SCRIPT="$REPO_ROOT/scripts/test-android-native-sync-host.sh"
for workflow in "$ANDROID_CI_WF" "$ANDROID_RELEASE_WF"; do
    require_literal "$(basename "$workflow") invokes the exact shared native sync gate" 'bash ../scripts/test-android-native-sync-host.sh' "$workflow"
    require_literal "$(basename "$workflow") admits all native sync JNI cases" 'VORTX_JNI_SYNC: "1"' "$workflow"
    require_literal "$(basename "$workflow") retains separate native sync results" 'name: VortX-Android-native-sync-host-tests' "$workflow"
done
require_literal "pretag sync binds the existing host receipt to exact app source" 'SOURCE_COMMIT: ${{ github.sha }}' "$ANDROID_CI_WF"
require_literal "the original owner-history and Media3 gate remains active" '--init-script owner-history-hosted.init.gradle' "$ANDROID_CI_WF"
require_literal "shared sync gate uses actual native runtime validation" '--init-script native-sync-hosted.init.gradle' "$NATIVE_SYNC_HOST_SCRIPT"
require_literal "shared sync gate requires all backup revision JNI tests" '--tests com.vortx.android.sync.VortXSyncManagerBackupRevisionTest' "$NATIVE_SYNC_HOST_SCRIPT"
require_literal "shared sync gate requires all native account tests" '--tests com.vortx.android.sync.NativeAccountSyncTest' "$NATIVE_SYNC_HOST_SCRIPT"
require_literal "shared sync gate requires fresh XML" 'test ! -e app/build/test-results/testPlayDebugUnitTest' "$NATIVE_SYNC_HOST_SCRIPT"
require_literal "shared sync gate rejects native/source changes" 'cmp --silent "$VORTX_JNI_SOURCE_MANIFEST" "$VORTX_JNI_SOURCE_MANIFEST.current"' "$NATIVE_SYNC_HOST_SCRIPT"
require_literal "shared sync gate retains post-runtime library proof" 'postRuntimeLibrarySha256:$after' "$NATIVE_SYNC_HOST_SCRIPT"
require_literal "shared sync gate retains post-runtime private input digest" 'postRuntimeSourceInputsSha256:$inputs' "$NATIVE_SYNC_HOST_SCRIPT"
require_literal "shared sync gate records 22 executed and 17 real JNI cases" 'executed:22,realJniCases:17,skipped:0,failures:0,errors:0' "$NATIVE_SYNC_HOST_SCRIPT"
require_literal "shared sync gate never accepts native sync skips" 'Require real native BackupRevision14 plus NativeAccountSync8, zero skips/failures' "$REPO_ROOT/android/native-sync-hosted.init.gradle"

printf 'PASS: Android VortX engine release selection/package contract\n'
