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
# Match the application pin, not a newer unrelated harness dependency. The
# compiler's own retained POM requires 1.8.0 independently of the app runtime.
coroutines_version="$(sed -n 's/^coroutines = "\([0-9.]*\)"$/\1/p' "$repo_root/android/gradle/libs.versions.toml")"
test -n "$coroutines_version"
coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm "$coroutines_version")"
compiler_coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.8.0)"
compiler_cp="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10):$stdlib:$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10):$annotations:$compiler_coroutines"
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
    'com/vortx/android/engine/NativeAccountCoordinator*' 'com/vortx/android/engine/VortxNativeSession*' \
    'com/vortx/android/engine/VortxAccountScope*' 'com/vortx/android/engine/NativeCheckpointRead*' \
    'com/vortx/android/engine/VortxCheckpointStore*' 'com/vortx/android/engine/VortxEncryptedCheckpointStore*' \
    'com/vortx/android/engine/VortxAndroidCheckpointKey*' 'com/vortx/android/engine/VortxNativeOwner*' \
    'com/vortx/android/engine/VortxNativeRead*' 'com/vortx/android/engine/NativePlaylist*' \
    'com/vortx/android/engine/NativeHostPreferences*' 'com/vortx/android/engine/NativeWebsiteProfileEdits*' \
    'com/vortx/android/sync/NativePlaylistProfileGateway*' \
    'com/vortx/android/profile/ProfileStore*' 'com/vortx/android/profile/PlaylistScopeEvidence*' 'com/vortx/android/profile/PlaylistScopeTransition*' \
    'com/vortx/android/playlists/SavedPlaylist*' \
    'com/vortx/android/player/queue/PlaybackQueueStore*' 'com/vortx/android/player/queue/PlaybackQueuePersistence*' \
    'com/vortx/android/player/queue/PlaybackQueueModel*' 'com/vortx/android/player/queue/PlaybackQueueCodec*' \
    'com/vortx/android/player/queue/PlaybackQueueEntry*' 'com/vortx/android/player/queue/PlaybackQueueState*' \
    'com/vortx/android/player/queue/PlaybackQueuePlaylistSnapshot*' 'com/vortx/android/player/queue/PlaybackQueueToken*' \
    'com/vortx/android/VortXApplication*' \
    'com/vortx/android/ui/viewmodel/VortXAccountViewModel*'
test_cp="$test_dir/retained-app.jar:$stdlib:$annotations:$coroutines:$dependency_cp:$android_jar"
source_dir="$repo_root/android/app/src/main/kotlin/com/vortx/android"
test_source="$repo_root/android/app/src/test/kotlin/com/vortx/android"
"$java_bin" -Xmx1800m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$test_dir/retained-app.jar" -classpath "$test_cp" \
    "$source_dir/sync/VortXSyncManager.kt" "$source_dir/sync/VortXSyncRealtime.kt" "$source_dir/sync/NativeAccountGateway.kt" \
    "$source_dir/sync/NativeSyncPublicationPolicy.kt" "$source_dir/engine/NativeAccountCoordinator.kt" \
    "$source_dir/engine/VortxNativeSession.kt" "$source_dir/engine/NativePlaylist.kt" \
    "$source_dir/engine/NativePlaylistCloudReceiptLedger.kt" "$source_dir/engine/NativeHostPreferences.kt" \
    "$source_dir/engine/NativeWebsiteProfileEdits.kt" "$source_dir/player/queue/PlaybackQueueModel.kt" "$source_dir/player/queue/PlaybackQueueStore.kt" \
    "$source_dir/profile/ProfileStore.kt" "$source_dir/profile/ProfileRestorePolicy.kt" \
    "$source_dir/playlists/SavedPlaylistStore.kt" "$source_dir/VortXApplication.kt" \
    "$source_dir/engine/NativeLegacyMaterial.kt" "$source_dir/ui/viewmodel/VortXAccountViewModel.kt" \
    "$test_source/sync/AndroidRealtimeSyncTest.kt" "$test_source/sync/DurableSessionStateTest.kt" \
    "$test_source/profile/PlaylistScopeTransitionTest.kt" \
    "$test_source/sync/NativeAccountSyncTest.kt" "$test_source/sync/VortXSessionOwnerTransitionContractTest.kt" \
    "$test_source/integrations/NativeProviderCredentialsTest.kt" \
    "$test_source/engine/NativePlaylistTest.kt" "$test_source/engine/NativePlaylistCloudReceiptLedgerTest.kt" \
    "$test_source/engine/NativeHostPreferencesTest.kt" "$test_source/engine/NativeWebsiteProfileEditsTest.kt" \
    -d "$test_dir/classes"
cd "$repo_root/android/app"
"$java_bin" -Xmx768m -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.sync.AndroidRealtimeSyncTest \
    com.vortx.android.sync.DurableSessionStateTest \
    com.vortx.android.sync.NativeAccountSyncTest \
    com.vortx.android.profile.PlaylistScopeTransitionTest \
    com.vortx.android.sync.VortXSessionOwnerTransitionContractTest \
    com.vortx.android.engine.NativePlaylistTest \
    com.vortx.android.engine.NativePlaylistCloudReceiptLedgerTest \
    com.vortx.android.engine.NativeHostPreferencesTest \
    com.vortx.android.engine.NativeWebsiteProfileEditsTest
printf 'Retained verification directory: %s\n' "$test_dir"
