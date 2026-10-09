#!/usr/bin/env bash
set -euo pipefail
# Actual changed Kotlin/Compose sources plus bounded JVM fixtures. No app/JNI/account/provider/media runs.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${VORTX_GRADLE_MODULE_CACHE:-/Users/daksh/.gradle/caches/modules-2/files-2.1}"
transforms_root="${VORTX_GRADLE_TRANSFORMS:-/Users/daksh/.gradle/caches/8.11.1/transforms}"
java_bin="${VORTX_TEST_JAVA:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java}"
app_classes="${VORTX_COMPILED_APP:?Point to retained actual Android app classes.jar}"
android_jar="${VORTX_ANDROID_JAR:-/Users/daksh/Library/Android/sdk/platforms/android-36/android.jar}"
test -f "$app_classes"
test -f "$android_jar"
jar() { rg --files "$cache_root/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
annotations="$(jar org.jetbrains annotations 13.0)"
coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
compiler_cp="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10):$stdlib:$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10):$annotations:$coroutines"
compose_plugin="$(jar org.jetbrains.kotlin kotlin-compose-compiler-plugin-embeddable 2.2.10)"
dependency_cp="$(rg --files "$cache_root" "$transforms_root" | rg '\.jar$' | paste -sd ':' -)"
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/playback-parity-kotlin.XXXXXX")"
# Do not let an older retained parser's exact overload win over the source's nullable/defaulted API.
cp "$app_classes" "$test_dir/retained-app.jar"
zip -qd "$test_dir/retained-app.jar" 'com/vortx/android/engine/EngineState*.class' 'com/vortx/android/engine/SourceListModel*.class' 'com/vortx/android/engine/SourceListState*.class' 'com/vortx/android/engine/SourceContributorSettlement.class'
test_cp="$test_dir/retained-app.jar:$stdlib:$annotations:$coroutines:$dependency_cp:$android_jar"
source_dir="$repo_root/android/app/src/main/kotlin/com/vortx/android"
test_source="$repo_root/android/app/src/test/kotlin/com/vortx/android"
"$java_bin" -Xmx1800m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$test_dir/retained-app.jar" -classpath "$test_cp" -Xplugin="$compose_plugin" \
    "$source_dir/engine/NativeResourceBatch.kt" "$source_dir/engine/NativeProviderBatch.kt" "$source_dir/engine/VortxNativeSession.kt" \
    "$source_dir/engine/VortxResourceBridge.kt" "$source_dir/engine/VortxResourceProjection.kt" "$source_dir/engine/EngineState.kt" "$source_dir/engine/SourceListModel.kt" "$source_dir/engine/NativeCatalogRepository.kt" \
    "$source_dir/player/PlayerAdmissionPolicy.kt" "$source_dir/player/PlayerSourceSwitching.kt" "$source_dir/player/PlayerScreen.kt" "$source_dir/player/PlayerChrome.kt" \
    "$source_dir/ui/viewmodel/DetailViewModel.kt" "$source_dir/ui/viewmodel/EpisodeResolutionBudget.kt" \
    "$source_dir/ui/components/EpisodeRailPolicy.kt" "$source_dir/ui/screens/DetailScreen.kt" "$source_dir/ui/tv/TvDetailScreen.kt" "$source_dir/ui/tv/TvDetailSections.kt" "$source_dir/ui/tv/TvSourceList.kt" \
    "$test_source/engine/NativeSearchBatchTest.kt" "$test_source/engine/NativeProviderBatchTest.kt" \
    "$test_source/player/PlayerSourceSwitchingTest.kt" "$test_source/player/PlayerRecoveryParityTest.kt" \
    "$test_source/ui/viewmodel/EpisodeResolutionBudgetTest.kt" "$test_source/ui/viewmodel/PlaybackResolveFenceTest.kt" \
    -d "$test_dir/classes"
cd "$repo_root/android/app"
"$java_bin" -Xmx768m -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.engine.NativeProviderBatchTest \
    com.vortx.android.player.PlayerSourceSwitchingTest \
    com.vortx.android.player.PlayerRecoveryParityTest \
    com.vortx.android.ui.viewmodel.EpisodeResolutionBudgetTest \
    com.vortx.android.ui.viewmodel.PlaybackResolveFenceTest
printf 'Retained verification directory: %s\n' "$test_dir"
