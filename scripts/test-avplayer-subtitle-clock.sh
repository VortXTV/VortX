#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
subtitle_test_dir=$(mktemp -d app/build/avplayer-subtitle-clock.XXXXXX)
source_ref="${1:-current}"
if [[ "$source_ref" != current ]]; then
  git show "$source_ref:app/Sources/Player/AVPlayerEngine.swift" > "$subtitle_test_dir/engine.swift"
else
  cp app/Sources/Player/AVPlayerEngine.swift "$subtitle_test_dir/engine.swift"
fi
printf 'Evidence: %s/%s (engine source: %s)\n' "$PWD" "$subtitle_test_dir" "$source_ref"
# Extract current production bodies verbatim; only their fixture access level changes.
# The historical-ref option changes the engine snapshot only, as before. All other inputs are frozen current files.
node - "$subtitle_test_dir" "$source_ref" <<'NODE'
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const [out, ref] = process.argv.slice(2);
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const inputs = {};
const remember = file => { inputs[path.resolve(file)] = sha(fs.readFileSync(file)); };
const freeze = file => {
  const bytes = fs.readFileSync(file), target = path.join(out, path.basename(file));
  inputs[path.resolve(file)] = sha(bytes); fs.writeFileSync(target, bytes); remember(target);
  return bytes.toString('utf8');
};
const source = fs.readFileSync(`${out}/engine.swift`, 'utf8');
remember(`${out}/engine.swift`);
if (ref === 'current') {
  const original = 'app/Sources/Player/AVPlayerEngine.swift';
  if (sha(fs.readFileSync(original)) !== sha(source)) throw Error('Engine changed during snapshot');
  remember(original);
}
function once(text, marker) {
  const at = text.indexOf(marker);
  if (at < 0 || text.indexOf(marker, at + marker.length) >= 0) throw Error('Missing/duplicate source boundary: ' + marker);
  return at;
}
function method(text, marker) {
  const begin = once(text, marker), end = text.indexOf('\n    }', begin);
  if (end < 0) throw Error('Missing method end: ' + marker);
  return text.slice(begin, end + '\n    }'.length);
}
const withoutComments = text => text.replace(/\/\/[^\n]*/g, '').trimStart();
const body = marker => {
  const value = method(source, marker), open = value.indexOf('{');
  if (open < 0) throw Error('Missing method body: ' + marker);
  return withoutComments(value.slice(open + 1));
};
const parts = ['    private var subtitleAlignmentGeneration: UInt64 = 0',
  '    var subtitleAlignmentRevision: UInt64?', '    private func retireSubtitleAlignment('];
const present = parts.filter(marker => source.includes(marker)).length;
if (present !== 0 && present !== parts.length) throw Error('Partial AV alignment capability');
const supportsAlignment = present === parts.length;
if (ref === 'current' && !supportsAlignment) throw Error('Current AV alignment capability missing');
const automaticParts = ['private final class AutomaticSubtitleRequest',
  '    private var alignedSubtitlePublication:', '    private var alignedSubtitleClock = SubtitleReferencePresentation.Clock()'];
const automaticPresent = automaticParts.filter(marker => source.includes(marker)).length;
if (automaticPresent !== 0 && automaticPresent !== automaticParts.length) throw Error('Partial AVKit request capability');
const automaticRequests = automaticPresent === automaticParts.length;
if (automaticRequests && !supportsAlignment) throw Error('AVKit request state without alignment retirement');
const retirementCauseMarker = 'private enum AVSubtitleRequestRetirementCause: Equatable {';
const typedRetirementCauses = source.includes(retirementCauseMarker);
if (ref === 'current' && !typedRetirementCauses) throw Error('Current AVKit alignment retirement cause is missing');
const alignmentRetirement = typedRetirementCauses
  ? 'retireSubtitleAlignment(cause: .successor)' : 'retireSubtitleAlignment()';
