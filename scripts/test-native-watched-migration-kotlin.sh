#!/usr/bin/env bash
set -euo pipefail
# Focused JVM execution against actual precompiled app classes; no Gradle/Android build or stubbed
# source model. The normal Full/Play tests remain the integration gate after the parent grants it.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${VORTX_GRADLE_MODULE_CACHE:-/Users/daksh/.gradle/caches/modules-2/files-2.1}"
java_bin="${VORTX_TEST_JAVA:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java}"
app_classes="${VORTX_COMPILED_APP:?Point to actual current Android compiled classes.jar}"
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
test_cp="$app_classes:$stdlib:$annotations:$coroutines:$(jar org.json json 20240303):$(jar junit junit 4.13.2):$(jar org.hamcrest hamcrest-core 1.3):$(jar com.squareup.okhttp3 okhttp 4.12.0):$(jar com.squareup.okio okio-jvm 3.15.0):$android_jar"
mkdir -p "$repo_root/app/build"
test_dir="$(mktemp -d "$repo_root/app/build/native-watched-kotlin.XXXXXX")"
source_dir="$repo_root/android/app/src/main/kotlin/com/vortx/android/engine"
test_source="$repo_root/android/app/src/test/kotlin/com/vortx/android/engine"
"$java_bin" -Xmx1g -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$app_classes" -classpath "$test_cp" \
    "$source_dir/LegacyWatchedBitfieldDecoder.kt" "$source_dir/LegacyWatchedBitfieldMigrationEvidence.kt" \
    "$source_dir/NativeWatchedMigrationProducer.kt" "$source_dir/NativeLegacyMaterial.kt" \
    "$test_source/LegacyWatchedBitfieldDecoderTest.kt" "$test_source/LegacyWatchedBitfieldMigrationEvidenceTest.kt" \
    "$test_source/NativeLegacyMaterialTest.kt" "$test_source/NativeWatchedMigrationProducerTest.kt" -d "$test_dir/classes"
cd "$repo_root/android/app"
"$java_bin" -Xmx1g -cp "$test_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.engine.LegacyWatchedBitfieldDecoderTest \
    com.vortx.android.engine.LegacyWatchedBitfieldMigrationEvidenceTest \
    com.vortx.android.engine.NativeLegacyMaterialTest \
    com.vortx.android.engine.NativeWatchedMigrationProducerTest
