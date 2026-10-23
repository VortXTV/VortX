#!/usr/bin/env bash
set -euo pipefail
# Small actual-source boundary test, not an Android app build or JNI/device test.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packet="$repo/scripts/tests/android-profile-publication"
cache="${VORTX_GRADLE_MODULE_CACHE:-${HOME}/.gradle/caches/modules-2/files-2.1}"
java_bin="${VORTX_TEST_JAVA:-java}"
jar() { rg --files "$cache/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
# Retained host tool versions are explicit; this is not proof of app dependency composition.
compiler="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10)"
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
reflect="$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10)"
annotations="$(jar org.jetbrains annotations 13.0)"
compiler_coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.8.0)"
runtime_coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
mkdir -p "$repo/android/app/build"
receipt="$(mktemp -d "$repo/android/app/build/profile-publication.XXXXXX")"
nice -n 15 node "$packet/tests-verify-source.mjs" "$repo" | tee "$receipt/source.log"
compiler_cp="$compiler:$stdlib:$reflect:$annotations:$compiler_coroutines"
runtime_cp="$stdlib:$annotations:$runtime_coroutines"
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx512m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -Xbackend-threads=1 -classpath "$runtime_cp" \
    "$packet/tests-extracted/NativeProfileAccess.kt" "$packet/tests-extracted/ProfileStoreBoundary.kt" \
    "$packet/tests-extracted/NativeProfileGateway.kt" "$packet/tests-extracted/ContinueWatchingOwnerGate.kt" \
    "$packet/tests-session-fixture.kt" "$packet/tests-profile-fixture.kt" "$packet/tests-main.kt" \
    -d "$receipt/classes" 2>&1 | tee "$receipt/compiler.log"
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx128m -cp "$receipt/classes:$runtime_cp" \
    com.vortx.android.engine.ProjectionBoundaryPacket 2>&1 | tee "$receipt/result.log"
printf 'Retained source-boundary receipt (not full Android): %s\n' "$receipt"
