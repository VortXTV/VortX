#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
test "$#" = 2
sdk=$1
proof=$2
baseline=85a46ac4b3ce5ebc75084383d00dc9152b738cb8
library="$sdk/libvortx_ffi.dylib"
header="$sdk/Headers/vortx/vortx_ffi.h"
module="$sdk/Headers/vortx/module.modulemap"
hash() { shasum -a 256 "$1" | cut -d ' ' -f 1; }

test "$(uname -m)" = arm64
test "$(git rev-parse HEAD)" = "${APP_SOURCE:?}"
test "$(git rev-parse HEAD^)" = "$baseline"
test -z "$(git status --porcelain)"
test "$ENGINE_SOURCE" = 2ea2e0f27dd2e53b7b28228435ca35a70f92831f
test "$(hash "$library")" = "${ENGINE_LIBRARY_SHA:?}"
test "$(hash "$header")" = "${ENGINE_HEADER_SHA:?}"
test -d "$proof" && test -z "$(ls -A "$proof")"

source scripts/native-watched-swift-inputs.sh
source scripts/xperience-observation-swift-inputs.sh
source scripts/native-owner-history-fixture-inputs.sh
mkdir -p app/build
scratch=$(mktemp -d "$PWD/app/build/website-roster-loopback.XXXXXXXX")
export VORTX_RECEIVE_PRODUCTION_REF="$baseline" VORTX_RECEIVE_SOURCE_HEAD="$APP_SOURCE"

run_quiet() {
    local label=$1
    shift
    if "$@" > "$scratch/$label.log" 2>&1; then
        printf '%s passed\n' "$label"
    else
        printf '::error::Apple website roster stage failed: %s\n' "$label" >&2
        # Publish fixture locations without printing diagnostic text or private paths.
        sed -nE 's#^.*/([[:alnum:]_-]+\.swift):([0-9]+):([0-9]+): error:.*$#\1:\2:\3#p;
            s#^.*(apple-website-roster\.mjs:[0-9]+:[0-9]+).*$#\1#p' "$scratch/$label.log" \
            | sort -u | awk 'NR <= 24 { print }' >&2
        return 1
    fi
}

run_quiet 'causal-extraction' node test/native-causal-repair.mjs --extract "$scratch"
run_quiet 'website-roster-extraction' node test/extract-apple-website-roster.mjs "$PWD" "$scratch"
inputs=(
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceProjection.swift
    app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift
    "${native_watched_swift_inputs[@]}" "${xperience_observation_swift_inputs[@]}"
    app/SourcesShared/VortxNativeOwnerHistoryIngress.swift app/SourcesShared/LegacyWatchOwnership.swift
    app/SourcesShared/VortxNativeOwnAccountProducer.swift app/SourcesShared/AuthenticatedHTTPTransport.swift
    app/SourcesShared/LinkAuthService.swift app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/LibraryGenreFacts.swift
    app/SourcesShared/VortxNativePreviouslyWatched.swift app/SourcesShared/VortxNativeProfiles.swift
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift
    app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxProfileOverlayWitness.swift
    app/SourcesShared/CatalogRowResolution.swift app/SourcesShared/VortXSyncCrypto.swift
    app/SourcesShared/NativeForegroundSyncPolicy.swift app/SourcesShared/SyncBackupUploadFailure.swift
    app/SourcesShared/AddonReorderMove.swift app/SourcesShared/ProfileRosterSyncPolicy.swift
    app/SourcesShared/PlaybackMutationOwnershipPolicy.swift app/SourcesShared/HomeCatalogLoadPolicy.swift
    app/SourcesShared/TabBarPrefs.swift app/SourcesShared/BecauseYouWatchedHistoryPolicy.swift
    app/SourcesShared/ContinueWatchingPreferences.swift app/SourcesShared/HomeContinueWatchingSelection.swift
    app/SourcesShared/SettingsDirtyKeys.swift app/SourcesShared/SyncDocumentRevisionPolicy.swift
    app/SourcesShared/NativePreferenceIntentStore.swift app/SourcesShared/CredentialRetryCoordinator.swift
    app/SourcesShared/VXProbeRedaction.swift
    "$scratch/UserProfile.swift" "$scratch/Discovery.swift" "$scratch/Models.swift"
    "$scratch/CatalogConsumers.swift" "$scratch/HomeRails.swift" "$scratch/OwnerHistoryFixtureCarriers.swift"
    "$scratch/WebsiteRosterCombined.swift" "$scratch/WebsiteRosterNativeSession.swift"
    "$scratch/WebsiteRosterResourceBridge.swift" "$scratch/WebsiteRosterWatchedTransport.swift"
)
for source in "${native_owner_history_fixture_swift_inputs[@]}"; do
    case "$source" in
        app/SourcesShared/Keychain.swift|app/SourcesShared/CredentialScope.swift|app/SourcesShared/VortxLegacyWatchedMetadataTransport.swift) continue ;;
    esac
    for retained in "${inputs[@]}"; do
        if [[ "$source" == "$retained" ]]; then continue 2; fi
    done
    inputs+=("$source")
