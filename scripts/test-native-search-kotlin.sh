#!/usr/bin/env bash
set -euo pipefail
# Bounded JVM verification of the actual search/session sources against retained Android dependencies.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${VORTX_GRADLE_MODULE_CACHE:-/Users/daksh/.gradle/caches/modules-2/files-2.1}"
java_bin="${VORTX_TEST_JAVA:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java}"
app_classes="${VORTX_COMPILED_APP:?Point to retained actual Android app classes.jar}"
android_jar="${VORTX_ANDROID_JAR:-/Users/daksh/Library/Android/sdk/platforms/android-36/android.jar}"
test -f "$app_classes"
jar() { rg --files "$cache_root/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
annotations="$(jar org.jetbrains annotations 13.0)"
coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
compiler_cp="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10):$stdlib:$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10):$annotations:$coroutines"
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/native-search-kotlin.XXXXXX")"
cp "$app_classes" "$test_dir/retained-app.jar"
zip -qd "$test_dir/retained-app.jar" 'com/vortx/android/engine/EngineState*.class'
test_cp="$test_dir/retained-app.jar:$stdlib:$annotations:$coroutines:$(jar org.json json 20240303):$(jar junit junit 4.13.2):$(jar org.hamcrest hamcrest-core 1.3):$android_jar"
source_dir="$repo_root/android/app/src/main/kotlin/com/vortx/android"
test_source="$repo_root/android/app/src/test/kotlin/com/vortx/android"
"$java_bin" -Xmx768m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$test_dir/retained-app.jar" -classpath "$test_cp" \
    "$source_dir/engine/NativeResourceBatch.kt" "$source_dir/engine/NativeProviderBatch.kt" "$source_dir/engine/VortxNativeSession.kt" \
    "$source_dir/engine/VortxResourceBridge.kt" "$source_dir/engine/VortxResourceProjection.kt" "$source_dir/engine/EngineState.kt" \
    "$source_dir/engine/NativeCatalogRepository.kt" "$source_dir/ui/search/SearchPresentation.kt" "$source_dir/ui/search/SearchCollections.kt" \
    "$test_source/engine/NativeSearchBatchTest.kt" "$test_source/engine/VortxNativeSessionTest.kt" \
    "$test_source/ui/search/SearchPresentationTest.kt" "$test_source/ui/search/SearchCollectionsTest.kt" "$test_source/ui/search/SearchRailsContractTest.kt" \
    -d "$test_dir/classes"
cd "$repo_root/android/app"
"$java_bin" -Xmx384m -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.engine.NativeSearchBatchTest \
    com.vortx.android.engine.VortxNativeSessionTest \
    com.vortx.android.ui.search.SearchPresentationTest \
    com.vortx.android.ui.search.SearchCollectionsTest \
    com.vortx.android.ui.search.SearchRailsContractTest
