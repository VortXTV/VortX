#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
profile_test_dir=$(mktemp -d app/build/profile-addons.XXXXXX)
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$profile_test_dir/UserProfile.swift"
{
  printf '%s\n' 'import Foundation'
  sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$profile_test_dir/Discovery.swift"
{
  printf '%s\n' 'import Foundation' 'extension ProfileStore {'
  for method in 'toggleAddon' 'isAddonDisabledForActive' 'addonPreferences' 'effectiveDisabledAddons' 'effectiveAddonRanking' 'applyAddonPreferences' 'customizeAddonVisibility' 'resetAddonVisibilityToMain' 'customizeAddonRanking' 'resetAddonRankingToMain' 'setAddonOrder' 'capturePlayback'; do
    sed -n "/^    .*func ${method}(/,/^    }/p" app/SourcesShared/Profiles.swift | sed 's/private func /func /'
  done
  sed -n '/^    var activeSharesMainAddons:/p' app/SourcesShared/Profiles.swift
  sed -n '/^    var activeInheritsAddonVisibility:/,/^    }/p' app/SourcesShared/Profiles.swift
  sed -n '/^    var activeInheritsAddonRanking:/,/^    }/p' app/SourcesShared/Profiles.swift
  sed -n '/^    private var ownerAddonRanking:/,/^    }/p' app/SourcesShared/Profiles.swift | sed 's/private var /var /'
  sed -n '/^    static func activeAddonOrder(/,/^    }/p' app/SourcesShared/Profiles.swift
  printf '%s\n' '}'
} > "$profile_test_dir/LiveMethods.swift"
for profile_test_mode in legacy native; do
  profile_test_flags=()
  if [[ "$profile_test_mode" == native ]]; then profile_test_flags=(-D VORTX_NATIVE_DATA_ENGINE); fi
  xcrun swiftc -parse-as-library -warnings-as-errors "${profile_test_flags[@]}" \
    "$profile_test_dir/UserProfile.swift" "$profile_test_dir/Discovery.swift" "$profile_test_dir/LiveMethods.swift" \
    app/SourcesShared/ProfileAddonPreferences.swift app/Tests/ProfileAddonPreferencesTests.swift \
    -o "$profile_test_dir/profile-addon-tests-$profile_test_mode"
  "$profile_test_dir/profile-addon-tests-$profile_test_mode"
done

# Parsing all touched shipping files catches both platform branches without starting an app or media.
xcrun swiftc -frontend -parse app/SourcesShared/Profiles.swift app/SourcesShared/ProfileAddonPreferences.swift \
  app/SourcesShared/AddonsView.swift app/SourcesShared/CoreBridge.swift app/SourcesShared/CoreModels.swift \
  app/SourcesShared/VortXSyncManager.swift app/SourcesShared/SettingsBackup.swift
