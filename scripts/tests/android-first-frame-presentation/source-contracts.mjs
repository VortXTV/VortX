#!/usr/bin/env node
// Source contracts only, not Compose/JNI/renderer/device execution.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const [repoArg, receiptArg, ...extra] = process.argv.slice(2);
assert(repoArg && receiptArg && extra.length === 0, 'Expected repository and existing receipt directory');
const repo = realpathSync(repoArg), receipt = realpathSync(receiptArg);
assert(statSync(receipt).isDirectory() && /^receipt\.[A-Za-z0-9]+$/.test(path.basename(receipt)), 'Use a fresh receipt directory');
const buildRoot = realpathSync(path.join(repo, 'android/app/build'));
assert(receipt.startsWith(buildRoot + path.sep), 'Receipt must remain below the actual repository android/app/build directory');
const paths = {
  policy: 'android/app/src/main/kotlin/com/vortx/android/player/PlaybackStartupPresentation.kt',
  policyTest: 'android/app/src/test/kotlin/com/vortx/android/player/PlaybackStartupPresentationTest.kt',
  screen: 'android/app/src/main/kotlin/com/vortx/android/player/PlayerScreen.kt',
  cover: 'android/app/src/main/kotlin/com/vortx/android/player/PlayerStartupCover.kt',
  engine: 'android/app/src/main/kotlin/com/vortx/android/player/PlayerEngine.kt',
  exo: 'android/app/src/main/kotlin/com/vortx/android/player/ExoPlayerEngine.kt',
  exoInputs: 'android/app/src/main/kotlin/com/vortx/android/player/ExoMetadataInputs.kt',
  exoTest: 'android/app/src/test/kotlin/com/vortx/android/player/ExoStartupAdmissionTest.kt',
  mpv: 'android/app/src/full/kotlin/com/vortx/android/player/mpv/MpvPlayer.kt',
  canonicalIdentity: 'android/app/src/main/kotlin/com/vortx/android/sources/CanonicalContentIdentity.kt',
  posterArtwork: 'android/app/src/main/kotlin/com/vortx/android/metadata/PosterArtwork.kt',
  ownerGate: 'android/app/src/main/kotlin/com/vortx/android/profile/ContinueWatchingOwnerGate.kt',
  artworkFallback: 'android/app/src/main/kotlin/com/vortx/android/ui/components/ArtworkFallback.kt',
  strings: 'android/app/src/main/res/values/strings.xml',
};
const files = Object.fromEntries(Object.entries(paths).map(([key, relative]) =>
  [key, readFileSync(path.join(repo, relative), 'utf8')]));
const sha256 = value => createHash('sha256').update(value).digest('hex');
function uniqueIndex(source, marker) {
  const offset = source.indexOf(marker);
  assert(offset >= 0 && source.indexOf(marker, offset + marker.length) < 0, 'Need one source anchor: ' + marker);
  return offset;
}
// Lexical body locator only; no copied admission algorithm. Ignore braces in comments and strings.
function block(source, marker) {
  const start = uniqueIndex(source, marker);
  const open = source.indexOf('{', start + marker.length);
  assert(open >= 0, 'No body after ' + marker);
  let level = 0, state = 'code', escaped = false;
  for (let i = open; i < source.length; i++) {
    const char = source[i], next = source[i + 1];
    if (state === 'line') { if (char === '\n') state = 'code'; continue; }
    if (state === 'comment') { if (char === '*' && next === '/') { state = 'code'; i++; } continue; }
    if (state === 'triple') { if (source.slice(i, i + 3) === '"""') { state = 'code'; i += 2; } continue; }
    if (state === 'string' || state === 'char' || state === 'backtick') {
      if (escaped) { escaped = false; continue; }
      if (char === '\\' && state !== 'backtick') { escaped = true; continue; }
      if ((state === 'string' && char === '"') || (state === 'char' && char === "'") ||
          (state === 'backtick' && char.charCodeAt(0) === 96)) state = 'code';
      continue;
    }
    if (char === '/' && next === '/') { state = 'line'; i++; continue; }
    if (char === '/' && next === '*') { state = 'comment'; i++; continue; }
    if (source.slice(i, i + 3) === '"""') { state = 'triple'; i += 2; continue; }
    if (char === '"') { state = 'string'; continue; }
    if (char === "'") { state = 'char'; continue; }
    if (char.charCodeAt(0) === 96) { state = 'backtick'; continue; }
    if (char === '{') level++;
    if (char === '}' && --level === 0) return source.slice(open + 1, i);
  }
  assert.fail('Unclosed body after ' + marker);
}
function has(source, ...needles) { return needles.every(needle => source.includes(needle)); }
function ordered(source, ...needles) {
  let previous = -1;
  return needles.every(needle => { const offset = source.indexOf(needle, previous + 1); if (offset < 0) return false; previous = offset; return true; });
}
function mutate(original, key, before, after) {
  assert(original[key].includes(before), 'Negative-control anchor missing: ' + before);
  return { ...original, [key]: original[key].replace(before, after) };
}
const results = [];
function contract(name, accepts, mutations) {
  assert(accepts(files), 'Actual source contract failed: ' + name);
  let rejected = 0;
  for (const [key, before, after] of mutations) {
    const changed = mutate(files, key, before, after);
    let accepted = false;
    try { accepted = accepts(changed); } catch { accepted = false; }
    assert(!accepted, 'Negative control accepted: ' + name + ' / ' + before);
    rejected++;
  }
  results.push({ name, negativeControls: rejected, status: 'pass' });
  console.log('SOURCE-CONTRACT ' + name + ': pass; negative-controls=' + rejected);
}

