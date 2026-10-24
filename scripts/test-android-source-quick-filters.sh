#!/usr/bin/env bash
set -euo pipefail
# One current-catalog serial host lane. NOT Android/Compose or runtime/device acceptance. Never downloads.
test "$#" -eq 0 || { printf 'Usage: bash scripts/test-android-source-quick-filters.sh\n' >&2; exit 2; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cache="${VORTX_GRADLE_MODULE_CACHE:-${HOME}/.gradle/caches/modules-2/files-2.1}"
jdk="${VORTX_TEST_JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
case "$jdk" in /*) ;; *) printf 'VORTX_TEST_JAVA_HOME must be absolute.\n' >&2; exit 2 ;; esac
java_bin="$jdk/bin/java"
test -x "$java_bin" && test -f "$jdk/release"
jdk_version="$(sed -n 's/^JAVA_VERSION="\([^"]*\)"$/\1/p' "$jdk/release")"
case "$jdk_version" in 21|21.*) ;; *) printf 'Need JDK21, found %s.\n' "$jdk_version" >&2; exit 1 ;; esac
command -v rg >/dev/null
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1
catalog="$repo/android/gradle/libs.versions.toml"
mkdir -p "$repo/android/app/build"
receipt="$(mktemp -d "$repo/android/app/build/source-quick-filters.XXXXXX")"
finish() {
    local status=$? dependency_status=0
    trap - EXIT
    set +e
    if test -f "$receipt/dependencies.sha256"; then
        shasum -a 256 -c "$receipt/dependencies.sha256" > "$receipt/dependencies-at-exit.log" 2>&1
        test "$?" -eq 0 || dependency_status=1
    fi
    if test "$status" -eq 0 && test "$dependency_status" -ne 0; then status=1; fi
    printf '%s\n' "$status" > "$receipt/exit-code.txt"
    printf 'Retained host-only quick-filter exit %s receipt: %s\n' "$status" "$receipt"
    exit "$status"
}
trap finish EXIT
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
    if test -n "$property"; then value="$(sed -n "s/.*<$property>\([^<]*\)<\/$property>.*/\1/p" "$1")"; fi
    case "$value" in ''|*[!0-9.]*) printf 'Unresolved POM dependency %s in %s\n' "$2" "$1" >&2; return 1 ;; esac
    printf '%s\n' "$value"
}
kotlin_version="$(catalog_version kotlin)"
compiler_pom="$(cached_file org.jetbrains.kotlin kotlin-compiler-embeddable "$kotlin_version" pom)"
stdlib_pom="$(cached_file org.jetbrains.kotlin kotlin-stdlib "$kotlin_version" pom)"
compiler="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable "$kotlin_version")"
stdlib="$(jar org.jetbrains.kotlin kotlin-stdlib "$kotlin_version")"
test "$(dependency_version "$compiler_pom" kotlin-stdlib)" = "$kotlin_version"
build_tools="$(jar org.jetbrains.kotlin kotlin-build-tools-api "$(dependency_version "$compiler_pom" kotlin-build-tools-api)")"
script_runtime="$(jar org.jetbrains.kotlin kotlin-script-runtime "$(dependency_version "$compiler_pom" kotlin-script-runtime)")"
reflect="$(jar org.jetbrains.kotlin kotlin-reflect "$(dependency_version "$compiler_pom" kotlin-reflect)")"
daemon="$(jar org.jetbrains.kotlin kotlin-daemon-embeddable "$(dependency_version "$compiler_pom" kotlin-daemon-embeddable)")"
compiler_coroutines="$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm "$(dependency_version "$compiler_pom" kotlinx-coroutines-core-jvm)")"
annotations="$(jar org.jetbrains annotations "$(dependency_version "$stdlib_pom" annotations)")"
compiler_cp="$compiler:$build_tools:$stdlib:$script_runtime:$reflect:$daemon:$compiler_coroutines:$annotations"
runtime_cp="$stdlib:$annotations"
shasum -a 256 "$catalog" "$compiler_pom" "$stdlib_pom" "$compiler" "$build_tools" "$stdlib" \
    "$script_runtime" "$reflect" "$daemon" "$compiler_coroutines" "$annotations" "$java_bin" "$jdk/release" \
    "$repo/scripts/test-android-source-quick-filters.sh" "$repo/scripts/tests/android-source-quick-filters.mjs" \
    > "$receipt/dependencies.sha256"
printf 'Kotlin=%s; JDK=%s; JVM CPU1/Xmx512MiB/backendthreads1/nice15; no downloads or Android SDK.\n' \
    "$kotlin_version" "$jdk_version" > "$receipt/source.log"
cd "$repo"
nice -n 15 node "$repo/scripts/tests/android-source-quick-filters.mjs" "$receipt/SourceQuickFilterProbe.kt" \
    > "$receipt/extractor.log" 2>&1
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx512m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -Xbackend-threads=1 -classpath "$runtime_cp" \
    "$receipt/SourceQuickFilterProbe.kt" -d "$receipt/classes" > "$receipt/compiler.log" 2>&1
nice -n 15 "$java_bin" -XX:ActiveProcessorCount=1 -Xmx128m -cp "$receipt/classes:$runtime_cp" \
    SourceQuickFilterProbeKt > "$receipt/runtime.log" 2>&1
nice -n 15 node --input-type=module - "$repo" "$receipt" <<'NODE' > "$receipt/source-conservation.log" 2>&1
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
const [repo, receipt] = process.argv.slice(2);
const previous = JSON.parse(await readFile(resolve(receipt, 'source-before.json'), 'utf8'));
const sha = value => createHash('sha256').update(value).digest('hex');
for (const [path, expected] of Object.entries(previous.inputs)) {
  assert.equal(sha(await readFile(resolve(repo, path))), expected, `source changed during run: ${path}`);
}
assert.equal(sha(await readFile(resolve(receipt, 'SourceQuickFilterProbe.kt'))), previous.generated_sha256, 'generated probe changed during run');
await writeFile(resolve(receipt, 'source-after.json'), JSON.stringify(previous, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
console.log('PASS: actual source and generated-harness bytes conserved');
NODE
printf 'Pure/caller host checks passed; Android JSON trust/ranker JUnit and Compose SDK/device gates remain separate.\n'
