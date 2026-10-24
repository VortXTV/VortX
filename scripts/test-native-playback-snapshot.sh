#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
snapshot_ref=${1:-working-tree}
snapshot_mode=${2:-run}
case "$snapshot_mode" in run|--focused|--prepare-only) ;; *) exit 2 ;; esac
mkdir -p app/build
snapshot_dir=$(mktemp -d "$PWD/app/build/native-playback-snapshot.XXXXXX")
snapshot_inputs=(
    scripts/test-native-playback-snapshot.sh app/Tests/NativePlaybackSnapshotTests.swift
    app/SourcesShared/CoreBridge.swift app/SourcesShared/Profiles.swift
    app/SourcesShared/VortxNativeCoreFacade.swift app/SourcesShared/VortxResourceBridge.swift
    app/SourcesShared/PlaybackMutationOwnershipPolicy.swift
)
shasum -a 256 "${snapshot_inputs[@]}" > "$snapshot_dir/inputs.before.sha256"
snapshot_exit() {
    local terminal_status=$?
    trap - EXIT
    shasum -a 256 "${snapshot_inputs[@]}" > "$snapshot_dir/inputs.after.sha256" || terminal_status=2
    if ! cmp -s "$snapshot_dir/inputs.before.sha256" "$snapshot_dir/inputs.after.sha256"; then
        printf 'FAIL: source inputs changed during verification.\n' >&2
        terminal_status=2
    fi
    printf 'Terminal status %s; retained %s\n' "$terminal_status" "$snapshot_dir"
    exit "$terminal_status"
}
trap snapshot_exit EXIT
node - "$snapshot_dir" "$snapshot_ref" <<'NODE'
const fs = require('node:fs'), cp = require('node:child_process'), crypto = require('node:crypto');
const [out, ref] = process.argv.slice(2);
const baseline = '57e1a98806d99b1ba074a455791b20aaea33894a';
const read = (path, revision = ref) => revision === 'working-tree' ? fs.readFileSync(path, 'utf8') : cp.execFileSync('git', ['show', `${revision}:${path}`], {encoding: 'utf8', maxBuffer: 8 * 1024 * 1024});
function member(source, marker) {
  const begin = source.indexOf(marker);
  if (begin < 0) throw new Error(`Missing production declaration: ${marker}`);
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
  throw new Error(`Unbalanced production declaration: ${marker}`);
}
const core = read('app/SourcesShared/CoreBridge.swift');
const oldCore = read('app/SourcesShared/CoreBridge.swift', baseline);
// The baseline lacks the new accessor: retain the current production accessor for direct
// fence tests, but use the EXACT old bridge method for the RED race/roundtrip comparison.
const facade = read('app/SourcesShared/VortxNativeCoreFacade.swift', 'working-tree');
const resource = read('app/SourcesShared/VortxResourceBridge.swift');
const policy = read('app/SourcesShared/PlaybackMutationOwnershipPolicy.swift');
// Always retain the current mirror as an explicitly recorded fixture dependency. Historical
// bridge/facade comparison bodies above remain the exact selected source, without fence rewrites.
const selectionProfiles = read('app/SourcesShared/Profiles.swift', 'working-tree');
const selectionRead = member(selectionProfiles, 'enum ProfileSelectionRead {');
const selectionSnapshot = member(selectionProfiles, 'private func selectionReadSnapshot()');
// Current watchlist capture is an additional fixture dependency, never substituted into
// the exact historical bridge bodies used by LegacyCoreBridge below.
const currentWatchlistCore = read('app/SourcesShared/CoreBridge.swift', 'working-tree');
const currentWatchlistHelpers = ['struct NativeWatchlistTarget {', 'private func captureNativeWatchlistTarget()']
  .map(marker => member(currentWatchlistCore, marker)).join('\n');
