#!/usr/bin/env bash
set -euo pipefail
# Actual submit/cleanup decisions with synthetic auth, not an Android application build.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="${VORTX_GRADLE_MODULE_CACHE:-${HOME}/.gradle/caches/modules-2/files-2.1}"
java_bin="${VORTX_TEST_JAVA:-java}"
jar() { rg --files "$cache/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
compiler="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10)"
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
reflect="$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10)"
annotations="$(jar org.jetbrains annotations 13.0)"
compiler_coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.8.0)"
runtime_coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
mkdir -p "$repo/android/app/build"
receipt="$(mktemp -d "$repo/android/app/build/account-submit.XXXXXX")"
nice -n 15 node "$repo/scripts/tests/android-account-submit.mjs" \
    "$repo/android/app/src/main/kotlin/com/vortx/android/ui/viewmodel/VortXAccountViewModel.kt" \
    "$receipt/AccountSubmitProbe.kt" | tee "$receipt/source.log"
compiler_cp="$compiler:$stdlib:$reflect:$annotations:$compiler_coroutines"
runtime_cp="$stdlib:$annotations:$runtime_coroutines"
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx512m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -Xbackend-threads=1 -classpath "$runtime_cp" \
    "$receipt/AccountSubmitProbe.kt" -d "$receipt/classes" 2>&1 | tee "$receipt/compiler.log"
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx128m -cp "$receipt/classes:$runtime_cp" \
    AccountSubmitProbeKt 2>&1 | tee "$receipt/runtime.log"
printf 'Retained actual-source submit receipt (host Kotlin2.2.10/coroutines1.10.2 only): %s\n' "$receipt"
