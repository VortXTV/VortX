#!/usr/bin/env bash
set -euo pipefail
# Offline, serial actual-source host regression. No Gradle, Android SDK, downloads or recovery inputs.
test "$#" -eq 0 || { printf 'Usage: bash scripts/test-session-audio-presets.sh\n' >&2; exit 2; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cache="${VORTX_GRADLE_MODULE_CACHE:-${HOME}/.gradle/caches/modules-2/files-2.1}"
jdk="${VORTX_TEST_JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
clangxx="${VORTX_TEST_CLANGXX:-/usr/bin/clang++}"
case "$jdk" in /*) ;; *) printf 'VORTX_TEST_JAVA_HOME must be absolute.\n' >&2; exit 2 ;; esac
case "$clangxx" in /*) ;; *) printf 'VORTX_TEST_CLANGXX must be absolute.\n' >&2; exit 2 ;; esac
java_bin="$jdk/bin/java"
test -x "$java_bin" && test -x "$clangxx"
test -f "$jdk/include/jni.h" && test -f "$jdk/include/darwin/jni_md.h"
jdk_version="$(sed -n 's/^JAVA_VERSION="\([^"]*\)"$/\1/p' "$jdk/release")"
case "$jdk_version" in 21|21.*) ;; *) printf 'Need JDK21, found %s.\n' "$jdk_version" >&2; exit 1 ;; esac
command -v rg >/dev/null
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1
catalog="$repo/android/gradle/libs.versions.toml"
app="$repo/android/app/src"
seam="$repo/android/mpv-seam/src"
cpp="$seam/main/cpp"
harness="$seam/test/cpp/audio_preset_transaction_test.cpp"
mkdir -p "$repo/android/app/build"
receipt="$(mktemp -d "$repo/android/app/build/session-audio-presets.XXXXXX")"
finish() {
    local result=$? check_result=0 manifest
    trap - EXIT
    set +e
    for manifest in source-before dependencies; do
        if test -f "$receipt/$manifest.sha256"; then
            shasum -a 256 -c "$receipt/$manifest.sha256" > "$receipt/$manifest-at-exit.log" 2>&1
            test "$?" -eq 0 || check_result=1
        fi
    done
    if test "$result" -eq 0 && test "$check_result" -ne 0; then result=1; fi
    printf '%s\n' "$result" > "$receipt/exit-code.txt"
    printf 'Session audio preset exit %s; retained receipt: %s\n' "$result" "$receipt"
    exit "$result"
}
trap finish EXIT
printf 'Retaining serial actual-source audio preset receipt: %s\n' "$receipt"
catalog_version() {
    local value
    value="$(sed -n "s/^$1 = \"\([0-9][0-9.]*\)\"$/\1/p" "$catalog")"
    test -n "$value" && test "$(printf '%s\n' "$value" | wc -l | tr -d ' ')" -eq 1 || return 1
    printf '%s\n' "$value"
}
cached_file() {
    local group="$1" artifact="$2" version="$3" extension="$4" candidate
    local matches=()
    while IFS= read -r candidate; do matches+=("$candidate"); done < <(
        rg --files "$cache/$group/$artifact/$version" -g "$artifact-$version.$extension"
    )
    test "${#matches[@]}" -eq 1 || {
        printf 'Need exactly one cached %s:%s:%s (%s); found %s. No download attempted.\n' \
            "$group" "$artifact" "$version" "$extension" "${#matches[@]}" >&2; return 1;
    }
    printf '%s\n' "${matches[0]}"
}
jar() { cached_file "$1" "$2" "$3" jar; }
dependency_version() {
    local value property
    value="$(sed -n "/<artifactId>$2<\/artifactId>/,/<\/dependency>/p" "$1" |
        sed -n 's/.*<version>\([^<]*\)<\/version>.*/\1/p')"
    test -n "$value" && test "$(printf '%s\n' "$value" | wc -l | tr -d ' ')" -eq 1 || return 1
    property="$(printf '%s\n' "$value" | sed -n 's/^\${\([A-Za-z][A-Za-z0-9_.-]*\)}$/\1/p')"
    if test -n "$property"; then
        value="$(sed -n "s/.*<$property>\([^<]*\)<\/$property>.*/\1/p" "$1")"
    fi
    case "$value" in ''|*[!0-9.]*) printf 'Unresolved POM dependency %s in %s\n' "$2" "$1" >&2; return 1 ;; esac
    printf '%s\n' "$value"
}
kotlin_version="$(catalog_version kotlin)"
junit_version="$(catalog_version junit)"
test "$kotlin_version" = 2.4.21
compiler_pom="$(cached_file org.jetbrains.kotlin kotlin-compiler-embeddable "$kotlin_version" pom)"
stdlib_pom="$(cached_file org.jetbrains.kotlin kotlin-stdlib "$kotlin_version" pom)"
junit_pom="$(cached_file junit junit "$junit_version" pom)"
compiler="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable "$kotlin_version")"
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib "$kotlin_version")"
test "$(dependency_version "$compiler_pom" kotlin-stdlib)" = "$kotlin_version"
build_tools="$(jar org.jetbrains.kotlin kotlin-build-tools-api "$(dependency_version "$compiler_pom" kotlin-build-tools-api)")"
script_runtime="$(jar org.jetbrains.kotlin kotlin-script-runtime "$(dependency_version "$compiler_pom" kotlin-script-runtime)")"
reflect="$(jar org.jetbrains.kotlin kotlin-reflect "$(dependency_version "$compiler_pom" kotlin-reflect)")"
daemon="$(jar org.jetbrains.kotlin kotlin-daemon-embeddable "$(dependency_version "$compiler_pom" kotlin-daemon-embeddable)")"
compiler_coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm "$(dependency_version "$compiler_pom" kotlinx-coroutines-core-jvm)")"
annotations="$(jar org.jetbrains annotations "$(dependency_version "$stdlib_pom" annotations)")"
junit="$(jar junit junit "$junit_version")"
hamcrest="$(jar org.hamcrest hamcrest-core "$(dependency_version "$junit_pom" hamcrest-core)")"
compiler_cp="$compiler:$build_tools:$stdlib:$script_runtime:$reflect:$daemon:$compiler_coroutines:$annotations"
runtime_cp="$stdlib:$annotations:$junit:$hamcrest"
production_sources=(
    "$app/main/kotlin/com/vortx/android/player/SessionAudioPreset.kt"
    "$app/full/kotlin/com/vortx/android/player/mpv/MpvMetadataLoadIdentity.kt"
    "$seam/main/kotlin/com/vortx/android/player/mpv/seam/MpvNativeHandleGate.kt"
)
test_sources=(
    "$app/test/kotlin/com/vortx/android/player/SessionAudioPresetSessionTest.kt"
    "$app/testFull/kotlin/com/vortx/android/player/mpv/MpvSessionAudioRouteTest.kt"
    "$seam/test/kotlin/com/vortx/android/player/mpv/seam/MpvSessionAudioPresetLeaseTest.kt"
    "$app/test/kotlin/com/vortx/android/player/SessionAudioPresetSourceContractTest.kt"
)
origin_sources=("${production_sources[@]}" "${test_sources[@]}" "$harness"
    "$app/full/kotlin/com/vortx/android/player/mpv/MpvPlayer.kt"
    "$app/full/kotlin/com/vortx/android/player/mpv/MPVLib.kt"
    "$seam/main/kotlin/com/vortx/android/player/mpv/seam/MpvSeam.kt"
    "$app/main/kotlin/com/vortx/android/player/PlayerChrome.kt"
    "$app/main/kotlin/com/vortx/android/player/PlayerScreen.kt"
    "$app/main/kotlin/com/vortx/android/player/PlayerEngine.kt"
    "$app/main/res/values/strings.xml"
    "$app/main/kotlin/com/vortx/android/player/ExoPlayerEngine.kt"
    "$cpp/audio_preset.cpp" "$cpp/property.cpp" "$cpp/main.cpp"
    "$cpp/globals.h" "$cpp/jni_utils.h" "$cpp/include/mpv/client.h"
    "$cpp/CMakeLists.txt" "$repo/android/mpv-seam/build.gradle.kts" "$catalog"
    "$repo/.github/workflows/release-packaging-validation.yml" "$repo/scripts/test-session-audio-presets.sh")
