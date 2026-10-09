#!/usr/bin/env node
// Generates only inert build fixtures. Production source bytes are extracted, never modified.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const baseline = process.argv.includes('--baseline');
const prepareOnly = process.argv.includes('--prepare-only');
const base = '844782d29a93ae51991bfadc639d50bc3619d40b';
fs.mkdirSync(path.join(root, 'app/build'), { recursive: true });
const build = fs.mkdtempSync(path.join(root, 'app/build/infuse-return-'));
const hashes = {};
function source(file, old = baseline) {
  const bytes = old ? execFileSync('git', ['-C', root, 'show', `${base}:${file}`]) : fs.readFileSync(path.join(root, file));
  hashes[`${old ? base : 'candidate'}:${file}`] = crypto.createHash('sha256').update(bytes).digest('hex');
  return bytes.toString('utf8');
}
function between(text, start, end) {
  const a = text.indexOf(start), b = text.indexOf(end, a + start.length);
  if (a < 0 || b < 0) throw new Error(`Missing extraction boundary ${start}`);
  return text.slice(a, b);
}
function member(text, start) {
  const a = text.indexOf(start);
  let first = -1, parentheses = 0;
  for (let i = a; i >= 0 && i < text.length; i++) {
    if (text[i] === '(') parentheses++;
    if (text[i] === ')') parentheses--;
    // Default closure arguments are part of the signature, not the member body.
    if (text[i] === '{' && parentheses === 0) { first = i; break; }
  }
  if (a < 0 || first < 0) throw new Error(`Missing member ${start}`);
  let depth = 0;
  for (let i = first; i < text.length; i++) {
    if (text[i] === '{') depth++;
    if (text[i] === '}' && --depth === 0) return text.slice(a, i + 1);
  }
  throw new Error(`Unbalanced member ${start}`);
}
const account = source('app/SourcesShared/StremioAccount.swift');
const core = source('app/SourcesShared/CoreBridge.swift');
const tvPlayer = source('app/SourcesTV/TVPlayerView.swift');
const iosPlayer = source('app/Sources/PlayerScreen.swift');
let test = source('app/Tests/InfuseReturnTests.swift', false);
const insertions = {
  OWNERSHIP_POLICY: source('app/SourcesShared/PlaybackMutationOwnershipPolicy.swift'),
  PLAYBACK_METADATA: member(account, 'struct PlaybackMeta: Hashable'),
  OWNER_EXTENSION: 'typealias PlaybackMutationTarget = PlaybackMutationOwnershipPolicy.Target\n' + member(account, 'extension PlaybackMutationTarget'),
  SERIES_LIFECYCLE: member(source('app/SourcesShared/CoreModels.swift'), 'static func usesSeriesLifecycle(type:'),
  NATIVE_BOUNDARY: between(core, '    func captureNativePlaybackTarget()', '    private func nativeWatchedIntent('),
  ACCOUNT_PROGRESS: member(account, 'func saveProgress(for meta:'),
  INFUSE_LINK: source('app/SourcesShared/InfuseDeepLink.swift'),
  TRANSFER_POLICY: source('app/SourcesShared/SourcePlayerChoicePolicy.swift'),
  TV_EXIT: member(tvPlayer, 'private func leavePlayback('),
  TV_PROGRESS: member(tvPlayer, 'private func saveProgress(').replace('PlayerLoadToken?', 'UUID?'),
  IOS_INVALIDATE: member(iosPlayer, 'private func invalidateEpisodeWorkForExit()'),
  IOS_PROGRESS: member(iosPlayer, 'private func reportProgress(').replace('PlayerLoadToken?', 'UUID?'),
  IOS_ACCOUNT_PROGRESS: member(iosPlayer, 'private func saveAccountProgress(').replace('PlayerLoadToken?', 'UUID?'),
};
if (!baseline) {
  const adapter = source('app/SourcesShared/ExternalPlaybackHandoff.swift');
  // Remove only SwiftUI presentation infrastructure; callback/ownership/mutation methods stay verbatim.
  insertions.ADAPTER = adapter.slice(0, adapter.indexOf('/// Mounted above the normal shell'))
    .replace('import SwiftUI', 'import Foundation')
    .replace('final class ExternalPlaybackHandoff: ObservableObject', 'final class ExternalPlaybackHandoff')
    .replace('@Published private(set) var presentation:', 'private(set) var presentation:');
  insertions.COORDINATOR = source('app/SourcesShared/InfuseHandoffCoordinator.swift');
  insertions.APPLE_OPEN = member(source('app/Sources/ExternalPlayer.swift'), '@MainActor static func open(');
  insertions.TV_OPEN = '@MainActor\n' + member(source('app/SourcesTV/ExternalPlayers.swift'), 'static func open(_ streamURL:');
  const tvDefault = member(tvPlayer, 'private func maybeRouteToDefaultExternalPlayer()');
  insertions.TV_DEFAULT_FENCE = member(tvDefault, 'let allowsLaunch =');
}
for (const [key, value] of Object.entries(insertions)) {
  const marker = `// INSERT_${key}`;
  if (!test.includes(marker)) throw new Error(`Missing fixture marker ${key}`);
  test = test.replace(marker, () => value);
}
if (!baseline && /\/\/ INSERT_/.test(test)) throw new Error('Unfilled candidate fixture marker');
fs.writeFileSync(path.join(build, 'fixture.swift'), test);
fs.writeFileSync(path.join(build, 'source-hashes.json'), JSON.stringify(hashes, null, 2) + '\n');
console.log(`Fixture evidence: ${build}`);
const args = ['swiftc', '-parse-as-library', '-strict-concurrency=complete', '-warnings-as-errors', '-D', 'VORTX_NATIVE_DATA_ENGINE'];
if (baseline) args.push('-D', 'BASELINE');
args.push(path.join(build, 'fixture.swift'), '-o', path.join(build, 'fixture'));
fs.writeFileSync(path.join(build, 'commands.json'), JSON.stringify({ root, baseline, base, compiler: ['xcrun', ...args], compilerTimeoutMs: 60000, execute: [path.join(build, 'fixture')], runtimeTimeoutMs: 20000 }, null, 2) + '\n');
if (prepareOnly) process.exit(0);
try {
  execFileSync('xcrun', args, { cwd: root, stdio: 'inherit', timeout: 60000 });
  execFileSync(path.join(build, 'fixture'), [], { cwd: root, stdio: 'inherit', timeout: 20000 });
} catch (error) {
  if (error.code === 'ETIMEDOUT') console.error('FAIL bounded fixture subprocess deadline');
  process.exit(error.status ?? 1);
}

