#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
test_dir=$(mktemp -d "$PWD/app/build/native-preference-ack.XXXXXX")
preference_phase=source
preference_supervisor="$PWD/test/mpv-bounded-child.mjs"
preference_inputs=(scripts/test-native-preference-acknowledgement.sh test/mpv-bounded-child.mjs
    app/SourcesShared/Profiles.swift app/SourcesShared/ProfileDiscoveryPreferences.swift
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/ProfileSync.swift
    app/Tests/NativePreferenceAcknowledgementTests.swift)
preference_finish() {
    local terminal_status=$?
    trap - EXIT
    set +e
    shasum -a 256 "${preference_inputs[@]}" > "$test_dir/source-after.sha256"
    [[ $? -eq 0 ]] || terminal_status=3
    cmp -s "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" || terminal_status=3
    if [[ -f "$test_dir/generated-before.sha256" ]]; then
        shasum -a 256 "$test_dir/UserProfile.swift" "$test_dir/Discovery.swift" \
            "$test_dir/WatchEntry.swift" "$test_dir/Combined.swift" > "$test_dir/generated-after.sha256"
        [[ $? -eq 0 ]] || terminal_status=3
        cmp -s "$test_dir/generated-before.sha256" "$test_dir/generated-after.sha256" || terminal_status=3
    fi
    printf 'exit_code=%s\nphase=%s\nscope=actual-profile-values-extracted-ack-methods-RAM-not-ProfileStore-or-native-session\n' \
        "$terminal_status" "$preference_phase" > "$test_dir/result.txt"
    printf 'Preference acknowledgement exit %s; retained %s\n' "$terminal_status" "$test_dir"
    exit "$terminal_status"
}
trap preference_finish EXIT
shasum -a 256 "${preference_inputs[@]}" > "$test_dir/source-before.sha256"
git -C "$PWD" rev-parse HEAD > "$test_dir/source-head.txt"
source_file=app/SourcesShared/Profiles.swift
case "${1:-}" in
"") test $# -eq 0 ;;
--baseline-ref)
    test $# -eq 2
    git -C "$PWD" show "$2:app/SourcesShared/Profiles.swift" > "$test_dir/baseline.swift"
    source_file="$test_dir/baseline.swift"
    shasum -a 256 "$source_file" > "$test_dir/baseline.sha256" ;;
*) printf 'usage: %s [--baseline-ref ref]\n' "$0" >&2; exit 2 ;;
esac
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$test_dir/UserProfile.swift"
{ printf '%s\n' 'import Foundation'; sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift; } > "$test_dir/Discovery.swift"
{ printf '%s\n' 'import Foundation'; sed -n '/^struct WatchEntry: /,/^}$/p' app/SourcesShared/ProfileSync.swift; } > "$test_dir/WatchEntry.swift"
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
shasum -a 256 "$test_dir/UserProfile.swift" "$test_dir/Discovery.swift" \
    "$test_dir/WatchEntry.swift" "$test_dir/Combined.swift" > "$test_dir/generated-before.sha256"
mkdir "$test_dir/module-cache"
preference_phase=compile
nice -n 15 node "$preference_supervisor" run 60 "$test_dir/compile-process.json" -- \
    /usr/bin/xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -j 1 -num-threads 1 -whole-module-optimization -module-cache-path "$test_dir/module-cache" \
    app/SourcesShared/ProfileAddonPreferences.swift "$test_dir/UserProfile.swift" "$test_dir/Discovery.swift" \
    "$test_dir/WatchEntry.swift" "$test_dir/Combined.swift" -o "$test_dir/preferences" \
    > "$test_dir/compiler.log" 2>&1
nice -n 15 node "$preference_supervisor" check "$test_dir/compile-process.json" 0 normal-exit
preference_phase=runtime
nice -n 15 node "$preference_supervisor" run 30 "$test_dir/runtime-process.json" -- \
    "$test_dir/preferences" > "$test_dir/runtime.log" 2>&1
nice -n 15 node "$preference_supervisor" check "$test_dir/runtime-process.json" 0 normal-exit
cat "$test_dir/runtime.log"
preference_phase=complete
