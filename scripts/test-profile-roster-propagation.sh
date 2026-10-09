#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
profile_test_dir=$(mktemp -d app/build/profile-propagation.XXXXXX)
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$profile_test_dir/UserProfile.swift"
{
  printf '%s\n' 'import Foundation'
  sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$profile_test_dir/Discovery.swift"
{
  printf '%s\n' 'import Foundation' 'extension ObserverFixture {'
  sed -n '/^    private func noteLocalSettingsChange() -> Bool {/,/^    }/p' app/SourcesShared/VortXSyncManager.swift | sed 's/private func /func /'
  sed -n '/^    private func observeDefaultsChange() {/,/^    }/p' app/SourcesShared/VortXSyncManager.swift | sed 's/private func /func /'
  sed -n '/^    private func noteLocalRosterMutation() {/,/^    }/p' app/SourcesShared/VortXSyncManager.swift | sed 's/private func /func /'
  sed -n '/^    private func drainLocalRosterPush() {/,/^    }/p' app/SourcesShared/VortXSyncManager.swift | sed 's/private func /func /'
  printf '%s\n' '}'
} > "$profile_test_dir/Observer.swift"
xcrun swiftc -parse-as-library -warnings-as-errors "$profile_test_dir/UserProfile.swift" "$profile_test_dir/Discovery.swift" "$profile_test_dir/Observer.swift" app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/SettingsDirtyKeys.swift app/SourcesShared/ProfileRosterSyncPolicy.swift app/Tests/ProfileRosterPropagationTests.swift -o "$profile_test_dir/profile-tests"
"$profile_test_dir/profile-tests"
# The executed marker/drain must be wired to genuine successful persistence, not housekeeping.
node --input-type=module -e '
import {readFileSync} from "node:fs";
import assert from "node:assert/strict";
const p=readFileSync("app/SourcesShared/Profiles.swift","utf8");
const body=p.slice(p.indexOf("    private func persist(touch:"),p.indexOf("    // MARK: Delete tombstones"));
assert(body.includes("guard let data = try? JSONEncoder().encode(profiles) else { return }"));
const genuine=body.slice(body.indexOf("if touch && !applyingProfileEdits"),body.indexOf("        } else {"));
assert(genuine.indexOf("writeRosterAndActive()")<genuine.indexOf("localRosterDidPersist()"));
assert(genuine.indexOf("localRosterDidPersist()")<genuine.indexOf("schedulePushRoster()"));
assert(!body.slice(body.indexOf("        } else {")).includes("localRosterDidPersist()"));
const s=readFileSync("app/SourcesShared/VortXSyncManager.swift","utf8");
assert(s.includes("self?.isApplyingRemote = false\n            self?.drainLocalRosterPush()"));
console.log("PASS synchronous roster persistence and post-suppression drain wiring");'
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors app/SourcesShared/ProfileMutationPresentation.swift app/Tests/ProfileMutationPresentationTests.swift -o "$profile_test_dir/profile-presentation"
"$profile_test_dir/profile-presentation"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors app/SourcesShared/NativeProfileActionPreparation.swift app/Tests/NativeProfileActionPreparationTests.swift -o "$profile_test_dir/profile-preparation"
"$profile_test_dir/profile-preparation"
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/ProfilePickerLayout.swift app/Tests/ProfilePickerLayoutTests.swift -o "$profile_test_dir/profile-picker-layout"
"$profile_test_dir/profile-picker-layout"
