#!/usr/bin/env bash
set -euo pipefail
# Focused complete skip-service JVM composition with explicit synthetic collaborators.
# Manual, serial host tests only: no Gradle/SDK/APK, download, real provider, player, or device run.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kotlin_lib="${VORTX_KOTLIN_LIB:?Existing Gradle 8.11.1 lib with Kotlin 2.0.20 required}"
deps="${VORTX_ANDROID_AUDIT_DEPS:?Existing public JSON/JUnit dependency directory required}"
java_bin="${VORTX_TEST_JAVA:?Existing Java 17 launcher required}"
compiler_jars=(kotlin-compiler-embeddable-2.0.20.jar kotlin-stdlib-2.0.20.jar kotlin-reflect-2.0.20.jar
  kotlin-script-runtime-2.0.20.jar kotlin-daemon-embeddable-2.0.20.jar trove4j-1.0.20200330.jar
  annotations-24.0.1.jar kotlinx-coroutines-core-jvm-1.6.4.jar)
compiler_cp=""
for name in "${compiler_jars[@]}"; do
  test -f "$kotlin_lib/$name"
  compiler_cp="${compiler_cp:+$compiler_cp:}$kotlin_lib/$name"
done
for name in json-20240303.jar junit-4.13.2.jar hamcrest-core-1.3.jar; do test -f "$deps/$name"; done
test -x "$java_bin"
test_cp="$kotlin_lib/kotlin-stdlib-2.0.20.jar:$kotlin_lib/kotlinx-coroutines-core-jvm-1.6.4.jar:$deps/json-20240303.jar:$deps/junit-4.13.2.jar:$deps/hamcrest-core-1.3.jar"
main="$repo_root/android/app/src/main/kotlin/com/vortx/android/skip"
fixture="$repo_root/scripts/fixtures/android-skip-service-composition"
sources=("$main/SkipTimestampService.kt" "$main/TheIntroDBV4.kt" "$main/SkipSegments.kt"
  "$fixture/Context.kt" "$fixture/Log.kt" "$fixture/SkipServiceCollaborators.kt"
  "$fixture/SkipTimestampServiceCompositionTest.kt")
# Root .gitignore already excludes **/.build/. Keep all retained output below this named host-test subtree.
build_root="$repo_root/.build/android-skip-service-composition"
mkdir -p "$build_root"
run_dir="$(mktemp -d "$build_root/run.XXXXXX")"
jvm_env="$(mktemp -d "$build_root/jvm-env.XXXXXX")"
mkdir -p "$jvm_env/home" "$jvm_env/tmp"
shasum -a 256 "${sources[@]}" > "$run_dir/source-manifest.txt"
toolchain=("$java_bin")
for name in "${compiler_jars[@]}"; do toolchain+=("$kotlin_lib/$name"); done
for name in json-20240303.jar junit-4.13.2.jar hamcrest-core-1.3.jar; do toolchain+=("$deps/$name"); done
shasum -a 256 "${toolchain[@]}" > "$run_dir/toolchain-manifest.txt"
# One compiler process/backend thread, then JUnit. No external deadline or OS sandbox is claimed.
env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$jvm_env/home" TMPDIR="$jvm_env/tmp/" \
  /usr/bin/nice -n 15 "$java_bin" \
  -Duser.home="$jvm_env/home" -Djava.io.tmpdir="$jvm_env/tmp" -XX:+PerfDisableSharedMem \
  -XX:ActiveProcessorCount=1 -Xmx384m -XX:MaxMetaspaceSize=192m \
  -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-stdlib -no-reflect -jvm-target 17 -Xbackend-threads=1 -classpath "$test_cp" \
  "${sources[@]}" -d "$run_dir/classes" 2>&1 | tee "$run_dir/compile.log"
env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$jvm_env/home" TMPDIR="$jvm_env/tmp/" \
  /usr/bin/nice -n 15 "$java_bin" \
  -Duser.home="$jvm_env/home" -Djava.io.tmpdir="$jvm_env/tmp" -XX:+PerfDisableSharedMem \
  -XX:ActiveProcessorCount=1 -Xmx192m -cp "$run_dir/classes:$test_cp" \
  org.junit.runner.JUnitCore com.vortx.android.skip.SkipTimestampServiceCompositionTest 2>&1 | tee "$run_dir/junit.log"
printf 'Retained service source/toolchain manifests, classes, logs, and private JVM dirs: %s %s\n' "$run_dir" "$jvm_env"
