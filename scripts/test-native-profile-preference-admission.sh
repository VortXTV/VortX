#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
preference_sdk="${VORTX_PREFERENCE_ADMISSION_SDK:-$PWD/app/Vendor/VortxEngine.xcframework/macos-arm64}"
preference_library="$preference_sdk/libvortx_ffi.a"
preference_headers="$preference_sdk/Headers/vortx"
test -f "$preference_library"
test -f "$preference_headers/vortx_ffi.h"
preference_library_hash=$(shasum -a 256 "$preference_library" | awk '{print $1}')
preference_header_hash=$(shasum -a 256 "$preference_headers/vortx_ffi.h" | awk '{print $1}')
preference_module_hash=$(shasum -a 256 "$preference_headers/module.modulemap" | awk '{print $1}')
mkdir -p app/build
preference_test_dir=$(mktemp -d "$PWD/app/build/preference-admission.XXXXXX")
printf 'Static library SHA256 %s\nHeader SHA256 %s\nModule map SHA256 %s\nRetained synthetic output %s\n' "$preference_library_hash" "$preference_header_hash" "$preference_module_hash" "$preference_test_dir"
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$preference_test_dir/UserProfile.swift"
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$preference_test_dir/Discovery.swift"
# Compile the actual in-memory credential registry and exact worker-safe Bridge authority with
# the synthetic installation/Facade seam. This is not a full application target integration.
{
    printf '%s\n' 'import Foundation' \
        'final class CoreBridge {' \
        'private let nativeFacadeLock = NSLock()' 'private var nativeFacadeStorage: VortxNativeCoreFacade?' \
        'private var nativeCredentialCapture: CredentialScopeRegistry.Capture?' 'private var nativeInstallGeneration = UUID()' \
        'init(_ facade: VortxNativeCoreFacade, _ capture: CredentialScopeRegistry.Capture) { nativeFacadeStorage = facade; nativeCredentialCapture = capture }' \
        'func captureAuthority() -> @Sendable () -> Bool {' \
        'let authority = NativeProfilePreferenceAuthority(core: self, facade: nativeFacadeStorage!, credential: nativeCredentialCapture!, installation: nativeInstallGeneration)' \
        'return { authority.isCurrent() }' '}' \
        'func rotateInstallation() { nativeFacadeLock.withLock { nativeInstallGeneration = UUID() } }' \
        'func retireFacade() { nativeFacadeLock.withLock { nativeFacadeStorage = nil } }'
    sed -n '/^    private final class NativeProfilePreferenceAuthority:/,/^    }/p' app/SourcesShared/CoreBridge.swift
    printf '%s\n' '}'
} > "$preference_test_dir/BridgeAuthority.swift"
node scripts/extract-subtitle-proof-hosts.cjs "$PWD" bridge-extension "$preference_test_dir/NativeSubtitleProofHosts.swift" > "$preference_test_dir/native-subtitle-proof-hosts.json"
xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
    -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -D VORTX_NATIVE_DATA_ENGINE -I "$preference_headers" \
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift \
    app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" \
    app/SourcesShared/CredentialScope.swift app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxNativePreviouslyWatched.swift app/SourcesShared/VortxNativeProfiles.swift \
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxProfileOverlayWitness.swift \
    "$preference_test_dir/UserProfile.swift" "$preference_test_dir/Discovery.swift" "$preference_test_dir/BridgeAuthority.swift" "$preference_test_dir/NativeSubtitleProofHosts.swift" app/Tests/NativeProfilePreferenceAdmissionLiveTests.swift \
    "$preference_library" -framework Security -framework SystemConfiguration -o "$preference_test_dir/preference-admission"
"$preference_test_dir/preference-admission" "$preference_test_dir/checkpoints"
test "$preference_library_hash" = "$(shasum -a 256 "$preference_library" | awk '{print $1}')"
test "$preference_header_hash" = "$(shasum -a 256 "$preference_headers/vortx_ffi.h" | awk '{print $1}')"
test "$preference_module_hash" = "$(shasum -a 256 "$preference_headers/module.modulemap" | awk '{print $1}')"
shasum -a 256 app/SourcesShared/CoreBridge.swift app/SourcesShared/VortxNativeCoreFacade.swift \
    app/Tests/NativeProfilePreferenceAdmissionLiveTests.swift scripts/test-native-profile-preference-admission.sh
