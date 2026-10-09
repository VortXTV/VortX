#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
profile_test_dir=$(mktemp -d app/build/profile-addons.XXXXXX)
node --input-type=module - "$profile_test_dir" <<'NODE'
import {readFileSync, writeFileSync, statSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const dir = process.argv[2];
const paths = ['app/SourcesShared/ProfileAddonPreferences.swift', 'app/Tests/ProfileAddonPreferencesTests.swift',
    'scripts/test-profile-addon-preferences.sh', 'app/SourcesShared/Profiles.swift',
    'app/SourcesShared/ProfileDiscoveryPreferences.swift'];
const inputs = paths.map(path => {
    const bytes = readFileSync(path); writeFileSync(dir + '/' + path.split('/').at(-1), bytes);
    return {path, mode:(statSync(path).mode & 0o777).toString(8), sha256:createHash('sha256').update(bytes).digest('hex')};
});
const source = readFileSync(dir + '/Profiles.swift', 'utf8');
const block = marker => {
    const start = source.indexOf(marker); if (start < 0) throw Error('Missing actual method ' + marker);
    let end = source.indexOf('{', start) + 1, depth = 1;
    for (; depth && end < source.length; end++) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; }
    if (depth) throw Error('Unterminated actual method ' + marker);
    return source.slice(start, end).replace(/^private (func|var)/, '$1');
};
writeFileSync(dir + '/UserProfile.swift', source.slice(0, source.indexOf('/// The profile roster and the active selection.')));
const discovery = readFileSync(dir + '/ProfileDiscoveryPreferences.swift', 'utf8');
const match = discovery.match(/^struct ProfileDiscoveryPreferences: [\s\S]*?^}/m);
if (!match) throw Error('Missing shipping discovery model');
writeFileSync(dir + '/Discovery.swift', 'import Foundation\n' + match[0] + '\n');
const markers = ['func toggleAddon(', 'func isAddonDisabledForActive(', 'private func addonPreferences(',
    'private func effectiveDisabledAddons(', 'private func effectiveAddonRanking(', 'private func applyAddonPreferences(',
    'func customizeAddonVisibility(', 'func resetAddonVisibilityToMain(', 'func customizeAddonRanking(',
    'func resetAddonRankingToMain(', 'func setAddonOrder(', 'func capturePlayback(',
    'var activeSharesMainAddons:', 'var activeInheritsAddonVisibility:', 'var activeInheritsAddonRanking:',
    'private var ownerAddonRanking:', 'static func activeAddonOrder('];
writeFileSync(dir + '/LiveMethods.swift', 'import Foundation\nextension ProfileStore {\n' + markers.map(block).join('\n') + '\n}\n');
const baseline = 'fa463b3f57da75426091f721b11603ba6649df34';
const original = execFileSync('git', ['show', baseline + ':app/SourcesShared/ProfileAddonPreferences.swift']);
writeFileSync(dir + '/BaselineProfileAddonPreferences.swift', original);
writeFileSync(dir + '/manifest.json', JSON.stringify({baseline, baselinePolicySHA256:createHash('sha256').update(original).digest('hex'), inputs}, null, 2));
console.log('Frozen actual profile policy/method inputs: ' + dir + '/manifest.json');
NODE
if [[ "$*" == "--freeze-only" ]]; then
  printf '%s\n' "Review freeze without compiler: $profile_test_dir"
  exit 0
fi

# Every owned compiler/test subprocess has a finite budget. No app, account, native lease or media runs.
profile_bounded() {
  node --input-type=module - "$@" <<'NODE'
import {spawn} from 'node:child_process';
const [command, ...args] = process.argv.slice(2);
const child = spawn(command, args, {stdio:'inherit', detached:true});
let expired = false;
let killTimer;
const timer = setTimeout(() => {
  expired = true;
  try { process.kill(-child.pid, 'SIGTERM'); } catch {}
  killTimer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 2000);
}, 30000);
child.on('error', error => { clearTimeout(timer); if (!expired) clearTimeout(killTimer); console.error(error.message); process.exitCode = 1; });
child.on('exit', (code, signal) => {
  clearTimeout(timer);
  // A terminated driver may leave descendants in its owned group. Keep escalation armed on timeout.
  if (!expired) clearTimeout(killTimer);
  if (expired) console.error('Owned subprocess exceeded 30-second budget');
  process.exitCode = expired ? 124 : (code ?? (signal ? 128 : 1));
});
NODE
}

profile_bounded xcrun swiftc -parse-as-library -warnings-as-errors \
  "$profile_test_dir/UserProfile.swift" "$profile_test_dir/Discovery.swift" "$profile_test_dir/LiveMethods.swift" \
  "$profile_test_dir/BaselineProfileAddonPreferences.swift" "$profile_test_dir/ProfileAddonPreferencesTests.swift" \
  -o "$profile_test_dir/profile-addon-tests-baseline"
set +e
profile_bounded "$profile_test_dir/profile-addon-tests-baseline" --migration-stability-only \
  2>&1 | tee "$profile_test_dir/baseline-red.log"
profile_baseline_status=${PIPESTATUS[0]}
set -e
if [[ "$profile_baseline_status" != 1 ]] || ! rg -q '^FAIL: stable legacy classification:' "$profile_test_dir/baseline-red.log" \
  || ! rg -q '^FAIL: stable actual ProfileStore classification:' "$profile_test_dir/baseline-red.log"; then
  printf '%s\n' "Expected actual baseline legacy stability RED was not observed (status $profile_baseline_status)"
  exit 1
fi
printf '%s\n' "PASS genuine baseline policy/ProfileStore classification RED (terminal 1)"
for profile_test_mode in legacy native; do
  profile_test_flags=()
  if [[ "$profile_test_mode" == native ]]; then profile_test_flags=(-D VORTX_NATIVE_DATA_ENGINE); fi
  profile_bounded xcrun swiftc -parse-as-library -warnings-as-errors "${profile_test_flags[@]}" \
    "$profile_test_dir/UserProfile.swift" "$profile_test_dir/Discovery.swift" "$profile_test_dir/LiveMethods.swift" \
    "$profile_test_dir/ProfileAddonPreferences.swift" "$profile_test_dir/ProfileAddonPreferencesTests.swift" \
    -o "$profile_test_dir/profile-addon-tests-$profile_test_mode"
  profile_bounded "$profile_test_dir/profile-addon-tests-$profile_test_mode" \
    2>&1 | tee "$profile_test_dir/candidate-$profile_test_mode.log"
done
printf '%s\n' "Retained actual profile add-on policy/method receipts: $profile_test_dir"
