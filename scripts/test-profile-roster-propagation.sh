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
  printf '%s\n' '}'
} > "$profile_test_dir/Observer.swift"
xcrun swiftc -parse-as-library -warnings-as-errors "$profile_test_dir/UserProfile.swift" "$profile_test_dir/Discovery.swift" "$profile_test_dir/Observer.swift" app/SourcesShared/SettingsDirtyKeys.swift app/SourcesShared/ProfileRosterSyncPolicy.swift app/Tests/ProfileRosterPropagationTests.swift -o "$profile_test_dir/profile-tests"
"$profile_test_dir/profile-tests"