done
tracked_helpers=(scripts/test-apple-website-roster.sh
    scripts/native-watched-swift-inputs.sh scripts/xperience-observation-swift-inputs.sh
    scripts/native-owner-history-fixture-inputs.sh
    test/apple-website-roster.mjs test/extract-apple-website-roster.mjs test/AppleWebsiteRosterFixture.swift.in
    test/native-causal-repair.mjs test/apple-sync-receive-publication.mjs
    app/Tests/NativeCausalRepairHarness.swift.in app/Tests/AppleSyncReceivePublicationPeer.swift)
hash_inputs=("$library" "$header" "$module" "$scratch/website-roster-extraction.json" "${tracked_helpers[@]}")
for source in "${inputs[@]}"; do
    [[ "$source" != -lz ]] || continue
    if [[ "$source" == app/SourcesShared/*.swift ]]; then
        expected=$(git show "$baseline:$source" | shasum -a 256 | cut -d ' ' -f 1)
        test "$(hash "$source")" = "$expected"
    fi
    hash_inputs+=("$source")
done
shasum -a 256 "${hash_inputs[@]}" > "$scratch/input-hashes.sha256"
run_quiet 'swift-compile' nice -n 15 xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -warnings-as-errors -j 1 -num-threads 1 -whole-module-optimization \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macosx14.0 \
    -module-cache-path "$scratch/module-cache" -I "$sdk/Headers/vortx" \
    -D CREDENTIAL_RETRY_COORDINATOR_STANDALONE -D VORTX_NATIVE_DATA_ENGINE \
    -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -D VORTX_ENGINE_OWNER_HISTORY_BRIDGE \
    "${inputs[@]}" "$library" -framework Security -framework SystemConfiguration \
    -Xlinker -rpath -Xlinker "$sdk" -o "$scratch/website-roster-peer"

export DYLD_LIBRARY_PATH="${VORTX_FIXTURE_DYLD_LIBRARY_PATH:-$sdk}"
run_quiet 'encrypted-loopback' node test/apple-website-roster.mjs "$scratch/website-roster-peer" "$scratch"
shasum -a 256 --check "$scratch/input-hashes.sha256" > "$scratch/input-post-check.log"
test -z "$(git status --porcelain)"
set -- "$scratch"/apple-website-roster.*/apple-website-roster-receipt.json
test "$#" = 1 && test -f "$1"
jq -cS \
    --arg baseline "$baseline" --arg extraction "$(hash "$scratch/website-roster-extraction.json")" \
    --arg inputs "$(hash "$scratch/input-hashes.sha256")" --arg binary "$(hash "$scratch/website-roster-peer")" \
    --arg runtime "$(hash "$1")" --arg module "$(hash "$module")" \
    '{
      schema: "vortx.apple-website-roster-loopback/1",
      runId: env.GITHUB_RUN_ID, attempt: env.GITHUB_RUN_ATTEMPT, operationsSource: env.GITHUB_SHA,
      fixtureSource: env.APP_SOURCE, baselineSource: $baseline,
      engineSource: env.ENGINE_SOURCE, engineLibrarySHA256: env.ENGINE_LIBRARY_SHA,
      engineHeaderSHA256: env.ENGINE_HEADER_SHA, engineLockSHA256: env.ENGINE_LOCK_SHA,
      engineModuleSHA256: $module, target: env.HOST_TARGET, rustToolchain: env.HOST_TOOLCHAIN,
      xcodeVersion: env.HOST_XCODE_VERSION, xcodeBuild: env.HOST_XCODE_BUILD, sdk: env.HOST_MACOS_SDK_VERSION,
      extractionSHA256: $extraction, inputManifestSHA256: $inputs, executableSHA256: $binary,
      runtimeReceiptSHA256: $runtime, assertions: {promotion: .promotion, changedBase: .changedBase}
    }' "$1" > "$proof/website-roster-apple-proof.json"
(cd "$proof" && shasum -a 256 website-roster-apple-proof.json > website-roster-apple-proof.sha256)
printf 'Apple website roster loopback passed with the unchanged pinned host engine\n'
