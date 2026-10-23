#!/usr/bin/env bash
# Standalone current-source JVM regression gate; no Gradle, package build, network, or device.
set -euo pipefail
workspace=/Users/daksh/VortXTV
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app="$(cd -- "$script_dir/.." && pwd)"
java_bin=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java
kotlin_lib=/Users/daksh/.gradle/wrapper/dists/gradle-8.11.1-bin/bpt9gzteqjrbo1mjrsomdt32c/gradle-8.11.1/lib
deps="$workspace/_build/audit-20261017-android-toolchain"
mode="${1:-positive}"
case "$mode" in positive|negative-scope|prepare) ;; *) echo 'Expected positive, negative-scope, or prepare' >&2; exit 2 ;; esac
source_mode="$mode"
if [[ "$mode" == prepare ]]; then source_mode=positive; fi
for file in "$java_bin" "$kotlin_lib/kotlin-stdlib-2.0.20.jar" \
  "$kotlin_lib/kotlin-compiler-embeddable-2.0.20.jar" "$kotlin_lib/kotlinx-coroutines-core-jvm-1.6.4.jar" \
  "$deps/json-20240303.jar" "$deps/okhttp-4.12.0.jar" "$deps/okio-jvm-3.6.0.jar" \
  "$deps/junit-4.13.2.jar" "$deps/hamcrest-core-1.3.jar"; do
  [[ -f "$file" ]] || { echo "Missing retained dependency: $file; no download or fallback authorized" >&2; exit 2; }
done
output_root="$workspace/_build/repair-20261018-android-watched-final-tests"
mkdir -p "$output_root"
run_dir="$(mktemp -d "$output_root/$source_mode.XXXXXX")"
mkdir -p "$run_dir/classes" "$run_dir/logs" "$run_dir/tmp"
printf 'Retained run directory: %s\n' "$run_dir"
node --max-old-space-size=128 "$app/scripts/prepare-android-watched-final.mjs" "$app" "$run_dir" "$source_mode" \
  2>&1 | tee "$run_dir/logs/preparation.log"
git -C "$app" rev-parse HEAD > "$run_dir/logs/worktree-head.txt"
if [[ "$mode" == prepare ]]; then exit 0; fi

test_cp="$kotlin_lib/kotlin-stdlib-2.0.20.jar:$kotlin_lib/kotlinx-coroutines-core-jvm-1.6.4.jar:$deps/okhttp-4.12.0.jar:$deps/okio-jvm-3.6.0.jar:$deps/json-20240303.jar:$deps/junit-4.13.2.jar:$deps/hamcrest-core-1.3.jar"
printf '%s\n' "$test_cp" > "$run_dir/logs/test-classpath.txt"
shasum -a 256 "$java_bin" "$kotlin_lib"/*.jar "$deps/json-20240303.jar" \
  "$deps/okhttp-4.12.0.jar" "$deps/okio-jvm-3.6.0.jar" "$deps/junit-4.13.2.jar" "$deps/hamcrest-core-1.3.jar" \
  > "$run_dir/logs/classpath-sha256.txt"
sources=()
while IFS= read -r source; do sources+=("$source"); done < "$run_dir/sources.list"
# Foreground, sequential JVMs only. No daemon, Gradle, worker pool, dependency operation, or APK task.
# If these caps fail, preserve the receipt and ask root to reschedule; do not automatically increase.
jvm=(-XX:ActiveProcessorCount=1 -XX:+UseSerialGC -Xms32m -Xmx384m -XX:MaxMetaspaceSize=192m \
  -Djava.io.tmpdir="$run_dir/tmp" -Dkotlinx.coroutines.io.parallelism=1 \
  -Dkotlinx.coroutines.scheduler.core.pool.size=1 -Dkotlinx.coroutines.scheduler.max.pool.size=2)
"$java_bin" "${jvm[@]}" -version 2> "$run_dir/logs/java-version.txt"
"$java_bin" "${jvm[@]}" -cp "$kotlin_lib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-stdlib -no-reflect -version 2>&1 | tee "$run_dir/logs/compiler-version.txt"
"$java_bin" "${jvm[@]}" -cp "$kotlin_lib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-stdlib -no-reflect -jvm-target 17 -classpath "$test_cp" "${sources[@]}" \
  -d "$run_dir/classes" 2>&1 | tee "$run_dir/logs/compile.log"

cd "$app"
if [[ "$source_mode" == negative-scope ]]; then
  # Deliberately removes only the admission fence in the generated copy. All eight behavioral
  # rejection cases must now fail; a compilation error is NOT a successful negative control.
  set +e
  "$java_bin" "${jvm[@]}" -cp "$run_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.engine.RepairWatchedFinalScopeFenceTest 2>&1 | tee "$run_dir/logs/junit.log"
  junit_status=${PIPESTATUS[0]}
  set -e
  missing_rejection_failures="$(rg -c '^java.lang.AssertionError: Expected actual production admission rejection, got null$' "$run_dir/logs/junit.log" || true)"
  [[ "$junit_status" == 1 && "$missing_rejection_failures" == 8 ]] && rg -q 'Tests run: 8,  Failures: 8' "$run_dir/logs/junit.log" || {
    echo 'Negative control did not produce the expected eight behavioral failures; gate remains HOLD' >&2; exit 1;
  }
  printf 'Expected behavioral negative control: 8/8 rejection assertions fail with only scope fence omitted.\n' \
    | tee "$run_dir/logs/negative-control-receipt.txt"
else
  "$java_bin" "${jvm[@]}" -cp "$run_dir/classes:$test_cp" org.junit.runner.JUnitCore \
    com.vortx.android.engine.LegacyWatchedBitfieldMigrationEvidenceTest \
    com.vortx.android.engine.LegacyWatchedBitfieldDecoderTest \
    com.vortx.android.engine.RepairWatchedStorageTest \
    com.vortx.android.engine.RepairWatchedCheckpointTest \
    com.vortx.android.engine.RepairWatchedFinalScopeTest \
    com.vortx.android.engine.RepairWatchedFinalScopeFenceTest 2>&1 | tee "$run_dir/logs/junit.log"
fi
printf 'Retained source manifest, classpath, compiler and JUnit receipts: %s/logs\n' "$run_dir"
