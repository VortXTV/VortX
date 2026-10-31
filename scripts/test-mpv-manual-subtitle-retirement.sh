#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
mkdir -p app/build
test_dir=$(mktemp -d app/build/mpv-manual-subtitle-retirement.XXXXXX)
source_ref="${1:-current}"
printf 'Evidence: %s/%s (source: %s)\n' "$repo_root" "$test_dir" "$source_ref"
host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) echo 'Unsupported host architecture' >&2; exit 2 ;; esac
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
node - "$test_dir" "$source_ref" <<'NODE'
const fs = require('node:fs');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const [out, ref] = process.argv.slice(2);
const commit = cp.execFileSync('git', ['rev-parse', '--verify', `${ref === 'current' ? 'HEAD' : ref}^{commit}`], {encoding:'utf8'}).trim();
const inputs = {}, selections = {};
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
function read(path) {
  const text = ref === 'current' ? fs.readFileSync(path, 'utf8') : cp.execFileSync('git', ['show', `${commit}:${path}`], {encoding:'utf8'});
  inputs[path] = sha(text);
  return text;
}
function once(text, marker) {
  const index = text.indexOf(marker);
  if (index < 0 || text.indexOf(marker, index + marker.length) >= 0) throw new Error(`Nonunique/missing source boundary: ${marker}`);
  return index;
}
// Only balanced declaration bodies are admitted. Unlike brace counting, this scanner ignores
// braces in escaped strings and line/nested-block comments. Unsupported literal forms fail closed.
function declaration(text, marker) {
  const start = once(text, marker), open = text.indexOf('{', start + marker.length);
  if (open < 0) throw new Error(`Missing declaration body: ${marker}`);
  let depth = 0, comment = 0, mode = 'code';
  for (let i = open; i < text.length; i++) {
    const c = text[i], n = text[i + 1];
    if (mode === 'line') { if (c === '\n') mode = 'code'; continue; }
    if (mode === 'block') {
      if (c === '/' && n === '*') { comment++; i++; }
      else if (c === '*' && n === '/') { i++; if (--comment === 0) mode = 'code'; }
      continue;
    }
    if (mode === 'string') { if (c === '\\') i++; else if (c === '"') mode = 'code'; continue; }
    if (c === '/' && n === '/') { mode = 'line'; i++; continue; }
    if (c === '/' && n === '*') { mode = 'block'; comment = 1; i++; continue; }
    if ((c === '#' && n === '"') || text.startsWith('"""', i)) throw new Error(`Unsupported literal in selected declaration: ${marker}`);
    if (c === '"') { mode = 'string'; continue; }
    if (c === '{') depth++;
    else if (c === '}' && --depth === 0) {
      const selected = text.slice(start, i + 1);
      selections[marker] = sha(selected);
      return selected;
    }
  }
  throw new Error(`Unclosed selected declaration: ${marker}`);
}
const controller = read('app/Sources/Player/MPVMetalViewController.swift');
const protocol = read('app/Sources/Player/PlayerEngine.swift');
if (!protocol.includes('var subtitleAlignmentRevision: UInt64? { get }')
    || !protocol.includes('var subtitleAlignmentRevision: UInt64? { nil }')) {
  if (ref === 'current') throw new Error('Current PlayerEngine must fail closed for unsupported alignment');
}
const core = read('app/SourcesShared/CoreModels.swift');
const properties = read('app/Sources/Player/MPVProperty.swift');
const native = declaration(controller, 'private final class MPVNativeState: Sendable');
const fullState = declaration(native, '    struct State: Sendable');
const alignmentMarkers = ['        var subtitleAlignmentGeneration: UInt64 = 0',
  '    var subtitleAlignmentRevision: UInt64?', '    private nonisolated func retireSubtitleAlignment()'];