contract('one-window-null-to-built-and-engine-keyed-collection', f =>
  has(f.screen, 'val startupWindow = remember(engineHolder, subtitleProfileRevision)',
    'val playerState = key(engine) {', 'else engine.state.collectAsStateWithLifecycle().value',
    'rememberPlayerStartupArtwork(currentPlayable, startupWindow, subtitleProfileRevision') &&
  (f.screen.match(/StartupCoverWindow\(SystemClock\.elapsedRealtime\(\)\)/g) ?? []).length === 1 &&
  (f.screen.match(/rememberStartupCoverWindow\(startupWindow, subtitleProfileRevision/g) ?? []).length === 2,
  [['screen', 'val playerState = key(engine) {', 'val playerState = key(Unit) {'],
   ['screen', 'val startupWindow = remember(engineHolder, subtitleProfileRevision)', 'val startupWindow = remember(engine, subtitleProfileRevision)']]);

contract('static-cover-below-gestures-chrome-and-error-back', f => {
  const pre = block(f.screen, '\n    if (engine == null)');
  const video = f.screen.slice(uniqueIndex(f.screen, 'engine.VideoSurface('));
  const cover = block(f.cover, 'internal fun PlayerStartupCover(');
  return has(f.screen, 'BackHandler(enabled = !playerExitRequested) { exitPlayer() }') &&
    ordered(pre, 'PlayerStartupCover(startupArtwork)', 'CircularProgressIndicator(') &&
    ordered(video, 'engine.VideoSurface(', 'if (showStartupCover) PlayerStartupCover(startupArtwork)', 'PlayerChrome(') &&
    !/\.clickable\(|\.pointerInput\(|\.focusable\(|BackHandler\(/.test(cover);
}, [['screen', 'if (showStartupCover) PlayerStartupCover(startupArtwork)', 'REMOVED_STARTUP_LAYER'],
    ['screen', 'BackHandler(enabled = !playerExitRequested) { exitPlayer() }', 'REMOVED_BACK']]);

contract('owner-deadline-pip-terminal-and-unsupported-fail-open', f =>
  has(f.screen, 'allowed = !playerExitRequested && hostActivity?.isInPictureInPictureMode != true',
    'allowed = !effectiveError && !playerExitRequested && !playerState.hasEnded && !pip.isInPip') &&
  has(f.cover, 'currentRevision == ownerRevision', 'val eligibleNow = allowed && evidence == PlaybackStartupEvidence.AWAITING && ownerCurrent',
    'return eligibleNow && immediatelyPending && pending', 'delay(STARTUP_WINDOW_POLL_MS)') &&
  has(f.policy, 'const val TIMEOUT_MS = 12_000L', 'evidence != PlaybackStartupEvidence.AWAITING',
    'nowMs < startedAtMs', 'retired = true') &&
  has(f.engine, 'startupEvidence: PlaybackStartupEvidence = PlaybackStartupEvidence.UNAVAILABLE'),
  [['screen', '!playerState.hasEnded && !pip.isInPip', '!playerState.hasEnded'],
   ['cover', 'return eligibleNow && immediatelyPending && pending', 'return true'],
   ['engine', 'startupEvidence: PlaybackStartupEvidence = PlaybackStartupEvidence.UNAVAILABLE', 'startupEvidence: PlaybackStartupEvidence = PlaybackStartupEvidence.AWAITING']]);

contract('canonical-only-public-logo-and-supplied-poster', f =>
  has(f.cover, 'val context = playable.playbackContext', 'playable.mediaRef',
    'CanonicalContentIdentity.imdb(raw.trim())', 'mediaRef.tmdb?.takeIf { it > 0 }',
    'PosterArtwork.resolvedLogo(publicId, metadata.type, null)', 'posterUrl = playable.posterUrl',
    'context?.title?.trim()?.takeIf(String::isNotEmpty)?.take(256)',
    'mediaRef.title?.trim()?.takeIf(String::isNotEmpty)?.take(256)') &&
  !/playable\.(?:url|title|headers)\b/.test(f.cover),
  [['cover', 'PosterArtwork.resolvedLogo(publicId, metadata.type, null)', 'PosterArtwork.resolvedLogo(playable.url, metadata.type, null)'],
   ['cover', 'posterUrl = playable.posterUrl', 'posterUrl = ambientDetail.poster']]);

contract('bounded-once-only-post-engine-artwork-with-cancellation', f => {
  const pre = block(f.screen, '\n    if (engine == null)');
  const artwork = block(f.cover, 'internal fun rememberPlayerStartupArtwork(');
  return has(pre, 'playerStartupPlaceholder(currentPlayable)') && !pre.includes('rememberPlayerStartupArtwork(') &&
    has(f.cover, 'private const val STARTUP_LOGO_TIMEOUT_MS = 2_500L', 'loadState.attempted = true',
      'withTimeoutOrNull(STARTUP_LOGO_TIMEOUT_MS)', 'if (resolved == null || !latestEnabled) return@LaunchedEffect',
      'if (currentRevision == ownerRevision && latestEnabled) loadState.logoUrl = resolved',
      'if (!latestEnabled || !ContinueWatchingOwnerGate.serialized { it == ownerRevision }) return@LaunchedEffect',
      'maxDecodePx = 1_280', 'maxDecodePx = 720', 'decodeScale = coil3.size.Scale.FIT') &&
    ordered(artwork, 'if (loadState.attempted) return@LaunchedEffect', 'loadState.attempted = true',
      'withTimeoutOrNull(STARTUP_LOGO_TIMEOUT_MS)') &&
    (artwork.match(/currentCoroutineContext\(\)\.ensureActive\(\)/g) ?? []).length >= 3 &&
    !has(f.cover, 'crossfade = true') && (f.cover.match(/crossfade = false/g) ?? []).length >= 2;
}, [['cover', 'if (loadState.attempted) return@LaunchedEffect', 'REMOVED_ONCE_LATCH'],
    ['cover', 'if (currentRevision == ownerRevision && latestEnabled) loadState.logoUrl = resolved', 'loadState.logoUrl = resolved'],
    ['cover', 'if (!latestEnabled || !ContinueWatchingOwnerGate.serialized { it == ownerRevision }) return@LaunchedEffect', 'REMOVED_BEFORE_REQUEST_OWNER_GUARD']]);

contract('media3-actual-render-event-not-ready', f => {
  const render = block(f.exo, 'override fun onRenderedFirstFrame(');
  const admission = block(f.exo, 'private fun acceptsStartupEvent(');
  const playbackState = block(f.exo, 'override fun onPlaybackStateChanged(playbackState: Int)');
  return has(render, 'surface == null', '!surface.isValid', 'output !== surface', '!acceptsStartupEvent(eventTime)',
    'acceptStartupEvidence(PlaybackStartupEvidence.MEDIA3_RENDERED_FIRST_FRAME)') &&
    has(admission, 'metadataInputs.isReleased', 'player.isPlayingAd',
      'metadataInputs.acceptsPresentation(exoMetadataEventContext(time), playing, tag, period.uid)') &&
    !playbackState.includes('MEDIA3_RENDERED_FIRST_FRAME') &&
    has(f.exoInputs, 'event == playing && event == current && actualTag === load',
      'event?.period?.periodUid == actualPeriodUID', '!context.period.isAd', 'context.period.windowSequenceNumber >= 0L');
}, [['exo', '|| !acceptsStartupEvent(eventTime)', ''],
    ['exoInputs', 'event == playing && event == current && actualTag === load', 'true']]);

contract('mpv-release-and-waiting-load-retire-under-same-gate', f => {
  const release = block(f.mpv, 'override fun release()');
  const releaseGate = block(release, 'synchronized(subtitleGenerationGate)');
  const load = block(f.mpv, 'override fun load(playable: Playable)');
  const loadGate = block(load, 'val (loadGeneration, initialSubtitleSelection) = synchronized(subtitleGenerationGate)');
  return has(f.mpv, 'private val subtitleSelections = SubtitleSelectionAuthority()') &&
    ordered(releaseGate, 'if (!released.compareAndSet(false, true)) return', 'subtitleSelections.retire()',
      'subtitleLoadGeneration.incrementAndGet()', 'metadataLoadIdentity.retire()',
      'startupEvidence = PlaybackStartupEvidence.UNAVAILABLE') &&
    ordered(loadGate, 'if (released.get() || originalPlaybackOwner?.isActive != true) return',
      'val generation = subtitleLoadGeneration.incrementAndGet()',
      'val original = subtitleSelections.beginSource(generation) ?: return',
      'metadataLoadIdentity.begin(generation)', 'startupEvidence = PlaybackStartupEvidence.AWAITING',
      'generation to original') &&
    !release.slice(0, release.indexOf('synchronized(subtitleGenerationGate)')).includes('compareAndSet');
}, [['mpv', 'override fun release() {\n        synchronized(subtitleGenerationGate)', 'override fun release() {\n        synchronized(unrelatedGate)'],
    ['mpv', 'val (loadGeneration, initialSubtitleSelection) = synchronized(subtitleGenerationGate) {\n            if (released.get() || originalPlaybackOwner?.isActive != true) return', 'val (loadGeneration, initialSubtitleSelection) = synchronized(subtitleGenerationGate) {\n            REMOVED_INNER_RELEASE_RECHECK'],
    ['mpv', 'val (loadGeneration, initialSubtitleSelection) = synchronized(subtitleGenerationGate) {\n            if (released.get() || originalPlaybackOwner?.isActive != true) return', 'val (loadGeneration, initialSubtitleSelection) = synchronized(subtitleGenerationGate) {\n            if (released.get()) return'],
    ['mpv', 'val original = subtitleSelections.beginSource(generation) ?: return', 'val original = subtitleSelections.capture() ?: return'],
    ['mpv', 'subtitleSelections.retire()', 'REMOVED_SUBTITLE_SELECTION_RETIREMENT']]);

contract('mpv-fresh-native-samples-final-admission-not-restart-pixels', f => {
  const sample = block(f.mpv, 'private fun sampleStartupPresentation()');
  const read = block(f.mpv, 'private fun readStartupSample()');
  const restart = block(f.mpv, 'MPVLib.Event.PLAYBACK_RESTART ->');
  return has(f.mpv, 'private fun sampleStartupPresentation() = synchronized(subtitleGenerationGate)') &&
    has(sample, 'startupSampleBudget.take(SystemClock.elapsedRealtime())',
      'metadataLoadIdentity.capture(generation, currentPlayingEntryID())', 'withAdmittedStartupRead(read',
      'sample = ::readStartupSample', 'startupSample?.takeIf { it.first == read }',
      'mpvStartupEvidence(previous, sample)', 'if (released.get() || !metadataLoadIdentity.accepts(read, subtitleLoadGeneration.get(), currentPlayingEntryID())) it',
      'settledStartupEvidence(it.startupEvidence, evidence)') &&
    has(read, 'mpv.getPropertyDouble(PROP_TIME_POS)', 'mpv.getPropertyDouble("audio-pts")',
      'mpv.getPropertyString(PROP_TRACK_LIST)', 'mpv.getPropertyInt("video-out-params/w")',
      'mpv.getPropertyInt("video-out-params/h")', 'if (aid != mpv.getPropertyString("aid") || vid != mpv.getPropertyString("vid")) return null') &&
    has(restart, 'sampleStartupPresentation()') && !restart.includes('startupEvidence =') &&
    !sample.includes('MEDIA3_RENDERED_FIRST_FRAME');
}, [['mpv', 'sample = ::readStartupSample', 'sample = { eventValue }'],
    ['mpv', 'if (released.get() || !metadataLoadIdentity.accepts(read, subtitleLoadGeneration.get(), currentPlayingEntryID())) it', 'if (false) it']]);

const declaredPolicy = (files.policyTest.match(/@Test\b/g) ?? []).length;
const declaredExo = (files.exoTest.match(/@Test\b/g) ?? []).length;
assert.equal(declaredPolicy, 14, 'Review actual policy count changes');
assert.equal(declaredExo, 4, 'Review actual SDK count changes');
const inputs = Object.entries(paths).map(([key, relative]) => ({ key, file: path.join(repo, relative), sha256: sha256(files[key]), bytes: Buffer.byteLength(files[key]) }));
writeFileSync(path.join(receipt, 'source-contracts.json'), JSON.stringify({
  schema: 1, kind: 'actual-source-contracts-not-runtime-compose-or-native-proof', repo, inputs, results,
  declaredPolicyTests: declaredPolicy, declaredExoSDKTests: declaredExo,
}, null, 2) + '\n', { flag: 'wx' });
console.log('SOURCE-CONTRACT groups=' + results.length + '; actual pure policy cases=14; actual Exo SDK cases=4 (execution reported separately).');
