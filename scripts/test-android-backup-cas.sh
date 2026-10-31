#!/usr/bin/env bash
set -euo pipefail
# Actual current host sources, local AES-GCM transport, synthetic and opt-in real JNI gateways.
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
    'com/vortx/android/sync/NativeAccountReadCapture*' 'com/vortx/android/sync/NativeSettingsFence*' \
    'com/vortx/android/sync/NativeHostUploadAcknowledgment*' \
    'com/vortx/android/sync/NativeAccountUploadCurrency*' \
    'com/vortx/android/engine/NativeCatalogRepository*' 'com/vortx/android/engine/XperienceInstalledCatalogSnapshot*' \
    'com/vortx/android/engine/XperienceCatalogRequestOutcome*' 'com/vortx/android/engine/XperienceCatalogConsumerID*' \
    'com/vortx/android/engine/NativeXperienceCatalog*' 'com/vortx/android/xperience/XperienceImportStore*' \
    'com/vortx/android/ui/viewmodel/XperienceCollectionsViewModel*' 'com/vortx/android/ui/viewmodel/StremioXViewModelFactory*' \
    'com/vortx/android/sync/NativePlaylistAccountProducer*' 'com/vortx/android/sync/NativePlaylistAccountWrite*' \
    'com/vortx/android/sync/NativeAccountMountToken*' 'com/vortx/android/sync/NativePlaylistProfileGateway*' \
    'com/vortx/android/sync/NativeXperienceProfileGateway*' 'com/vortx/android/engine/NativeXperienceWrite*' \
    'com/vortx/android/xperience/XperienceCollections*' 'com/vortx/android/xperience/XperienceImportNamespace*' \
    'com/vortx/android/xperience/XperienceAddonBinding*' \
    'com/vortx/android/sync/NativeSyncPublicationPolicy*' \
    'com/vortx/android/sync/VortXSyncRealtime*' 'com/vortx/android/engine/NativeAccountCoordinator*' \
    'com/vortx/android/engine/VortxAccountScope*' 'com/vortx/android/engine/NativeCheckpointRead*' \
    'com/vortx/android/engine/VortxCheckpointStore*' 'com/vortx/android/engine/VortxEncryptedCheckpointStore*' \
    'com/vortx/android/engine/VortxAndroidCheckpointKey*' 'com/vortx/android/engine/VortxNativeOwner*' \
    'com/vortx/android/engine/VortxNativeRead*' 'com/vortx/android/engine/VortxNativeSession*' \
    'com/vortx/android/engine/NativeWebsiteProfileEdits*' \
    'com/vortx/android/engine/NativePlaylistAccountComposer*' 'com/vortx/android/engine/NativeOwnerHistoryAccount*' \
    'com/vortx/android/engine/NativeRawHostPreferences*' 'com/vortx/android/engine/NativePreparedAccountAdmission*' \
    'com/vortx/android/engine/NativeOwnerHistoryCoordinator*' 'com/vortx/android/engine/NativeOwnerHistorySessionAdapter*' \
    'com/vortx/android/engine/VortxNativeRuntime*' 'com/vortx/android/engine/VortxRuntimeBindings*' \
    'com/vortx/android/engine/VortxRuntimeDelegate*' 'com/vortx/android/engine/VortxPreparedAccountDelegate*' \
    'com/vortx/android/foryou/ForYouPerson*' 'com/vortx/android/foryou/ForYouInterests*' \
    'com/vortx/android/foryou/SmartCollectionRules*' 'com/vortx/android/foryou/SmartCollection*' \
    'com/vortx/android/foryou/ForYouSync*' 'com/vortx/android/foryou/ForYouGenre*' \
    'com/vortx/android/foryou/ForYouExtra*' 'com/vortx/android/foryou/ForYouEra*' 'com/vortx/android/foryou/ForYouModelKt*' \
    'com/vortx/android/foryou/ForYouNativeGateway*' 'com/vortx/android/foryou/ForYouObservedField*' \
    'com/vortx/android/foryou/ForYouIdentityRef*' 'com/vortx/android/foryou/ForYouOrigin*' \
    'com/vortx/android/foryou/ForYouEditSession*' 'com/vortx/android/foryou/PreparedForYouWrite*' \
    'com/vortx/android/foryou/ForYouState*' 'com/vortx/android/foryou/ForYouStore*' \
    'com/vortx/android/foryou/ForYouStoreKt*' 'com/vortx/android/foryou/ForYouEditFields*' \
    'com/vortx/android/engine/OHJson*' 'com/vortx/android/engine/OHState*' \
    'com/vortx/android/engine/NativeOwnAccountSource*' 'com/vortx/android/engine/NativeOwnAccountProducer*' \
    'com/vortx/android/engine/NativeOwnAccountBaseline*' 'com/vortx/android/engine/NativeOwnAccountHTTP*' \
    'com/vortx/android/engine/NativeLegacyMaterialKt*' \
    'com/vortx/android/engine/NativeLegacyPreparation*' 'com/vortx/android/engine/NativeLegacyHeld*' \
    'com/vortx/android/engine/LegacyReconciliationRequired*' 'com/vortx/android/profile/ProfileRestorePolicyKt*' \
    'com/vortx/android/engine/NativeHostPreferences*' 'com/vortx/android/engine/NativePlaylist*' \
    'com/vortx/android/profile/ProfileStore*' 'com/vortx/android/profile/PlaylistScopeEvidence*' 'com/vortx/android/profile/PlaylistScopeTransition*' 'com/vortx/android/backup/SettingsBackup*' \
    'com/vortx/android/integrations/NativeProviderCredentials*' 'com/vortx/android/integrations/NativeProviderAccess*' \
    'com/vortx/android/integrations/NativeProviderVault*' 'com/vortx/android/integrations/NativeProviderAdmission*' \
    'com/vortx/android/integrations/CredentialStoreAccess*' 'com/vortx/android/integrations/CredentialConnectionState*' \
    'com/vortx/android/integrations/SecureTokenStore*' 'com/vortx/android/security/FailClosedCredential*' \
    'com/vortx/android/security/CredentialBackend*' 'com/vortx/android/security/PersistentCredential*' \
    'com/vortx/android/security/ConditionalCredentialWrite*' 'com/vortx/android/security/SharedPreferencesCredentialBackend*' \
    'com/vortx/android/moat/WatchSignalClient*' \
    'com/vortx/android/playlists/SavedPlaylist*' 'com/vortx/android/player/queue/PlaybackQueueStore*' \
    'com/vortx/android/player/queue/PlaybackQueuePersistence*' 'com/vortx/android/player/queue/PlaybackQueueModel*' \
    'com/vortx/android/player/queue/PlaybackQueueCodec*' 'com/vortx/android/player/queue/PlaybackQueueEntry*' \
    'com/vortx/android/player/queue/PlaybackQueueState*' 'com/vortx/android/player/queue/PlaybackQueuePlaylistSnapshot*' \
    'com/vortx/android/player/queue/PlaybackQueueToken*' 'com/vortx/android/ui/viewmodel/VortXAccountViewModel*' \
    'com/vortx/android/VortXApplication*' || test "$?" -eq 12
