#!/usr/bin/env bash
set -euo pipefail
art_script_dir="$(cd "$(dirname "$0")" && pwd)"
art_root="$(cd "$art_script_dir/.." && pwd)"
mkdir -p "$art_root/app/build"
art_receipt="$(mktemp -d "$art_root/app/build/player-first-frame-artwork.XXXXXX")"
node --input-type=module - "$art_root" "$art_receipt" <<'NODE'
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
const [root, out] = process.argv.slice(2);
function declaration(source, signature) {
  const start = source.indexOf(signature);
  assert(start >= 0 && source.indexOf(signature, start + signature.length) < 0, `unique ${signature}`);
  let depth = 0, open = false, state = 'code', escaped = false;
  for (let i = start; i < source.length; i++) {
    const c = source[i], n = source[i + 1];
    if (state === 'line') { if (c === '\n') state = 'code'; continue; }
    if (state === 'block') { if (c === '*' && n === '/') { state = 'code'; i++; } continue; }
    if (state === 'string') { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') state = 'code'; continue; }
    if (c === '/' && n === '/') { state = 'line'; i++; continue; }
    if (c === '/' && n === '*') { state = 'block'; i++; continue; }
    if (c === '"') { state = 'string'; continue; }
    if (c === '{') { depth++; open = true; }
    if (c === '}' && open && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`unterminated ${signature}`);
}
const paths = ['app/SourcesShared/PlayerFirstFrameCoverPolicy.swift', 'app/SourcesShared/PlayerFirstFrameArtwork.swift',
  'app/Sources/PlayerScreen.swift', 'app/SourcesTV/TVPlayerView.swift',
  'app/Sources/Player/ApplePlaybackRecoveryPolicy.swift', 'app/Tests/PlayerFirstFrameCoverTests.swift'];
for (const path of paths.slice(2, 4)) {
  const source = readFileSync(resolve(root, path), 'utf8');
  const handler = declaration(source, 'private func handleProperty(_ name: String, _ data: Any?, loadToken: PlayerLoadToken? = nil)');
  assert(handler.length < 75_000, 'bound actual callback transaction');
  const receipt = handler.indexOf('publishAssetSanityStartEffectsIfNeeded(');
  assert(receipt >= 0, 'actual caller consumes shared policy');
  for (const guard of ['ApplePlaybackStartPolicy.hasStarted(', 'guard admitIncomingEpisodeAudio(',
    'guard settleAssetSanityIfPossible(', 'guard commitPendingAdvanceOnFirstFrame(']) {
    assert(handler.indexOf(guard) >= 0 && handler.indexOf(guard) < receipt, `cover retirement follows ${guard}`);
  }
  const publisher = declaration(source, 'private func publishAssetSanityStartEffectsIfNeeded(');
  assert(publisher.includes('firstFrameCover.acceptStart('));
  for (const gate of ['pendingAdvance == nil', 'assetSanityDeferredStartToken == loadToken', 'assetSanityAttempt.isAccepted(owner: loadToken)']) {
    assert(publisher.indexOf(gate) >= 0 && publisher.indexOf(gate) < publisher.indexOf('firstFrameCover.acceptStart('), `actual start receipt requires ${gate}`);
  }
  assert(publisher.includes('accepted: true'), 'signal is accepted only inside existing first-start/asset transaction');
  assert(publisher.indexOf('firstFrameCover.acceptStart(') < publisher.indexOf('assetSanityStartEffectsToken = loadToken'),
    'delayed acceptance can reveal before the one-shot side-effects latch');
  assert(handler.includes('firstFrameCover.bind(owner: loadToken,'), 'initial surface binds an exact active callback owner');
  const load = declaration(source, path.includes('SourcesTV') ? 'private func loadIntoPlayer(_ url: URL,' : 'private func loadIntoPlayer(_ u: URL,');
  const bind = load.indexOf('firstFrameCover.bind(owner: issuedToken,');
  assert(bind > load.indexOf('if let issuedToken {'), 'refused load does not replace cover owner');
  assert(source.includes('firstFrameCover.retire()') && source.includes('firstFrameCover.beginPresentation()'));
  assert(source.includes('.id(firstFrameCoverMedia)'), 'new media cannot retain outgoing image/logo task state');
  const media = declaration(source, 'private var firstFrameCoverMetadata: PlaybackMeta?');
  assert(media.includes('pendingAdvance?.issued == true'), 'unissued resolver does not prematurely change visible artwork');
  const layer = declaration(source, 'private var firstFrameCoverLayer: some View');
  assert(!layer.includes('buffering') && !layer.includes('hasStartedPlaying'), 'buffer/recovery flags do not re-cover healthy playback');
  const surface = source.indexOf('\n            playerSurface\n');
  const cover = source.indexOf('\n            firstFrameCoverLayer\n', surface);
  const input = source.indexOf(path.includes('SourcesTV') ? '\n            RemoteCatcher(' : 'PlayerVideoInteractionSurface(', surface);
  assert(surface >= 0 && cover > surface && input > cover, 'decorative art remains below input/controls/error layers');
}
const view = readFileSync(resolve(root, paths[1]), 'utf8');
assert(view.includes('ResolvedTitleLogo(') && view.includes('FallbackArtwork('));
assert(view.includes('.allowsHitTesting(false)') && view.includes('.accessibilityHidden(true)'));
assert(view.includes('reduceMotion ? nil') && view.includes('HeroArtworkQualityPolicy.fullHDLongEdge') && view.includes('HeroArtworkQualityPolicy.mobileLongEdge'));
const start = readFileSync(resolve(root, paths[4]), 'utf8');
assert(start.includes('guard let avPlayerEvidence else { return positionSeconds > 0 }'),
  'honest MPV settled-clock startup boundary; not a fabricated physical frame receipt');
writeFileSync(resolve(out, 'source-sha256.txt'), paths.map(path => {
  const absolute = resolve(root, path);
  return `${createHash('sha256').update(readFileSync(absolute)).digest('hex')}  ${absolute}`;
}).join('\n') + '\n');
console.log('PASS bounded actual Apple caller wiring; backend first-start evidence limitations retained');
NODE
nice -n 15 xcrun swiftc -j 1 -num-threads 1 -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library "$art_root/app/SourcesShared/PlayerFirstFrameCoverPolicy.swift" \
  "$art_root/app/Tests/PlayerFirstFrameCoverTests.swift" -o "$art_receipt/checks" 2>&1 | tee "$art_receipt/compile.log"
nice -n 15 "$art_receipt/checks" 2>&1 | tee "$art_receipt/checks.log"
shasum -a 256 -c "$art_receipt/source-sha256.txt"
printf 'Retained first-frame artwork policy receipt: %s\n' "$art_receipt"
