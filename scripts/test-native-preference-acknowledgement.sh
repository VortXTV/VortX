#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
test_dir=$(mktemp -d "$PWD/app/build/native-preference-ack.XXXXXX")
source_file=app/SourcesShared/Profiles.swift
if [[ ${1:-} == --baseline-ref ]]; then
    test $# -eq 2
    git show "$2:app/SourcesShared/Profiles.swift" > "$test_dir/baseline.swift"
    source_file="$test_dir/baseline.swift"
fi
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$test_dir/UserProfile.swift"
{ printf '%s\n' 'import Foundation'; sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift; } > "$test_dir/Discovery.swift"
cp app/Tests/NativePreferenceAcknowledgementTests.swift "$test_dir/Combined.swift"
{
    printf '\n%s\n' 'extension PreferenceHarness {'
    sed -n '/^    func nativePreferenceIsAcknowledged(/,/^    }/p' "$source_file"
    for name in 'private struct NativeThemeProjection' 'private func currentNativeThemeProjection(' 'private func nativePlaybackProjectionRepresents(' 'private func nativeDiscoveryProjectionRepresents(' 'private static func nativeDiscoveryProjectionIsRepresented(' 'func retryNativePreferenceProjection(' 'private func profileCapturingPlayback('; do
        # Baseline ACK regression uses candidate-only support methods without rewriting its tested body.
        sed -n "/^    $name/,/^    }/p" app/SourcesShared/Profiles.swift
    done
    printf '%s\n' '}' 'extension ProfileDiscoveryPreferencesStore {'
    sed -n '/^    enum Key {/,/^    }/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
    printf '%s\n' '}'
} >> "$test_dir/Combined.swift"
xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors app/SourcesShared/ProfileAddonPreferences.swift "$test_dir/UserProfile.swift" "$test_dir/Discovery.swift" "$test_dir/Combined.swift" -o "$test_dir/preferences"
"$test_dir/preferences"
