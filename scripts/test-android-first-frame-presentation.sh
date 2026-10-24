#!/usr/bin/env bash
set -euo pipefail
# Offline focused lane only. No Gradle, dependency install, renderer/app launch or network.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo="${VORTX_FIRST_FRAME_REPO:-$(cd "$script_dir/.." && pwd -P)}"
helpers="${VORTX_FIRST_FRAME_HELPERS:-$repo/scripts/tests/android-first-frame-presentation}"
cache="${VORTX_GRADLE_MODULE_CACHE:-${HOME}/.gradle/caches/modules-2/files-2.1}"
java_bin="/opt/homebrew/opt/openjdk@21/bin/java"
java_home="$(cd /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home && pwd -P)"
java_release="$java_home/release"
catalog="$repo/android/gradle/libs.versions.toml"
player="$repo/android/app/src/main/kotlin/com/vortx/android/player"
test_player="$repo/android/app/src/test/kotlin/com/vortx/android/player"
with_exo=false
case "${1:-}" in
    '') ;;
    --with-exo-sdk) with_exo=true ;;
    *) printf 'Usage: %s [--with-exo-sdk]\n' "$0" >&2; exit 2 ;;
esac
test "$#" -le 1
test -f "$catalog"
test -f "$helpers/source-contracts.mjs"
test -x "$java_bin"
test -f "$java_release"
rg -q '^JAVA_VERSION="21([."]|$)' "$java_release"
output_base="$repo/android/app/build/first-frame-focused"
mkdir -p "$output_base"
build_root="$(cd "$repo/android/app/build" && pwd -P)"
output_base="$(cd "$output_base" && pwd -P)"
case "$output_base" in
    "$build_root"/*) ;;
    *) printf 'Focused receipt directory must remain below actual android/app/build.\n' >&2; exit 1 ;;
esac
receipt="$(mktemp -d "$output_base/receipt.XXXXXX")"
finish() {
    local result=$?
    trap - EXIT
    set +e
    printf '%s\n' "$result" > "$receipt/original-exit-code.txt"
    local manifest
    for manifest in source-before dependencies generated sdk-generated; do
        if test -f "$receipt/$manifest.sha256"; then
            shasum -a 256 -c "$receipt/$manifest.sha256" > "$receipt/$manifest-at-exit.log" 2>&1
            if test "$?" -ne 0; then result=1; fi
        fi
    done
    printf '%s\n' "$result" > "$receipt/exit-code.txt"
    printf 'Focused first-frame exit %s; retained receipt: %s\n' "$result" "$receipt"
    exit "$result"
}
trap finish EXIT
printf 'Retaining actual first-frame receipt: %s\n' "$receipt"
catalog_version() {
    local value
    value="$(sed -n "s/^$1 = \"\([0-9][0-9.]*\)\"$/\1/p" "$catalog")"
    test -n "$value" && test "$(printf '%s\n' "$value" | wc -l | tr -d ' ')" -eq 1 || {
        printf 'Need one exact catalog version: %s\n' "$1" >&2; return 1;
    }
    printf '%s\n' "$value"
}
cached_file() {
    local group="$1" artifact="$2" version="$3" extension="$4" candidate
    local matches=() count=0
    while IFS= read -r candidate; do matches+=("$candidate"); count=$((count + 1)); done < <(
        rg --files "$cache/$group/$artifact/$version" -g "$artifact-$version.$extension"
    )
    test "$count" -eq 1 || {
        printf 'Need one cached %s:%s:%s (%s); found %s. No download attempted.\n' \
            "$group" "$artifact" "$version" "$extension" "$count" >&2; return 1;
    }
    printf '%s\n' "${matches[0]}"
}
jar() { cached_file "$1" "$2" "$3" jar; }
dependency_version() {
    local value property
    value="$(sed -n "/<artifactId>$2<\/artifactId>/,/<\/dependency>/p" "$1" |
        sed -n 's/.*<version>\([^<]*\)<\/version>.*/\1/p')"
    test -n "$value" && test "$(printf '%s\n' "$value" | wc -l | tr -d ' ')" -eq 1 || {
        printf 'Need one exact POM dependency version for %s in %s\n' "$2" "$1" >&2; return 1;
    }
    property="$(printf '%s\n' "$value" | sed -n 's/^\${\([A-Za-z][A-Za-z0-9_.-]*\)}$/\1/p')"
    if test -n "$property"; then value="$(sed -n "s/.*<$property>\([^<]*\)<\/$property>.*/\1/p" "$1")"; fi
    case "$value" in ''|*[!0-9A-Za-z.+_-]*) printf 'Unresolved POM version for %s\n' "$2" >&2; return 1 ;; esac
    printf '%s\n' "$value"
}
kotlin_version="$(catalog_version kotlin)"
junit_version="$(catalog_version junit)"
test "$kotlin_version" = 2.4.21
compiler="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable "$kotlin_version")"
compiler_pom="$(cached_file org.jetbrains.kotlin kotlin-compiler-embeddable "$kotlin_version" pom)"
junit_pom="$(cached_file junit junit "$junit_version" pom)"
stdlib_pom="$(cached_file org.jetbrains.kotlin kotlin-stdlib "$kotlin_version" pom)"
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib "$kotlin_version")"
test "$(dependency_version "$compiler_pom" kotlin-stdlib)" = "$kotlin_version"
build_tools="$(jar org.jetbrains.kotlin kotlin-build-tools-api "$(dependency_version "$compiler_pom" kotlin-build-tools-api)")"
script_runtime="$(jar org.jetbrains.kotlin kotlin-script-runtime "$(dependency_version "$compiler_pom" kotlin-script-runtime)")"
reflect="$(jar org.jetbrains.kotlin kotlin-reflect "$(dependency_version "$compiler_pom" kotlin-reflect)")"
daemon="$(jar org.jetbrains.kotlin kotlin-daemon-embeddable "$(dependency_version "$compiler_pom" kotlin-daemon-embeddable)")"
compiler_coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm "$(dependency_version "$compiler_pom" kotlinx-coroutines-core-jvm)")"
# Compiler annotations only; no Android model substitute.
annotations="$(jar org.jetbrains annotations "$(dependency_version "$stdlib_pom" annotations)")"
junit="$(jar junit junit "$junit_version")"
hamcrest="$(jar org.hamcrest hamcrest-core "$(dependency_version "$junit_pom" hamcrest-core)")"
compiler_cp="$compiler:$build_tools:$stdlib:$script_runtime:$reflect:$daemon:$compiler_coroutines:$annotations"
runtime_cp="$stdlib:$annotations:$junit:$hamcrest"
production_sources=("$player/PlaybackStartupPresentation.kt")
test_sources=("$test_player/PlaybackStartupPresentationTest.kt")
test_classes=(com.vortx.android.player.PlaybackStartupPresentationTest)
origin_sources=(
    "$player/PlaybackStartupPresentation.kt" "$test_player/PlaybackStartupPresentationTest.kt"
    "$player/PlayerScreen.kt" "$player/PlayerStartupCover.kt" "$player/PlayerEngine.kt"
    "$player/ExoPlayerEngine.kt" "$player/ExoMetadataInputs.kt" "$test_player/ExoStartupAdmissionTest.kt"
    "$repo/android/app/src/full/kotlin/com/vortx/android/player/mpv/MpvPlayer.kt"
    "$repo/android/app/src/full/kotlin/com/vortx/android/player/mpv/MpvMetadataLoadIdentity.kt"
    "$repo/android/app/src/main/kotlin/com/vortx/android/sources/CanonicalContentIdentity.kt"
    "$repo/android/app/src/main/kotlin/com/vortx/android/metadata/PosterArtwork.kt"
    "$repo/android/app/src/main/kotlin/com/vortx/android/profile/ContinueWatchingOwnerGate.kt"
    "$repo/android/app/src/main/kotlin/com/vortx/android/ui/components/ArtworkFallback.kt"
    "$repo/android/app/src/main/res/values/strings.xml"
    "$catalog" "$repo/android/app/build.gradle.kts" "${BASH_SOURCE[0]}" "$helpers/source-contracts.mjs"
)
dependencies=("$compiler" "$build_tools" "$stdlib" "$script_runtime" "$reflect" "$daemon"
    "$compiler_coroutines" "$annotations" "$junit" "$hamcrest" "$compiler_pom" "$junit_pom" "$stdlib_pom"
    "$java_bin" "$java_release")
