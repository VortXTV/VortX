#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
node --input-type=module <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const manager = fs.readFileSync('app/SourcesShared/VortXSyncManager.swift', 'utf8');
const preparation = manager.split('private func prepareNativeLegacyMaterial(')[1]
    .split('private static func nativeWebsiteEvents')[0];
const capture = preparation.split('let captured = try profiles.compactMap')[1].split('let missingCredentialBindings')[0];
assert.ok(preparation.indexOf('firstImportRecovery(priorSourceArchive, scope: scope)') < preparation.indexOf('let captured = try profiles.compactMap'));
assert.ok(preparation.includes('let resumedPendingOwn = validatedSync == nil ?'));
assert.ok(preparation.includes('if validatedSync == nil, let priorWatchedDraft {'),
    'an established account must not resurrect pending actions from an older migration draft');
assert.ok(capture.includes('if resumedPendingOwn.contains(profile.id)'));
assert.ok(capture.includes('resumedPendingCredentials.append(VortxNativeOwnAccountProducer.capture(slot: slot))'));
const absent = capture.split('guard case .value(let token) = credential, !token.isEmpty else {')[1]
    .split('guard preferredSources')[0];
assert.ok(absent.indexOf('guard case .missing = credential else') < absent.indexOf('newlyMissingOwn.insert(profile.id)'));
assert.ok(absent.includes('missingOwnCredentials[slot] = VortxNativeOwnAccountProducer.capture(slot: slot)'));
assert.ok(capture.indexOf('firstImportRecovery.quarantinedProfiles.contains(profile.id)') < capture.indexOf('return Captured('));
assert.ok(preparation.includes('Array(missingCredentialBindings.values) + resumedPendingCredentials'));
assert.ok(preparation.includes('missingCredentialBindings.keys.allSatisfy'));
assert.ok(preparation.includes('if case .missing = Keychain.confirmedString($0)'));
assert.ok(preparation.includes('VortxNativeOwnAccountProducer.archive([], pendingOverlays: pendingOverlays)'));
assert.ok(preparation.includes('pendingOriginProfileIDs: newlyMissingOwn'));
assert.ok(manager.includes('if remoteNative == nil {\n                        initialActions += try VortxNativeProfiles.pendingLegacyImportActions'));
console.log('PASS first-import manager wiring: missing-only admission, scoped draft origin before capture, generation fences, no UUID reattribution and legacy-only initial CAS (static contracts)');
JS
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
    app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" app/SourcesShared/VortxNativeSession.swift \
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxProfileOverlayWitness.swift \
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
        app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" app/SourcesShared/VortxNativeSession.swift \
        app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxProfileOverlayWitness.swift \
        app/SourcesShared/AuthenticatedHTTPTransport.swift app/SourcesShared/LinkAuthService.swift app/SourcesShared/VortxNativeOwnAccountProducer.swift \
        app/SourcesShared/VortxNativeProfiles.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxNativePreviouslyWatched.swift app/SourcesShared/VortxNativeAccountCredentials.swift \
        "$own_source_dir/UserProfile.swift" "$own_source_dir/Discovery.swift" app/Tests/VortxNativeOwnAccountLiveTests.swift \
        "$VORTX_FFI_LIBRARY" -o "$own_source_dir/own-live"
    DYLD_LIBRARY_PATH="$(dirname "$VORTX_FFI_LIBRARY"):$(dirname "$VORTX_FFI_LIBRARY")/deps" "$own_source_dir/own-live" "$own_source_dir/checkpoints"
    test "$own_library_hash" = "$(shasum -a 256 "$VORTX_FFI_LIBRARY" | awk '{print $1}')"
    test "$own_header_hash" = "$(shasum -a 256 "$VORTX_FFI_HEADER" | awk '{print $1}')"
    printf 'Verified immutable own-account ABI/header: %s %s\n' "$own_library_hash" "$own_header_hash"
fi
