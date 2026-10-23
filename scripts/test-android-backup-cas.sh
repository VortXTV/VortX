#!/usr/bin/env bash
set -euo pipefail
# Actual current host sources, local AES-GCM transport, synthetic gateway and legacy profile store.
# No Gradle/app build, private JNI/engine build, device, live account/provider, or network.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${VORTX_GRADLE_MODULE_CACHE:-/Users/daksh/.gradle/caches/modules-2/files-2.1}"
transforms_root="${VORTX_GRADLE_TRANSFORMS:-/Users/daksh/.gradle/caches/8.11.1/transforms}"
java_bin="${VORTX_TEST_JAVA:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java}"
app_classes="${VORTX_COMPILED_APP:?Exact retained Android app classes.jar required}"
android_jar="${VORTX_ANDROID_JAR:-/Users/daksh/.gradle/caches/8.11.1/transforms/c1f9c6b9136522e4129f5b6956c421bd/transformed/android.jar}"
test -f "$app_classes"
test -f "$android_jar"
jar() { rg --files "$cache_root/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
annotations="$(jar org.jetbrains annotations 13.0)"
coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
compiler_cp="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10):$stdlib:$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10):$annotations:$coroutines"
dependency_cp="$(rg --files --no-ignore "$cache_root" "$transforms_root" | rg '\.jar$' | paste -sd ':' -)"
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/backup-cas-kotlin.XXXXXX")"
cp "$app_classes" "$test_dir/retained-app.jar"
zip -qd "$test_dir/retained-app.jar" 'com/vortx/android/BuildConfig*' 'com/vortx/android/sync/VortXSyncManager*' \
    'com/vortx/android/sync/SyncSessionLease*' 'com/vortx/android/sync/SessionOperationCoordinator*' \
    'com/vortx/android/sync/DurableSessionState*' 'com/vortx/android/sync/DurablePendingSyncState*' \
    'com/vortx/android/sync/PendingSync*' 'com/vortx/android/sync/PendingMarkerTruth*' 'com/vortx/android/sync/SessionMutationResult*' \
    'com/vortx/android/sync/VortXSyncDoc*' 'com/vortx/android/sync/BackupRevisionPolicy*' \
    'com/vortx/android/sync/NativeAccountGateway*' 'com/vortx/android/sync/NativeAccountExport*' \
    'com/vortx/android/sync/NativeAccountMountToken*' 'com/vortx/android/sync/NativeSyncPublicationPolicy*' \
    'com/vortx/android/sync/VortXSyncRealtime*' 'com/vortx/android/engine/NativeAccountCoordinator*' \
    'com/vortx/android/engine/NativeWebsiteProfileEdits*' \
    'com/vortx/android/engine/NativeHostPreferences*' \
    'com/vortx/android/profile/ProfileStore*' 'com/vortx/android/backup/SettingsBackup*' \
    'com/vortx/android/integrations/NativeProviderCredentials*' 'com/vortx/android/integrations/NativeProviderAccess*' \
    'com/vortx/android/integrations/NativeProviderVault*' 'com/vortx/android/integrations/NativeProviderAdmission*' \
    'com/vortx/android/ui/viewmodel/VortXAccountViewModel*' 'com/vortx/android/VortXApplication*' || test "$?" -eq 12
test_cp="$test_dir/retained-app.jar:$stdlib:$annotations:$coroutines:$(jar org.json json 20240303):$android_jar:$dependency_cp"
source_dir="$repo_root/android/app/src/main/kotlin/com/vortx/android"
test_source="$repo_root/android/app/src/test/kotlin/com/vortx/android"
"$java_bin" -Xmx1400m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$test_dir/retained-app.jar" -classpath "$test_cp" \
    "$repo_root/test/fixtures/android-backup-cas/BuildConfig.kt" \
    "$source_dir/sync/VortXSyncManager.kt" "$source_dir/sync/VortXSyncRealtime.kt" \
    "$source_dir/sync/VortXSyncDoc.kt" "$source_dir/sync/BackupRevisionPolicy.kt" \
    "$source_dir/sync/NativeAccountGateway.kt" "$source_dir/sync/NativeSyncPublicationPolicy.kt" \
    "$source_dir/profile/ProfileStore.kt" "$source_dir/profile/ProfileRestorePolicy.kt" "$source_dir/backup/SettingsBackup.kt" \
    "$source_dir/integrations/NativeProviderCredentials.kt" "$source_dir/integrations/NativeProviderAccess.kt" \
    "$source_dir/engine/NativeAccountCoordinator.kt" "$source_dir/engine/NativeLegacyMaterial.kt" \
    "$source_dir/engine/NativeWebsiteProfileEdits.kt" \
    "$source_dir/engine/NativeHostPreferences.kt" \
    "$source_dir/ui/viewmodel/VortXAccountViewModel.kt" "$source_dir/VortXApplication.kt" \
    "$test_source/sync/VortXSyncManagerBackupRevisionTest.kt" "$test_source/sync/VortXSyncManagerLegacyBackupRevisionTest.kt" \
    "$test_source/sync/VortXBackupCasContractTest.kt" "$test_source/sync/BackupRevisionPolicyTest.kt" \
    "$test_source/sync/NativeAccountSyncTest.kt" "$test_source/sync/AndroidRealtimeSyncTest.kt" \
    "$test_source/integrations/NativeProviderCredentialsTest.kt" \
    "$test_source/engine/NativeWebsiteProfileEditsTest.kt" \
    "$test_source/engine/NativeHostPreferencesTest.kt" \
    -d "$test_dir/classes" 2>&1 | tee "$test_dir/compile.log"
cd "$repo_root/android/app"
"$java_bin" -Xmx512m -Dvortx.test.native=true -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.sync.VortXBackupCasContractTest com.vortx.android.sync.BackupRevisionPolicyTest \
    com.vortx.android.sync.NativeAccountSyncTest com.vortx.android.sync.AndroidRealtimeSyncTest \
    com.vortx.android.integrations.NativeProviderCredentialsTest \
    com.vortx.android.engine.NativeWebsiteProfileEditsTest com.vortx.android.engine.NativeHostPreferencesTest 2>&1 | tee "$test_dir/native-host.log"
"$java_bin" -Xmx512m -Dvortx.test.native=false -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.sync.VortXSyncManagerLegacyBackupRevisionTest 2>&1 | tee "$test_dir/legacy-host.log"
printf 'Retained verification directory: %s\n' "$test_dir"
