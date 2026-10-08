#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
header="${VORTX_FFI_HEADER:?exact reviewed private header required}"
library="${VORTX_FFI_LIBRARY:?matching immutable macOS C/JNI dylib required}"
test "$(shasum -a 256 "$library" | awk '{print $1}')" = "${VORTX_FFI_EXPECTED_SHA256:?immutable artifact hash required}"
test "$(shasum -a 256 "$header" | awk '{print $1}')" = "${VORTX_FFI_HEADER_EXPECTED_SHA256:?immutable header hash required}"
app_classes="${VORTX_COMPILED_APP:?exact retained Android app classes required}"
classes_hash="$(shasum -a 256 "$app_classes" | awk '{print $1}')"
mkdir -p app/build
carrier_dir=$(mktemp -d "$PWD/app/build/native-sync-carrier.XXXXXX")
cp "$app_classes" "$carrier_dir/android-app-classes.jar"
test "$(shasum -a 256 "$carrier_dir/android-app-classes.jar" | awk '{print $1}')" = "$classes_hash"
export VORTX_COMPILED_APP="$carrier_dir/android-app-classes.jar"
export VORTX_CARRIER_APP_CLASSES_SHA256="$classes_hash"
export VORTX_CARRIER_PUBLIC_BASE="$(git -C "$PWD" rev-parse HEAD)"
export VORTX_CARRIER_SWIFT_COMPILER="$(xcrun swiftc --version | head -1)"
cp "$header" "$carrier_dir/vortx_ffi.h"
printf 'module VortxEngine { header "vortx_ffi.h" export * }\n' > "$carrier_dir/module.modulemap"
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$carrier_dir/UserProfile.swift"
{ printf '%s\n' 'import Foundation'; sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift; } > "$carrier_dir/Discovery.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -I "$carrier_dir" \
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift \
    app/SourcesShared/VortxResourceProjection.swift app/SourcesShared/VortxNativeBootstrapArchive.swift \
    app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" app/SourcesShared/VortxNativeSession.swift \
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxProfileOverlayWitness.swift \
    app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortXSyncCrypto.swift \
    "$carrier_dir/UserProfile.swift" "$carrier_dir/Discovery.swift" app/Tests/NativeSyncCarrierPeer.swift \
    "$library" -o "$carrier_dir/swift-peer"
source scripts/native-sync-kotlin-peer-inputs.sh
compile_native_sync_kotlin_peer "$carrier_dir"
DYLD_LIBRARY_PATH="$(dirname "$library"):$(dirname "$library")/deps" \
    node test/native-sync-carrier.mjs "$carrier_dir/swift-peer" "$carrier_dir/kotlin-peer" "$carrier_dir"
test "$(shasum -a 256 "$library" | awk '{print $1}')" = "$VORTX_FFI_EXPECTED_SHA256"
test "$(shasum -a 256 "$header" | awk '{print $1}')" = "$VORTX_FFI_HEADER_EXPECTED_SHA256"
printf 'Verified immutable C/JNI artifact %s\n' "$VORTX_FFI_EXPECTED_SHA256"
printf 'Verified immutable header %s\nRetained Android app classes %s\n' "$VORTX_FFI_HEADER_EXPECTED_SHA256" "$classes_hash"