test_cp="$test_dir/retained-app.jar:$stdlib:$annotations:$coroutines:$(jar org.json json 20240303):$android_jar:$dependency_cp"
source_dir="$repo_root/android/app/src/main/kotlin/com/vortx/android"
test_source="$repo_root/android/app/src/test/kotlin/com/vortx/android"
"$java_bin" -Xmx1400m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$test_dir/retained-app.jar" -classpath "$test_cp" \
    "$repo_root/test/fixtures/android-backup-cas/BuildConfig.kt" \
    "$source_dir/sync/VortXSyncManager.kt" "$source_dir/sync/VortXSyncRealtime.kt" \
    "$source_dir/sync/VortXSyncDoc.kt" "$source_dir/sync/BackupRevisionPolicy.kt" \
    "$source_dir/sync/NativeAccountGateway.kt" "$source_dir/sync/NativeSyncPublicationPolicy.kt" \
    "$source_dir/sync/NativeXperienceProfileGateway.kt" "$source_dir/engine/NativeXperienceWrite.kt" \
    "$source_dir/xperience/XperienceCollections.kt" "$source_dir/xperience/XperienceImportNamespace.kt" \
    "$source_dir/xperience/XperienceAddonBinding.kt" \
    "$source_dir/sync/NativeSettingsFence.kt" "$source_dir/engine/NativePlaylistAccountComposer.kt" \
    "$source_dir/engine/NativeOwnerHistoryAccount.kt" "$source_dir/engine/NativeOwnAccountSources.kt" \
    "$source_dir/engine/NativeRawHostPreferences.kt" "$source_dir/engine/VortxNativeRuntime.kt" \
    "$source_dir/engine/NativeOwnerHistoryCoordinator.kt" "$source_dir/engine/NativeOwnerHistorySessionAdapter.kt" \
    "$source_dir/foryou/ForYouModel.kt" "$source_dir/foryou/ForYouStore.kt" \
    "$source_dir/profile/ProfileStore.kt" "$source_dir/profile/ProfileRestorePolicy.kt" "$source_dir/backup/SettingsBackup.kt" \
    "$source_dir/integrations/NativeProviderCredentials.kt" "$source_dir/integrations/NativeProviderAccess.kt" \
    "$source_dir/integrations/SecureTokenStore.kt" "$source_dir/security/FailClosedCredentialStore.kt" \
    "$source_dir/moat/WatchSignalClient.kt" \
    "$source_dir/engine/VortxNativeSession.kt" \
    "$source_dir/engine/NativeAccountCoordinator.kt" "$source_dir/engine/NativeLegacyMaterial.kt" \
    "$source_dir/engine/NativeCatalogRepository.kt" "$source_dir/engine/NativeXperienceCatalogGateway.kt" \
    "$source_dir/xperience/XperienceImportStore.kt" "$source_dir/ui/viewmodel/XperienceCollectionsViewModel.kt" \
    "$source_dir/ui/viewmodel/ViewModelFactory.kt" \
    "$source_dir/engine/NativeWebsiteProfileEdits.kt" \
    "$source_dir/engine/NativePlaylist.kt" "$source_dir/engine/NativePlaylistCloudReceiptLedger.kt" "$source_dir/engine/NativeHostPreferences.kt" \
    "$source_dir/player/queue/PlaybackQueueModel.kt" "$source_dir/player/queue/PlaybackQueueStore.kt" \
    "$source_dir/playlists/SavedPlaylistStore.kt" "$source_dir/ui/viewmodel/VortXAccountViewModel.kt" \
    "$source_dir/VortXApplication.kt" \
    "$test_source/sync/VortXSyncManagerBackupRevisionTest.kt" \
    "$test_source/sync/VortXBackupCasContractTest.kt" "$test_source/sync/BackupRevisionPolicyTest.kt" \
    "$test_source/profile/PlaylistScopeTransitionTest.kt" \
    "$test_source/sync/NativeAccountSyncTest.kt" "$test_source/sync/AndroidRealtimeSyncTest.kt" \
    "$test_source/integrations/NativeProviderCredentialsTest.kt" \
    "$test_source/integrations/NativeProspectiveProviderTest.kt" \
    "$test_source/engine/NativeWebsiteProfileEditsTest.kt" \
    "$test_source/engine/NativeHostPreferencesTest.kt" "$test_source/engine/NativePlaylistTest.kt" "$test_source/engine/NativePlaylistCloudReceiptLedgerTest.kt" \
    "$test_source/engine/NativePlaylistProfileGatewayTest.kt" "$test_source/engine/NativeOwnerHistoryJniTest.kt" \
    "$test_source/engine/NativeRawHostPreferencesTest.kt" "$test_source/engine/NativeOwnerHistoryCompatibilityTest.kt" \
    "$test_source/engine/NativeXperienceWriteTest.kt" "$test_source/engine/NativeXperiencePreparedAccountJniTest.kt" \
    "$test_source/sync/NativeRawHostUploadJniTest.kt" \
    "$test_source/engine/NativeXperienceCatalogSourceTest.kt" \
    "$test_source/ui/viewmodel/XperienceCollectionsCallerSourceControls.kt" \
    "$test_source/xperience/XperienceImportStoreSourceControls.kt" \
    -d "$test_dir/classes" 2>&1 | tee "$test_dir/compile.log"
