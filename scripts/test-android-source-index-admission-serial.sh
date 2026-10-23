#!/usr/bin/env bash
set -euo pipefail
# Focused complete-source JVM compilation, explicitly serial and low priority. No Gradle/daemon,
# APK, dependency downloads, provider calls, DNS lookup, or player/device activity.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="/Users/daksh/VortXTV"
kotlin_lib="${VORTX_KOTLIN_LIB:?Existing Gradle 8.11.1 lib with Kotlin 2.0.20 required}"
deps="${VORTX_ANDROID_AUDIT_DEPS:?Existing public JSON/JUnit dependency directory required}"
java_bin="${VORTX_TEST_JAVA:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java}"
compiler_jars=(kotlin-compiler-embeddable-2.0.20.jar kotlin-stdlib-2.0.20.jar kotlin-reflect-2.0.20.jar
  kotlin-script-runtime-2.0.20.jar kotlin-daemon-embeddable-2.0.20.jar trove4j-1.0.20200330.jar
  annotations-24.0.1.jar kotlinx-coroutines-core-jvm-1.6.4.jar)
compiler_cp=""
for name in "${compiler_jars[@]}"; do
  test -f "$kotlin_lib/$name"
  compiler_cp="${compiler_cp:+$compiler_cp:}$kotlin_lib/$name"
done
for name in json-20240303.jar junit-4.13.2.jar hamcrest-core-1.3.jar; do test -f "$deps/$name"; done
test_cp="$kotlin_lib/kotlin-stdlib-2.0.20.jar:$kotlin_lib/kotlinx-coroutines-core-jvm-1.6.4.jar:$deps/json-20240303.jar:$deps/junit-4.13.2.jar:$deps/hamcrest-core-1.3.jar"
build_root="$workspace/_build/repair-20261018-android-source-admission"
mkdir -p "$build_root"
run_dir="$(mktemp -d "$build_root/run.XXXXXX")"
main="$repo_root/android/app/src/main/kotlin/com/vortx/android"
tests="$repo_root/android/app/src/test/kotlin/com/vortx/android/engine"
fixture="$repo_root/scripts/fixtures/android-source-index-admission"
sources=("$main/singularity/SourceIndexClient.kt" "$main/sources/CanonicalContentIdentity.kt"
  "$fixture/Log.kt" "$fixture/Engine.kt" "$fixture/Model.kt" "$fixture/EdgeAuth.kt"
  "$tests/SourceIndexPooledAdmissionBoundaryTest.kt")
shasum -a 256 "${sources[@]}" > "$run_dir/source-manifest.txt"
# Direct CLI, one compiler process, one backend thread; release compiler before starting JUnit.
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx384m -XX:MaxMetaspaceSize=192m \
  -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-stdlib -no-reflect -jvm-target 17 -Xbackend-threads=1 -classpath "$test_cp" \
  "${sources[@]}" -d "$run_dir/classes"
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx192m -cp "$run_dir/classes:$test_cp" \
  org.junit.runner.JUnitCore com.vortx.android.engine.SourceIndexPooledAdmissionBoundaryTest
printf 'Retained source manifest and classes: %s\n' "$run_dir"
