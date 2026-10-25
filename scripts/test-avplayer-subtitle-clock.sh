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
alignment=0
if grep -Fq '    var subtitleAlignmentRevision: UInt64?' "$subtitle_test_dir/engine.swift"; then alignment=1; fi
printf 'Evidence: %s/%s (source: %s; alignment: %s)\n' "$PWD" "$subtitle_test_dir" "$source_ref" "$alignment"
# Exact production call sites and renderer, with only the AV clock / visual overlay replaced by inert doubles.
{
  printf '%s\n' 'import Foundation' '@MainActor extension SubtitleClockFixtureEngine {'
  sed -n '/    private func setExternalSubtitleActive(/,/^    }/p' "$subtitle_test_dir/engine.swift"
  sed -n '/    func setSubDelay(/,/^    }/p' "$subtitle_test_dir/engine.swift"
  sed -n '/    private func updateSubtitleOverlay(/,/^    }/p' "$subtitle_test_dir/engine.swift"
  if [[ "$alignment" -eq 1 ]]; then
    sed -n '/^    var subtitleAlignmentRevision: UInt64?/p' "$subtitle_test_dir/engine.swift"
    sed -n '/    private func retireSubtitleAlignment(/,/^    }/p' "$subtitle_test_dir/engine.swift"
  fi
  printf '%s\n' '}'
} | sed 's/private func /func /' > "$subtitle_test_dir/production-methods.swift"
{
  printf '%s\n' 'import Foundation'
  sed -n '/^enum SubtitleFileBudget {/,/^}/p' app/Sources/Player/SubtitleCueRenderer.swift
  # Only the real cue storage/bounds/offset/lookup are needed. Exclude parsing, downloads and native views.
  sed -n '/^struct SubtitleCue:/,/    \/\/ MARK: - Parsing/p' \
    app/Sources/Player/SubtitleCueRenderer.swift | sed '$d'
  sed -n '/    nonisolated private static func boundedCues(/,/^    }/p' app/Sources/Player/SubtitleCueRenderer.swift
  printf '%s\n' '}'
} > "$subtitle_test_dir/renderer.swift"
node - "$subtitle_test_dir" "$source_ref" <<'NODE'
const fs = require('node:fs'), crypto = require('node:crypto');
const [out, ref] = process.argv.slice(2);
const source = fs.readFileSync(`${out}/engine.swift`, 'utf8');
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const parts = ['    private var subtitleAlignmentGeneration: UInt64 = 0',
  '    var subtitleAlignmentRevision: UInt64?', '    private func retireSubtitleAlignment()'];
const present = parts.filter(marker => source.includes(marker)).length;
if (present !== 0 && present !== parts.length) throw Error('Partial AV alignment capability');
const supportsAlignment = present === parts.length;
if (ref === 'current' && !supportsAlignment) throw Error('Current AV alignment capability missing');
const contracts = {};
function once(marker) {
  const at = source.indexOf(marker);
  if (at < 0 || source.indexOf(marker, at + marker.length) >= 0) throw Error('Missing/duplicate source boundary: ' + marker);
  return at;
}
function withoutComments(text) { return text.replace(/^(?:\s|\/\/[^\n]*(?:\n|$))*/, ''); }
if (supportsAlignment) {
  for (const marker of ['    func invalidateLoadToken()', '    func loadFile(', '    func setSubtitleTrack(',
    '    private func selectNativeSubtitle(', '    private func setExternalSubtitleActive(',
    '    func addExternalSubtitle(', '    private func disableExternalSubtitle(', '    func setSubDelay(']) {
    const at = once(marker), open = source.indexOf('{', at + marker.length);
    const first = withoutComments(source.slice(open + 1));
    if (open < 0 || !first.startsWith('retireSubtitleAlignment()')) throw Error('Missing entry retirement: ' + marker);
    contracts[marker] = 'entry-retirement-source-contract';
  }
  const fallback = once('        let freshItem = AVPlayerItem(asset: AVURLAsset(url: fallbackURL))');
  if (!source.slice(fallback - 60, fallback).trimEnd().endsWith('retireSubtitleAlignment()')) throw Error('HDR fallback must retire previous preparation');
  const notification = once('              owns(changedItem, loadToken: loadToken) else { return }');
  const afterGuard = source.slice(notification + '              owns(changedItem, loadToken: loadToken) else { return }'.length);
  if (!withoutComments(afterGuard).startsWith('retireSubtitleAlignment()')) throw Error('System selection retirement must follow original admission guard');
  const begin = once('    func setSubDelay('), end = source.indexOf('\n    }', begin);
  const delay = source.slice(begin, end);
  if (delay.includes('externalSubtitleRequestRevision') || delay.includes('subtitleSelectionRevision')) throw Error('Timing edit must not cancel fetch or native settlement');
  contracts.hdr_and_notification = 'source-order-only';
}
const files = [`${out}/engine.swift`, `${out}/production-methods.swift`, `${out}/renderer.swift`,
  'app/Sources/Player/RemuxResumePolicy.swift', 'app/Sources/Player/SubtitleCueRenderer.swift',
  'app/Tests/AVPlayerSubtitleClockTests.swift', 'scripts/test-avplayer-subtitle-clock.sh'];
const inputs = Object.fromEntries(files.map(file => [file, sha(fs.readFileSync(file))]));
fs.writeFileSync(`${out}/source-manifest.json`, JSON.stringify({source_ref:ref, supports_alignment:supportsAlignment, inputs, contracts,
  scope:'Actual activation/delay/update/getter/helper and cue storage/lookup; AV clock/visual overlay are inert doubles. Other lifecycle/selection retirement is source-asserted only, not AVFoundation runtime.'}, null, 2) + '\n');
NODE
host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) echo 'Unsupported host architecture' >&2; exit 2 ;; esac
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$subtitle_test_dir/module-cache"
language_flags=(-swift-version 5)
if [[ "$alignment" -eq 1 ]]; then language_flags=(-swift-version 6 -D VORTX_CURRENT_ALIGNMENT); fi
nice -n 15 xcrun swiftc -parse-as-library "${language_flags[@]}" -strict-concurrency=complete -warnings-as-errors \
  -j 1 -num-threads 1 -target "$host_arch-apple-macosx14.0" -sdk "$host_sdk" \
  -module-cache-path "$subtitle_test_dir/module-cache" \
  app/Sources/Player/RemuxResumePolicy.swift "$subtitle_test_dir/renderer.swift" \
  "$subtitle_test_dir/production-methods.swift" app/Tests/AVPlayerSubtitleClockTests.swift \
  -o "$subtitle_test_dir/subtitle-clock"
"$subtitle_test_dir/subtitle-clock"
