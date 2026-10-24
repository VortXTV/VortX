#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { resolve, join } from 'node:path';
const { extractDeclaration } = createRequire(import.meta.url)('./xperience-harness-inputs.cjs');
const root = resolve(new URL('..', import.meta.url).pathname), output = resolve(process.argv[2]);
assert.equal(process.argv.length, 3);
const hash = value => createHash('sha256').update(value).digest('hex');
const paths = {
  profiles: 'app/SourcesShared/Profiles.swift', home: 'app/SourcesShared/HomeContinueWatchingSelection.swift',
  shadow: 'app/SourcesShared/TraktPlaybackShadow.swift', simklShadow: 'app/SourcesShared/SIMKLContinueWatchingShadow.swift',
  policy: 'app/SourcesShared/PlaybackMutationOwnershipPolicy.swift', prefs: 'app/SourcesShared/ContinueWatchingPreferences.swift',
  discovery: 'app/SourcesShared/ProfileDiscoveryPreferences.swift', credential: 'app/SourcesShared/CredentialScope.swift',
  trakt: 'app/SourcesShared/TraktScrobbleProgressPolicy.swift', simkl: 'app/SourcesShared/SIMKLAuth.swift',
  external: 'app/SourcesShared/ExternalSyncSessionPolicy.swift', fold: 'app/SourcesShared/TraktContinueWatchingFold.swift',
  cache: 'app/SourcesShared/TraktPlaybackCacheStorage.swift', fixture: 'app/Tests/CWWorkerCurrentnessTests.swift',
};
const source = Object.fromEntries(await Promise.all(Object.entries(paths).map(async ([key, path]) =>
  [key, await readFile(join(root, path), 'utf8')])));
const receipts = [];
function member(key, marker, input = source[key]) {
  let text = extractDeclaration(input, marker);
  const start = input.indexOf(text);
  let prefix = input.lastIndexOf('\n', start - 1) + 1;
  while (prefix > 0) {
    const previousEnd = prefix - 1, prior = input.lastIndexOf('\n', previousEnd - 1) + 1;
    if (!input.slice(prior, previousEnd).trim().startsWith('@')) break;
    prefix = prior;
  }
  if (prefix < start) text = input.slice(prefix, start) + text;
  receipts.push({ path: paths[key], marker, ownerSHA256: hash(source[key]), declarationSHA256: hash(text) });
  return text;
}
function line(key, text) {
  const matches = source[key].split('\n').filter(value => value.includes(text));
  assert.equal(matches.length, 1, 'exact constant/property line: ' + text);
  receipts.push({ path: paths[key], marker: text, ownerSHA256: hash(source[key]), declarationSHA256: hash(matches[0]) });
  return matches[0];
}
const home = member('home', 'enum HomeContinueWatchingSelection {');
const context = extractDeclaration(home, 'struct Context:');
const intent = extractDeclaration(home, 'struct Intent:');
assert.match(context, /struct Context: Hashable, Sendable/);
assert.match(intent, /struct Intent: Hashable, Sendable/);
assert.match(source.policy, /enum Target: Hashable, Sendable/);
assert.match(source.policy, /struct NativeBinding: Hashable, Sendable/);
assert(!context.includes('@unchecked') && !intent.includes('@unchecked'));
const checked = [
  ['Context worker', extractDeclaration(context, 'func isCurrent(core: CoreBridge)'),
    'let profile = selection.activeProfile', 'selection.activeID == profile.id'],
  ['Context UI', extractDeclaration(context, '@MainActor func isCurrent('),
    'let profile = profiles.active', 'profiles.activeID == profile.id'],
  ['Intent UI', extractDeclaration(intent, '@MainActor func isCurrent('),
    'let profile = profiles.active', 'profiles.activeID == profile.id'],
  ['capture', extractDeclaration(home, 'static func captureContext('),
    'let profile = selection.activeProfile', 'selection.activeID == profile.id'],
  ['retention', extractDeclaration(home, '@MainActor static func awaitsRecapture('),
    'let selected = selection.activeProfile', 'selection.activeID == selected.id'],
  ['suggestion', member('shadow', 'func suggestion('),
    'let profile = profileSelection.activeProfile', 'profileSelection.activeID == profile.id'],
  ['direct cache', member('shadow', 'func continueWatchingSelection('),
    'let profile = profileSelection.activeProfile', 'profileSelection.activeID == profile.id'],
];
function extantCheck(body, unwrap, equality) {
  const flat = body.replace(/\s+/g, ' ');
  assert(flat.includes(unwrap), 'extant member unwrap');
  assert(flat.includes(equality), 'selected/member equality');
}
let controls = 0;
for (const [name, body, unwrap, equality] of checked) {
  extantCheck(body, unwrap, equality);
  for (const clause of [unwrap, equality]) {
    const candidate = body.replace(/\s+/g, ' ').replace(clause, '/* deliberately removed guard */');
    assert.throws(() => extantCheck(candidate, unwrap, equality), name + ' independent guard-removal control');
    controls++;
  }
}
const worker = checked[0][1], capture = checked[3][1];
assert(worker.includes('nativeTarget.stillOwnsCurrentContext(core: core)') && worker.includes('legacyTarget.stillOwnsCurrentContext(core: core)'));
assert(worker.includes('ProfileSelectionRead.snapshot() == selection') && worker.includes('preferenceEpoch == ContinueWatchingPreferences.selectionEpoch'));
assert(!capture.includes('current(') && !capture.includes('cwItems') && !capture.includes('TraktPlaybackShadow'));
for (const name of ['awaitsRecapture', 'refreshCurrent', 'refreshVisibleTraktNextEpisodes', 'waitingForPresentation', 'current', 'permitsPrivateArtworkCommit']) {
  assert(home.includes('@MainActor static func ' + name + '('), 'retained UI actor: ' + name);
}
assert(source.shadow.includes('HomeContinueWatchingSelection.captureContext()'));
assert(!/isCurrent\(core: \.shared, profiles: \.shared\)/.test(source.shadow));
assert(!/isCurrent\(core: \.shared, profiles: \.shared\)/.test(source.simklShadow));
const registry = extractDeclaration(source.credential, 'final class CredentialScopeRegistry:');
const declarations = [
  member('profiles', 'enum ProfileSelectionRead {'), member('credential', 'enum CredentialScope:'),
  member('trakt', 'struct TraktSessionID:'), member('simkl', 'struct SIMKLSessionID:'),
  member('external', 'struct AccountBoundResumeProposal<'), member('external', 'struct AccountBoundResumeSuggestion<'),
  member('discovery', 'struct ProfileDiscoveryPreferences:'),
  member('fold', 'struct TraktContinueWatchingSeed:'), member('fold', 'struct TraktPlaybackActivityStamps:'),
  member('trakt', 'enum TraktPlaybackSnapshotPolicy {'), member('trakt', 'enum TraktPlaybackRefreshThrottlePolicy {'),
  member('cache', 'struct TraktPlaybackCacheSnapshot:'), member('cache', 'enum TraktPlaybackCacheError:'),
].join('\n\n');
const cacheProperties = [
  ['progressByID', '[String: Double]'], ['continueWatchingSeeds', '[TraktContinueWatchingSeed]'],
  ['hasContinueWatchingSnapshot', 'Bool'], ['lastActivityStamps', 'TraktPlaybackActivityStamps?'],
  ['lastRefresh', 'Date?'], ['stateSessionID', 'TraktSessionID?'], ['refreshingGeneration', 'Int?'], ['generation', 'Int'],
].map(([name, type]) => 'private var ' + name + ': ' + type
  + ' { get { state.update { $0.' + name + ' } } set { state.update { $0.' + name + ' = newValue } } }').join('\n');
