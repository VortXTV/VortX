#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
native_oauth_dir=$(mktemp -d app/build/native-oauth.XXXXXX)
# Compile the real OAuth actor and exact production journal/linearization methods. Reuse the
# existing injectable secure-store/HTTP seams; no provider request or real Keychain is touched.
sed '/^@main/,$d' app/Tests/SIMKLSessionSecurityTests.swift > "$native_oauth_dir/SIMKLSeams.swift"
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$native_oauth_dir/UserProfile.swift"
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$native_oauth_dir/Discovery.swift"
{
    printf '%s\n' 'import Foundation' '@MainActor final class VortXSyncManager {' 'static let shared = VortXSyncManager()'
    printf '%s\n' 'func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { CredentialScopeRegistry.shared.isCurrent(capture) }'
    printf '%s\n' 'func nativeHostActor(capture: CredentialScopeRegistry.Capture) throws -> String { "00000000-0000-0000-0000-000000000001" }' 'func requestSyncSoon() {}'
    sed -n '/^    private func nativeProviderState(/,/^    \/\/\/ Called only after/{ /^    \/\/\/ Called only after/!p; }' app/SourcesShared/VortXSyncManager.swift
    printf '%s\n' 'func testProviderState(capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { try nativeProviderState(capture: capture) }' '}'
} > "$native_oauth_dir/Journal.swift"
xcrun swiftc -parse-as-library -D VORTX_NATIVE_DATA_ENGINE -strict-concurrency=complete -warnings-as-errors \
    app/SourcesShared/CredentialScope.swift app/SourcesShared/AuthenticatedHTTPTransport.swift app/SourcesShared/SIMKLAuth.swift \
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift \
    app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift \
    app/SourcesShared/VortxNativeSession.swift app/SourcesShared/ProfileAddonPreferences.swift \
    "$native_oauth_dir/UserProfile.swift" "$native_oauth_dir/Discovery.swift" "$native_oauth_dir/SIMKLSeams.swift" "$native_oauth_dir/Journal.swift" \
    app/Tests/VortxNativeOAuthIntentTests.swift -o "$native_oauth_dir/oauth-intents"
"$native_oauth_dir/oauth-intents"
sed '/^@main/,$d' app/Tests/TraktSessionSecurityTests.swift > "$native_oauth_dir/TraktSeams.swift"
xcrun swiftc -parse-as-library -D DEBUG -D VORTX_NATIVE_DATA_ENGINE -strict-concurrency=complete -warnings-as-errors \
    app/SourcesShared/CredentialScope.swift app/SourcesShared/AuthenticatedHTTPTransport.swift app/SourcesShared/TraktAuth.swift \
    app/SourcesShared/TraktScrobbleProgressPolicy.swift app/SourcesShared/VortXEdgeAuth.swift \
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift \
    app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift \
    app/SourcesShared/VortxNativeSession.swift app/SourcesShared/ProfileAddonPreferences.swift \
    "$native_oauth_dir/UserProfile.swift" "$native_oauth_dir/Discovery.swift" "$native_oauth_dir/TraktSeams.swift" "$native_oauth_dir/Journal.swift" \
    app/Tests/VortxNativeTraktIntentTests.swift -o "$native_oauth_dir/trakt-intents"
"$native_oauth_dir/trakt-intents"
