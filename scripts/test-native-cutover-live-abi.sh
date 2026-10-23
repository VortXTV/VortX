#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
source scripts/native-owner-history-fixture-inputs.sh
header="${VORTX_FFI_HEADER:?point at the exact reviewed private header}"
library="${VORTX_FFI_LIBRARY:?point at the matching macOS libvortx_ffi.dylib}"
library_hash=$(shasum -a 256 "$library" | awk '{print $1}')
header_hash=$(shasum -a 256 "$header" | awk '{print $1}')
mkdir -p app/build
native_live_dir=$(mktemp -d "$PWD/app/build/native-live-abi.XXXXXX")
# Generated import artifacts are retained under ignored build output, never added to public source.
cp "$header" "$native_live_dir/vortx_ffi.h"
printf 'module VortxEngine { header "vortx_ffi.h" export * }\n' > "$native_live_dir/module.modulemap"
node test/native-resource-fixture-server.mjs test/fixtures/native-resource-contract.json "$native_live_dir/port" "$native_live_dir/delay-meta" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true' EXIT
for attempt in {1..50}; do
    [[ ! -s "$native_live_dir/port" ]] || break
    sleep 0.1
done
test -s "$native_live_dir/port"
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$native_live_dir/UserProfile.swift"
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$native_live_dir/Discovery.swift"
shasum -a 256 scripts/native-watched-swift-inputs.sh scripts/native-owner-history-fixture-inputs.sh \
    test/xperience-harness-inputs.cjs app/SourcesShared/Profiles.swift \
    app/SourcesShared/ProfileDiscoveryPreferences.swift "$0" app/SourcesShared/VortXSyncManager.swift > "$native_live_dir/carrier-sources.sha256"
node test/xperience-harness-inputs.cjs --owner-history-carriers "$native_live_dir"
shasum -a 256 --check "$native_live_dir/carrier-sources.sha256"
native_live_inputs=(
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift
    app/SourcesShared/VortxResourceProjection.swift app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxNativePreviouslyWatched.swift
    "$native_live_dir/UserProfile.swift" "$native_live_dir/Discovery.swift" app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxProfileOverlayWitness.swift app/SourcesShared/VortxNativeProfiles.swift app/SourcesShared/VortxNativeProviderCredentials.swift
    app/SourcesShared/VortxNativeProfileEditHost.swift app/Tests/VortxNativeLiveABITests.swift
    app/Tests/OwnerHistorySwiftLiveABICases.swift
    "${native_owner_history_fixture_swift_inputs[@]}" "$native_live_dir/OwnerHistoryFixtureCarriers.swift"
)
# The opt-in real closure overlaps old explicit sources; retain all test entries once.
native_live_unique=("${native_live_inputs[0]}")
for native_live_input in "${native_live_inputs[@]}"; do
  native_live_seen=0
  for native_live_retained in "${native_live_unique[@]}"; do
    if [[ "$native_live_input" == "$native_live_retained" ]]; then native_live_seen=1; break; fi
  done
  if [[ "$native_live_seen" -eq 0 ]]; then native_live_unique+=("$native_live_input"); fi
done
native_live_inputs=("${native_live_unique[@]}")
for native_live_input in "${native_live_inputs[@]}"; do
    [[ "$native_live_input" == -lz ]] || shasum -a 256 "$native_live_input" >> "$native_live_dir/carrier-sources.sha256"
done
nice -n 15 xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -j 1 -num-threads 1 -whole-module-optimization \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$native_live_dir/module-cache" \
    -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -D VORTX_ENGINE_OWNER_HISTORY_BRIDGE -I "$native_live_dir" \
    "${native_live_inputs[@]}" "$library" -o "$native_live_dir/live-abi"
DYLD_LIBRARY_PATH="$(dirname "$library"):$(dirname "$library")/deps" \
    nice -n 15 "$native_live_dir/live-abi" test/fixtures/native-resource-contract.json "$(<"$native_live_dir/port")" "$native_live_dir/checkpoints" "$native_live_dir/delay-meta"
shasum -a 256 --check "$native_live_dir/carrier-sources.sha256"
test "$library_hash" = "$(shasum -a 256 "$library" | awk '{print $1}')"
test "$header_hash" = "$(shasum -a 256 "$header" | awk '{print $1}')"
printf 'Verified unchanged library %s\nVerified unchanged header %s\n' "$library_hash" "$header_hash"
