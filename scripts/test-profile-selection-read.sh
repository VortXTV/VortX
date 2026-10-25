#!/usr/bin/env bash
# RAM-only actual Combined/observer test; no application initialization or persisted state access.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
selection_out=$(mktemp -d "$PWD/app/build/profile-selection.XXXXXX")
selection_phase=source-extraction
selection_inputs=(app/SourcesShared/Profiles.swift app/SourcesShared/CoreBridge.swift
  app/SourcesShared/LegacyWatchOwnership.swift app/Tests/ProfileSelectionReadTests.swift
  scripts/test-profile-selection-read.sh)
selection_finish() {
  local selection_exit=$?
  trap - EXIT
  set +e
  shasum -a 256 "${selection_inputs[@]}" > "$selection_out/source-after.sha256"
  [[ $? -eq 0 ]] || selection_exit=3
  cmp -s "$selection_out/source-before.sha256" "$selection_out/source-after.sha256" || selection_exit=3
  if [[ -f "$selection_out/generated-before.sha256" ]]; then
    shasum -a 256 "$selection_out/Combined.swift" > "$selection_out/generated-after.sha256"
    [[ $? -eq 0 ]] || selection_exit=3
    cmp -s "$selection_out/generated-before.sha256" "$selection_out/generated-after.sha256" || selection_exit=3
  fi
  printf 'exit_code=%s\nphase=%s\nscope=actual-scalar-and-Combine-observers-not-full-ProfileStore\n' \
    "$selection_exit" "$selection_phase" > "$selection_out/result.txt"
  printf 'Profile selection exit %s. Retained receipt: %s\n' "$selection_exit" "$selection_out"
  exit "$selection_exit"
}
trap selection_finish EXIT
shasum -a 256 "${selection_inputs[@]}" > "$selection_out/source-before.sha256"
node - "$selection_out" <<'NODE'
const fs = require('node:fs'), assert = require('node:assert/strict');
const out = process.argv[2], profiles = fs.readFileSync('app/SourcesShared/Profiles.swift', 'utf8');
const core = fs.readFileSync('app/SourcesShared/CoreBridge.swift', 'utf8');
function full(source, marker) {
  const start = source.indexOf(marker), open = source.indexOf('{', start);
  assert.ok(start >= 0 && source.indexOf(marker, start + marker.length) < 0, 'missing/ambiguous ' + marker);
  let depth = 1, end = open + 1;
  for (; depth && end < source.length; end++) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; }
  assert.equal(depth, 0, 'unbalanced ' + marker);
  return source.slice(start, end);
}
const begin = '// BEGIN legacy-watch lifecycle projection', end = '// END legacy-watch lifecycle projection.';
const from = profiles.indexOf(begin), to = profiles.indexOf(end, from);
assert.ok(from >= 0 && to > from && profiles.indexOf(begin, from + 1) < 0);
const observers = profiles.slice(profiles.indexOf('\n', from) + 1, to);
const finish = 'defer { ProfileSelectionRead.publishInitial(selectionReadSnapshot()) }';
assert.ok(full(profiles, 'private init()').includes(finish));
const scalar = full(profiles, 'enum ProfileSelectionRead {');
const projector = full(profiles, 'private func selectionReadSnapshot()');
for (const field of ['continueWatchingSource', 'continueWatchingWindow']) {
  assert.ok(scalar.includes('let ' + field + ': String?'), 'checked stored discovery field: ' + field);
  assert.ok(projector.includes('$0.discovery?.' + field), 'real stored roster projection: ' + field);
}
const template = fs.readFileSync('app/Tests/ProfileSelectionReadTests.swift', 'utf8');
fs.writeFileSync(out + '/Combined.swift', template
  .replace('// PRODUCTION_PROFILE_SELECTION_READ', full(profiles, 'enum ProfileSelectionRead {'))
  .replace('// PRODUCTION_PROFILE_SELECTION_OBSERVERS', observers)
  .replace('// PRODUCTION_PROFILE_SELECTION_INIT_FINISH', finish));
function checkWorkerReads(source) {
  const startup = full(source, 'func start()');
  assert.ok(startup.indexOf('_ = ProfileStore.shared') >= 0 && startup.indexOf('_ = ProfileStore.shared') < startup.indexOf('started = true'), 'startup finishes profile initialization before native bootstrap');
  for (const marker of ['private func currentNativePlaybackBinding()', 'private func captureNativeWatchlistTarget()']) {
    const member = full(source, marker);
    assert.equal(member.split('ProfileSelectionRead.snapshot()').length - 1, 1, 'one immutable selection moment per native capture');
    assert.ok(!member.includes('ProfileStore.shared'), 'native worker helper cannot access live profile owner');
    assert.ok(member.includes('let profile = selection.activeProfile?.id') && member.includes('selection.activeID == profile'), 'native capture requires an extant matching selected roster member');
    for (const required of ['CredentialScopeRegistry.shared.isCurrent(capture)', 'nativePublishedAccountGeneration', 'nativeInstallGeneration']) {
      assert.ok(member.includes(required), 'selection facts cannot replace native authority: ' + required);
    }
  }
}
checkWorkerReads(core);
function mutateMember(marker, before, after) {
  const original = full(core, marker);
  assert.ok(original.includes(before), 'negative control has a source-bound target');
  return core.replace(original, original.replace(before, after));
}
const playback = 'private func currentNativePlaybackBinding()';
const controls = [
  mutateMember('func start()', '_ = ProfileStore.shared', '_ = 0'),
  mutateMember(playback, 'let profile = selection.activeProfile?.id', 'let profile = selection.activeID'),
  mutateMember(playback, 'selection.activeID == profile', 'true'),
  mutateMember(playback, 'CredentialScopeRegistry.shared.isCurrent(capture)', 'true'),
  mutateMember(playback, 'nativePublishedAccountGeneration == epoch', 'true'),
  mutateMember(playback, 'sessionGeneration: nativeInstallGeneration', 'sessionGeneration: UUID()'),
];
for (const candidate of controls) {
  assert.notEqual(candidate, core, 'negative control changed actual source');
  assert.throws(() => checkWorkerReads(candidate), 'unsafe worker read or lost authority must fail source contract');
}
console.log('Actual profile selection extraction and startup/worker source contracts pass; six negative controls rejected');
NODE
shasum -a 256 "$selection_out/Combined.swift" > "$selection_out/generated-before.sha256"
mkdir "$selection_out/module-cache"
selection_phase=strict-swift6-compile
/usr/bin/nice -n 15 xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -j 1 -num-threads 1 -whole-module-optimization -parse-as-library \
  -module-cache-path "$selection_out/module-cache" "$selection_out/Combined.swift" \
  app/SourcesShared/LegacyWatchOwnership.swift -o "$selection_out/profile-selection-tests" > "$selection_out/compiler.log" 2>&1
selection_phase=actual-Combine-runtime
/usr/bin/nice -n 15 "$selection_out/profile-selection-tests" > "$selection_out/runtime.log" 2>&1
selection_phase=complete
