#!/usr/bin/env bash
set -euo pipefail
# Pure recovery/share boundaries only; no Android package, native library or live account.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="${VORTX_GRADLE_MODULE_CACHE:-${HOME}/.gradle/caches/modules-2/files-2.1}"
java_bin="${VORTX_TEST_JAVA:-java}"
jar() { rg --files "$cache/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
compiler="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10)"
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
reflect="$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10)"
annotations="$(jar org.jetbrains annotations 13.0)"
compiler_coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.8.0)"
coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
junit="$(jar junit junit 4.13.2)"
hamcrest="$(jar org.hamcrest hamcrest-core 1.3)"
mkdir -p "$repo/android/app/build"
receipt="$(mktemp -d "$repo/android/app/build/recovery-boundaries.XXXXXX")"
source="$repo/android/app/src/main/kotlin/com/vortx/android"
tests="$repo/android/app/src/test/kotlin/com/vortx/android"
compiler_cp="$compiler:$stdlib:$reflect:$annotations:$compiler_coroutines"
runtime_cp="$stdlib:$annotations:$coroutines:$junit:$hamcrest"
printf 'Host probe Kotlin2.2.10/coroutines1.10.2, not full Android composition\n'
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx512m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -Xbackend-threads=1 -classpath "$runtime_cp" \
    "$source/diagnostics/DiagnosticShareOperation.kt" "$source/engine/NativeRetirementDispatch.kt" "$source/sync/NativeAccountAttempt.kt" \
    "$tests/diagnostics/DiagnosticShareOperationTest.kt" "$tests/engine/NativeRetirementDispatchTest.kt" "$tests/sync/NativeAccountAttemptTest.kt" \
    -d "$receipt/classes" 2>&1 | tee "$receipt/compiler.log"
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx128m -cp "$receipt/classes:$runtime_cp" org.junit.runner.JUnitCore \
    com.vortx.android.diagnostics.DiagnosticShareOperationTest com.vortx.android.engine.NativeRetirementDispatchTest com.vortx.android.sync.NativeAccountAttemptTest \
    2>&1 | tee "$receipt/runtime.log"
printf 'Retained actual-helper receipt: %s\n' "$receipt"