sdk_sources=()
sdk_generated=()
if "$with_exo"; then
    media3_version="$(catalog_version media3)"
    common_pom="$(cached_file androidx.media3 media3-common "$media3_version" pom)"
    exo_pom="$(cached_file androidx.media3 media3-exoplayer "$media3_version" pom)"
    sdk_sources+=("$common_pom" "$exo_pom")
    # Real cached Media3 classfiles only, from the exact current catalog version.
    for module in media3-common media3-exoplayer media3-container media3-datasource media3-decoder media3-extractor media3-database; do
        aar="$(cached_file androidx.media3 "$module" "$media3_version" aar)"
        target="$receipt/$module.jar"
        unzip -p "$aar" classes.jar > "$target"
        test -s "$target"
        sdk_sources+=("$aar")
        sdk_generated+=("$target")
        runtime_cp="$runtime_cp:$target"
    done
    guava_version="$(dependency_version "$common_pom" guava)"
    guava="$(jar com.google.guava guava "$guava_version")"
    # Annotation metadata classfiles, not application pin changes. Explicitly recorded test-only inputs.
    annotation_jvm="$(jar androidx.annotation annotation-jvm "${VORTX_FIRST_FRAME_ANNOTATION_JVM_VERSION:-1.10.0}")"
    annotation_experimental="$(cached_file androidx.annotation annotation-experimental "${VORTX_FIRST_FRAME_ANNOTATION_EXPERIMENTAL_VERSION:-1.4.1}" aar)"
    annotation_classes="$receipt/annotation-experimental.jar"
    unzip -p "$annotation_experimental" classes.jar > "$annotation_classes"
    test -s "$annotation_classes"
    sdk_sources+=("$guava" "$annotation_jvm" "$annotation_experimental")
    sdk_generated+=("$annotation_classes")
    runtime_cp="$runtime_cp:$guava:$annotation_jvm:$annotation_classes"
    sdk_root="${ANDROID_HOME:-${HOME}/Library/Android/sdk}"
    compile_sdk="$(sed -n 's/^    compileSdk = \([0-9][0-9]*\)$/\1/p' "$repo/android/app/build.gradle.kts")"
    test -n "$compile_sdk"
    if test -n "${VORTX_FIRST_FRAME_ANDROID_JAR:-}"; then
        android_jar="$VORTX_FIRST_FRAME_ANDROID_JAR"
    else
        sdk_candidates=()
        sdk_candidate_count=0
        for candidate in "$sdk_root/platforms/android-$compile_sdk/android.jar" "$sdk_root/platforms/android-$compile_sdk.0/android.jar"; do
            if test -f "$candidate"; then sdk_candidates+=("$candidate"); sdk_candidate_count=$((sdk_candidate_count + 1)); fi
        done
        test "$sdk_candidate_count" -eq 1 || {
            printf 'Need one real cached compileSdk %s android.jar or explicit VORTX_FIRST_FRAME_ANDROID_JAR; SDK gate remains OPEN.\n' "$compile_sdk" >&2; exit 1;
        }
        android_jar="${sdk_candidates[0]}"
    fi
    test -f "$android_jar"
    sdk_sources+=("$android_jar")
    runtime_cp="$runtime_cp:$android_jar"
    production_sources+=("$player/ExoMetadataInputs.kt")
    test_sources+=("$test_player/ExoStartupAdmissionTest.kt")
    test_classes+=(com.vortx.android.player.ExoStartupAdmissionTest)
    printf 'ATTEMPTING: actual ExoMetadataInputs + 4 actual tests against cached Media3 %s and real compileSdk %s jars. Not device/rendering proof.\n' \
        "$media3_version" "$compile_sdk" > "$receipt/exo-sdk-gate.txt"
