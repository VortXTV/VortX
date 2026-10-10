#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
# Pin to the packaged static ABI; a stale development dylib is never a valid substitute.
membership_sdk="${VORTX_MEMBERSHIP_SDK:-$PWD/app/Vendor/VortxEngine.xcframework/macos-arm64}"
membership_library="$membership_sdk/libvortx_ffi.a"
membership_headers="$membership_sdk/Headers/vortx"
test -f "$membership_library"
test -f "$membership_headers/module.modulemap"
test -f "$membership_headers/vortx_ffi.h"
membership_library_hash=$(shasum -a 256 "$membership_library" | awk '{print $1}')
membership_header_hash=$(shasum -a 256 "$membership_headers/vortx_ffi.h" | awk '{print $1}')
membership_module_hash=$(shasum -a 256 "$membership_headers/module.modulemap" | awk '{print $1}')
mkdir -p app/build
membership_test_dir=$(mktemp -d "$PWD/app/build/native-membership-receipts.XXXXXX")
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$membership_test_dir/UserProfile.swift"
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$membership_test_dir/Discovery.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -I "$membership_headers" \
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift \
    app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" \
    app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeProfiles.swift \
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxProfileOverlayWitness.swift \
    "$membership_test_dir/UserProfile.swift" "$membership_test_dir/Discovery.swift" app/Tests/VortxNativeMembershipReceiptLiveTests.swift \
    "$membership_library" -framework Security -framework SystemConfiguration -o "$membership_test_dir/membership-live"
"$membership_test_dir/membership-live" "$membership_test_dir/checkpoints"
test "$membership_library_hash" = "$(shasum -a 256 "$membership_library" | awk '{print $1}')"
test "$membership_header_hash" = "$(shasum -a 256 "$membership_headers/vortx_ffi.h" | awk '{print $1}')"
test "$membership_module_hash" = "$(shasum -a 256 "$membership_headers/module.modulemap" | awk '{print $1}')"
printf 'Verified unchanged packaged static library: %s\nVerified unchanged header: %s\nVerified unchanged module map: %s\nRetained synthetic test output: %s\n' \
    "$membership_library_hash" "$membership_header_hash" "$membership_module_hash" "$membership_test_dir"
