#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ""|--prepare-only) ;; *) printf 'usage: %s [--prepare-only]\n' "$0" >&2; exit 2 ;; esac
mkdir -p app/build
facade_lock_dir=$(mktemp -d "$PWD/app/build/native-facade-lock.XXXXXX")
printf 'Retained facade lock worker lane: %s\n' "$facade_lock_dir"
facade_lock_inputs=(
    scripts/test-native-facade-lock.sh test/native-facade-lock.mjs test/xperience-harness-inputs.cjs
    app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxNativeFIFOAdmission.swift
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift
    app/SourcesShared/VortxNativeHostFieldMutation.swift
    app/Tests/VortxNativeFIFOAdmissionTests.swift
    app/Tests/VortxNativeFacadeLockTests.swift app/Tests/VortxNativeFacadeLockMain.swift
)
shasum -a 256 "${facade_lock_inputs[@]}" > "$facade_lock_dir/inputs.before.sha256"
facade_lock_exit() {
    local terminal_status=$?
    trap - EXIT
    shasum -a 256 "${facade_lock_inputs[@]}" > "$facade_lock_dir/inputs.after.sha256" || terminal_status=2
    if ! cmp -s "$facade_lock_dir/inputs.before.sha256" "$facade_lock_dir/inputs.after.sha256"; then
        printf 'FAIL: source inputs changed during facade lock verification.\n' >&2
        terminal_status=2
    fi
    printf 'Terminal status %s; retained %s\n' "$terminal_status" "$facade_lock_dir"
    exit "$terminal_status"
}
trap facade_lock_exit EXIT
export VORTX_FACADE_LOCK_SOURCE_HEAD
VORTX_FACADE_LOCK_SOURCE_HEAD=$(git -C "$PWD" rev-parse HEAD)
nice -n 15 node test/native-facade-lock.mjs --extract "$facade_lock_dir"
if [[ ${1:-} == --prepare-only ]]; then exit 0; fi
facade_lock_sdk=$(nice -n 15 xcrun --sdk macosx --show-sdk-path)
facade_lock_platform=$(nice -n 15 xcrun --sdk macosx --show-sdk-platform-path)
facade_lock_frameworks="$facade_lock_platform/Developer/Library/Frameworks"
facade_lock_libraries="$facade_lock_platform/Developer/usr/lib"
test -d "$facade_lock_sdk"
test -d "$facade_lock_frameworks/XCTest.framework"
test -f "$facade_lock_libraries/libXCTestSwiftSupport.dylib"
case "$(uname -m)" in arm64) facade_lock_arch=arm64 ;; x86_64) facade_lock_arch=x86_64 ;; *) exit 2 ;; esac
facade_lock_compile_status=0
nice -n 15 xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -j 1 -num-threads 1 -whole-module-optimization -parse-as-library \
    -sdk "$facade_lock_sdk" -target "$facade_lock_arch-apple-macosx14.0" \
    -module-cache-path "$facade_lock_dir/module-cache" \
    -F "$facade_lock_frameworks" -framework XCTest -I "$facade_lock_libraries" -L "$facade_lock_libraries" \
    -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$facade_lock_frameworks" \
    -Xlinker -rpath -Xlinker "$facade_lock_libraries" \
    "$facade_lock_dir/Combined.swift" "$facade_lock_dir/FIFO.swift" \
    app/Tests/VortxNativeFIFOAdmissionTests.swift app/Tests/VortxNativeFacadeLockMain.swift \
    -o "$facade_lock_dir/facade-lock-tests" > "$facade_lock_dir/compile.log" 2>&1 || facade_lock_compile_status=$?
if (( facade_lock_compile_status != 0 )); then
    cat "$facade_lock_dir/compile.log"
    exit "$facade_lock_compile_status"
fi
facade_lock_run_status=0
nice -n 15 "$facade_lock_dir/facade-lock-tests" > "$facade_lock_dir/run.log" 2>&1 || facade_lock_run_status=$?
cat "$facade_lock_dir/run.log"
shasum -a 256 "$facade_lock_dir/Combined.swift" "$facade_lock_dir/FIFO.swift" \
    "$facade_lock_dir/source-binding.json" "$facade_lock_dir/facade-lock-tests" \
    "$facade_lock_dir/run.log" > "$facade_lock_dir/artifacts.sha256"
exit "$facade_lock_run_status"
