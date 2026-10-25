#!/usr/bin/env bash
set -euo pipefail
# Type checks the real For You store, models and views per platform SDK (macOS, tvOS 18, iOS 16)
# against signature stubs (app/Tests/ForYouViewStubs.swift), with and without the native data engine.
# No app build, device, network or account.
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/for-you-views.XXXXXX)
trap 'rm -rf "$dir"' EXIT
proof_dir=$(mktemp -d app/build/native-subtitle-proofs.XXXXXX)
node scripts/extract-subtitle-proof-hosts.cjs "$PWD" bridge-extension-facade-shell "$proof_dir/NativeSubtitleProofHosts.swift" > "$proof_dir/native-subtitle-proof-hosts.json"
shasum -a 256 "$0" scripts/extract-subtitle-proof-hosts.cjs app/SourcesShared/CoreBridge.swift \
  app/SourcesShared/LegacyWatchOwnership.swift \
  app/SourcesShared/VortxNativeCoreFacade.swift "$proof_dir/NativeSubtitleProofHosts.swift" \
  "$proof_dir/native-subtitle-proof-hosts.json" > "$proof_dir/subtitle-proof-inputs.sha256"
{
  printf '%s\n' 'import Foundation'
  sed -n '/^indirect enum VortxJSON/,/^}/p' app/SourcesShared/VortxResourceBridge.swift
  sed -n '/^enum VortxNativeError/,/^}/p' app/SourcesShared/VortxNativeRuntime.swift
  printf '%s\n' 'enum VortxNativeHostPreferences {'
  sed -n '/^    static let forYouPrefix = /,/^    }$/p' app/SourcesShared/VortxNativeHostPreferences.swift
  printf '%s\n' '}'
} > "$dir/support.swift"
# The collection editors now build on the Xperience/curation UI and are compiled by the app targets;
# this check covers the store, models, interests picker and the For You Home sections.
shared=(
  "$dir/support.swift" app/Tests/ForYouViewStubs.swift
  "$proof_dir/NativeSubtitleProofHosts.swift"
  app/SourcesShared/ValueChangeObservation.swift
  app/SourcesShared/ForYouInterests.swift app/SourcesShared/ForYouDiscover.swift app/SourcesShared/ForYouStore.swift
  app/SourcesShared/ForYouRowsModel.swift app/SourcesShared/FlowLayout.swift
  app/SourcesShared/ForYouInterestsView.swift app/SourcesShared/ForYouInterestsEdit.swift
  app/SourcesShared/ForYouLocalStorageDocument.swift app/SourcesShared/CurationCollection.swift
  app/SourcesShared/CurationEdit.swift app/SourcesShared/CurationDocument.swift
  app/SourcesShared/VortxNativeHostFieldMutation.swift app/SourcesShared/CredentialScope.swift
  app/SourcesShared/VortxNativeBootstrapArchive.swift
)
check() {
  local sdk=$1 target=$2
  shift 2
  xcrun --sdk "$sdk" swiftc -typecheck -swift-version 5 -j 1 -num-threads 1 -target "$target" "$@"
  printf 'type-checked: %s %s\n' "$target" "$*" | cut -c1-140
}
check macosx arm64-apple-macos14.0 "${shared[@]}"
check macosx arm64-apple-macos14.0 -D VORTX_NATIVE_DATA_ENGINE "${shared[@]}"
check appletvsimulator arm64-apple-tvos18.0-simulator -D VORTX_NATIVE_DATA_ENGINE "${shared[@]}" \
  app/SourcesTV/ForYouHomeSection.swift
check iphonesimulator arm64-apple-ios16.0-simulator -D VORTX_NATIVE_DATA_ENGINE "${shared[@]}" \
  app/SourcesiOS/iOSForYouSection.swift
echo "for-you views: type-checked on macOS, tvOS and iOS"
shasum -a 256 --check "$proof_dir/subtitle-proof-inputs.sha256"
printf 'retained subtitle proof source and receipt: %s\n' "$proof_dir"
