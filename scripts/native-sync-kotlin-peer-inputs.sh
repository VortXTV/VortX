#!/usr/bin/env bash
set -euo pipefail

# Source this file from the native carrier acceptance runner. The function below compiles the
# actual Kotlin peer once and leaves a reusable cold-process launcher at <carrier-dir>/kotlin-peer.
# It intentionally shares the dependency lookup used by test-native-watched-migration-kotlin.sh.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${VORTX_GRADLE_MODULE_CACHE:-/Users/daksh/.gradle/caches/modules-2/files-2.1}"
java_bin="${VORTX_TEST_JAVA:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java}"
app_classes="${VORTX_COMPILED_APP:?Exact retained actual Android app classes required}"
android_jar="${VORTX_ANDROID_JAR:-/Users/daksh/Library/Android/sdk/platforms/android-36/android.jar}"

jar_path() {
    rg --files "$cache_root/$1/$2/$3" | rg "/$2-$3.jar$" | head -1
}

compile_native_sync_kotlin_peer() {
    local carrier_dir="${1:?carrier output directory is required}"
    local fixture_library="${VORTX_FFI_LIBRARY:-${VORTX_JNI_LIBRARY:-}}"
    local fixture_sha="${VORTX_FFI_EXPECTED_SHA256:-${VORTX_JNI_EXPECTED_SHA256:-}}"
    test -n "$fixture_library"
    test -n "$fixture_sha"
    test -f "$fixture_library"
    test "$(shasum -a 256 "$fixture_library" | awk '{print $1}')" = "$fixture_sha"
    test -f "$app_classes"
    test -f "$android_jar"
    test -x "$java_bin"

    local compiler stdlib reflect annotations coroutines json compiler_cp test_cp classes_dir launcher
    compiler="$(jar_path org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10)"
    stdlib="$(jar_path org.jetbrains.kotlin kotlin-stdlib 2.2.10)"
    reflect="$(jar_path org.jetbrains.kotlin kotlin-reflect 1.6.10)"
    annotations="$(jar_path org.jetbrains annotations 13.0)"
    coroutines="$(jar_path org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
    json="$(jar_path org.json json 20240303)"
    compiler_cp="$compiler:$stdlib:$reflect:$annotations:$coroutines"
    test_cp="$app_classes:$stdlib:$annotations:$coroutines:$json:$android_jar"
    export VORTX_CARRIER_KOTLIN_COMPILER_SHA256="$(shasum -a 256 "$compiler" | awk '{print $1}')"
    export VORTX_CARRIER_JAVA_RUNTIME="$("$java_bin" -version 2>&1 | head -1)"

    mkdir -p "$carrier_dir"
    classes_dir="$carrier_dir/kotlin-classes"
    mkdir -p "$classes_dir"
    "$java_bin" -Xmx1g -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
        -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="$app_classes" -classpath "$test_cp" \
        "$repo_root/android/app/src/test/kotlin/com/vortx/android/sync/NativeSyncCarrierPeer.kt" \
        -d "$classes_dir"

    launcher="$carrier_dir/kotlin-peer"
    local q_library q_sha q_java q_classes q_test_cp
    printf -v q_library '%q' "$fixture_library"
    printf -v q_sha '%q' "$fixture_sha"
    printf -v q_java '%q' "$java_bin"
    printf -v q_classes '%q' "$classes_dir"
    printf -v q_test_cp '%q' "$test_cp"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
        printf 'fixture_library=${VORTX_FFI_LIBRARY:-${VORTX_JNI_LIBRARY:-%s}}\n' "$q_library"
        printf 'fixture_sha=${VORTX_FFI_EXPECTED_SHA256:-${VORTX_JNI_EXPECTED_SHA256:-%s}}\n' "$q_sha"
        printf 'test -f "$fixture_library"\n'
        printf 'test "$(shasum -a 256 "$fixture_library" | awk '\''{print $1}'\'')" = "$fixture_sha"\n'
        printf 'exec env VORTX_JNI_LIBRARY="$fixture_library" %s -Xmx512m -cp %s com.vortx.android.sync.NativeSyncCarrierPeer "$@"\n' \
            "$q_java" "$q_classes:$q_test_cp"
    } > "$launcher"
    chmod +x "$launcher"
}

# Retain a direct one-input mode for local diagnosis while keeping source mode side-effect free
# until compile_native_sync_kotlin_peer is called by the acceptance runner.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "$#" -ne 1 ]]; then
        printf '%s\n' '{"accepted":false,"error":"expected one JSON input path"}'
        exit 2
    fi
    mkdir -p "$repo_root/android/app/build"
    direct_dir="$(mktemp -d "$repo_root/android/app/build/native-sync-kotlin-peer.XXXXXX")"
    compile_native_sync_kotlin_peer "$direct_dir"
    exec "$direct_dir/kotlin-peer" "$1"
fi
