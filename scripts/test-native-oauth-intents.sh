#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
source scripts/native-owner-history-fixture-inputs.sh
header="${VORTX_FFI_HEADER:?point at the exact reviewed private header}"
library="${VORTX_FFI_LIBRARY:?point at the matching macOS libvortx_ffi.dylib}"
test -s "$header" && test -s "$library"
library_hash=$(shasum -a 256 "$library" | awk '{print $1}')
header_hash=$(shasum -a 256 "$header" | awk '{print $1}')
mkdir -p app/build
native_oauth_dir=$(mktemp -d "$PWD/app/build/native-oauth.XXXXXX")
# Import and link the same real engine accepted by the protected parent; no stub SDK.
cp "$header" "$native_oauth_dir/vortx_ffi.h"
printf 'module VortxEngine { header "vortx_ffi.h" export * }\n' > "$native_oauth_dir/module.modulemap"
test "$header_hash" = "$(shasum -a 256 "$native_oauth_dir/vortx_ffi.h" | awk '{print $1}')"
native_oauth_sdk=$(xcrun --sdk macosx --show-sdk-path)
native_oauth_target="$(uname -m)-apple-macosx14.0"
shasum -a 256 "$0" scripts/native-watched-swift-inputs.sh scripts/native-owner-history-fixture-inputs.sh \
    test/xperience-harness-inputs.cjs scripts/extract-subtitle-proof-hosts.cjs \
    app/SourcesShared/CoreBridge.swift app/SourcesShared/Profiles.swift app/SourcesShared/LegacyWatchOwnership.swift \
    app/SourcesShared/ProfileDiscoveryPreferences.swift app/SourcesShared/VortXSyncManager.swift \
    app/Tests/SIMKLSessionSecurityTests.swift app/Tests/TraktSessionSecurityTests.swift \
    "$header" "$library" > "$native_oauth_dir/consumed-inputs.sha256"
# Compile the real OAuth actor and exact production journal/linearization methods. Reuse the
# existing injectable secure-store/HTTP seams; no provider request or real Keychain is touched.
sed '/^@main/,$d' app/Tests/SIMKLSessionSecurityTests.swift > "$native_oauth_dir/SIMKLSeams.swift"
sed '/^@main/,$d' app/Tests/TraktSessionSecurityTests.swift > "$native_oauth_dir/TraktSeams.swift"
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$native_oauth_dir/UserProfile.swift"
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$native_oauth_dir/Discovery.swift"
{
    printf '%s\n' 'import Foundation' '@MainActor final class VortXSyncManager {' 'static let shared = VortXSyncManager()'
    printf '%s\n' 'func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { CredentialScopeRegistry.shared.isCurrent(capture) }'
    printf '%s\n' 'var testActorLookupHook: (() -> Void)?' 'var testPreparedHook: (() -> Void)?' 'func nativeHostActor(capture: CredentialScopeRegistry.Capture) throws -> String { let hook = testActorLookupHook; testActorLookupHook = nil; hook?(); return "00000000-0000-0000-0000-000000000001" }' 'func requestSyncSoon() {}'
    sed -n '/^    private func nativeProviderState(/,/^    \/\/\/ Called only after/{ /^    \/\/\/ Called only after/!p; }' app/SourcesShared/VortXSyncManager.swift | sed '/^[[:space:]]*return events$/i\
            let preparedHook = testPreparedHook; testPreparedHook = nil; preparedHook?()\
'
    printf '%s\n' 'func testProviderState(capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { try nativeProviderState(capture: capture) }' '}'
} > "$native_oauth_dir/Journal.swift"
node scripts/extract-subtitle-proof-hosts.cjs "$PWD" full-shells "$native_oauth_dir/NativeSubtitleProofHosts.swift" > "$native_oauth_dir/native-subtitle-proof-hosts.json"
# The full current Session also owns owner history. Reuse its actual shared declarations and
# existing verbatim account/peer carriers instead of inventing a smaller owner-history model.
node test/xperience-harness-inputs.cjs --owner-history-carriers "$native_oauth_dir"
native_oauth_inputs=(
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxNativeBootstrapArchive.swift
    app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}"
    app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxResourceBridge.swift
    app/SourcesShared/VortxResourceProjection.swift app/SourcesShared/VortxNativeSession.swift
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxProfileOverlayWitness.swift
    "$native_oauth_dir/UserProfile.swift" "$native_oauth_dir/Discovery.swift"
    "$native_oauth_dir/Journal.swift" "$native_oauth_dir/NativeSubtitleProofHosts.swift"
    app/SourcesShared/VortxNativeProfileEditHost.swift
    "${native_owner_history_fixture_swift_inputs[@]}" "$native_oauth_dir/OwnerHistoryFixtureCarriers.swift"
)
# Shared closures overlap. The unchanged SIMKL/Trakt seam for each lane supplies its existing
# injectable Keychain, including confirmedString used by the real Xperience export witness;
# compiling the production Keychain as well would redeclare that fixture dependency and touch
# the real secure-store graph. No other owner-history declaration is excluded or replaced.
native_oauth_unique=("${native_oauth_inputs[0]}")
for native_oauth_input in "${native_oauth_inputs[@]}"; do
    [[ "$native_oauth_input" == app/SourcesShared/Keychain.swift ]] && continue
    native_oauth_seen=0
    for native_oauth_retained in "${native_oauth_unique[@]}"; do
        if [[ "$native_oauth_input" == "$native_oauth_retained" ]]; then native_oauth_seen=1; break; fi
    done
    if [[ "$native_oauth_seen" -eq 0 ]]; then native_oauth_unique+=("$native_oauth_input"); fi