else
    printf 'OPEN: Exo actual SDK lane not requested. Four actual Exo tests are NOT executed or counted as passing.\n' > "$receipt/exo-sdk-gate.txt"
fi
{
    printf 'Actual complete startup policy, 14 actual JUnit cases, actual caller source contracts. SDK requested=%s\n' "$with_exo"
    printf 'repo=%s\nhead=' "$repo"
    git -C "$repo" rev-parse HEAD
    git -C "$repo" status --short -- android/app/src/main/kotlin/com/vortx/android/player \
        android/app/src/full/kotlin/com/vortx/android/player/mpv android/app/src/test/kotlin/com/vortx/android/player
    printf 'Kotlin %s / JUnit %s; no fabricated Frame/MediaPeriodId models; no Android/Compose/JNI/device execution.\n' "$kotlin_version" "$junit_version"
    nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx64m -XshowSettings:properties -version 2>&1
} | tee "$receipt/source.log"
test "$(sed -n 's/^[[:space:]]*java.home = //p' "$receipt/source.log")" = "$java_home"
rg -q 'version "21([."]|$)' "$receipt/source.log"
shasum -a 256 "${origin_sources[@]}" | tee "$receipt/source-before.sha256"
if "$with_exo"; then
    shasum -a 256 "${dependencies[@]}" "${sdk_sources[@]}" | tee "$receipt/dependencies.sha256"
