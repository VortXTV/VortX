#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

test -d "$repo_root/app" || fail "app directory is missing"
test -f "$repo_root/app/SourcesShared/SubtitleEmbeddedExtractor.swift" || fail "selected extractor source is missing"
test -f "$repo_root/app/Tests/SubtitleTimingPolicyTests.swift" || fail "maintained fixture is missing"
command -v node >/dev/null 2>&1 || fail "node is required for source selection"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required for the genuine macOS SDK gate"

mkdir -p app/build
test_dir="$(mktemp -d app/build/subtitle-timing-policy.XXXXXX)"
source_ref="${1:-current}"
printf 'Evidence: %s/%s (source: %s)\n' "$repo_root" "$test_dir" "$source_ref"

host_arch="$(uname -m)"
case "$host_arch" in
  arm64|x86_64) ;;
  *) fail "unsupported host architecture: $host_arch" ;;
esac
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
test -d "$host_sdk" || fail "macOS SDK path is not a directory: $host_sdk"

node - "$test_dir" "$source_ref" <<'NODE'
const fs = require('node:fs');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const path = require('node:path');

const [out, sourceRef] = process.argv.slice(2);
const sourcePath = 'app/SourcesShared/SubtitleEmbeddedExtractor.swift';
const fixturePath = 'app/Tests/SubtitleTimingPolicyTests.swift';
const preparationPath = 'app/SourcesShared/SubtitleReferencePreparation.swift';
const queryPath = 'app/SourcesShared/SubtitleReferenceNativeQuery.swift';
const sourceCommit = cp.execFileSync(
  'git', ['rev-parse', '--verify', `${sourceRef === 'current' ? 'HEAD' : sourceRef}^{commit}`],
  { encoding: 'utf8' }
).trim();
const inputs = {};
const selections = {};
const sha256 = value => crypto.createHash('sha256').update(value).digest('hex');

function read(pathname) {
  const text = sourceRef === 'current'
    ? fs.readFileSync(pathname, 'utf8')
    : cp.execFileSync('git', ['show', `${sourceCommit}:${pathname}`], { encoding: 'utf8' });
  inputs[pathname] = sha256(text);
  return text;
}

function count(text, marker) {
  let found = 0;
  let at = 0;
  while ((at = text.indexOf(marker, at)) >= 0) { found++; at += marker.length; }
  return found;
}

function once(text, marker) {
  const first = text.indexOf(marker);
  if (first < 0 || text.indexOf(marker, first + marker.length) >= 0) {
    throw new Error(`Nonunique/missing source boundary: ${marker}`);
  }
  return first;
}

// Keep this scanner aligned with the existing source-contract runners. It balances
// only code braces, ignores escaped strings and nested block comments, and fails
// closed for unsupported raw/triple string literals in a selected declaration.
function declaration(text, marker) {
  const start = once(text, marker);
  const open = text.indexOf('{', start + marker.length);
  if (open < 0) throw new Error(`Missing declaration body: ${marker}`);
  let depth = 0;
  let blockComments = 0;
  let mode = 'code';
  for (let i = open; i < text.length; i++) {
    const c = text[i], n = text[i + 1];
    if (mode === 'line') { if (c === '\n') mode = 'code'; continue; }
    if (mode === 'block') {
      if (c === '/' && n === '*') { blockComments++; i++; }
      else if (c === '*' && n === '/') { i++; if (--blockComments === 0) mode = 'code'; }
      continue;
    }
    if (mode === 'string') { if (c === '\\') i++; else if (c === '"') mode = 'code'; continue; }
    if (c === '/' && n === '/') { mode = 'line'; i++; continue; }
    if (c === '/' && n === '*') { mode = 'block'; blockComments = 1; i++; continue; }
    if ((c === '#' && n === '"') || text.startsWith('"""', i)) {
      throw new Error(`Unsupported literal in selected declaration: ${marker}`);
    }
    if (c === '"') { mode = 'string'; continue; }
    if (c === '{') depth++;
    else if (c === '}' && --depth === 0) {
      const selected = text.slice(start, i + 1);
      selections[marker] = sha256(selected);
      return selected;
    }
  }
  throw new Error(`Unclosed selected declaration: ${marker}`);
}

const source = read(sourcePath);
const preparation = read(preparationPath);
const query = read(queryPath);
const hasOutputMarker = '    static func timingPacketHasOutput(';
const movTextMarker = '    static func timingPacketIsMovTextClear(';
const appendMarker = '    static func appendTimingCue(';
const projectionMarker = '    nonisolated static func referenceTimings(';
const missing = [hasOutputMarker, movTextMarker, appendMarker].filter(marker => count(source, marker) !== 1);
if (count(preparation, projectionMarker) !== 1) missing.push(projectionMarker);

