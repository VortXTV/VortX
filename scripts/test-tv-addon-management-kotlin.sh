#!/usr/bin/env bash
set -euo pipefail
# Run the same tests with the immutable Beta-1 production VM, then the actual compiled current VM.
# Compile ONLY the isolated old VM after Full/Play classes/tests have been compiled in the granted slot.
# Never restore a checkout, launch an app, fetch a provider or open a real account.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
baseline=844782d29a93ae51991bfadc639d50bc3619d40b
classpath_file="${VORTX_ADDON_UNIT_CLASSPATH_FILE:?Export the genuine Full/Play unit runtime classpath first}"
java_bin="${VORTX_TEST_JAVA:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java}"
cache_root="${VORTX_GRADLE_MODULE_CACHE:-/Users/daksh/.gradle/caches/modules-2/files-2.1}"
test -f "$classpath_file"
unit_cp="$(<"$classpath_file")"
jar() { rg --files "$cache_root/$1/$2/$3" | rg "/$2-$3.jar$" | head -1; }
compiler_cp="$(jar org.jetbrains.kotlin kotlin-compiler-embeddable 2.2.10):$(jar org.jetbrains.kotlin kotlin-stdlib 2.2.10):$(jar org.jetbrains.kotlin kotlin-reflect 1.6.10):$(jar org.jetbrains annotations 13.0):$(jar org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.10.2)"
mkdir -p "$repo_root/android/app/build"
test_dir="$(mktemp -d "$repo_root/android/app/build/tv-addon-management.XXXXXX")"
git -C "$repo_root" show "$baseline:android/app/src/main/kotlin/com/vortx/android/ui/viewmodel/AddonsViewModel.kt" > "$test_dir/AddonsViewModel.kt"
shasum -a 256 "$test_dir/AddonsViewModel.kt" "$classpath_file" | tee "$test_dir/inputs.sha256"
"$java_bin" -Xmx512m -cp "$compiler_cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -no-reflect -jvm-target 17 -module-name app -Xfriend-paths="${unit_cp//:/,}" \
    -classpath "$unit_cp" "$test_dir/AddonsViewModel.kt" -d "$test_dir/baseline-classes" \
    2>&1 | tee "$test_dir/baseline-compile.log"
set +e
"$java_bin" -Xmx256m -cp "$test_dir/baseline-classes:$unit_cp" org.junit.runner.JUnitCore \
    com.vortx.android.ui.viewmodel.AddonsViewModelOwnershipTest 2>&1 | tee "$test_dir/baseline-red.log"
baseline_status=${PIPESTATUS[0]}
set -e
if [[ "$baseline_status" == 0 ]] || ! rg -q 'Tests run: 8,  Failures: 7' "$test_dir/baseline-red.log"; then
    printf 'Expected seven behavior regressions and one failure-control pass; inspect %s\n' "$test_dir/baseline-red.log" >&2
    exit 1
fi
"$java_bin" -Xmx256m -cp "$unit_cp" org.junit.runner.JUnitCore \
    com.vortx.android.ui.viewmodel.AddonsViewModelOwnershipTest \
    com.vortx.android.ui.viewmodel.AddonsRenderedOwnerTest \
    com.vortx.android.ui.viewmodel.AddonsViewModelHealthTest \
    com.vortx.android.data.AddonManagementTargetTest \
    com.vortx.android.ui.tv.TvAddonManagementPolicyTest \
    com.vortx.android.ui.tv.TvAddonManagementContractTest \
    com.vortx.android.ui.tv.TvAddonsContractTest \
    com.vortx.android.engine.EngineActionsAddonFlagsTest \
    com.vortx.android.sync.AddonPublicationProofsTest 2>&1 | tee "$test_dir/current-green.log"
if [[ "${VORTX_JNI_SYNC:-}" == 1 && -n "${VORTX_JNI_LIBRARY:-}" ]]; then
    test -f "$VORTX_JNI_LIBRARY"
    shasum -a 256 "$VORTX_JNI_LIBRARY" | tee "$test_dir/native-fixture.sha256"
    "$java_bin" -Xmx256m -cp "$unit_cp" org.junit.runner.JUnitCore \
        com.vortx.android.engine.NativeRepositoryMutationJniTest 2>&1 | tee "$test_dir/native-fixture.log"
else
    printf 'Native repository fixture NOT RUN: exact reviewed JNI required.\n' | tee "$test_dir/native-fixture-not-run.log"
fi
printf 'Retained add-on behavior receipts: %s\n' "$test_dir"