const alignmentParts = alignmentMarkers.filter(marker => controller.includes(marker)).length;
if (alignmentParts !== 0 && alignmentParts !== alignmentMarkers.length) throw new Error('Partial alignment capability');
const supportsAlignment = alignmentParts === alignmentMarkers.length;
const retirementTakeMarker = '    private nonisolated func takeSubtitleAlignmentRetirement() -> (';
const supportsOwnedRetirement = supportsAlignment && controller.includes(retirementTakeMarker);
if (ref === 'current' && !supportsAlignment) throw new Error('Current MPV alignment capability is missing');
const stateMembers = [
  '        var context: MPVNativeHandle?',
  '        var loadProvenance = PlayerLoadProvenanceState()',
  '        var externalSubtitleRequestGeneration: UInt64 = 0'
];
if (supportsAlignment) stateMembers.push(alignmentMarkers[0]);
if (supportsOwnedRetirement) stateMembers.push(
  '        var subtitleAlignmentCancellation: SubtitleEmbeddedExtractor.TimingWindowCancellation?',
  '        var subtitleRendererRegistration: CredentialPublicationOutbox.SubtitleRendererRegistration?',
  '        var alignedSubtitle: MPVAlignedSubtitleRecord?'
);
const remoteCancellationMember = '        var subtitleRemoteCancellation: MPVRemoteReferenceCancellation?';
if (fullState.includes(remoteCancellationMember + '\n')) stateMembers.push(remoteCancellationMember);
for (const member of stateMembers) once(fullState, member + '\n');
const projectedNative = native.replace(fullState, '    struct State: Sendable {\n' + stateMembers.join('\n') + '\n    }');
for (const marker of ['let transaction = NSRecursiveLock()', 'OSAllocatedUnfairLock(initialState: State())', 'transaction.lock(); defer { transaction.unlock() }']) {
  if (!projectedNative.includes(marker)) throw new Error(`Missing real recursive native state boundary: ${marker}`);
}
const blocks = {
  models: declaration(core, 'struct PlayerLoadToken: Hashable, Sendable') + '\n' + declaration(core, 'struct PlayerLoadProvenanceState: Sendable'),
  properties,
  native: projectedNative,
  accessors: [
    '    private nonisolated var nativeContext: MPVNativeHandle?',
    '    private nonisolated var loadTokenLock: NSRecursiveLock',
    '    private nonisolated var loadProvenance: PlayerLoadProvenanceState',
  '    private nonisolated var externalSubtitleRequestGeneration: UInt64',
  '    private nonisolated func callbackLoadToken(requiresLoadedFile: Bool = false)'
  ].map(marker => declaration(controller, marker)).join('\n'),
  primary: declaration(controller, '    func setSubtitleTrack(_ id: Int)'),
  secondary: declaration(controller, '    func setSecondarySubtitleTrack(_ id: Int)'),
  apply: declaration(controller, '    private nonisolated func applyExternalSubtitle('),
  arguments: declaration(controller, '    private nonisolated func makeCArgs(_ command: String, _ args: [String?])'),
  delay: declaration(controller, '    func setSubDelay(_ seconds: Double)'),
  enqueueManualSubtitleProperty: declaration(controller, '    private func enqueueManualSubtitleProperty('),
  mountLocalExternalSubtitle: declaration(controller, '    private nonisolated func mountLocalExternalSubtitle('),
  alignmentAccessor: supportsAlignment ? declaration(controller, alignmentMarkers[1]) : '',
  alignmentTake: supportsOwnedRetirement ? declaration(controller, retirementTakeMarker) : '',
  alignmentRetire: supportsAlignment ? declaration(controller, alignmentMarkers[2]) : '',
  requestIntent: declaration(controller, '        let requestGeneration = native.update')
};
if (supportsAlignment) {
  if (supportsOwnedRetirement) {
    // Retain the literal current retirement-before-reservation prologue, not an old
    // modeled generation increment. Nullable renderer collaborators are never mounted.
    const add = declaration(controller, '    func addExternalSubtitle(');
    const prefix = '        retireSubtitleAlignment()\n';
    const start = once(add, prefix + '        let requestGeneration = native.update');
    if (!blocks.requestIntent.includes('$0.externalSubtitleRequestGeneration &+= 1')
        || blocks.requestIntent.includes('subtitleAlignmentGeneration')) {
      throw new Error('Current external intent must reserve only its independent request revision');
    }
    blocks.requestIntent = add.slice(start, start + prefix.length) + blocks.requestIntent;
  } else if (!blocks.requestIntent.includes('$0.subtitleAlignmentGeneration &+= 1')
      || !blocks.requestIntent.includes('$0.externalSubtitleRequestGeneration &+= 1')) {
    throw new Error('Historical external intent must reserve the independent revisions in one update');
  }
  for (const marker of ['    func invalidateLoadToken()', '    func loadFile(\n', '    private func loadFile(\n']) {
    if (!declaration(controller, marker).includes('retireSubtitleAlignment()')) throw new Error('Missing load retirement: ' + marker);
  }
}
for (const marker of ['context.withBorrow', 'loadTokenLock.lock(); defer { loadTokenLock.unlock() }', 'nativeContext === context', '!context.isRetired', 'externalSubtitleRequestGeneration == requestGeneration', 'PlayerLoadProvenanceState.accepts(', 'return mountLocalExternalSubtitle(localFile, title: title, lang: lang, handle: handle)']) {
  if (!blocks.apply.includes(marker)) throw new Error(`Incomplete final-apply source: ${marker}`);
}
for (const marker of ['context.withBorrow', 'self.loadTokenLock.lock(); defer { self.loadTokenLock.unlock() }', 'self.nativeContext === context', 'self.callbackLoadToken(requiresLoadedFile: false) == load', 'self.setString(name, value, handle: handle)']) {
  if (!blocks.enqueueManualSubtitleProperty.includes(marker)) throw new Error(`Incomplete queued manual-property source: ${marker}`);
}
for (const marker of ['mpv_command(handle, &arguments)', 'for case let pointer? in arguments { free(UnsafeMutablePointer(mutating: pointer)) }']) {
  if (!blocks.mountLocalExternalSubtitle.includes(marker)) throw new Error(`Incomplete exact local-mount source: ${marker}`);
}
if (!blocks.primary.includes('setSecondarySubtitleTrack(-1)') || !blocks.primary.includes('enqueueManualSubtitleProperty(MPVProperty.sid, id < 0 ? "no" : String(id))')) throw new Error('Incomplete actual primary setter');
if (!blocks.secondary.includes('secondarySubtitleID = id') || !blocks.secondary.includes('MPVProperty.secondarySubPos')) throw new Error('Incomplete actual secondary setter');
let fixture = fs.readFileSync('app/Tests/MPVManualSubtitleRetirementTests.swift', 'utf8');
inputs['app/Tests/MPVManualSubtitleRetirementTests.swift'] = sha(fixture);
for (const [name, body] of Object.entries(blocks)) { const marker = `// @source:${name}`; once(fixture, marker); fixture = fixture.replace(marker, body); }
if (fixture.includes('// @source:')) throw new Error('Unfilled actual-source fixture slot');
fs.writeFileSync(`${out}/ActualSourceTests.swift`, fixture);
fs.writeFileSync(`${out}/source-manifest.json`, JSON.stringify({source_ref:ref, commit, supports_alignment:supportsAlignment, supports_owned_retirement:supportsOwnedRetirement, inputs, selections, projected_native_sha256:sha(projectedNative), generated_sha256:sha(fixture), projection:'Actual context/provenance/request/alignment fields and recursive transaction/storage/accessors; actual request retirement/reservation, selection, delay, scalar take and final apply. Native C API, queue-owned context and property recorder are inert checked test collaborators. Owned renderer/cancellation fields remain nil; their fixture-only collaborators reject unexpected invocation. No mounted-renderer cleanup, native owned subtitle, account/profile or full-player runtime proof.'}, null, 2) + '\n');
NODE
alignment_flags=(-D VORTX_SUBTITLE_RETIREMENT_FIXTURE)
if [[ "$(node -p "require('./$test_dir/source-manifest.json').supports_alignment")" == true ]]; then
  alignment_flags+=(-D VORTX_CURRENT_ALIGNMENT)
fi
nice -n 15 xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -warnings-as-errors -j 1 -num-threads 1 "${alignment_flags[@]}" -target "$host_arch-apple-macosx14.0" -sdk "$host_sdk" \
  -module-cache-path "$test_dir/module-cache" "$test_dir/ActualSourceTests.swift" -o "$test_dir/tests"
"$test_dir/tests"
