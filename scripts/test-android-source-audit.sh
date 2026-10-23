#!/usr/bin/env bash
set -euo pipefail
# Focused actual-source JVM checks. No Gradle, APK, native engine, account, or device run.
# The installed Gradle distribution's Kotlin 2.0.20 compiler was used for the audit receipt;
# the Android target pins 2.2.10, so this is not full-module/Compose integration evidence.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kotlin_lib="${VORTX_KOTLIN_LIB:?Directory containing kotlin-compiler-embeddable and its runtime jars}"
deps="${VORTX_ANDROID_AUDIT_DEPS:?Directory containing the public audit dependency jars}"
java_bin="${VORTX_TEST_JAVA:-java}"
android_jar="${VORTX_ANDROID_JAR:?Existing Android SDK platform android.jar required}"
for jar_name in okhttp-4.12.0.jar okio-jvm-3.6.0.jar json-20240303.jar junit-4.13.2.jar hamcrest-core-1.3.jar; do
    test -f "$deps/$jar_name"
done
test -f "$android_jar"
stdlib="$(rg --files --hidden --no-ignore "$kotlin_lib" | rg '/kotlin-stdlib-[0-9][^/]*\.jar$' | head -1)"
coroutines="$(rg --files --hidden --no-ignore "$kotlin_lib" | rg '/kotlinx-coroutines-core-jvm-[^/]*\.jar$' | head -1)"
test -f "$stdlib"; test -f "$coroutines"
dependency_cp="$deps/okhttp-4.12.0.jar:$deps/okio-jvm-3.6.0.jar:$deps/json-20240303.jar:$deps/junit-4.13.2.jar:$deps/hamcrest-core-1.3.jar"
test_cp="$stdlib:$coroutines:$dependency_cp:$android_jar"
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/source-audit.XXXXXX")"
main="$repo_root/android/app/src/main/kotlin/com/vortx/android"
tests="$repo_root/android/app/src/test/kotlin/com/vortx/android"
"$java_bin" -cp "$kotlin_lib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -version
"$java_bin" -Xmx1g -cp "$kotlin_lib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -classpath "$test_cp" \
    "$main/engine/AddonManifestFetcher.kt" "$main/engine/NativeProfileOverlayWitness.kt" \
    "$main/imports/ImportTextFetcher.kt" "$main/imports/ImportHttp.kt" \
    "$repo_root/scripts/fixtures/android-import-http-ua.kt" \
    "$main/sync/BackupRevisionPolicy.kt" "$main/sync/ProgressUploadWindow.kt" \
    "$main/sources/SourceRequestFence.kt" "$main/debrid/ProviderCircuitBreaker.kt" \
    "$main/downloads/DownloadDirectoryPolicy.kt" "$main/player/DeviceMemoryTier.kt" \
    "$main/player/AudioFocusPolicy.kt" "$main/player/NextEpisodePreloadPolicy.kt" \
    "$tests/engine/AddonManifestFetcherTest.kt" "$tests/engine/NativeProfileOverlayWitnessTest.kt" \
    "$tests/imports/ImportTextFetcherTest.kt" "$tests/sync/BackupRevisionPolicyTest.kt" \
    "$tests/sync/ProgressUploadWindowTest.kt" "$tests/sources/SourceRequestFenceTest.kt" \
    "$tests/debrid/ProviderCircuitBreakerTest.kt" "$tests/downloads/DownloadDirectoryPolicyTest.kt" \
    "$tests/player/DeviceMemoryTierTest.kt" "$tests/player/AudioFocusPolicyTest.kt" \
    "$tests/player/NextEpisodePreloadPolicyTest.kt" -d "$test_dir/classes"
"$java_bin" -Xmx512m -cp "$test_dir/classes:$repo_root/android/app/src/test/resources:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.engine.AddonManifestFetcherTest \
    com.vortx.android.engine.NativeProfileOverlayWitnessTest \
    com.vortx.android.imports.ImportTextFetcherTest \
    com.vortx.android.sync.BackupRevisionPolicyTest \
    com.vortx.android.sync.ProgressUploadWindowTest \
    com.vortx.android.sources.SourceRequestFenceTest \
    com.vortx.android.debrid.ProviderCircuitBreakerTest \
    com.vortx.android.downloads.DownloadDirectoryPolicyTest \
    com.vortx.android.player.DeviceMemoryTierTest \
    com.vortx.android.player.AudioFocusPolicyTest \
    com.vortx.android.player.NextEpisodePreloadPolicyTest
printf 'Retained standalone test classes: %s\n' "$test_dir"