for input in "${origin_sources[@]}"; do
    test -f "$input" || { printf 'Required current-source input missing: %s\n' "$input" >&2; exit 1; }
done
{
    printf 'Actual-source serial audio presets: full current JUnit classes, then full native case table.\n'
    printf 'Kotlin=%s; JUnit=%s; JDK=%s\nrepo=%s\nhead=' "$kotlin_version" "$junit_version" "$jdk_version" "$repo"
    git -C "$repo" rev-parse HEAD
    printf 'JVM CPU1/Xmx512MiB/backendthreads1; nice15; one native C++11 TU.\n'
    printf 'No hard clang CPU/RSS containment claim; no SDK, Gradle, generators or network.\n'
    nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx64m -version 2>&1
} | tee "$receipt/source.log"
shasum -a 256 "${origin_sources[@]}" | tee "$receipt/source-before.sha256"
shasum -a 256 "$compiler_pom" "$stdlib_pom" "$junit_pom" "$compiler" "$build_tools" \
    "$stdlib" "$script_runtime" "$reflect" "$daemon" "$compiler_coroutines" "$annotations" \
    "$junit" "$hamcrest" "$java_bin" "$jdk/release" "$jdk/include/jni.h" \
    "$jdk/include/darwin/jni_md.h" "$clangxx" | tee "$receipt/dependencies.sha256"
