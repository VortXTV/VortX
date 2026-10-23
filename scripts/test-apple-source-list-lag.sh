#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_list_mode=${1:-run}
case "$source_list_mode" in run|--prepare-only) ;; *) exit 2 ;; esac
mkdir -p app/build
source_list_dir=$(mktemp -d "$PWD/app/build/apple-source-list-lag.XXXXXX")
node - "$source_list_dir" <<'NODE'
const fs = require('node:fs'), cp = require('node:child_process'), crypto = require('node:crypto');
const out = process.argv[2];
const path = 'app/SourcesiOS/iOSDetailView.swift';
const baselineRef = '93a0af6ab26d376ac47fabc00883b4451741dc06';
const baseline = cp.execFileSync('git', ['show', `${baselineRef}:${path}`], {encoding: 'utf8', maxBuffer: 2 * 1024 * 1024});
const current = fs.readFileSync(path, 'utf8');
const fixture = fs.readFileSync('app/Tests/AppleSourceListLagTests.swift', 'utf8');
function block(source, marker) {
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
const markers = ['enum SourceSort:', 'private func sortedStreams(', 'private var visibleGroups:', 'private var windowedPlan:'];
const consumers = [
  ['movie', '@ViewBuilder private var sourceSection:'],
  ['live', '@ViewBuilder private var liveSourceSection:'],
  ['episode', 'private func sourceListView('],
];
const receipt = {baselineRef, sourcePath: path, note: 'Actual production declarations and consumer expressions, controlled values/parsing counters; no app, accounts, storage, networking or private engine.', inputs: {}};
for (const [label, source] of [['Baseline', baseline], ['Current', current]]) {
  const methods = markers.map(marker => block(source, marker));
  if (source.includes('private func stableDescendingStreams<')) methods.push(block(source, 'private func stableDescendingStreams<'));
  if (source.includes('static func windowTakes(')) methods.push(block(source, 'static func windowTakes('));
  const expressions = consumers.map(([name, marker]) => {
    const body = block(source, marker);
    const match = body.match(/states:\s*([^\n]+),\s*\n\s*sourcesSettled:/);
    if (!match || !body.includes('sourcesSettled: sourceList.isSettled')) throw new Error(`Missing ${name} production states/settlement wiring`);
    if (!body.includes('.equatable()')) throw new Error(`Missing ${name} Equatable publication gate`);
    return `func ${name}States(_ suspended: Bool) -> [CoreBridge.StreamAddonState] { return ${match[1]} }`;
  });
  const rows = ['private struct SourceRow:', 'private struct WindowedGroup:'].map(marker => block(source, marker));
  const combined = fixture.replace('// PRODUCTION_ROWS', rows.join('\n'))
    .replace('// PRODUCTION_METHODS', methods.join('\n'))
    .replace('// PRODUCTION_CONSUMERS', expressions.join('\n'));
  fs.writeFileSync(`${out}/${label}.swift`, combined);
  fs.writeFileSync(`${out}/${label}.source`, source);
  receipt.inputs[label] = {sourceSHA256: crypto.createHash('sha256').update(source).digest('hex'), extractedSHA256: crypto.createHash('sha256').update(combined).digest('hex')};
}
// These displayed diagnostics and stable row identities are intentionally untouched.
for (const marker of ['@ViewBuilder private var emptyState:', '@ViewBuilder private var unresolvedFooter:', 'private var erroredAddons:', 'private var emptyAddons:']) {
  if (block(current, marker) !== block(baseline, marker)) throw new Error(`Unexpected diagnostic rendering change: ${marker}`);
}
if ((current.match(/states:\s*/g) || []).length !== 4) throw new Error('Unexpected source diagnostic consumer count');
receipt.inputs.Fixture = crypto.createHash('sha256').update(fixture).digest('hex');
fs.writeFileSync(`${out}/source-receipt.json`, JSON.stringify(receipt, null, 2) + '\n');
NODE
printf 'Retained source-list fixture %s\n' "$source_list_dir"
if [[ "$source_list_mode" == --prepare-only ]]; then exit 0; fi
xcrun swiftc -j 2 -swift-version 6 -strict-concurrency=complete -parse-as-library -warnings-as-errors \
    "$source_list_dir/Baseline.swift" -o "$source_list_dir/baseline"
set +e
"$source_list_dir/baseline" | tee "$source_list_dir/baseline.log"
source_list_red_status=${PIPESTATUS[0]}
set -e
if [[ "$source_list_red_status" == 0 ]] || ! rg -q 'FAIL movie diagnostic acquisition gate' "$source_list_dir/baseline.log" \
    || ! rg -q 'FAIL size no parsing after exhausted budget' "$source_list_dir/baseline.log" \
    || ! rg -q 'FAIL seeders comparator keys parsed once per stream' "$source_list_dir/baseline.log"; then
    printf '%s\n' 'Expected baseline RED evidence is missing' >&2
    exit 1
fi
printf '%s\n' 'Baseline RED confirmed from exact pinned production expressions and display methods'
xcrun swiftc -j 2 -swift-version 6 -strict-concurrency=complete -parse-as-library -warnings-as-errors \
    "$source_list_dir/Current.swift" -o "$source_list_dir/current"
"$source_list_dir/current" | tee "$source_list_dir/current.log"
xcrun swiftc -frontend -parse app/SourcesiOS/iOSDetailView.swift
shasum -a 256 "$source_list_dir/Baseline.swift" "$source_list_dir/Current.swift" \
    "$source_list_dir/baseline.log" "$source_list_dir/current.log" "$source_list_dir/source-receipt.json" \
    scripts/test-apple-source-list-lag.sh app/Tests/AppleSourceListLagTests.swift > "$source_list_dir/hashes.sha256"
printf 'PASS actual-source RED/GREEN, consumer wiring and production parse; retained %s\n' "$source_list_dir"
