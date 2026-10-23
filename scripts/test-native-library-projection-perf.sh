#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
projection_ref=working-tree
projection_mode=run
if (( $# > 0 )); then projection_ref=$1; fi
if (( $# > 1 )); then projection_mode=$2; fi
case "$projection_mode" in run|--prepare-only) ;; *) exit 2 ;; esac
mkdir -p app/build
projection_dir=$(mktemp -d "$PWD/app/build/native-library-projection.XXXXXX")
node - "$projection_dir" "$projection_ref" <<'NODE'
const fs = require('node:fs'), cp = require('node:child_process'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const [out, ref] = process.argv.slice(2);
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
const oldWatched = read('app/SourcesShared/VortxNativePreviouslyWatched.swift', baseline);
const fixture = fs.readFileSync('app/Tests/NativeLibraryProjectionTests.swift', 'utf8');
const markers = ['private func string(', 'private func projectedLibraryItems(', 'private func libraryRow(', 'private func libraryProjection(', 'private func localSearchProjection(', 'private func stateFields(', 'private func metaWithPlayback(', 'private func isoTimestamp(', 'private func playbackRow('];
const combined = fixture
  .replace('// PRODUCTION_JSON', member(resource, 'indirect enum VortxJSON:'))
  .replace('// PRODUCTION_ERROR', member(runtime, 'enum VortxNativeError:'))
  .replace('// PRODUCTION_PREVIOUSLY_WATCHED', member(watched, 'enum VortxNativePreviouslyWatched {'))
  .replace('// BASELINE_PREVIOUSLY_WATCHED', member(oldWatched, 'enum VortxNativePreviouslyWatched {').replaceAll('VortxNativePreviouslyWatched', 'BaselinePreviouslyWatched'))
  .replace('// PRODUCTION_CURRENT', markers.map(m => member(current, m)).join('\n'))
  .replace('// PRODUCTION_BASELINE', markers.map(m => member(prior, m)).join('\n').replaceAll('VortxNativePreviouslyWatched', 'BaselinePreviouslyWatched'));
fs.writeFileSync(out + '/Combined.swift', combined);
const receipt = {sourceRef: ref, baselineRef: baseline, note: 'Exact production declarations; controlled playback/library state only. No SDK, app launch, account, credentials, or network.', sha256: {}};
for (const [name, value] of Object.entries({CurrentFacade: current, BaselineFacade: prior, ResourceJSON: resource, RuntimeError: runtime, CurrentPreviouslyWatched: watched, BaselinePreviouslyWatched: oldWatched, Fixture: fixture, Combined: combined})) {
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
console.log('PASS source contracts: first-wins O(CW + rows) lookup, one projection and one local formatter per stateFields');
NODE
printf 'Source %s; retained pure fixture %s\n' "$projection_ref" "$projection_dir"
if [[ "$projection_mode" == --prepare-only ]]; then exit 0; fi
xcrun swiftc -O -j 2 -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$projection_dir/module-cache" "$projection_dir/Combined.swift" -o "$projection_dir/native-library-projection"
set +e
"$projection_dir/native-library-projection" > "$projection_dir/test.log" 2>&1
projection_status=$?
set -e
sed -n '1,120p' "$projection_dir/test.log"
shasum -a 256 "$projection_dir/Combined.swift" "$projection_dir/native-library-projection" \
    "$projection_dir/test.log" "$projection_dir/source-receipt.json" \
    scripts/test-native-library-projection-perf.sh app/Tests/NativeLibraryProjectionTests.swift > "$projection_dir/hashes.sha256"
printf 'Terminal status %s; retained %s\n' "$projection_status" "$projection_dir"
exit "$projection_status"
