#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
source scripts/native-owner-history-fixture-inputs.sh
mkdir -p app/build
foreground_dir=$(mktemp -d "$PWD/app/build/native-foreground-sync.XXXXXX")
trap 'rm -rf "$foreground_dir"' EXIT
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$foreground_dir/UserProfile.swift"
{ printf '%s\n' 'import Foundation'; sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift; } > "$foreground_dir/Discovery.swift"
# The session now carries owner history, so compile the shared owner-history closure and its carriers too.
node test/xperience-harness-inputs.cjs --owner-history-carriers "$foreground_dir"
proof_dir=$(mktemp -d "$PWD/app/build/native-subtitle-proofs.XXXXXX")
node scripts/extract-subtitle-proof-hosts.cjs "$PWD" full-shells "$proof_dir/NativeSubtitleProofHosts.swift" > "$proof_dir/native-subtitle-proof-hosts.json"
shasum -a 256 "$0" scripts/extract-subtitle-proof-hosts.cjs app/SourcesShared/CoreBridge.swift \
  app/SourcesShared/LegacyWatchOwnership.swift \
  app/SourcesShared/VortxNativeCoreFacade.swift "$proof_dir/NativeSubtitleProofHosts.swift" \
  "$proof_dir/native-subtitle-proof-hosts.json" > "$proof_dir/subtitle-proof-inputs.sha256"
inputs=(
  "${native_owner_history_fixture_swift_inputs[@]}" "$foreground_dir/OwnerHistoryFixtureCarriers.swift"
  "$proof_dir/NativeSubtitleProofHosts.swift"
  app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift
  app/SourcesShared/VortxResourceProjection.swift app/SourcesShared/VortxNativeBootstrapArchive.swift
  app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}"
  app/SourcesShared/VortxNativeSession.swift app/SourcesShared/ProfileAddonPreferences.swift
  app/SourcesShared/VortxProfileOverlayWitness.swift app/SourcesShared/VortxNativeProfileEditHost.swift
  app/SourcesShared/NativeForegroundSyncPolicy.swift app/SourcesShared/SettingsDirtyKeys.swift
  app/SourcesShared/HomeRailPreferences.swift "$foreground_dir/UserProfile.swift" "$foreground_dir/Discovery.swift"
  app/Tests/NativeForegroundSyncPolicyTests.swift
)
# The shared closures overlap; pass each input once.
unique=()
for input in "${inputs[@]}"; do
  seen=0
  for kept in "${unique[@]+"${unique[@]}"}"; do [[ "$input" == "$kept" ]] && { seen=1; break; }; done
  [[ $seen -eq 0 ]] && unique+=("$input")
done
nice -n 15 xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
    "${unique[@]}" -o "$foreground_dir/foreground-sync"
"$foreground_dir/foreground-sync"
shasum -a 256 --check "$proof_dir/subtitle-proof-inputs.sha256"
printf 'retained subtitle proof source and receipt: %s\n' "$proof_dir"
