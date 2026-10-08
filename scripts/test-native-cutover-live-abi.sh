#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
header="${VORTX_FFI_HEADER:?point at the exact reviewed private header}"
library="${VORTX_FFI_LIBRARY:?point at the matching macOS libvortx_ffi.dylib}"
library_hash=$(shasum -a 256 "$library" | awk '{print $1}')
header_hash=$(shasum -a 256 "$header" | awk '{print $1}')
mkdir -p app/build
native_live_dir=$(mktemp -d "$PWD/app/build/native-live-abi.XXXXXX")
# Generated import artifacts are retained under ignored build output, never added to public source.
cp "$header" "$native_live_dir/vortx_ffi.h"
printf 'module VortxEngine { header "vortx_ffi.h" export * }\n' > "$native_live_dir/module.modulemap"
node test/native-resource-fixture-server.mjs test/fixtures/native-resource-contract.json "$native_live_dir/port" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true' EXIT
for attempt in {1..50}; do
    [[ ! -s "$native_live_dir/port" ]] || break
    sleep 0.1
done
test -s "$native_live_dir/port"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -I "$native_live_dir" \
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift \
    app/SourcesShared/VortxResourceProjection.swift app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeCoreFacade.swift \
    app/Tests/VortxNativeLiveABITests.swift "$library" -o "$native_live_dir/live-abi"
DYLD_LIBRARY_PATH="$(dirname "$library"):$(dirname "$library")/deps" \
    "$native_live_dir/live-abi" test/fixtures/native-resource-contract.json "$(<"$native_live_dir/port")" "$native_live_dir/checkpoints"
test "$library_hash" = "$(shasum -a 256 "$library" | awk '{print $1}')"
test "$header_hash" = "$(shasum -a 256 "$header" | awk '{print $1}')"
printf 'Verified unchanged library %s\nVerified unchanged header %s\n' "$library_hash" "$header_hash"
