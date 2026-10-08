#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
own_source_dir=$(mktemp -d app/build/native-own-source.XXXXXX)
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$own_source_dir/UserProfile.swift"
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$own_source_dir/Discovery.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    app/SourcesShared/CredentialScope.swift app/SourcesShared/Keychain.swift \
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift \
    app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift app/SourcesShared/VortxNativeSession.swift \
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxProfileOverlayWitness.swift app/SourcesShared/VortxLegacyBootstrapMaterial.swift \
    app/SourcesShared/AuthenticatedHTTPTransport.swift app/SourcesShared/LinkAuthService.swift app/SourcesShared/VortxNativeOwnAccountProducer.swift app/SourcesShared/VortxNativeAccountCredentials.swift \
    "$own_source_dir/UserProfile.swift" "$own_source_dir/Discovery.swift" app/Tests/VortxNativeOwnAccountProducerTests.swift \
    -o "$own_source_dir/own-source"
"$own_source_dir/own-source"
if [[ -n "${VORTX_FFI_LIBRARY:-}" ]]; then
    own_library_hash=$(shasum -a 256 "$VORTX_FFI_LIBRARY" | awk '{print $1}')
    own_header_hash=$(shasum -a 256 "${VORTX_FFI_HEADER:?exact reviewed header required}" | awk '{print $1}')
    cp "$VORTX_FFI_HEADER" "$own_source_dir/vortx_ffi.h"
    printf 'module VortxEngine { header "vortx_ffi.h" export * }\n' > "$own_source_dir/module.modulemap"
    xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
        -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -I "$own_source_dir" \
        app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift \
        app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift app/SourcesShared/VortxNativeSession.swift \
        app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxProfileOverlayWitness.swift app/SourcesShared/VortxLegacyBootstrapMaterial.swift \
        app/SourcesShared/AuthenticatedHTTPTransport.swift app/SourcesShared/LinkAuthService.swift app/SourcesShared/VortxNativeOwnAccountProducer.swift \
        app/SourcesShared/VortxNativeProfiles.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxNativeAccountCredentials.swift \
        "$own_source_dir/UserProfile.swift" "$own_source_dir/Discovery.swift" app/Tests/VortxNativeOwnAccountLiveTests.swift \
        "$VORTX_FFI_LIBRARY" -o "$own_source_dir/own-live"
    DYLD_LIBRARY_PATH="$(dirname "$VORTX_FFI_LIBRARY"):$(dirname "$VORTX_FFI_LIBRARY")/deps" "$own_source_dir/own-live" "$own_source_dir/checkpoints"
    test "$own_library_hash" = "$(shasum -a 256 "$VORTX_FFI_LIBRARY" | awk '{print $1}')"
    test "$own_header_hash" = "$(shasum -a 256 "$VORTX_FFI_HEADER" | awk '{print $1}')"
    printf 'Verified immutable own-account ABI/header: %s %s\n' "$own_library_hash" "$own_header_hash"
fi