cd "$repo_root/android/app"
"$java_bin" -Xmx512m -Dvortx.test.native=true -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.sync.VortXBackupCasContractTest com.vortx.android.sync.BackupRevisionPolicyTest \
    com.vortx.android.sync.NativeAccountSyncTest com.vortx.android.sync.AndroidRealtimeSyncTest \
    com.vortx.android.profile.PlaylistScopeTransitionTest \
    com.vortx.android.integrations.NativeProviderCredentialsTest \
    com.vortx.android.integrations.NativeProspectiveProviderTest \
    com.vortx.android.engine.NativeWebsiteProfileEditsTest com.vortx.android.engine.NativeHostPreferencesTest \
    com.vortx.android.engine.NativePlaylistTest com.vortx.android.engine.NativePlaylistCloudReceiptLedgerTest com.vortx.android.engine.NativePlaylistProfileGatewayTest \
    com.vortx.android.engine.NativeOwnerHistoryJniTest 2>&1 | tee "$test_dir/native-host.log"
"$java_bin" -Xmx512m -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.engine.NativeRawHostPreferencesTest \
    com.vortx.android.engine.NativeOwnerHistoryCompatibilityTest 2>&1 | tee "$test_dir/raw-host-prerequisite.log"
"$java_bin" -Xmx512m -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.engine.NativeXperienceWriteTest 2>&1 | tee "$test_dir/xperience-write-controlled.log"
# Additional opt-in methods, separate from the strict 87/32 hosted XML roster. No skip is proof.
if [[ "${VORTX_JNI_SYNC:-}" == "1" ]]; then
    "$java_bin" -Xmx768m -Djava.library.path="$(dirname "${VORTX_JNI_LIBRARY:?Exact reviewed JNI required}")" \
        -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
        com.vortx.android.engine.NativeXperiencePreparedAccountJniTest 2>&1 | tee "$test_dir/xperience-write-jni.log"
    "$java_bin" -Xmx768m -Djava.library.path="$(dirname "${VORTX_JNI_LIBRARY:?Exact reviewed JNI required}")" \
        -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
        com.vortx.android.sync.NativeRawHostUploadJniTest 2>&1 | tee "$test_dir/raw-host-upload-jni.log"
    "$java_bin" -Xmx768m -Dvortx.test.native=true \
        -Djava.library.path="$(dirname "${VORTX_JNI_LIBRARY:?Exact reviewed JNI required}")" \
        -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
        com.vortx.android.sync.VortXSyncManagerBackupRevisionTest 2>&1 | tee "$test_dir/current-backup-revision-jni.log"
else
    printf '%s\n' 'UNRUN: exact JNI suites, including current BackupRevision14, XperiencePreparedAccount3 and RawHostUpload12. Any skipped JNI method above is not executed proof.' \
        | tee "$test_dir/exact-jni-unrun.log"
fi
printf 'Retained verification directory: %s\n' "$test_dir"
if [[ "${VORTX_XPERIENCE_CALLER_CONTROLS:-0}" == 1 ]]; then
    "$java_bin" -Xmx512m -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
        com.vortx.android.engine.NativeXperienceCatalogSourceTest 2>&1 | tee "$test_dir/xperience-catalog-controlled.log"
    "$java_bin" -Xmx512m -cp "$test_dir/classes:$test_cp" com.vortx.android.ui.viewmodel.XperienceCollectionsCallerSourceControls \
        2>&1 | tee "$test_dir/xperience-caller-controlled.log"
    "$java_bin" -Xmx512m -cp "$test_dir/classes:$test_cp" com.vortx.android.xperience.XperienceImportStoreSourceControls \
        2>&1 | tee "$test_dir/xperience-store-controlled.log"
else
    printf '%s\n' 'UNRUN: separately opted Xperience catalog5/caller8 and unchanged Store14 controls. Inventory is not an execution result.'
fi
