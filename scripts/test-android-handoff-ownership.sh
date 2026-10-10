#!/usr/bin/env bash
set -euo pipefail
# Compile the production handoff seam and executable JVM regressions. No app/JNI/provider runs.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${VORTX_GRADLE_MODULE_CACHE:-/Users/daksh/.gradle/caches/modules-2/files-2.1}"
java_bin="${VORTX_TEST_JAVA:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home/bin/java}"
app_classes="${VORTX_COMPILED_APP:?Point to retained actual Android app classes.jar}"
android_jar="${VORTX_ANDROID_JAR:-/Users/daksh/Library/Android/sdk/platforms/android-36/android.jar}"
test -f "$app_classes"
test -f "$android_jar"
jar() { rg --files "$cache_root/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
annotations="$(jar org.jetbrains annotations 13.0)"
coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
compiler_cp="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10):$stdlib:$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10):$annotations:$coroutines"
dependency_cp="$(rg --files "$cache_root" | rg '\.jar$' | paste -sd ':' -)"
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/handoff-ownership-kotlin.XXXXXX")"
printf 'Retained verification directory: %s\n' "$test_dir"
cp "$app_classes" "$test_dir/retained-app.jar"
# The subject always comes from this worktree, never an older retained implementation.
zip -qd "$test_dir/retained-app.jar" 'com/vortx/android/player/PlayerSourceSwitch*.class' 'com/vortx/android/player/PlayerEpisodeSwitchCompletion.class' 'com/vortx/android/player/PendingPlayer*Switch.class'
test_cp="$test_dir/retained-app.jar:$stdlib:$annotations:$coroutines:$dependency_cp:$android_jar"
source_dir="$repo_root/android/app/src/main/kotlin/com/vortx/android"
test_source="$repo_root/android/app/src/test/kotlin/com/vortx/android"
"$java_bin" -Xmx1200m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$test_dir/retained-app.jar" -classpath "$test_cp" \
    "$source_dir/player/PlayerSourceSwitching.kt" "$source_dir/player/PlayerAdmissionPolicy.kt" \
    "$source_dir/player/NextEpisodePreloadPolicy.kt" "$source_dir/ui/viewmodel/EpisodeResolutionBudget.kt" \
    "$source_dir/ui/components/EpisodeRailPolicy.kt" \
    "$test_source/player/PlayerSourceSwitchingTest.kt" "$test_source/player/PlayerRecoveryParityTest.kt" \
    "$test_source/player/NextEpisodePreloadPolicyTest.kt" "$test_source/player/NextEpisodePreloadTaskOwnerTest.kt" \
    "$test_source/ui/viewmodel/EpisodeResolutionBudgetTest.kt" \
    -d "$test_dir/classes" 2>&1 | tee "$test_dir/compile.log"
cd "$repo_root/android/app"
"$java_bin" -Xmx768m -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.player.PlayerSourceSwitchingTest \
    com.vortx.android.player.PlayerRecoveryParityTest \
    com.vortx.android.player.NextEpisodePreloadPolicyTest \
    com.vortx.android.player.NextEpisodePreloadTaskOwnerTest \
    com.vortx.android.ui.viewmodel.EpisodeResolutionBudgetTest 2>&1 | tee "$test_dir/result.log"
