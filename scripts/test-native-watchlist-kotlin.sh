#!/usr/bin/env bash
set -euo pipefail
# Compile the actual bounded store/codec/gateway sources against retained app classes. This is not
# a Gradle, Android UI, JNI or account-host integration gate; it does not run apps/accounts/media.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${VORTX_GRADLE_MODULE_CACHE:-/Users/daksh/.gradle/caches/modules-2/files-2.1}"
java_bin="${VORTX_TEST_JAVA:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java}"
app_classes="${VORTX_COMPILED_APP:?Point to retained actual Android app classes.jar}"
android_jar="${VORTX_ANDROID_JAR:-/Users/daksh/Library/Android/sdk/platforms/android-36/android.jar}"
test -f "$app_classes"
test -f "$android_jar"
jar() { rg --files "$cache_root/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
compiler="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10)"
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
reflect="$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10)"
annotations="$(jar org.jetbrains annotations 13.0)"
coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
compiler_cp="$compiler:$stdlib:$reflect:$annotations:$coroutines"
test_cp="$app_classes:$stdlib:$annotations:$coroutines:$(jar org.json json 20240303):$(jar junit junit 4.13.2):$(jar org.hamcrest hamcrest-core 1.3):$android_jar"
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/native-watchlist-kotlin.XXXXXX")"
source_dir="$repo_root/android/app/src/main/kotlin/com/vortx/android/library"
test_source="$repo_root/android/app/src/test/kotlin/com/vortx/android/library"
"$java_bin" -Xmx512m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$app_classes" -classpath "$test_cp" \
    "$source_dir/WatchlistStore.kt" "$source_dir/NativeWatchlistGateway.kt" "$source_dir/NativeWatchlistCodec.kt" \
    "$test_source/WatchlistCodecTest.kt" "$test_source/NativeWatchlistCodecTest.kt" "$test_source/NativeWatchlistStoreTest.kt" \
    "$test_source/NativeWatchlistCanonicalFixture.kt" "$test_source/NativeWatchlistUiCaptureContractTest.kt" \
    -d "$test_dir/classes"
"$java_bin" -Xmx256m -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.library.WatchlistCodecTest \
    com.vortx.android.library.NativeWatchlistCodecTest \
    com.vortx.android.library.NativeWatchlistStoreTest \
    com.vortx.android.library.NativeWatchlistUiCaptureContractTest
"$java_bin" -Xmx256m -cp "$test_dir/classes:$test_cp" com.vortx.android.library.NativeWatchlistCanonicalFixture \
    | tee "$test_dir/canonical-fixtures.json" | node "$repo_root/test/native-watchlist-canonical.mjs"
shasum -a 256 "$test_dir/canonical-fixtures.json"