const contracts = {};
if (supportsAlignment) {
  const entryMarkers = ['    func invalidateLoadToken()', '    func loadFile(', '    func setSubtitleTrack(',
    '    func addExternalSubtitle(', '    private func disableExternalSubtitle(', '    func setSubDelay('];
  const statementLines = marker => body(marker).split(/\n/).map(line => line.trim()).filter(Boolean);
  const contributionLoadExists = source.includes('    private func retireSubtitleContributionLoad()');
  for (let index = 0; index < entryMarkers.length; index++) {
    const marker = entryMarkers[index], lines = statementLines(marker);
    let expected;
    if (index < 2 && contributionLoadExists) {
      expected = ['retireSubtitleContributionLoad()', alignmentRetirement];
    } else {
      expected = [alignmentRetirement];
    }
    if (lines.length < expected.length || expected.some((line, offset) => lines[offset] !== line)) {
      throw Error('Missing ordered entry retirement: ' + marker);
    }
    contracts[marker] = 'entry-retirement-source-contract';
  }
  for (const marker of ['    private func selectNativeSubtitle(', '    private func setExternalSubtitleActive(']) {
    const first = body(marker);
    if (automaticRequests) {
      const retirement = typedRetirementCauses
        ? 'retireSubtitleAlignment\\(cause: \\.successor\\)' : 'retireSubtitleAlignment\\(\\)';
      const expected = marker.includes('setExternalSubtitleActive')
        ? new RegExp(`^if let original \\{\\s*guard automaticSubtitleRequestIsCurrent\\(original\\) else \\{ return \\}\\s*automaticSubtitleRequest\\?\\.rawSettled = active\\s*\\} else \\{ ${retirement} \\}`)
        : new RegExp(`^if let original \\{\\s*guard automaticSubtitleRequestIsCurrent\\(original\\) else \\{ return \\}\\s*\\} else \\{ ${retirement} \\}`);
      if (!expected.test(first)) throw Error('Missing owned-preservation/manual-retirement branch: ' + marker);
      contracts[marker] = 'owned-preservation/manual-retirement-source-contract-only';
    } else {
      if (!first.startsWith(alignmentRetirement)) throw Error('Missing entry retirement: ' + marker);
      contracts[marker] = 'entry-retirement-source-contract';
    }
  }
  const fallback = once(source, '        let freshItem = AVPlayerItem(asset: AVURLAsset(url: fallbackURL))');
  if (!source.slice(fallback - 90, fallback).trimEnd().endsWith(alignmentRetirement)) throw Error('HDR fallback must retire previous preparation');
  const notification = method(source, '    @objc private func mediaSelectionDidChange(');
  const admission = '              owns(changedItem, loadToken: loadToken) else { return }';
  const afterGuard = withoutComments(notification.slice(once(notification, admission) + admission.length));
  if (automaticRequests) {
    const expectedStart = 'if let original = automaticSubtitleRequest, ownsAutomaticSubtitle(original),';
    if (!afterGuard.startsWith(expectedStart)) throw Error('Selection notification lost its owned-request exemption');
    const retirement = once(afterGuard, '        retireSubtitleAlignment()');
    const exemption = afterGuard.slice(0, retirement);
    for (const marker of ['original.selectionRevision == subtitleSelectionRevision',
      'changedItem.currentMediaSelection.selectedMediaOption(in: group) == nil',
      'externalSubtitleSettlement.consumeIfNativeDeselected(',
      'setExternalSubtitleActive(true, preservingAutomaticRequest: original.generation)',
      'if original.rawSettled && externalSubActive']) once(exemption, marker);
    if (!afterGuard.slice(retirement).startsWith('        retireSubtitleAlignment()\n        retireBadgeMetadata()')) throw Error('Selection retirement order changed');
  } else if (!afterGuard.startsWith('retireSubtitleAlignment()')) {
    throw Error('System selection retirement must follow original admission guard');
  }
  const delay = method(source, '    func setSubDelay(');
  if (delay.includes('externalSubtitleRequestRevision') || delay.includes('subtitleSelectionRevision')) throw Error('Timing edit must not cancel fetch or native settlement');
  contracts.hdr_and_notification = 'source-order-only; no AVFoundation execution';
}
const methods = [method(source, '    private func setExternalSubtitleActive('),
  method(source, '    func setSubDelay('), method(source, '    private func updateSubtitleOverlay(')];
if (supportsAlignment) {
  const getter = source.slice(once(source, '    var subtitleAlignmentRevision: UInt64?')).split('\n')[0];
  methods.push(getter, method(source, '    private func retireSubtitleAlignment('));
}
fs.writeFileSync(`${out}/production-methods.swift`, 'import Foundation\n@MainActor extension SubtitleClockFixtureEngine {\n'
  + methods.join('\n').replace(/private func /g, 'func ') + '\n}\n');
const renderer = freeze('app/Sources/Player/SubtitleCueRenderer.swift');
const budgetStart = once(renderer, 'enum SubtitleFileBudget {');
const budgetEnd = renderer.indexOf('\n}', budgetStart);
const cueStart = once(renderer, 'struct SubtitleCue:');
const parsing = once(renderer, '    // MARK: - Parsing');
if (budgetEnd < 0 || parsing < cueStart) throw Error('Renderer extraction boundary changed');
fs.writeFileSync(`${out}/renderer.swift`, 'import Foundation\n' + renderer.slice(budgetStart, budgetEnd + 2) + '\n'
  + renderer.slice(cueStart, parsing) + method(renderer, '    nonisolated private static func boundedCues(') + '\n}\n');