// A real historical ref that predates these helpers is unsupported input. Do not
// copy the current dirty source or manufacture a baseline that can turn absence
// into causal red evidence.
if (missing.length > 0) {
  const manifest = {
    status: sourceRef === 'current' ? 'FAIL' : 'UNSUPPORTED',
    source_ref: sourceRef,
    commit: sourceCommit,
    inputs,
    missing_markers: missing,
    note: sourceRef === 'current'
      ? 'Current selected source does not contain exactly one copy of every required helper.'
      : 'Historical source lacks the selected helpers; no manufactured baseline was generated.'
  };
  fs.writeFileSync(path.join(out, 'source-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  if (sourceRef !== 'current') {
    console.error(`UNSUPPORTED historical source ${sourceRef}: selected helper declarations are absent or nonunique`);
    process.exit(2);
  }
  throw new Error(manifest.note);
}

const fixture = read(fixturePath);
const hasOutput = declaration(source, hasOutputMarker);
const movTextClear = declaration(source, movTextMarker);
const timingCue = declaration(source, '    private static func timingCue(');
const collector = declaration(source, '    private static func collectTimingCues(');
const appendCue = declaration(source, appendMarker);
const window = declaration(source, '    struct TimingWindow:');
const cue = declaration(source, '    struct TimingCue:');
const failures = declaration(source, '    enum TimingWindowFailure:');
const projection = declaration(preparation, projectionMarker);
const queryTiming = declaration(query, '    struct Timing:');
const queryWindows = ['    static let scoringWindowStartMs:', '    static let scoringWindowEndMs:',
                      '    static let referenceWindowEndMs:'].map(marker => {
  const at = once(query, marker);
  return query.slice(at, query.indexOf('\n', at));
}).join('\n');
selections.referenceQueryWindows = sha256(queryWindows);
if (count(collector, 'try appendTimingCue(cue, to: &cues)') !== 1 ||
    collector.includes('cues.sorted') || collector.includes('cues.last != cue') ||
    !collector.includes('return (cues, packets)')) {
  throw new Error('Actual collector must use the complete-corpus helper once without deduplication or sorting');
}
const prepare = declaration(preparation, '    nonisolated static func prepare(');
if (count(prepare, 'referenceTimings(from: result.cues, window: request.referenceWindow)') !== 1) {
  throw new Error('Actual worker lost the genuine projection helper call');
}

for (const anchor of [
  'guard packetSize >= 0, bytesConsumed >= 0, bytesConsumed == packetSize else {',
  'return gotSubtitle != 0 && rectangleCount > 0'
]) {
  if (!hasOutput.includes(anchor)) throw new Error(`Selected output helper lost required anchor: ${anchor}`);
}
if (hasOutput.indexOf('guard packetSize') > hasOutput.indexOf('return gotSubtitle')) {
  throw new Error('Selected output helper returns got-output before its full-consumption guard');
}
for (const anchor of [
  'guard codecID == AV_CODEC_ID_MOV_TEXT, packetSize == 2, let data else { return false }',
  'return data[0] == 0 && data[1] == 0'
]) {
  if (!movTextClear.includes(anchor)) throw new Error(`Selected MOV_TEXT helper lost required anchor: ${anchor}`);
}

const predecoder = 'if timingPacketIsMovTextClear(\n            codecID: decoder.pointee.codec_id,\n            packetSize: packet.pointee.size, data: packet.pointee.data) { return nil }';
const decoderCall = 'let code = avcodec_decode_subtitle2(decoder, &subtitle, &got, packet)';
const fullConsumption = 'guard try timingPacketHasOutput(\n            bytesConsumed: code, packetSize: packet.pointee.size,\n            gotSubtitle: got, rectangleCount: subtitle.num_rects) else { return nil }';
const predecoderAt = timingCue.indexOf(predecoder);
const decoderAt = timingCue.indexOf(decoderCall);
const fullConsumptionAt = timingCue.indexOf(fullConsumption);
if (predecoderAt < 0 || decoderAt < 0 || fullConsumptionAt < 0 ||
    !(predecoderAt < decoderAt && decoderAt < fullConsumptionAt)) {
  throw new Error('Actual timingCue lost the required predecoder, decode, or full-consumption order');
}

const generated = fixture
  .replace('// @source:timingPacketHasOutput', hasOutput)
  .replace('// @source:timingPacketIsMovTextClear', movTextClear)
  .replace('// @source:TimingWindowFailure', failures)
  .replace('// @source:TimingWindow', window)
  .replace('// @source:TimingCue', cue)
  .replace('// @source:appendTimingCue', appendCue)
  .replace('// @source:referenceQueryWindows', queryWindows)
  .replace('// @source:referenceQueryTiming', queryTiming)
  .replace('// @source:referenceTimings', projection);
if (generated.includes('// @source:')) throw new Error('Unfilled actual-source fixture slot');
fs.writeFileSync(path.join(out, 'ActualSourceTests.swift'), generated);
fs.writeFileSync(path.join(out, 'source-manifest.json'), JSON.stringify({
  status: 'READY',
  source_ref: sourceRef,
  commit: sourceCommit,
  inputs,
  selections,
  timing_cue_sha256: sha256(timingCue),
  generated_sha256: sha256(generated),
  policy_collaborators: 'AVCodecID is a scalar typealias and the two codec constants are distinct inert policy-only values; this is not genuine Libav enum ABI proof.',
  extraction: 'Complete actual policy/model declarations are inserted byte-for-byte after balanced source selection. timingCue, collectTimingCues and the real prepare helper call are source-checked only; no native decoder call or owner worker is compiled or replaced.'
}, null, 2) + '\n');
NODE

mkdir -p "$test_dir/module-cache"
nice -n 15 xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -warnings-as-errors -j 1 -num-threads 1 -target "$host_arch-apple-macosx14.0" \
  -sdk "$host_sdk" -module-cache-path "$test_dir/module-cache" \
  "$test_dir/ActualSourceTests.swift" -o "$test_dir/tests"
"$test_dir/tests"
printf 'PASS subtitle timing policy; receipt: %s/source-manifest.json\n' "$test_dir"