done
for native_oauth_input in "${native_oauth_unique[@]}" \
    app/SourcesShared/SIMKLAuth.swift "$native_oauth_dir/SIMKLSeams.swift" app/Tests/VortxNativeOAuthIntentTests.swift \
    app/SourcesShared/TraktAuth.swift app/SourcesShared/TraktScrobbleProgressPolicy.swift app/SourcesShared/VortXEdgeAuth.swift \
    "$native_oauth_dir/TraktSeams.swift" app/Tests/VortxNativeTraktIntentTests.swift \
    "$native_oauth_dir/vortx_ffi.h" "$native_oauth_dir/module.modulemap" "$native_oauth_dir/native-subtitle-proof-hosts.json"; do
    [[ "$native_oauth_input" == -lz ]] || shasum -a 256 "$native_oauth_input" >> "$native_oauth_dir/consumed-inputs.sha256"
done
shasum -a 256 --check "$native_oauth_dir/consumed-inputs.sha256"
nice -n 15 xcrun swiftc -parse-as-library -swift-version 6 -D VORTX_NATIVE_DATA_ENGINE -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
    -sdk "$native_oauth_sdk" -target "$native_oauth_target" -module-cache-path "$native_oauth_dir/module-cache" \
    -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -D VORTX_ENGINE_OWNER_HISTORY_BRIDGE -I "$native_oauth_dir" \
    "${native_oauth_unique[@]}" app/SourcesShared/SIMKLAuth.swift "$native_oauth_dir/SIMKLSeams.swift" \
    app/Tests/VortxNativeOAuthIntentTests.swift "$library" -o "$native_oauth_dir/oauth-intents"
DYLD_LIBRARY_PATH="$(dirname "$library"):$(dirname "$library")/deps" nice -n 15 "$native_oauth_dir/oauth-intents"
nice -n 15 xcrun swiftc -parse-as-library -swift-version 6 -D DEBUG -D VORTX_NATIVE_DATA_ENGINE -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
    -sdk "$native_oauth_sdk" -target "$native_oauth_target" -module-cache-path "$native_oauth_dir/module-cache" \
    -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -D VORTX_ENGINE_OWNER_HISTORY_BRIDGE -I "$native_oauth_dir" \
    "${native_oauth_unique[@]}" app/SourcesShared/TraktAuth.swift \
    app/SourcesShared/TraktScrobbleProgressPolicy.swift app/SourcesShared/VortXEdgeAuth.swift \
    "$native_oauth_dir/TraktSeams.swift" app/Tests/VortxNativeTraktIntentTests.swift "$library" -o "$native_oauth_dir/trakt-intents"
DYLD_LIBRARY_PATH="$(dirname "$library"):$(dirname "$library")/deps" nice -n 15 "$native_oauth_dir/trakt-intents"
shasum -a 256 --check "$native_oauth_dir/consumed-inputs.sha256"
test "$library_hash" = "$(shasum -a 256 "$library" | awk '{print $1}')"
test "$header_hash" = "$(shasum -a 256 "$header" | awk '{print $1}')"
printf 'Native OAuth real-SDK inputs conserved after both original entrypoints\n'