const fixture = fs.readFileSync('app/Tests/NativePlaybackSnapshotTests.swift', 'utf8');
const facadeMarkers = ['struct RegistryBinding:', 'struct WatchlistBinding:', 'var accountGeneration:', 'var watchlistBinding:', 'var isAvailable:', 'var registryBinding:', 'func stateData(', 'func playbackSnapshot(', 'private func string('];
const bridgeMarkers = ['func nativePlaybackSnapshot()', 'private func currentNativePlaybackBinding()', 'private func nativePlaybackBinding('];
let combined = fixture
  .replace('// PRODUCTION_SELECTION_READ', selectionRead)
  .replace('// PRODUCTION_SELECTION_SNAPSHOT', selectionSnapshot)
  .replace('// PRODUCTION_CURRENT_WATCHLIST_BRIDGE', currentWatchlistHelpers)
  .replace('// PRODUCTION_JSON', member(resource, 'indirect enum VortxJSON:'))
  .replace('// PRODUCTION_POLICY', member(policy, 'enum PlaybackMutationOwnershipPolicy {'))
  .replace('// PRODUCTION_FACADE', facadeMarkers.map(m => member(facade, m)).join('\n'))
  .replace('// PRODUCTION_BRIDGE', bridgeMarkers.map(m => member(core, m)).join('\n'))
  .replace('// PRODUCTION_BASELINE_BRIDGE', bridgeMarkers.map(m => member(oldCore, m)).join('\n'));
fs.writeFileSync(`${out}/Combined.swift`, combined);
const inputs = {sourceRef: ref, baselineRef: baseline, facadeRef: 'working-tree', profileSelectionRef: 'working-tree', currentWatchlistRef: 'working-tree', profileSelectionBoundary: 'Real current mirror and projector; RAM singleton initializes once and brackets roster/activeID mutation; context seeds explicit synthetic roster flags. Current watchlist capture is a separately hashed fixture dependency; historical bridge bodies remain exact.', note: 'No engine/session SDK, network, account storage, or customer state. Production declarations are unchanged; collaborators only provide controlled state and lock-boundary scheduling.', inputs: {}};
for (const [name, value] of Object.entries({CoreBridge: core, LegacyCoreBridge: oldCore, VortxNativeCoreFacade: facade, VortxResourceBridge: resource, PlaybackMutationOwnershipPolicy: policy, ProfileSelectionDependency: selectionProfiles, ProfileSelectionRead: selectionRead, ProfileSelectionSnapshot: selectionSnapshot, CurrentWatchlistCoreBridge: currentWatchlistCore, CurrentWatchlistHelpers: currentWatchlistHelpers, Fixture: fixture, Combined: combined})) {
  fs.writeFileSync(`${out}/${name}.source`, value);
  inputs.inputs[name] = crypto.createHash('sha256').update(value).digest('hex');
}
fs.writeFileSync(`${out}/source-receipt.json`, JSON.stringify(inputs, null, 2) + '\n');
NODE
printf 'Source %s; retained snapshot fixture %s\n' "$snapshot_ref" "$snapshot_dir"
if [[ "$snapshot_mode" == --prepare-only ]]; then exit 0; fi
nice -n 15 xcrun swiftc -O -j 1 -num-threads 1 -swift-version 6 -parse-as-library -warnings-as-errors \
    "$snapshot_dir/Combined.swift" -o "$snapshot_dir/native-playback-snapshot"
set +e
if [[ "$snapshot_mode" == --focused ]]; then export VORTX_SNAPSHOT_SKIP_BENCHMARK=1; fi
nice -n 15 "$snapshot_dir/native-playback-snapshot" | tee "$snapshot_dir/test.log"
snapshot_status=${PIPESTATUS[0]}
set -e
shasum -a 256 "$snapshot_dir/Combined.swift" "$snapshot_dir/native-playback-snapshot" \
    "$snapshot_dir/test.log" "$snapshot_dir/source-receipt.json" \
    scripts/test-native-playback-snapshot.sh app/Tests/NativePlaybackSnapshotTests.swift > "$snapshot_dir/hashes.sha256"
exit "$snapshot_status"