const methods = [
  line('shadow', 'typealias ContinueWatchingSource ='),
  line('shadow', 'private static let minimumSuggestionSeconds:'), line('shadow', 'private static let maximumSuggestionFraction:'),
  line('shadow', 'private static let staleLocalThresholdSeconds:'),
  member('shadow', 'struct ContinueWatchingSelection {'), checked[5][1], checked[6][1],
  member('shadow', 'private static func episodeKey('), member('shadow', 'private func commitPlayback('),
  member('shadow', 'private func finishRefresh('), member('shadow', 'private static func saveCache('),
  member('shadow', 'private static func resetCache('), member('shadow', 'private static func logCacheFailure('),
].join('\n\n');
let combined = source.fixture;
for (const [marker, text] of [
  ['// PRODUCTION_CW_DECLARATIONS', declarations],
  ['// PRODUCTION_CREDENTIAL_CAPTURE', member('credential', 'struct Capture:', registry)],
  ['// PRODUCTION_SELECTION_PROJECTOR', member('profiles', 'private func selectionReadSnapshot()')],
  ['// PRODUCTION_CACHE_PROPERTIES', cacheProperties], ['// PRODUCTION_TRAKT_METHODS', methods],
]) {
  assert.equal(combined.split(marker).length, 2, 'unique fixture marker');
  combined = combined.replace(marker, text);
}
combined += '\n' + home + '\n';
await writeFile(join(output, 'Combined.swift'), combined, { flag: 'wx' });
await writeFile(join(output, 'source-binding.json'), JSON.stringify({
  sourceHEAD: process.env.VORTX_CW_WORKER_SOURCE_HEAD, sourceHashes: Object.fromEntries(
    Object.entries(paths).map(([key, path]) => [path, hash(source[key])])), receipts, guardRemovalControls: controls,
  generatedSHA256: hash(combined),
  scope: 'Real checked values/scalar/Context/Intent/direct Trakt predicates/commit and finish; checked RAM collaborators only. No whole Trakt singleton/app/SDK/durability result.',
  mutations: 'Source-contract guard-removal controls are static checks, not compiled behavioral mutants.',
}, null, 2) + '\n', { flag: 'wx' });
