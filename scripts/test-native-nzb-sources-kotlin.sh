#!/usr/bin/env bash
set -euo pipefail
# Actual native repository/indexer/session sources; synthetic JVM transport only. No Gradle/JNI/accounts.
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
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/native-nzb-kotlin.XXXXXX")"
printf 'Retained verification directory: %s\n' "$test_dir"
cp "$app_classes" "$test_dir/retained-app.jar"
zip -qd "$test_dir/retained-app.jar" 'com/vortx/android/engine/EngineState*.class' 'com/vortx/android/data/CatalogRepository*.class'
test_cp="$test_dir/retained-app.jar:$stdlib:$annotations:$coroutines:$(jar org.json json 20240303):$(jar junit junit 4.13.2):$(jar org.hamcrest hamcrest-core 1.3):$android_jar"
source_dir="$repo_root/android/app/src/main/kotlin/com/vortx/android"
test_source="$repo_root/android/app/src/test/kotlin/com/vortx/android"
# Optional exact git-object source for retained RED counterexample verification; default is current source.
repository_source="${VORTX_NATIVE_NZB_REPO_SOURCE:-$source_dir/engine/NativeCatalogRepository.kt}"
"$java_bin" -Xmx768m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$test_dir/retained-app.jar" -classpath "$test_cp" \
    "$source_dir/engine/NativeResourceBatch.kt" "$source_dir/engine/NativeProviderBatch.kt" "$source_dir/engine/VortxNativeSession.kt" \
    "$source_dir/engine/VortxResourceBridge.kt" "$source_dir/engine/VortxResourceProjection.kt" "$source_dir/engine/EngineState.kt" \
    "$source_dir/data/CatalogRepository.kt" "$source_dir/data/SourcePreparation.kt" \
    "$repository_source" "$source_dir/engine/NzbSourceAggregator.kt" \
    "$test_source/engine/NativeNzbSourcesTest.kt" \
    -d "$test_dir/classes" 2>&1 | tee "$test_dir/compile.log"
cd "$repo_root/android/app"
"$java_bin" -Xmx384m -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.engine.NativeNzbSourcesTest 2>&1 | tee "$test_dir/result.log"
printf 'Retained verification directory: %s\n' "$test_dir"
