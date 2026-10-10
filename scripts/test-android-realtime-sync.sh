#!/usr/bin/env bash
set -euo pipefail
# Actual Android sync/coordinator sources; deterministic local crypto, transport, socket and clock.
# No native private library, live account/provider, Gradle/app build or device playback.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${VORTX_GRADLE_MODULE_CACHE:-/Users/daksh/.gradle/caches/modules-2/files-2.1}"
transforms_root="${VORTX_GRADLE_TRANSFORMS:-/Users/daksh/.gradle/caches/8.11.1/transforms}"
java_bin="${VORTX_TEST_JAVA:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java}"
app_classes="${VORTX_COMPILED_APP:?Exact retained actual Android app classes.jar required}"
android_jar="${VORTX_ANDROID_JAR:-/Users/daksh/Library/Android/sdk/platforms/android-36/android.jar}"
test -f "$app_classes"
test -f "$android_jar"
jar() { rg --files "$cache_root/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
annotations="$(jar org.jetbrains annotations 13.0)"
coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
compiler_cp="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10):$stdlib:$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10):$annotations:$coroutines"
dependency_cp="$(rg --files "$cache_root" "$transforms_root" | rg '\.jar$' | paste -sd ':' -)"
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/realtime-sync-kotlin.XXXXXX")"
cp "$app_classes" "$test_dir/retained-app.jar"
# Avoid resolving retained default-argument overloads instead of the actual changed source.
zip -qd "$test_dir/retained-app.jar" 'com/vortx/android/sync/VortXSyncManager*' 'com/vortx/android/sync/VortXSyncRealtime*' \
    'com/vortx/android/sync/DurableSessionState*' 'com/vortx/android/sync/DurablePendingSyncState*' \
    'com/vortx/android/sync/PendingSync*' 'com/vortx/android/sync/PendingMarkerTruth*' \
    'com/vortx/android/sync/SessionOperationCoordinator*' 'com/vortx/android/sync/SessionMutationResult*' \
    'com/vortx/android/sync/SyncSessionLease*' 'com/vortx/android/sync/NativeAccountGateway*' 'com/vortx/android/sync/NativeAccountExport*' \
    'com/vortx/android/engine/NativeAccountCoordinator*' 'com/vortx/android/VortXApplication*'
test_cp="$test_dir/retained-app.jar:$stdlib:$annotations:$coroutines:$dependency_cp:$android_jar"
source_dir="$repo_root/android/app/src/main/kotlin/com/vortx/android"
test_source="$repo_root/android/app/src/test/kotlin/com/vortx/android"
"$java_bin" -Xmx1800m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$test_dir/retained-app.jar" -classpath "$test_cp" \
    "$source_dir/sync/VortXSyncManager.kt" "$source_dir/sync/VortXSyncRealtime.kt" "$source_dir/sync/NativeAccountGateway.kt" \
    "$source_dir/sync/NativeSyncPublicationPolicy.kt" "$source_dir/engine/NativeAccountCoordinator.kt" "$source_dir/VortXApplication.kt" \
    "$source_dir/engine/NativeLegacyMaterial.kt" \
    "$test_source/sync/AndroidRealtimeSyncTest.kt" "$test_source/sync/DurableSessionStateTest.kt" \
    "$test_source/sync/NativeAccountSyncTest.kt" "$test_source/sync/VortXSessionOwnerTransitionContractTest.kt" \
    "$test_source/integrations/NativeProviderCredentialsTest.kt" \
    -d "$test_dir/classes"
cd "$repo_root/android/app"
"$java_bin" -Xmx768m -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.sync.AndroidRealtimeSyncTest \
    com.vortx.android.sync.DurableSessionStateTest \
    com.vortx.android.sync.NativeAccountSyncTest \
    com.vortx.android.sync.VortXSessionOwnerTransitionContractTest
printf 'Retained verification directory: %s\n' "$test_dir"