if (!baseline) {
  let checks = 0;
  function check(label, condition) {
    if (!condition) throw new Error(`FAIL source contract: ${label}`);
    checks++; console.log(`PASS source contract: ${label}`);
  }
  const player = source('app/Sources/PlayerScreen.swift', false);
  const tv = source('app/SourcesTV/TVPlayerView.swift', false);
  const iosDetail = source('app/SourcesiOS/iOSDetailView.swift', false);
  const tvDetail = source('app/SourcesTV/DetailView.swift', false);
  check('both player handoffs retain metadata and full request',
    player.includes('metadata: curMeta, handoff: infuseHandoff)')
    && player.split('metadata: curMeta, handoff: infuseHandoff)').length === 3);
  check('both TV player handoffs retain metadata and full request', tv.split('metadata: curMeta, handoff: handoff)').length === 3);
  check('both source-row handoffs carry request and chosen preference', iosDetail.includes('metadata: playbackMeta, handoff: handoff)')
    && tvDetail.includes('metadata: meta, handoff: handoff)')
    && [iosDetail, tvDetail].every(s => s.includes('addon: addon, bingeGroup: stream.behaviorHints?.bingeGroup')));
  check('observed duration is gated by exact accepted media on each player',
    player.includes('assetSanityAttempt.isAccepted(owner: externalHandoffLoadToken) && !effectivelyLive ? duration : nil')
    && tv.includes('assetSanityAttempt.isAccepted(owner: owner) && !isCurrentLiveStream ? duration : nil'));
  check('new player sessions retire old callbacks', [player, tv].every(s => s.includes('ExternalPlaybackHandoff.shared.enteredInternalPlayer()')));
  const iosApp = source('app/SourcesiOS/VortXiOSApp.swift', false), tvApp = source('app/SourcesTV/VortXTVApp.swift', false);
  check('both app roots route callback and present return flow', [iosApp, tvApp].every(s => s.includes('.externalPlaybackReturns()') && s.includes('ExternalPlaybackHandoff.shared.handle($0)')));
  check('TV capability callback precedes generic diagnostics router', tvApp.includes('if !ExternalPlaybackHandoff.shared.handle($0) { DeepLinkRouter.shared.handle($0) }'));
  for (const plist of ['app/Resources/Info-iOS.plist', 'app/Resources/Info-macOS.plist']) {
    const data = source(plist, false);
    check(`${plist} uses per-bundle callback scheme`, data.includes('<key>CFBundleURLSchemes</key><array><string>$(PRODUCT_BUNDLE_IDENTIFIER).infuse</string>')
      && data.includes('<key>VortXURLScheme</key><string>$(PRODUCT_BUNDLE_IDENTIFIER).infuse</string>'));
  }
  const adapter = source('app/SourcesShared/ExternalPlaybackHandoff.swift', false);
  check('return selection carries exact opaque episode ID into existing detail routes', adapter.includes('initialVideoID: next.id)') && adapter.split('initialVideoID: next.id)').length === 3);
  check('handoff never persists or logs capability URLs', !/UserDefaults|DiagnosticsLog|NSLog|print\(/.test(adapter + insertions.COORDINATOR));
  check('legacy positive-duration account mirror guard remains', account.includes('guard let key = authKey, durationSeconds > 0, positionSeconds >= 0 else { return }'));
  fs.writeFileSync(path.join(build, 'source-hashes.json'), JSON.stringify(hashes, null, 2) + '\n');
  console.log(`RESULT ${checks} source contracts passed`);
}