verify_inputs() {
    shasum -a 256 -c "$receipt/source-before.sha256" | tee "$receipt/source-$1.log"
    shasum -a 256 -c "$receipt/dependencies.sha256" | tee "$receipt/dependencies-$1.log"
}
# One compilation of the full real declarations and tests. No extracted or replacement policy.
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx512m -cp "$compiler_cp" \
    org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -jvm-target 17 \
    -Xbackend-threads=1 -module-name vortx_session_audio_presets -classpath "$runtime_cp" \
    "${production_sources[@]}" "${test_sources[@]}" -d "$receipt/classes" 2>&1 | tee "$receipt/kotlin-compiler.log"
verify_inputs after-kotlin-compile
(
    cd "$repo/android"
    nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx512m \
        -cp "$receipt/classes:$runtime_cp" org.junit.runner.JUnitCore \
        com.vortx.android.player.SessionAudioPresetSessionTest \
        com.vortx.android.player.mpv.MpvSessionAudioRouteTest \
        com.vortx.android.player.mpv.seam.MpvSessionAudioPresetLeaseTest \
        com.vortx.android.player.SessionAudioPresetSourceContractTest
) 2>&1 | tee "$receipt/kotlin-runtime.log"
verify_inputs after-kotlin-test
# Mandatory binding is the integrated production file. No adjacent/recovery fallback is allowed.
nice -n 15 "$clangxx" -std=c++11 -pthread -O0 \
    "-DVORTX_AUDIO_PRESET_SOURCE=\"$cpp/audio_preset.cpp\"" \
    -I "$cpp" -I "$cpp/include" -I "$jdk/include" -I "$jdk/include/darwin" \
    "$harness" -o "$receipt/audio-preset-transaction-test" 2>&1 | tee "$receipt/native-compiler.log"
verify_inputs after-native-compile
nice -n 15 "$receipt/audio-preset-transaction-test" 2>&1 | tee "$receipt/native-runtime.log"
verify_inputs after-native-test
printf 'Retained serial actual-source audio preset receipt: %s\n' "$receipt"
