#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
mkdir -p app/build
persistence_test_dir=$(mktemp -d "$PWD/app/build/native-persistence.XXXXXX")
persistence_sdk_args=()
persistence_link_args=()
if [[ -n "${VORTX_NATIVE_PERSISTENCE_SDK:-}" ]]; then
    persistence_sdk_library="$VORTX_NATIVE_PERSISTENCE_SDK/libvortx_ffi.a"
    persistence_sdk_hash=$(shasum -a 256 "$persistence_sdk_library" | awk '{print $1}')
    persistence_sdk_args=(-D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -D VORTX_NATIVE_DATA_ENGINE -I "$VORTX_NATIVE_PERSISTENCE_SDK/Headers/vortx")
    persistence_link_args=("$persistence_sdk_library" -framework Security -framework SystemConfiguration)
fi
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$persistence_test_dir/UserProfile.swift"
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$persistence_test_dir/Discovery.swift"
xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    "${persistence_sdk_args[@]}" \
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift \
    app/SourcesShared/VortxResourceProjection.swift app/SourcesShared/VortxNativeBootstrapArchive.swift \
    app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" \
    app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxNativePreviouslyWatched.swift \
    app/SourcesShared/VortxProfileOverlayWitness.swift "$persistence_test_dir/UserProfile.swift" \
    "$persistence_test_dir/Discovery.swift" app/SourcesShared/ProfileAddonPreferences.swift \
    app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxNativeProfileEditHost.swift \
    app/Tests/VortxNativeSessionTests.swift "${persistence_link_args[@]}" -o "$persistence_test_dir/native-session"
"$persistence_test_dir/native-session" "$persistence_test_dir"
node --input-type=module <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const source = fs.readFileSync('app/SourcesShared/CoreBridge.swift', 'utf8');
const sync = fs.readFileSync('app/SourcesShared/VortXSyncManager.swift', 'utf8');
const preparation = sync.split('private func prepareNativeLegacyMaterial')[1].split('private static func nativeWebsiteEvents')[0];
const probe = preparation.split('let probe = try VortxEncryptedCheckpointStore(')[1].split('\n        let remote')[0];
assert.ok(probe.includes('installationKey: VortxNativeInstallationKey.loadOrCreate()'),
    'legacy preparation must authenticate the same multi-account inventory as the opener');
const board = source.split('private func scheduleNativeLegacyBoard(receipt:')[1].split('private static func prepareNativeLegacyBoard')[0];
assert.ok(board.includes('Task.detached(priority: .userInitiated)'),
    'legacy board scheduling must keep preparation in a detached worker');
assert.ok(board.includes('prepareNativeLegacyBoard(receipt: receipt, preferences: preferences)'),
    'legacy board scheduling must use the value-only preparation split');
assert.ok(board.includes('DispatchQueue.main.asyncAfter'),
    'legacy board scheduling must retain debounced cancellation handling');
const nativeBoardPreparation = source.split('private static func prepareNativeLegacyBoard(receipt:')[1].split('\n    }\n', 1)[0];
assert.equal((nativeBoardPreparation.match(/nativeLegacyDecode\(CoreBoardState\.self/g) || []).length, 1);
assert.ok(nativeBoardPreparation.includes('nativeLegacyDecode(CoreBoardState.self, value: receipt.values["board"])'),
    'legacy board preparation must decode the board value in the worker');
assert.ok(nativeBoardPreparation.includes('nativeLegacyDecode(CoreCtx.self, value: receipt.values["ctx"])'),
    'legacy board preparation must decode context in the worker');
assert.ok(!nativeBoardPreparation.includes('JSONEncoder'),
    'legacy board preparation must not encode under the worker split');
assert.ok(!nativeBoardPreparation.includes('JSONSerialization'),
    'legacy board preparation must not use actor-bound JSONSerialization');
for (const name of ['settleResidentNativeSession', 'prepareNativeProfileActionTarget']) {
    const method = source.split(`func ${name}`)[1].split('\n    }')[0];
    assert.ok(method.includes('await facade.settleNativeMutations()'));
    assert.ok(!method.includes('.settled()'));
}
console.log('Board snapshot: detached preparation; value-only/no encoding; profile admission: native FIFO only PASS');
JS
printf 'Retained synthetic receipts: %s\n' "$persistence_test_dir"
if [[ -n "${VORTX_NATIVE_PERSISTENCE_SDK:-}" ]]; then
    test "$persistence_sdk_hash" = "$(shasum -a 256 "$persistence_sdk_library" | awk '{print $1}')"
    printf 'Unchanged packaged SDK library SHA256: %s\n' "$persistence_sdk_hash"
fi
