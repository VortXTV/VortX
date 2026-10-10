#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
publication_sdk="${VORTX_ADDON_PUBLICATION_SDK:-$PWD/app/Vendor/VortxEngine.xcframework/macos-arm64}"
publication_library="$publication_sdk/libvortx_ffi.a"
publication_headers="$publication_sdk/Headers/vortx"
test -f "$publication_library"
test -f "$publication_headers/module.modulemap"
test -f "$publication_headers/vortx_ffi.h"
publication_library_hash=$(shasum -a 256 "$publication_library" | awk '{print $1}')
publication_header_hash=$(shasum -a 256 "$publication_headers/vortx_ffi.h" | awk '{print $1}')
publication_module_hash=$(shasum -a 256 "$publication_headers/module.modulemap" | awk '{print $1}')
mkdir -p app/build
publication_test_dir=$(mktemp -d "$PWD/app/build/addon-publication.XXXXXX")
printf 'Production model SHA256 %s\nStatic library SHA256 %s\nHeader SHA256 %s\nModule map SHA256 %s\nRetained synthetic output %s\n' \
    "$(shasum -a 256 app/SourcesShared/CoreModels.swift | awk '{print $1}')" "$publication_library_hash" "$publication_header_hash" "$publication_module_hash" "$publication_test_dir"
node test/native-addon-publication-fixture-server.mjs "$publication_test_dir/port" "$publication_test_dir/hold-streams" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true' EXIT
for attempt in {1..50}; do
    [[ ! -s "$publication_test_dir/port" ]] || break
    sleep 0.1
done
test -s "$publication_test_dir/port"
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$publication_test_dir/UserProfile.swift"
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$publication_test_dir/Discovery.swift"
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct CoreCtx:/,/^\/\/ MARK: assembled UI row/{ /^\/\/ MARK: assembled UI row/!p; }' app/SourcesShared/CoreModels.swift
} > "$publication_test_dir/AddonModels.swift"
{
    printf '%s\n' 'import Foundation' '@MainActor final class AddonConfirmationProbe {' \
        'let nativeFacade: VortxNativeCoreFacade?' 'var usesNativeProfileState = true' \
        'var addons: [CoreDescriptor] = []' 'var rawAddonsByUrl: [String: [String: Any]] = [:]' \
        'init(nativeFacade: VortxNativeCoreFacade) { self.nativeFacade = nativeFacade }' \
        'func refresh() throws {' \
        'let data = nativeFacade!.stateData("ctx")!' \
        'addons = try JSONDecoder().decode(CoreCtx.self, from: data).profile.addons' \
        'let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]' \
        'let rows = (root["profile"] as! [String: Any])["addons"] as! [[String: Any]]' \
        'rawAddonsByUrl = Dictionary(uniqueKeysWithValues: rows.map { ($0["transportUrl"] as! String, $0) })' '}'
    sed -n '/^    private func confirmedInstalled(/,/^    private static func isRetryable/{ /^    private static func isRetryable/!p; }' app/SourcesShared/CoreBridge.swift \
        | sed 's/private func confirmedInstalled/func confirmedInstalled/'
    printf '%s\n' '}'
} > "$publication_test_dir/AddonConfirmationProbe.swift"
xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -D VORTX_NATIVE_DATA_ENGINE -I "$publication_headers" \
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift \
    app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" \
    app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxNativeProfiles.swift \
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxProfileOverlayWitness.swift \
    app/SourcesShared/CatalogRowResolution.swift "$publication_test_dir/UserProfile.swift" "$publication_test_dir/Discovery.swift" "$publication_test_dir/AddonModels.swift" \
    "$publication_test_dir/AddonConfirmationProbe.swift" app/Tests/AppleAddonPublicationLiveTests.swift "$publication_library" -framework Security -framework SystemConfiguration -o "$publication_test_dir/addon-publication"
"$publication_test_dir/addon-publication" "$(<"$publication_test_dir/port")" "$publication_test_dir/checkpoints" "$publication_test_dir/hold-streams"
test "$publication_library_hash" = "$(shasum -a 256 "$publication_library" | awk '{print $1}')"
test "$publication_header_hash" = "$(shasum -a 256 "$publication_headers/vortx_ffi.h" | awk '{print $1}')"
test "$publication_module_hash" = "$(shasum -a 256 "$publication_headers/module.modulemap" | awk '{print $1}')"
printf 'Verified unchanged static library %s\nVerified unchanged header %s\nVerified unchanged module map %s\nRetained synthetic output %s\n' \
    "$publication_library_hash" "$publication_header_hash" "$publication_module_hash" "$publication_test_dir"
shasum -a 256 app/SourcesShared/CoreBridge.swift app/SourcesShared/VortxNativeCoreFacade.swift \
    app/Tests/AppleAddonPublicationLiveTests.swift test/native-addon-publication-fixture-server.mjs scripts/test-apple-addon-publication.sh
