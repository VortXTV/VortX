// Actual iOS/Mac caller contracts. Negative mutations are in memory only.
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
if (!root || !fs.existsSync(path.join(root, 'app/project.yml'))) throw Error('Exact VortX checkout required');
const file = path.join(root, 'app/SourcesiOS/iOSDetailView.swift');
const source = fs.readFileSync(file, 'utf8');
function need(ok, message) { if (!ok) throw Error(message); }
function method(text, name) {
  const start = text.indexOf('private func ' + name + '(');
  need(start >= 0, 'Missing actual method ' + name);
  const open = text.indexOf('{', start);
  let depth = 1, end = open + 1;
  for (; depth && end < text.length; end++) {
    if (text[end] === '{') depth++;
    if (text[end] === '}') depth--;
  }
  need(depth === 0, 'Unclosed actual method ' + name);
  return text.slice(start, end);
}
function before(text, first, second, label) {
  need(text.includes(first) && text.includes(second) && text.indexOf(first) < text.indexOf(second), label);
}
function contract(text) {
  const split = text.indexOf('struct iOSEpisodeStreams: View');
  need(split > 0, 'Missing actual episode view');
  const movie = text.slice(0, split), episode = text.slice(split);
  for (const [name, view, cancel] of [['movie', movie, 'cancelPendingQuickWatch'], ['episode', episode, 'cancelPendingAutoPick']]) {
    need(view.includes('var randomPickPlayIntent: RandomPickPlayIntent? = nil'), name + ': unchanged default routes');
    const scope = method(view, 'quickWatchScopeIsCurrent');
    before(scope, 'randomPickPlayIntent?.isCurrent(core: core, profiles: profiles) != false',
      'CinemaQuickWatchScopePolicy.accepts(', name + ': pending full-profile and original scope fences');
    need(scope.includes('!sourceList.playbackReceiptIsCurrent(receipt, pin: sourcePin) { return false }'), name + ': source changes invalidate suspended resolver');
    for (const term of ['accountBoundaryGeneration:', 'routeGeneration:', 'taskCancelled: Task.isCancelled'])
      need(scope.includes(term), name + ': retained scope term ' + term);
    const admission = method(view, 'admitRandomPickPlayback');
    need(admission.includes('guard let quickWatchScope else { randomPickPlayIntent?.revoke(); return true }'), name + ': manual handoff retires auto grant');
    before(admission, 'quickWatchScopeIsCurrent(quickWatchScope)',
      'randomPickPlayIntent?.consume(core: core, profiles: profiles) != false', name + ': final scope before consume');
    need((admission.match(/ref\?\.nativeUsenetLease\?\.close\(\)\n            return false/g) || []).length === 2,
      name + ': both rejected source and owner leases close and return');
    need(admission.includes('randomPickSourceReceipt.map({ sourceList.playbackReceiptIsCurrent($0, pin: sourcePin) }) != true'), name + ': final complete-set receipt required');
    need(!admission.includes('await '), name + ': atomic synchronous handoff');
    const cancellation = method(view, cancel);
    before(cancellation, 'guard presentation == nil else { return }', 'randomPickPlayIntent?.revoke()', name + ': cancellation preserves admitted player');
    need(cancellation.includes('quickWatchRouteGeneration &+= 1') && cancellation.includes('Task?.cancel()'), name + ': retire existing queued generation/task');
    need(cancellation.includes('randomPickSourceReceipt = nil'), name + ': cancellation retires old source receipt');
    need(cancellation.includes('if hadTask { preparation.cancel() }'), name + ': cancellation retires preparation ownership');
    need(view.includes('@State private var preparation = PlaybackPreparationState()') &&
      view.includes('private var preparing: Bool { preparation.isActive }'), name + ': shared preparation ownership state');
  }
  const forward = movie.slice(movie.indexOf('if let autoPlayEpisode, let m = meta'));
  need(forward.includes('autoPlayOnAppear: true,\n                            randomPickPlayIntent: randomPickPlayIntent'), 'series forwards same grant, no replacement');
  need(movie.includes('cancelPendingQuickWatch(revokingRandomPlay: autoPlayEpisode == nil)'), 'parent disappearance preserves series child grant');
  need(method(movie, 'requestAutoPlayIfReady').includes('randomPickPlayIntent?.isCurrent(core: core, profiles: profiles) != false'), 'metadata-ready callback cannot rearm revoked grant');
  const ready = method(movie, 'requestAutoPlayIfReady');
  need(ready.includes('!intent.bind(meta: m, video: primary.video, core: core, profiles: profiles)') &&
    ready.includes('!intent.bind(meta: m, video: nil, core: core, profiles: profiles)'), 'Library series/movie bind actual authoritative metadata before autoplay');
  need(movie.includes('randomPickPlayIntent?.invalidateMetadata(details)') &&
    episode.includes('.onReceive(core.$metaDetails) { randomPickPlayIntent?.invalidateMetadata($0) }'), 'raw metadata A-B-A revokes pending intent on both surfaces');
  need(episode.includes('!intent.bind(meta: meta, video: shownVideo, core: core, profiles: profiles)'), 'episode child conserves bound exact metadata and coordinates');
  need(episode.includes('var suppressPreferenceAutoPlay: Bool = false') &&
    episode.includes('(autoPlayOnAppear || (!suppressPreferenceAutoPlay && SourcePreferences.shared.autoPickBest))'), 'ordinary preferences retained but navigation-only Open suppresses auto-pick');
  need(movie.includes('randomPickPlayIntent: route.intent, suppressPreferenceAutoPlay: true') &&
    forward.includes('suppressPreferenceAutoPlay: randomPickPlayIntent != nil'), 'Random episode and Library-series routes suppress unintended preference replay');
  for (const name of ['selectRandomEpisode', 'playTrailer', 'playExtra']) need(method(movie, name).includes('cancelPendingQuickWatch()'), name + ': manual action retires Library autoplay');
  const playMovie = method(movie, 'playMovie');
  before(playMovie, 'if quickWatchScope == nil { cancelPendingQuickWatch() }', 'guard !preparing', 'manual movie action retires auto before work');
  before(playMovie, 'guard let receipt = sourceList.playbackReceipt(pin: sourcePin) else { return }',
    'let preparingAttempt = preparation.begin()', 'movie captures real settled source receipt before resolving');
  before(playMovie, 'randomPickSourceReceipt = receipt', 'let preparingAttempt = preparation.begin()', 'movie retains captured source receipt');
  for (const [view, names] of [[movie, ['playMovie', 'playStream', 'playLiveStream']], [episode, ['play', 'playBest']]]) {
    for (const name of names) {
      const body = method(view, name);
      need(body.includes('let preparingAttempt = preparation.begin()') && body.includes('preparation.finish(preparingAttempt)'), name + ': attempt-owned cleanup');
      need(!body.includes('preparing = false'), name + ': old callback cannot clear new spinner');
    }
  }
  need((playMovie.match(/guard admitRandomPickPlayback\(quickWatchScope: quickWatchScope, ref: /g) || []).length === 3,
    'movie fast resume, race and fallback all admit');
  need((playMovie.match(/guard admitRandomPickPlayback\([^\n]+else \{ return \}\n(?:\s+didTransferPlayback = true\n)?\s+presentation = \.player/g) || []).length === 3,
    'all three movie admissions immediately precede publication');
  before(method(movie, 'playStream'), 'cancelPendingQuickWatch()', 'if stream.isYouTubeTrailer', 'manual source cancels before content/trailer resolution');
  before(method(movie, 'playTrailerStream'), 'cancelPendingQuickWatch()', 'await iOSDetailView.resolveTrailerLaunch', 'manual trailer cancels first');
  for (const name of ['play', 'playBest', 'playTrailerStream']) {
    const block = method(episode, name);
    before(block, 'if quickWatchScope == nil { cancelPendingAutoPick() }', 'let target = shownVideo', 'manual episode ' + name + ' retires auto before work');
    if (name !== 'playTrailerStream') need(/guard admitRandomPickPlayback\([^\n]+else \{ return \}\n\s+didTransferPlayback = true\n\s+presentation = \.player/.test(block), 'episode ' + name + ': atomic final handoff');
  }
  need(playMovie.includes('if !didTransferPlayback { ref?.nativeUsenetLease?.close(); attemptPrime?.cancel() }') &&
    method(episode, 'play').includes('if !didTransferPlayback { ref?.nativeUsenetLease?.close(); attemptPrime?.cancel() }'), 'rejected attempt closes its own lease and prime');
  need(playMovie.includes('if prime { attemptPrime = torrentPrime }') && method(episode, 'play').includes('attemptPrime = torrentPrime'), 'cleanup captures only its own prime, never a newer manual task');
  const autoEpisode = method(episode, 'autoPickAndPlayEpisode');
  need(autoEpisode.includes('randomPickPlayIntent == nil || sourceList.playbackReceipt(pin: sourcePin) != nil { break }'), 'episode waits for authoritative source receipt');
  before(autoEpisode, 'randomPickSourceReceipt = receipt', 'StreamRanking.rankedCandidates(', 'episode receipt predates candidate capture');
}
contract(source);
const mutations = [
  ['var randomPickPlayIntent: RandomPickPlayIntent? = nil', 'var randomPickPlayIntent: RandomPickPlayIntent?', 'default route API'],
  ['guard randomPickPlayIntent?.isCurrent(core: core, profiles: profiles) != false else { return false }', '', 'pending full-profile fence'],
  ['randomPickPlayIntent?.consume(core: core, profiles: profiles) != false', 'true', 'movie consumes at final handoff'],
  ['ref?.nativeUsenetLease?.close()\n            return false', 'return false', 'rejected lease cleanup'],
  ['guard presentation == nil else { return }\n        if revokingRandomPlay', 'if revokingRandomPlay', 'cancel tears down accepted player'],
  ['quickWatchRouteGeneration &+= 1\n        let hadTask = quickWatchTask', 'let hadTask = quickWatchTask', 'cancel fails to retire generation'],
  ['quickWatchTask?.cancel()', '// obsolete task retained', 'cancel fails to stop work'],
  ['autoPlayOnAppear: true,\n                            randomPickPlayIntent: randomPickPlayIntent', 'autoPlayOnAppear: true', 'series drops shared grant'],
  ['cancelPendingQuickWatch(revokingRandomPlay: autoPlayEpisode == nil)', 'cancelPendingQuickWatch()', 'parent revokes forwarded series grant'],
  ['guard admitRandomPickPlayback(quickWatchScope: quickWatchScope, ref: nil) else { return }', '', 'fast resume skips admission'],
  ['guard admitRandomPickPlayback(quickWatchScope: quickWatchScope, ref: win.ref) else { return }', '', 'movie race skips admission'],
  ['guard admitRandomPickPlayback(quickWatchScope: quickWatchScope, ref: ref) else { return }', '', 'movie fallback skips admission'],
  ['if quickWatchScope == nil { cancelPendingQuickWatch() }', '', 'manual hero competes with auto'],
  ['cancelPendingQuickWatch()\n        // #95:', '// #95:', 'manual source competes with auto'],
  ['if quickWatchScope == nil { cancelPendingAutoPick() }', '', 'manual episode competes with auto'],
  ['!sourceList.playbackReceiptIsCurrent(receipt, pin: sourcePin) { return false }', 'false { return false }', 'suspended resolver source changed'],
  ['randomPickSourceReceipt.map({ sourceList.playbackReceiptIsCurrent($0, pin: sourcePin) }) != true', 'false', 'missing final source admission'],
  ['randomPickSourceReceipt = nil', '// old receipt retained', 'manual cancellation keeps old source receipt'],
  ['randomPickSourceReceipt = receipt', '// receipt omitted', 'movie receipt not captured'],
  ['attemptPrime?.cancel()', '// rejected prime retained', 'obsolete prime keeps retrying'],
  ['if prime { attemptPrime = torrentPrime }', '', 'cleanup cannot identify its own prime'],
  ['preparation.finish(preparingAttempt)', 'preparation.cancel()', 'old automatic callback clears manual spinner'],
  ['!intent.bind(meta: m, video: primary.video, core: core, profiles: profiles)', 'false', 'Library series drops authoritative coordinates'],
  ['!intent.bind(meta: meta, video: shownVideo, core: core, profiles: profiles)', 'false', 'episode child loses metadata admission'],
  ['randomPickPlayIntent?.invalidateMetadata(details)', '// raw changes ignored', 'pending metadata A-B-A retains old authority'],
  ['!suppressPreferenceAutoPlay && SourcePreferences.shared.autoPickBest', 'SourcePreferences.shared.autoPickBest', 'Open accidentally starts playback from preference'],
];
for (const [before, after, label] of mutations) {
  need(source.includes(before), 'Missing mutation anchor: ' + label);
  let rejected = false;
  try { contract(source.replace(before, after)); } catch { rejected = true; }
  need(rejected, 'Negative mutation survived: ' + label);
}
console.log('Random Pick iOS/Mac actual playback contracts PASS; ' + mutations.length + ' negative mutations rejected');