freeze('app/Sources/Player/RemuxResumePolicy.swift');
freeze('app/Tests/AVPlayerSubtitleClockTests.swift');
if (automaticRequests) {
  freeze('app/Sources/Player/AVPlayerRecoverySettlementPolicy.swift');
  freeze('app/SourcesShared/SubtitleReferencePresentation.swift');
  const query = freeze('app/SourcesShared/SubtitleReferenceNativeQuery.swift');
  // Exact production transport DTOs only. No native query implementation, decoder stand-in, owner or capture grant.
  const end = once(query, '    private struct External:');
  fs.writeFileSync(`${out}/native-query-values.swift`, query.slice(0, end) + '}\n');
}
fs.writeFileSync(`${out}/capabilities.env`, `alignment=${Number(supportsAlignment)}\nautomatic_requests=${Number(automaticRequests)}\n`);
fs.writeFileSync(`${out}/deny-network.sb`, '(version 1)\n(allow default)\n(deny network*)\n');
remember('scripts/test-avplayer-subtitle-clock.sh');
for (const file of ['production-methods.swift', 'renderer.swift', 'capabilities.env', 'deny-network.sb',
  ...(automaticRequests ? ['native-query-values.swift'] : [])]) remember(`${out}/${file}`);
const manifest = {source_ref: ref, supports_alignment: supportsAlignment, automatic_requests: automaticRequests,
  inputs, contracts, scope: 'Exact production activation/delay/update/retirement/getter and cue storage/lookup; actual RemuxResumePolicy, recovery settlement and pure Presentation/Clock. AV clock and raw visual overlay are inert doubles. Automatic admission, request/publication access and corrected-overlay publication trap if entered; no capture, owner grant, native query, AVFoundation runtime or automatic adoption is exercised. Historical ref selects engine only; remaining recorded inputs are current.'};
const bytes = JSON.stringify(manifest, null, 2) + '\n';
fs.writeFileSync(`${out}/source-manifest.json`, bytes);
fs.writeFileSync(`${out}/manifest.sha256`, sha(bytes) + '\n');
NODE
# The generated capabilities file contains only the two validated Boolean assignments above.
source "$subtitle_test_dir/capabilities.env"
verify_inputs() {
  node - "$subtitle_test_dir" "${1:-inputs}" <<'NODE'
const fs = require('node:fs'), crypto = require('node:crypto');
const [out, phase] = process.argv.slice(2), sha = value => crypto.createHash('sha256').update(value).digest('hex');
const bytes = fs.readFileSync(`${out}/source-manifest.json`);
if (sha(bytes) !== fs.readFileSync(`${out}/manifest.sha256`, 'utf8').trim()) throw Error('Source manifest changed');
const manifest = JSON.parse(bytes);
for (const [file, expected] of Object.entries(manifest.inputs)) {
  if (sha(fs.readFileSync(file)) !== expected) throw Error('Input changed: ' + file);
}
if (phase === 'seal') {
  fs.writeFileSync(`${out}/binary.sha256`, sha(fs.readFileSync(`${out}/subtitle-clock`)) + '\n', {flag: 'wx'});
} else if (phase === 'binary') {
  if (sha(fs.readFileSync(`${out}/subtitle-clock`)) !== fs.readFileSync(`${out}/binary.sha256`, 'utf8').trim()) throw Error('Compiled binary changed');
}
NODE
}
host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) echo 'Unsupported host architecture' >&2; exit 2 ;; esac
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$subtitle_test_dir/module-cache"
language_flags=(-swift-version 5)
sources=("$subtitle_test_dir/RemuxResumePolicy.swift" "$subtitle_test_dir/renderer.swift")
if [[ "$alignment" -eq 1 ]]; then language_flags=(-swift-version 6 -D VORTX_CURRENT_ALIGNMENT); fi
if [[ "$automatic_requests" -eq 1 ]]; then
  language_flags+=(-D VORTX_AVKIT_ALIGNMENT_REQUEST)
  sources+=("$subtitle_test_dir/AVPlayerRecoverySettlementPolicy.swift" "$subtitle_test_dir/native-query-values.swift"
    "$subtitle_test_dir/SubtitleReferencePresentation.swift")
fi
sources+=("$subtitle_test_dir/production-methods.swift" "$subtitle_test_dir/AVPlayerSubtitleClockTests.swift")
verify_inputs
nice -n 15 xcrun swiftc -parse-as-library "${language_flags[@]}" -strict-concurrency=complete -warnings-as-errors \
  -j 1 -num-threads 1 -target "$host_arch-apple-macosx14.0" -sdk "$host_sdk" \
  -module-cache-path "$subtitle_test_dir/module-cache" \
  "${sources[@]}" \
  -o "$subtitle_test_dir/subtitle-clock"
verify_inputs seal
verify_inputs binary
/usr/bin/sandbox-exec -f "$subtitle_test_dir/deny-network.sb" "$subtitle_test_dir/subtitle-clock"
verify_inputs binary
