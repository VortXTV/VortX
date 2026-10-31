#!/usr/bin/env bash
set -euo pipefail
# UNRUN source proposal. No acquisition/download; uses retained compiler/coroutines/org.json jars only.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packet="$repo/scripts/tests/android-foryou-write-authority"
cache="${VORTX_GRADLE_MODULE_CACHE:-${HOME}/.gradle/caches/modules-2/files-2.1}"
java_bin="${VORTX_TEST_JAVA:-java}"
jar() { rg --files "$cache/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
compiler="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10)"
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
reflect="$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10)"
annotations="$(jar org.jetbrains annotations 13.0)"
compiler_coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.8.0)"
runtime_coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
json="${VORTX_TEST_JSON:-$(rg --files "$cache/org.json/json" | rg '/json-[^/]+\.jar$' | sort | tail -1)}"
test -f "$json"
mkdir -p "$repo/android/app/build"
receipt="$(mktemp -d "$repo/android/app/build/foryou-write-authority.XXXXXX")"
nice -n 15 node "$packet/tests-verify-source.mjs" "$repo" | tee "$receipt/source.log"
compiler_cp="$compiler:$stdlib:$reflect:$annotations:$compiler_coroutines"
runtime_cp="$stdlib:$annotations:$runtime_coroutines:$json"
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx512m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -Xbackend-threads=1 -classpath "$runtime_cp" \
    "$repo/scripts/tests/android-profile-publication/tests-extracted/ForYouReloadBoundary.kt" \
    "$repo/scripts/tests/android-profile-publication/tests-android-prefs-fixture.kt" \
    "$repo/android/app/src/main/kotlin/com/vortx/android/foryou/ForYouModel.kt" \
    "$repo/android/app/src/main/kotlin/com/vortx/android/engine/NativeForYouAccess.kt" \
    "$packet/tests-native-fixture.kt" "$packet/tests-sync-fixture.kt" "$packet/tests-home-extracted.kt" "$packet/tests-main.kt" \
    -d "$receipt/classes" 2>&1 | tee "$receipt/compiler.log"
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx128m -cp "$receipt/classes:$runtime_cp" \
    com.vortx.android.engine.ForYouWriteAuthorityPacket 2>&1 | tee "$receipt/result.log"
printf 'Retained actual Store/adapter boundary receipt (not JNI/device proof): %s\n' "$receipt"
