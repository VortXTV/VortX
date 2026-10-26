#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
projection_ref=working-tree
projection_mode=run
if (( $# > 0 )); then projection_ref=$1; fi
if (( $# > 1 )); then projection_mode=$2; fi
case "$projection_mode" in run|--prepare-only|--functional-only|--owner-history-red) ;; *) exit 2 ;; esac
mkdir -p app/build
projection_dir=$(mktemp -d "$PWD/app/build/native-library-projection.XXXXXX")
projection_phase=source-extraction
projection_inputs=(app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxResourceBridge.swift
  app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxNativePreviouslyWatched.swift
  app/SourcesShared/VortxNativeSession.swift app/SourcesShared/OwnerHistoryExactJSON.swift app/SourcesShared/OwnerHistorySessionPublication.swift
  app/Tests/NativeLibraryProjectionTests.swift
  scripts/test-native-library-projection-perf.sh)
projection_finish() {
  local projection_exit=$?
  trap - EXIT
  set +e
  shasum -a 256 "${projection_inputs[@]}" > "$projection_dir/source-after.sha256"
  [[ $? -eq 0 ]] || projection_exit=3
  cmp -s "$projection_dir/source-before.sha256" "$projection_dir/source-after.sha256" || projection_exit=3
  if [[ -f "$projection_dir/generated-before.sha256" ]]; then
    shasum -a 256 "$projection_dir/Combined.swift" > "$projection_dir/generated-after.sha256"
    [[ $? -eq 0 ]] || projection_exit=3
    cmp -s "$projection_dir/generated-before.sha256" "$projection_dir/generated-after.sha256" || projection_exit=3
  fi
  printf 'exit_code=%s\nphase=%s\nmode=%s\n' "$projection_exit" "$projection_phase" "$projection_mode" > "$projection_dir/result.txt"
  printf 'Projection checks exit %s; retained %s\n' "$projection_exit" "$projection_dir"
  exit "$projection_exit"
}
trap projection_finish EXIT
shasum -a 256 "${projection_inputs[@]}" > "$projection_dir/source-before.sha256"
node - "$projection_dir" "$projection_ref" "$projection_mode" <<'NODE'
const fs = require('node:fs'), cp = require('node:child_process'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const [out, ref, mode] = process.argv.slice(2);
const baseline = '82cc8387222469d36dfbb7fc09881c375e36de45';
const read = (path, revision = ref) => revision === 'working-tree' ? fs.readFileSync(path, 'utf8') : cp.execFileSync('git', ['show', revision + ':' + path], {encoding: 'utf8', maxBuffer: 8 * 1024 * 1024});
function member(source, marker) {
  const begin = source.indexOf(marker);
  assert.ok(begin >= 0, 'Missing production declaration: ' + marker);
  const open = source.indexOf('{', begin);
  let depth = 0, quoted = false, escaped = false, lineComment = false;
  for (let i = open; i < source.length; i++) {
    const c = source[i], n = source[i + 1];
    if (lineComment) { if (c === '\n') lineComment = false; continue; }
    if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; continue; }
    if (c === '/' && n === '/') { lineComment = true; i++; continue; }
    if (c === '"') { quoted = true; continue; }
    if (c === '{') depth++;
    if (c === '}' && --depth === 0) return source.slice(begin, i + 1);
  }
  throw new Error('Unbalanced declaration: ' + marker);
}
const path = 'app/SourcesShared/VortxNativeCoreFacade.swift';
const current = read(path), prior = read(path, baseline);
const resource = read('app/SourcesShared/VortxResourceBridge.swift');
const runtime = read('app/SourcesShared/VortxNativeRuntime.swift');
const watched = read('app/SourcesShared/VortxNativePreviouslyWatched.swift');
const membership = member(current, 'struct VortxLibraryMembership: Sendable {');
const oldWatched = read('app/SourcesShared/VortxNativePreviouslyWatched.swift', baseline);
const fixture = fs.readFileSync('app/Tests/NativeLibraryProjectionTests.swift', 'utf8');
// The behavioral red uses the exact older projection body with today's optional composed VIEW
// present but ignored. Its failure must come from missing imported rows, not missing new methods.
const publication = fs.readFileSync('app/SourcesShared/OwnerHistorySessionPublication.swift', 'utf8');
const exact = fs.readFileSync('app/SourcesShared/OwnerHistoryExactJSON.swift', 'utf8');
const exactPrefixEnd = exact.indexOf('    /// Complete native ENGINE output only,');
assert.ok(exactPrefixEnd > 0);
const pureExact = exact.slice(0, exactPrefixEnd) + member(exact, 'private struct Parser {') + '\n}';
const markers = ['private func string(', 'private func projectedLibraryItems(', 'private func libraryRow(', 'private func libraryProjection(', 'private func localSearchProjection(', 'private func stateFields(', 'private func metaWithPlayback(', 'private func isoTimestamp(', 'private func playbackRow('];
const managementHelpers = ['private func addonOwner(', 'private func addonManagementProjection(']
  .map(marker => member(current, marker)).join('\n');
const presentationFields = current.match(/^    private static let presentationFields: Set<String> = \[[\s\S]*?\]/gm) ?? [];
assert.equal(presentationFields.length, 1, 'unique actual presentation field declaration');
const sourceChangedHook = current.split('\n').filter(line => line.trim()
  === 'private var sourceChangedDelivery: (@Sendable ([String], ChangeReceipt?) -> (@Sendable () -> Void)?)?');
assert.equal(sourceChangedHook.length, 1, 'unique exact production generic source-delivery property');
const combined = fixture
  .replace('// PRODUCTION_EXACT_JSON', pureExact)
  .replace('// PRODUCTION_OWNER_LIBRARY', member(publication, 'struct Presentation: Sendable {'))
  .replace('// PRODUCTION_JSON', member(resource, 'indirect enum VortxJSON:'))
  .replace('// PRODUCTION_MEMBERSHIP', membership)
  .replace('// PRODUCTION_LOCK', member(current, 'final class VortxNativeFacadeLock:'))
  .replace('// PRODUCTION_ERROR', member(runtime, 'enum VortxNativeError:'))
  .replace('// PRODUCTION_PREVIOUSLY_WATCHED', member(watched, 'enum VortxNativePreviouslyWatched {'))
  .replace('// BASELINE_PREVIOUSLY_WATCHED', member(oldWatched, 'enum VortxNativePreviouslyWatched {').replaceAll('VortxNativePreviouslyWatched', 'BaselinePreviouslyWatched'))
  .replace('// PRODUCTION_CHANGE_RECEIPT', member(current, 'struct ChangeReceipt: Sendable {'))
  .replace('// PRODUCTION_SOURCE_CHANGED_DELIVERY', sourceChangedHook[0])
  .replace('// PRODUCTION_CURRENT_PUBLICATION', [member(current, 'private func makeChangeReceipt('),
    member(current, 'private func stageChanged('), member(current, 'private func publish(')].join('\n'))
  .replace('// PRODUCTION_CURRENT_MANAGEMENT', managementHelpers)
  .replace('// PRODUCTION_PRESENTATION_FIELDS', presentationFields[0])
  .replace('// PRODUCTION_CURRENT', markers.map(m => member(current, m)).join('\n'))
  .replace('// PRODUCTION_BASELINE', markers.map(m => member(prior, m)).join('\n').replaceAll('VortxNativePreviouslyWatched', 'BaselinePreviouslyWatched'));
fs.writeFileSync(out + '/Combined.swift', combined);
const receipt = {sourceRef: ref, baselineRef: baseline, note: 'Exact production declarations; controlled playback/library state only. No SDK, app launch, account, credentials, or network.', sha256: {}};
for (const [name, value] of Object.entries({CurrentFacade: current, BaselineFacade: prior, ResourceJSON: resource, RuntimeError: runtime, MembershipIndex: membership, CurrentPreviouslyWatched: watched, BaselinePreviouslyWatched: oldWatched, SourceChangedHook: sourceChangedHook[0], ManagementHelpers: managementHelpers, PresentationFields: presentationFields[0], Fixture: fixture, Combined: combined})) {
  receipt.sha256[name] = crypto.createHash('sha256').update(value).digest('hex');
}
fs.writeFileSync(out + '/source-receipt.json', JSON.stringify(receipt, null, 2) + '\n');
// Deterministic complexity contracts, not a flaky timing threshold. Pointing this runner at
// the pinned baseline is a RED control: the old per-row scan / duplicate projection must fail.
const row = member(current, 'private func libraryRow('), fields = member(current, 'private func stateFields(');
assert.ok(!row.includes('continueWatching') && !row.includes('.first'), 'Library row must use the prebuilt first-wins index');
assert.ok(member(current, 'private func projectedLibraryItems(').includes('resumeByID[id] == nil'), 'Duplicate resume keys must retain the first entry');
assert.equal((fields.match(/projectedLibraryItems\(/g) || []).length, 1);
assert.ok(fields.includes('request: libraryRequest, projected: projected'), 'stateFields must reuse its projected rows');
assert.equal((fields.match(/ISO8601DateFormatter\(\)/g) || []).length, 1);
assert.ok(!member(current, 'private func isoTimestamp(').includes('ISO8601DateFormatter()'), 'No formatter construction per row');
function verifyMembershipSource(source) {
  const publication = member(source, 'private func publish('), stateFields = member(source, 'private func stateFields('), close = member(source, 'func close(');
  assert.ok(publication.includes('library: metadataLibraryMembership') && !publication.includes('values["library"]'), 'Metadata publication must never use the filtered screen catalog');
  assert.ok(stateFields.includes('let membership = VortxLibraryMembership(projected)') && stateFields.includes('metadataLibraryMembership = membership'), 'Full acknowledged projection replaces the membership index');
  assert.ok(close.includes('metadataLibraryMembership = VortxLibraryMembership()') && close.indexOf('metadataLibraryMembership = VortxLibraryMembership()') < close.indexOf('lock.unlock()'), 'Close clears membership while holding the facade lock');
}
verifyMembershipSource(current);
if (mode !== '--owner-history-red') {
  const session = fs.readFileSync('app/SourcesShared/VortxNativeSession.swift', 'utf8');
  const snapshot = member(session, 'func addonSnapshot()');
  assert.ok(snapshot.includes('ownerHistory.read(kind: "view", capture: capture)')
    && snapshot.includes('expectedFence: capture.fence') && snapshot.includes('ownerLibrary = view')
    && !snapshot.includes('try?'), 'one synchronous actor snapshot must require its original fenced composed view without fallback');
  assert.equal((current.match(/ownerHistoryLibrary = addonSnapshot\.ownerHistoryLibrary/g) || []).length, 2,
    'creation and locked acknowledged mutation must replace the composed view with their own snapshot');
  assert.equal((current.match(/ownerLibrary\.playback/g) || []).length, 2,
    'creation and acknowledged mutation must use playback from the same composed view');
  const projection = member(current, 'private func projectedLibraryItems(');
  assert.ok(projection.includes('view.profileID == active') && projection.includes('view.scope == string(state["nativeSync"]?["scope"])')
    && projection.includes('view.ownerProfileID == string(state["nativeSync"]?["ownerProfileId"])'), 'cached VIEW must reject replacement account/owner/profile');
  assert.ok(current.includes('self.playback = previousPlayback; self.ownerHistoryLibrary = previousOwnerLibrary')
    && current.includes('self.addonInventories = previousAddonInventories'),
    'projection failure must restore the previous paired playback/VIEW/inventory cache');
} else {
  assert.notEqual(ref, 'working-tree', 'red must name an immutable older revision');
  assert.ok(!member(current, 'private func projectedLibraryItems(').includes('ownerHistoryLibrary'),
    'behavioral red must compile the real old body that ignores composed source membership');
}
for (const fragment of ['library: metadataLibraryMembership', 'let membership = VortxLibraryMembership(projected)',
                        'metadataLibraryMembership = membership', 'metadataLibraryMembership = VortxLibraryMembership();']) {
  assert.ok(current.includes(fragment), 'missing negative control target');
  assert.throws(() => verifyMembershipSource(current.replace(fragment, 'REMOVED_NEGATIVE_CONTROL')), 'source guard must reject removal');
}
console.log('PASS membership caller contracts: full-state construction/publication/retirement; four negative controls rejected');
console.log('PASS source contracts: first-wins O(CW + rows) lookup, one projection and one local formatter per stateFields');
NODE
printf 'Source %s; retained pure fixture %s\n' "$projection_ref" "$projection_dir"
if [[ "$projection_mode" == --prepare-only ]]; then exit 0; fi
shasum -a 256 "$projection_dir/Combined.swift" > "$projection_dir/generated-before.sha256"
projection_phase=strict-swift6-compile
/usr/bin/nice -n 15 xcrun swiftc -O -j 1 -num-threads 1 -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$projection_dir/module-cache" "$projection_dir/Combined.swift" -o "$projection_dir/native-library-projection" > "$projection_dir/compiler.log" 2>&1
if [[ "$projection_mode" == --functional-only || "$projection_mode" == --owner-history-red ]]; then
  export VORTX_LIBRARY_PROJECTION_FUNCTIONAL_ONLY=1
else
  unset VORTX_LIBRARY_PROJECTION_FUNCTIONAL_ONLY
fi
projection_phase=actual-projection-runtime
set +e
/usr/bin/nice -n 15 "$projection_dir/native-library-projection" > "$projection_dir/test.log" 2>&1
projection_status=$?
set -e
sed -n '1,120p' "$projection_dir/test.log"
shasum -a 256 "$projection_dir/Combined.swift" "$projection_dir/native-library-projection" \
    "$projection_dir/test.log" "$projection_dir/source-receipt.json" \
    scripts/test-native-library-projection-perf.sh app/Tests/NativeLibraryProjectionTests.swift > "$projection_dir/hashes.sha256"
printf 'Terminal status %s; retained %s\n' "$projection_status" "$projection_dir"
projection_phase=complete
exit "$projection_status"
