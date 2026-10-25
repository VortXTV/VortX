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
  core: 'app/SourcesShared/CoreBridge.swift', facade: 'app/SourcesShared/VortxNativeCoreFacade.swift',
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

const contextCore = extractDeclaration(context, 'func isCurrent(core: CoreBridge)');
const contextOwner = extractDeclaration(context, 'func isCurrent(owner: CoreBridge.NativePlaybackReadCapability)');
const contextUI = extractDeclaration(context, '@MainActor func isCurrent(core: CoreBridge, profiles: ProfileStore)');
const intentCore = extractDeclaration(intent, 'func isCurrent(core: CoreBridge = .shared)');
const intentOwner = extractDeclaration(intent, 'func isCurrent(owner: CoreBridge.NativePlaybackReadCapability)');
const intentUI = extractDeclaration(intent, '@MainActor func isCurrent(core: CoreBridge, profiles: ProfileStore)');
const capture = extractDeclaration(home, 'static func captureContext(core: CoreBridge = .shared)');
const retention = extractDeclaration(home, '@MainActor static func awaitsRecapture(');
assert(!home.includes('static func captureContext()'), 'obsolete no-argument captureContext declaration absent');

const suggestion = member('shadow', 'func suggestion(');
const directCache = member('shadow', 'func continueWatchingSelection(');
const checked = [
  ['Context compatibility worker', contextCore,
    'let profile = selection.activeProfile', 'selection.activeID == profile.id'],
  ['Context native owner worker', contextOwner,
    'let profile = selection.activeProfile', 'selection.activeID == profile.id'],
  ['Context UI', contextUI,
    'let profile = profiles.active', 'profiles.activeID == profile.id'],
  ['Intent UI', intentUI,
    'let profile = profiles.active', 'profiles.activeID == profile.id'],
  ['capture', capture,
    'let profile = selection.activeProfile', 'selection.activeID == profile.id'],
  ['retention', retention,
    'let selected = selection.activeProfile', 'selection.activeID == selected.id'],
  ['suggestion', suggestion,
    'let profile = profileSelection.activeProfile', 'profileSelection.activeID == profile.id'],
  ['direct cache', directCache,
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
const ownerClauses = ['owner.owns(nativeTarget)', 'owner.isCurrent()', 'profile.id == owner.binding.profileID'];
const ownerFlat = contextOwner.replace(/\s+/g, ' ');
function ownerCheck(body) {
  const flat = body.replace(/\s+/g, ' ');
  assert(flat.includes('owner.owns(nativeTarget)'), 'native owner target ownership');
  assert(flat.includes('owner.isCurrent()'), 'native owner currentness');
  assert(flat.includes('profile.id == owner.binding.profileID'), 'native owner profile binding');
  assert(flat.includes('let profile = selection.activeProfile'), 'native owner member unwrap');
  assert(flat.includes('selection.activeID == profile.id'), 'native owner selected/member equality');
}
ownerCheck(contextOwner);
for (const clause of ownerClauses) {
  assert(ownerFlat.includes(clause), 'native owner clause present: ' + clause);
  const candidate = ownerFlat.replaceAll(clause, '/* deliberately removed owner guard */');
  assert.throws(() => ownerCheck(candidate),
    'native owner guard-removal control: ' + clause);
  controls++;
}
assert(intentCore.includes('context.isCurrent(core: core)'), 'intent retains core compatibility predicate');
function intentOwnerCheck(body) {
  assert(body.includes('context.isCurrent(owner: owner)'), 'intent worker uses native owner overload');
}
intentOwnerCheck(intentOwner);
assert.throws(() => intentOwnerCheck(intentOwner.replace('context.isCurrent(owner: owner)', 'REMOVED_OWNER_GUARD')),
  'intent original-owner guard-removal control');
controls++;
assert(intentUI.includes('return isCurrent(core: core)'), 'intent UI retains supplied core compatibility route');
const worker = contextCore, ownerWorker = contextOwner;
assert(worker.includes('nativeTarget.stillOwnsCurrentContext(core: core)') && worker.includes('legacyTarget.stillOwnsCurrentContext(core: core)'));
assert(worker.includes('ProfileSelectionRead.snapshot() == selection') && worker.includes('preferenceEpoch == ContinueWatchingPreferences.selectionEpoch'));
assert(ownerWorker.includes('owner.owns(nativeTarget)') && ownerWorker.includes('owner.isCurrent()')
  && ownerWorker.includes('profile.id == owner.binding.profileID'));
assert(!capture.includes('current(') && !capture.includes('cwItems') && !capture.includes('TraktPlaybackShadow'));
for (const name of ['awaitsRecapture', 'refreshCurrent', 'refreshVisibleTraktNextEpisodes', 'waitingForPresentation', 'current', 'permitsPrivateArtworkCommit']) {
  assert(home.includes('@MainActor static func ' + name + '('), 'retained UI actor: ' + name);
}

assert(source.shadow.includes('HomeContinueWatchingSelection.captureContext(core: core)'),
  'Trakt provider has explicit core capture route');
assert(!source.shadow.includes('HomeContinueWatchingSelection.captureContext()'),
  'Trakt provider does not use obsolete no-argument capture');
assert(source.shadow.includes('captureNativePlaybackReadCapability(target'),
  'Trakt provider captures native read capability');
assert(source.shadow.includes('context.isCurrent(owner: owner)'),
  'Trakt provider checks original owner before provider work');
assert(!/isCurrent\(core: \.shared, profiles: \.shared\)/.test(source.shadow),
  'Trakt provider does not recapture shared UI owner');
assert(source.simklShadow.includes('expected.isCurrent(owner: owner)'),
  'SIMKL provider retains supplied native owner');
assert(!/isCurrent\(core: \.shared, profiles: \.shared\)/.test(source.simklShadow),
  'SIMKL provider does not recapture shared UI owner');
const pull = member('shadow', 'private func pullPlayback(').replace(/\s+/g, ' ');
assert(pull.includes('guard context.isCurrent(owner: owner), let token = try? await TraktAuth.shared.validToken'),
  'Trakt pull checks original owner before token/provider await');

const nativeReadCapability = member('core', 'struct NativePlaybackReadCapability: Sendable {');
assert(nativeReadCapability.includes('func owns(') && nativeReadCapability.includes('func isCurrent()')
  && nativeReadCapability.includes('originalInstallationIsCurrent')
  && nativeReadCapability.includes('originalEpochIsCurrent'),
  'full native playback read capability and original witnesses extracted');
const facadeBindings = [
  member('facade', 'struct RegistryBinding:'),
  member('facade', 'struct WatchlistBinding:'),
].join('\n\n');
assert(facadeBindings.includes('struct RegistryBinding:') && facadeBindings.includes('struct WatchlistBinding:'),
  'actual facade registry/watchlist bindings extracted');

const registry = extractDeclaration(source.credential, 'final class CredentialScopeRegistry:');
const declarations = [
  home,
  member('profiles', 'enum ProfileSelectionRead {'), member('credential', 'enum CredentialScope:'),
  member('trakt', 'struct TraktSessionID:'), member('simkl', 'struct SIMKLSessionID:'),
  member('external', 'struct AccountBoundResumeProposal<'), member('external', 'struct AccountBoundResumeSuggestion<'),
  member('discovery', 'struct ProfileDiscoveryPreferences:'),
  member('fold', 'struct TraktContinueWatchingSeed:'), member('fold', 'struct TraktPlaybackActivityStamps:'),
  member('trakt', 'enum TraktPlaybackSnapshotPolicy {'), member('trakt', 'enum TraktPlaybackRefreshThrottlePolicy {'),
  member('cache', 'struct TraktPlaybackCacheSnapshot:'), member('cache', 'enum TraktPlaybackCacheError:'),
].join('\n\n');
const traktState = member('shadow', 'private struct State: Sendable {');
const methods = [
  line('shadow', 'typealias ContinueWatchingSource ='),
  line('shadow', 'private static let minimumSuggestionSeconds:'), line('shadow', 'private static let maximumSuggestionFraction:'),
  line('shadow', 'private static let staleLocalThresholdSeconds:'),
  member('shadow', 'struct ContinueWatchingSelection: Sendable {'), suggestion, directCache,
  member('shadow', 'private static func episodeKey('), member('shadow', 'private func commitPlayback('),
  member('shadow', 'private func finishRefresh('), member('shadow', 'private static func saveCache('),
  member('shadow', 'private static func resetCache('), member('shadow', 'private static func logCacheFailure('),
].join('\n\n');

let combined = source.fixture;
for (const [marker, text] of [
  ['// PRODUCTION_CW_DECLARATIONS', declarations],
  ['// PRODUCTION_CREDENTIAL_CAPTURE', member('credential', 'struct Capture:', registry)],
  ['// PRODUCTION_SELECTION_PROJECTOR', member('profiles', 'private func selectionReadSnapshot()')],
  ['// PRODUCTION_NATIVE_READ_CAPABILITY', nativeReadCapability],
  ['// PRODUCTION_FACADE_BINDINGS', facadeBindings],
  ['// PRODUCTION_TRAKT_STATE', traktState],
  ['// PRODUCTION_TRAKT_METHODS', methods],
]) {
  assert.equal(combined.split(marker).length, 2, 'unique fixture marker: ' + marker);
  combined = combined.replace(marker, text);
}
assert(!combined.includes('// PRODUCTION_'), 'every production composition marker resolved');
await writeFile(join(output, 'Combined.swift'), combined, { flag: 'wx' });
await writeFile(join(output, 'source-binding.json'), JSON.stringify({
  sourceHEAD: process.env.VORTX_CW_WORKER_SOURCE_HEAD,
  sourceHashes: Object.fromEntries(Object.entries(paths).map(([key, path]) => [path, hash(source[key])])),
  receipts,
  ownerPredicates: {
    contextCompatibilityWorker: hash(contextCore),
    contextNativeOwnerWorker: hash(contextOwner),
    contextUI: hash(contextUI),
    intentCompatibilityWorker: hash(intentCore),
    intentNativeOwnerWorker: hash(intentOwner),
    intentUI: hash(intentUI),
    capture: hash(capture),
    retention: hash(retention),
    suggestion: hash(suggestion),
    directCache: hash(directCache),
  },
  capability: {
    path: paths.core,
    marker: 'struct NativePlaybackReadCapability: Sendable {',
    declarationSHA256: hash(nativeReadCapability),
  },
  facadeBindings: {
    path: paths.facade,
    markers: ['struct RegistryBinding:', 'struct WatchlistBinding:'],
    declarationSHA256: hash(facadeBindings),
  },
  guardRemovalControls: controls,
  generatedSHA256: hash(combined),
  scope: 'Real Context/Intent owner and compatibility predicates, native read capability/original witnesses, direct Trakt predicates and storage-backed commit/finish; RAM collaborators only. No whole Trakt singleton, provider transport, app, SDK, or durability result.',
  mutations: 'Source-contract guard-removal controls are static checks, not compiled behavioral mutants.',
}, null, 2) + '\n', { flag: 'wx' });