else
    shasum -a 256 "${dependencies[@]}" | tee "$receipt/dependencies.sha256"
fi
if "$with_exo"; then
    shasum -a 256 "${sdk_generated[@]}" | tee "$receipt/sdk-generated.sha256"
fi
nice -n 15 node --max-old-space-size=128 "$helpers/source-contracts.mjs" "$repo" "$receipt" | tee "$receipt/source-contracts.log"
shasum -a 256 "$receipt/source-contracts.json" | tee "$receipt/generated.sha256"
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx512m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -Xbackend-threads=1 -module-name vortx_first_frame_focused \
    -classpath "$runtime_cp" "${production_sources[@]}" "${test_sources[@]}" \
    -d "$receipt/classes" 2>&1 | tee "$receipt/compiler.log"
shasum -a 256 -c "$receipt/source-before.sha256" | tee "$receipt/source-after-compile.log"
shasum -a 256 -c "$receipt/dependencies.sha256" | tee "$receipt/dependencies-after-compile.log"
shasum -a 256 -c "$receipt/generated.sha256" | tee "$receipt/generated-after-compile.log"
if test -f "$receipt/sdk-generated.sha256"; then shasum -a 256 -c "$receipt/sdk-generated.sha256" | tee "$receipt/sdk-after-compile.log"; fi
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx512m -cp "$receipt/classes:$runtime_cp" \
    org.junit.runner.JUnitCore "${test_classes[@]}" 2>&1 | tee "$receipt/runtime.log"
shasum -a 256 -c "$receipt/source-before.sha256" | tee "$receipt/source-after-test.log"
shasum -a 256 -c "$receipt/dependencies.sha256" | tee "$receipt/dependencies-after-test.log"
shasum -a 256 -c "$receipt/generated.sha256" | tee "$receipt/generated-after-test.log"
if test -f "$receipt/sdk-generated.sha256"; then shasum -a 256 -c "$receipt/sdk-generated.sha256" | tee "$receipt/sdk-after-test.log"; fi
if "$with_exo"; then
    printf 'PASS: whole actual ExoMetadataInputs plus 4 actual SDK-admission cases. No Android rendering/device claim.\n' > "$receipt/exo-sdk-gate.txt"
    printf 'Actual JUnit lane passed: 14 pure policy + 4 real-library Exo admission tests; see source-contracts.json separately.\n'
else
    printf 'Actual JUnit lane passed: 14 pure policy tests; Exo SDK gate remains OPEN (not run). See source-contracts.json separately.\n'
fi
