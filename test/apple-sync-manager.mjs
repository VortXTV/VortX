import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const members = ['nativeGlobalEdits', 'nativeDirtySettingIsExported', 'clearPushedDirtySettings', 'ensureNativeCheckpoint',
  'syncUp', 'mergeLocalIntoDoc', 'pullDocVersionedResult', 'pushSyncDocAt', 'pushDerivedDoc', 'requestSyncSoon'];
if (process.argv[2] === '--extract') {
  const source = await readFile(process.argv[3], 'utf8');
  const selected = members.map(name => {
    const start = source.search(new RegExp(`^    (?:private )?func ${name}\\(`, 'm'));
    assert(start >= 0, `missing production method ${name}`);
    const end = source.indexOf('\n    }', start); assert(end > start);
    return source.slice(start, end + 6);
  });
  selected.push('private enum VersionedPull { case doc(doc: [String: Any], version: Int); case empty; case failed(retryable: Bool) }',
    'private enum PushOutcome { case accepted(version: Int); case rejected(storedVersion: Int?); case error }',
    'private struct DerivedSyncDoc { let document: [String: Any]; let baseRevision: Int? }');
  const profiles = await readFile('app/SourcesShared/Profiles.swift', 'utf8');
  const preferenceFixture = await readFile('app/Tests/NativePreferenceAcknowledgementTests.swift', 'utf8');
  const block = (text, marker) => {
    const start = text.indexOf(marker); assert(start >= 0, marker);
    const end = text.indexOf('\n    }', start); assert(end > start, marker);
    return text.slice(start, end + 6);
  };
  const environment = preferenceFixture.slice(preferenceFixture.indexOf('private struct PlaybackMutationTarget'), preferenceFixture.indexOf('@MainActor private final class CoreBridge'))
    + preferenceFixture.slice(preferenceFixture.indexOf('@MainActor private final class ThemeManager'), preferenceFixture.indexOf('@MainActor private final class PreferenceHarness'))
    + preferenceFixture.slice(preferenceFixture.indexOf('@MainActor private final class PreferenceHarness'), preferenceFixture.indexOf('@main private enum'))
        .replace('final class PreferenceHarness {', 'final class ProfileStore {\n    static let shared = ProfileStore()');
  const managerEnvironment = environment
    .replace(/private struct PlaybackMutationTarget: Equatable \{[\s\S]*?\n\}/, '')
    .replaceAll('PlaybackMutationTarget', 'ManagerPlaybackMutationTarget')
    .replace('.init(generation: 1)', '.native(.init(credential: .init(generation: 1), profileID: UUID(uuidString: AppleSyncManagerPeer.owner)!))');
  const productionPreferences = ['private struct NativeThemeProjection', 'private func currentNativeThemeProjection(',
    'private func nativePlaybackProjectionRepresents(', 'private func nativeDiscoveryProjectionRepresents(',
    'func nativePreferenceProjectionMatches(',
    'func nativePreferenceIsAcknowledged(', 'private static func nativeDiscoveryProjectionIsRepresented(',
    'private func nativePreferenceIsLocalRevert(',
    'func retryNativePreferenceProjection(', 'func capturePlayback(', 'private func profileCapturingPlayback('].map(marker => block(profiles, marker)
      .replaceAll('PlaybackMutationTarget', 'ManagerPlaybackMutationTarget')
      .replaceAll('NativePlaybackProjectionSource', 'ManagerNativePlaybackProjectionSource')
      .replaceAll('NativeDiscoveryProjectionSource', 'ManagerNativeDiscoveryProjectionSource'));
  productionPreferences[7] = productionPreferences[7]
    .replace('private func nativePreferenceIsLocalRevert(', 'func nativePreferenceIsLocalRevert(')
    .replaceAll('VortXSyncManager.shared', 'ManagerHarness.shared');
  const productionIntentMethods = [
    'private func nativePreferenceStampIsAttributed(',
    'private struct NativePreferenceContext {',
    'private func nativePreferenceContext(',
    'nonisolated private static func makeNativePreferenceContext(',
    'nonisolated private static func nativePreferenceValue(',
    'nonisolated private static func nativePreferenceSnapshot(',
    'func nativePreferenceAdmission(',
    'func prepareNativePreferenceIntents(',
    'func normalizedNativePreferenceSubmission(',
    'func nativePreferenceIsLocalRevert(',
    'func finishNativePreferenceIntents(',
    'private func replayNativePreferenceIntents(',
    'private func quarantineNativePreferenceStamps()',
    'private static var nativePreferenceProjectionKeys:',
    'nonisolated static func nativePreferenceProjectionWillMount()',
    'private func noteLocalSettingsChange()',
    'private func pendingNativePreferenceReceipts(',
    'private func acknowledgeNativePreferenceCloud(',
    'private func nativePreferenceIntentsNeedReplay()',
    'private func flushDirtySettingsIfNeeded()'
  ].map(marker => block(source, marker)).join('\n')
    .replaceAll('PlaybackMutationTarget', 'ManagerPlaybackMutationTarget');
  const productionProfileSave = block(profiles, 'func saveNative(_ profile: UserProfile, creating: Bool, target: PlaybackMutationTarget? = nil,')
    .replaceAll('PlaybackMutationTarget', 'ManagerPlaybackMutationTarget')
    .replaceAll('VortXSyncManager.shared', 'ManagerHarness.shared');
  const discovery = await readFile('app/SourcesShared/ProfileDiscoveryPreferences.swift', 'utf8');
  await writeFile(process.argv[4], (await readFile('app/Tests/AppleSyncManagerPeer.swift', 'utf8')) + managerEnvironment
    + '\nextension ProfileStore {\n' + productionPreferences.join('\n') + '\n}\nextension ProfileDiscoveryPreferencesStore {\n'
    + block(discovery, 'enum Key {') + '\n}\nextension ProfileStore {\n' + productionProfileSave + '\n}\nextension ManagerHarness {\n'
    + productionIntentMethods + '\n' + selected.join('\n') + '\n}\n');
  process.exit(0);
}
const [peerBinary, root] = process.argv.slice(2);
const run = promisify(execFile);
const wire = [];
let stored = null;
let replyMode = 'normal';
let sameBaseReaders = null;
const server = createServer(async (req, res) => {
  assert.equal(req.url, '/v1/backup');
  assert.equal(req.headers.authorization, 'Bearer synthetic-fixture-only');
  res.setHeader('content-type', 'application/json');
  if (req.method === 'GET') {
    wire.push({ method: 'GET', version: stored?.version });
    if (sameBaseReaders) {
      sameBaseReaders.push(res);
      if (sameBaseReaders.length === 2) {
        const responses = sameBaseReaders; sameBaseReaders = null;
        const snapshot = JSON.stringify(stored);
        for (const response of responses) response.end(snapshot);
      }
      return;
    }
    res.statusCode = stored ? 200 : 404;
    res.end(JSON.stringify(stored ?? {})); return;
  }
  let raw = ''; for await (const part of req) raw += part;
  const body = JSON.parse(raw);
  assert.deepEqual(Object.keys(body).sort(), ['document', 'version']);
  assert(body.document.startsWith('v2.')); assert(Number.isSafeInteger(body.version));
  const accepted = !stored || body.version > stored.version;
  if (accepted) stored = body;
  wire.push({ method: 'PUT', version: body.version, accepted });
  res.end(JSON.stringify(replyMode === 'missing' ? {} : replyMode === 'number' ? { accepted: 1 } : { accepted, version: stored.version }));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const baseURL = `http://127.0.0.1:${server.address().port}`;
let serial = 0;
async function peer(name, mode, extra = {}) {
  const directory = join(root, name); await mkdir(directory, { recursive: true });
  const sequence = ++serial;
  const path = join(root, `command-${sequence}.json`);
  await writeFile(path, JSON.stringify({ mode, directory, baseURL, actor: name === 'phone' ? '00000000-0000-4000-8000-000000000001' : '00000000-0000-4000-8000-000000000002', ...extra }));
  const { stdout } = await run(peerBinary, [path], { maxBuffer: 16 * 1024 * 1024 });
  const result = JSON.parse(stdout); await writeFile(join(root, `result-${sequence}.json`), JSON.stringify(result)); return result;
}
const owner = '10000000-0000-0000-0000-000000000001';
const viewer = '10000000-0000-0000-0000-000000000002';
const watchField = 'watchlist.series.' + Buffer.from('tt-naruto-fixture').toString('base64url');
let failures = 0;
function check(condition, label) { console.log(`${condition ? 'PASS' : 'FAIL'} ${label}`); if (!condition) failures++; }
try {
  await peer('phone', 'edit', { actions: [
    { type: 'add_profile', id: viewer, name: 'Viewer' },
    { type: 'add_library_item', profileId: owner, item: { kind: 'standard', id: 'tt-naruto-fixture', type: 'series', name: 'Synthetic Naruto', poster: null } },
    { type: 'report_progress', metaId: 'tt-naruto-fixture', videoId: 'tt-naruto-fixture:1:2', name: 'Synthetic Naruto', positionMs: 120000, durationMs: 1200000, metadata: { type: 'series' } }
  ], edits: [{ profileID: owner, fields: { [watchField]: { id: 'tt-naruto-fixture', type: 'series', name: 'Synthetic Naruto', addedAt: 123.5 } } }] });
  const blocked = await peer('phone', 'auto', { pendingProjection: true, projectionSaveFails: true });
  check(blocked.accepted === true && blocked.stamped === 1, 'unacknowledged preference cannot block committed native state upload or success stamp');
  check(blocked.dirtyProjectionRetained === true, 'unexported preference remains dirty');
  check(blocked.pendingPush === false, 'accepted native upload releases the pending-push pull guard');
  if (!blocked.accepted) {
    await writeFile(join(root, 'receipt.json'), JSON.stringify({ result: 'RED', failures, wire, members }, null, 2));
    process.exitCode = 1;
  } else {
    const mac = await peer('mac', 'pull');
    check(mac.state.libraries[owner].items.some(x => x.id === 'tt-naruto-fixture'), 'remote native saved library receives committed title');
    check(mac.host.profiles[owner].fields[watchField].value.addedAt === 123.5, 'remote profile Watchlist receives fractional timestamp');
    check(mac.playback.resumeById['tt-naruto-fixture:1:2'].offsetMs === 120000, 'remote episode Continue Watching position receives exact video identity');
    const preferences = await peer('phone', 'auto', { pendingProjection: true, pendingPlayback: true, pendingDiscovery: true });
    check(preferences.accepted && preferences.preferenceSaves === 1 && !preferences.dirtyProjectionRetained,
      'production retry commits local theme/playback/discovery through real native transaction before upload ACK');
    const remotePreferences = await peer('mac', 'pull');
    check(remotePreferences.state.roster.profiles[owner].settings.accent === 'violet'
      && remotePreferences.host.profiles[owner].fields.playback.value.audioLang === 'hi'
      && remotePreferences.host.profiles[owner].fields.discovery.value.catalogOrder[0] === 'fixture-catalog',
      'second native installation receives replayed theme, playback language and discovery preference');
    const forced = await peer('phone', 'push');
    check(forced.accepted && forced.stamped === 1, 'forced no-edit sync refreshes success stamp after accepted encrypted PUT');
    await peer('mac', 'edit', { actions: [{ type: 'patch_profile', id: viewer, edits: [{ field: 'name', value: 'Renamed on Mac' }] }] });
    check((await peer('mac', 'push', { missingSession: true })).accepted, 'upload restores missing native session before export');
    const renamed = await peer('phone', 'pull');
    check(renamed.state.roster.profiles[viewer].name === 'Renamed on Mac', 'profile rename crosses isolated installations without changing IDs');
    for (const extra of [{ restoreFails: true }, { retireDuringEnsure: true }]) {
      const failed = await peer('phone', 'push', { missingSession: true, pendingProjection: true, ...extra });
      check(!failed.accepted && failed.stamped === 0 && failed.putVersions.length === 0 && failed.dirtyProjectionRetained,
        'failed or superseded session restoration retains edits and refuses upload');
    }
    for (const extra of [{ retireDuringPUT: true }, { keyABA: true }]) {
      const failed = await peer('phone', 'push', extra);
      check(!failed.accepted && failed.stamped === 0 && failed.lastVersion === 0, 'account/key ABA during PUT cannot publish stale success');
    }
    const mid = await peer('phone', 'auto', { editDuringPUT: [{ type: 'patch_profile', id: viewer, edits: [{ field: 'name', value: 'Edited during PUT' }] }] });
    check(mid.accepted && mid.pendingPush, 'edit committed during PUT remains queued beyond older transport ACK');
    await peer('phone', 'push');
    const afterMid = await peer('mac', 'pull');
    check(afterMid.state.roster.profiles[viewer].name === 'Edited during PUT', 'next export carries edit committed during preceding PUT');
    const addedPhone = '10000000-0000-0000-0000-000000000003';
    const addedMac = '10000000-0000-0000-0000-000000000004';
    await peer('phone', 'edit', { actions: [{ type: 'add_profile', id: addedPhone, name: 'Phone concurrent edit' }] });
    await peer('mac', 'edit', { actions: [{ type: 'add_profile', id: addedMac, name: 'Mac concurrent edit' }] });
    sameBaseReaders = [];
    const raced = await Promise.all([peer('phone', 'push'), peer('mac', 'push')]);
    check(raced.every(x => x.accepted) && raced.reduce((sum, x) => sum + x.putVersions.length, 0) === 3,
      'two actual manager clients from the same base reject and rebuild the losing encrypted PUT');
    const converged = await peer('cold', 'pull');
    check(converged.state.roster.profiles[addedPhone]?.name === 'Phone concurrent edit'
      && converged.state.roster.profiles[addedMac]?.name === 'Mac concurrent edit', 'cold native client receives both concurrent profile edits');
    for (const mode of ['missing', 'number']) {
      replyMode = mode;
      const invalid = await peer('phone', 'push');
      check(!invalid.accepted && invalid.stamped === 0, 'non-boolean or absent relay acceptance never becomes success');
    }
    replyMode = 'normal';
    // Isolate the intent lifecycle so each process gets a clean relay history. These cases
    // cross process boundaries and use a real encrypted journal plus the static native C ABI.
    stored = null;
    const seed = await peer('intent-seed', 'push');
    check(seed.accepted, 'intent lifecycle starts from an accepted native baseline');
    const conflictAdmission = await peer('intent-conflict', 'inspect', {
      preferenceCommand: 'prepare-theme', preferenceValue: 'violet'
    });
    check(conflictAdmission.preparedCount === 1 && conflictAdmission.pendingPreferenceIntentCount === 1
      && !('accent' in conflictAdmission.state.roster.profiles[owner].settings),
      'pre-save admission persists an encrypted theme intent without committing its native profile value');
    const admissionChecks = await peer('intent-conflict', 'inspect', { preferenceCommand: 'admission-checks' });
    check(admissionChecks.admissionAcceptsUnrelatedProgress && admissionChecks.admissionRejectsGroupRevisionChange
      && admissionChecks.admissionRejectsBindingABA && admissionChecks.admissionRejectsUnintendedGroupChange,
      'captured admission accepts unrelated progress but rejects group revision, binding ABA, and non-intended group changes');
    const firstQueueAdmission = await peer('intent-idempotent', 'inspect', {
      preferenceCommand: 'prepare-theme', preferenceValue: 'violet'
    });
    const repeatedQueueAdmission = await peer('intent-idempotent', 'inspect', {
      preferenceCommand: 'prepare-theme', preferenceValue: 'violet'
    });
    check(firstQueueAdmission.preparationQueuedPush && !repeatedQueueAdmission.preparationQueuedPush,
      'new preference intent schedules transport once while idempotent re-prepare does not starve unrelated pulls');
    const interruptedAdmission = await peer('intent-startup-wake', 'inspect', {
      preferenceCommand: 'prepare-theme', preferenceValue: 'violet'
    });
    check(interruptedAdmission.pendingPreferenceIntentCount === 1, 'startup wake case persists the intent before simulated process exit');
    const startupFlush = await peer('intent-startup-wake', 'inspect', { preferenceCommand: 'startup-flush' });
    check(!startupFlush.startupHadDirtySettings && !startupFlush.startupHadQueuedPush && startupFlush.startupFlushQueuedPush,
      'new process flushes a reopened durable intent even with no dirty settings or preexisting queued push');
    const stampedIntent = await peer('intent-stamped', 'inspect', {
      preferenceCommand: 'prepare-theme', preferenceValue: 'violet', projectionStamp: 42, projectionValue: 'violet'
    });
    check(stampedIntent.pendingThemeProjectionStamp === 42,
      'pre-save intent captures the exact attributed flat-projection dirty stamp');
    const stampedRestart = await peer('intent-stamped', 'inspect', {
      preferenceCommand: 'quarantine-check', projectionStamp: 42, projectionValue: 'violet'
    });
    check(stampedRestart.quarantineSucceeded && stampedRestart.quarantinedProjectionCount === 0
      && stampedRestart.projectionStampAttributed,
      'cold mount preserves only the exact authenticated projection stamp witnessed by its pending intent');
    const unstampedLegacy = await peer('intent-legacy-only', 'inspect', {
      preferenceCommand: 'quarantine-check', projectionStamp: 77, projectionValue: 'violet'
    });
    check(unstampedLegacy.quarantinedProjectionCount === 1 && unstampedLegacy.remainingProjectionDirty
      && !unstampedLegacy.projectionStampAttributed,
      'legacy projection without a saved native receipt remains quarantined and cannot become an export warning');
    const competingCommit = await peer('intent-writer', 'inspect', {
      preferenceCommand: 'commit-theme-and-push', preferenceValue: 'coral'
    });
    check(competingCommit.accepted === true
      && competingCommit.state.roster.profiles[owner].settings.accent === 'coral',
      'competing native edit commits the peer theme before stale intent replay');
    const conflictedReplay = await peer('intent-conflict', 'push');
    check(conflictedReplay.state.roster.profiles[owner].settings.accent === 'coral'
      && conflictedReplay.pendingPreferenceIntentCount === 1,
      'stale group revision retains its durable intent and never overwrites the peer theme');

    const replayMounted = await peer('intent-replay', 'pull');
    check(replayMounted.pulledVersion > 0 && replayMounted.state.roster.profiles[owner].settings.accent === 'coral',
      'cold peer mounts and merges the current carrier before admitting a local preference edit');
    const admitted = await peer('intent-replay', 'inspect', {
      preferenceCommand: 'prepare-theme', preferenceValue: 'indigo'
    });
    check(admitted.preparedCount === 1 && admitted.pendingPreferenceIntentCount === 1
      && admitted.state.roster.profiles[owner].settings.accent === 'coral',
      'theme edit is durably admitted before native checkpoint save');
    const restartedReplay = await peer('intent-replay', 'push');
    check(restartedReplay.accepted && restartedReplay.state.roster.profiles[owner].settings.accent === 'indigo'
      && restartedReplay.pendingPreferenceIntentCount === 0,
      'new process merges the peer carrier, replays the pending intent, then exports and acknowledges it');
    const remotelyReplayed = await peer('intent-observer', 'pull');
    check(remotelyReplayed.state.roster.profiles[owner].settings.accent === 'indigo',
      'replayed durable preference reaches a second native installation');

    await peer('intent-commit-crash', 'pull');
    const commitAdmission = await peer('intent-commit-crash', 'inspect', {
      preferenceCommand: 'prepare-theme', preferenceValue: 'gold'
    });
    check(commitAdmission.pendingPreferenceIntentCount === 1, 'commit-before-ACK case begins with a persisted intent');
    const committedUnacked = await peer('intent-commit-crash', 'inspect', {
      preferenceCommand: 'commit-prepared-without-ack'
    });
    check(committedUnacked.state.roster.profiles[owner].settings.accent === 'gold'
      && committedUnacked.pendingPreferenceIntentCount === 1,
      'simulated process exit after native commit leaves the journal unacknowledged');
    const commitCrashReplay = await peer('intent-commit-crash', 'push');
    check(commitCrashReplay.accepted && commitCrashReplay.state.roster.profiles[owner].settings.accent === 'gold'
      && commitCrashReplay.pendingPreferenceIntentCount === 0,
      'restart recognizes an already-applied native value and clears its exact pending intent');

    await peer('intent-revert', 'pull');
    await peer('intent-revert', 'inspect', { preferenceCommand: 'prepare-theme', preferenceValue: 'violet' });
    const reverted = await peer('intent-revert', 'inspect', { preferenceCommand: 'prepare-theme', preferenceValue: 'gold' });
    check(reverted.pendingPreferenceIntentCount === 1 && reverted.pendingThemeAccent === 'gold'
      && reverted.state.roster.profiles[owner].settings.accent === 'gold',
      'explicit return to current theme supersedes a failed pending edit instead of leaving its old desired value');
    const revertReplay = await peer('intent-revert', 'push');
    check(revertReplay.accepted && revertReplay.pendingPreferenceIntentCount === 0
      && revertReplay.state.roster.profiles[owner].settings.accent === 'gold',
      'already-current reverted intent is safely finalized without reapplying the abandoned edit');

    await peer('intent-cloudack', 'pull');
    const stampedAdmission = await peer('intent-cloudack', 'inspect', {
      preferenceCommand: 'prepare-theme', preferenceValue: 'violet', projectionStamp: 44, projectionValue: 'violet'
    });
    check(stampedAdmission.pendingThemeProjectionStamp === 44, 'cloud ACK receipt case captures its exact local dirty stamp');
    const nativeCommitted = await peer('intent-cloudack', 'inspect', {
      preferenceCommand: 'commit-prepared', projectionStamp: 44, projectionValue: 'violet'
    });
    check(nativeCommitted.dirtyProjectionRetained && nativeCommitted.pendingPreferenceIntentCount === 1
      && nativeCommitted.pendingThemeProjectionStamp === 44,
      'durable native commit retains its stamped intent and local dirty value before cloud acceptance');
    const cloudAccepted = await peer('intent-cloudack', 'push', { projectionStamp: 44, projectionValue: 'violet' });
    check(cloudAccepted.accepted && cloudAccepted.pendingPreferenceIntentCount === 0
      && !cloudAccepted.dirtyProjectionRetained && cloudAccepted.nativeUnsupportedSettings.length === 0,
      'exact accepted cloud carrier clears its receipt and dirty stamp without leaving an unsupported-preference warning');

    stored = null;
    check((await peer('stale-presentation-seed', 'push')).accepted, 'stale-presentation case starts from a clean accepted native baseline');
    const stalePresentation = await peer('intent-stale-presentation', 'inspect', {
      preferenceCommand: 'stale-presentation'
    });
    check(stalePresentation.stalePresentedPlayback === 'en'
      && stalePresentation.peerPlaybackAtAdmission === 'fr',
      'real native host edit publishes fr while the submitted profile still presents stale en');
    check(JSON.stringify(stalePresentation.staleIntentGroups) === JSON.stringify(['theme']),
      'stale theme presentation does not mint a playback intent from peer fr back to en');
    check(stalePresentation.stalePresentationPushAccepted
      && stalePresentation.host.profiles[owner].fields.playback.value.audioLang === 'fr',
      'saving and pushing the theme preserves the peer playback value');

    stored = null;
    check((await peer('stale-nil-seed', 'push')).accepted, 'stale-nil case starts from a clean accepted native baseline');
    const staleNilPresentation = await peer('intent-stale-presentation-nil', 'inspect', {
      preferenceCommand: 'stale-presentation-nil'
    });
    check(staleNilPresentation.stalePresentedPlayback === null && staleNilPresentation.peerPlaybackAtAdmission === 'fr'
      && JSON.stringify(staleNilPresentation.staleIntentGroups) === JSON.stringify(['theme'])
      && staleNilPresentation.host.profiles[owner].fields.playback.value.audioLang === 'fr',
      'stale nil playback presentation normalizes to the peer value without manufacturing a playback intent');

    stored = null;
    check((await peer('open-editor-stale-seed', 'push')).accepted, 'open-editor stale-draft case starts from a clean baseline');
    const openEditorStale = await peer('intent-open-editor-stale', 'inspect', { preferenceCommand: 'baseline-presentation' });
    check(openEditorStale.editorBaselinePlayback === 'en' && openEditorStale.peerPlaybackAtAdmission === 'fr'
      && openEditorStale.baselineSaveAccepted && JSON.stringify(openEditorStale.baselineIntentGroups) === JSON.stringify(['theme'])
      && openEditorStale.host.profiles[owner].fields.playback.value.audioLang === 'fr',
      'open editor theme draft uses its captured en baseline, journals only theme, and preserves unpublished peer fr through direct save');

    stored = null;
    check((await peer('open-editor-conflict-seed', 'push')).accepted, 'open-editor conflict case starts from a clean baseline');
    const openEditorConflict = await peer('intent-open-editor-conflict', 'inspect', { preferenceCommand: 'baseline-conflict' });
    check(openEditorConflict.editorBaselinePlayback === 'en' && openEditorConflict.peerPlaybackAtAdmission === 'fr'
      && !openEditorConflict.baselineSaveAccepted
      && JSON.stringify(openEditorConflict.baselineIntentGroups) === JSON.stringify(['playback', 'theme'])
      && openEditorConflict.baselinePlaybackIntentValue === 'de' && openEditorConflict.baselinePlaybackRequiresResolution
      && openEditorConflict.host.profiles[owner].fields.playback.value.audioLang === 'fr',
      'open editor playback edit de against captured en and current peer fr persists a resolution conflict without overwriting fr');

    stored = null;
    check((await peer('stale-edited-seed', 'push')).accepted, 'genuinely edited stale playback case starts from a clean baseline');
    const stalePlaybackEdit = await peer('intent-stale-playback', 'inspect', { preferenceCommand: 'stale-playback-edit' });
    check(JSON.stringify(stalePlaybackEdit.stalePlaybackEditGroups) === JSON.stringify(['playback'])
      && stalePlaybackEdit.stalePlaybackPrepareRejected && stalePlaybackEdit.stalePlaybackRequiresResolution
      && stalePlaybackEdit.stalePlaybackSaveAccepted === false
      && stalePlaybackEdit.host.profiles[owner].fields.playback.value.audioLang === 'fr',
      'genuinely edited stale playback is retained as an explicit resolution conflict, not silently committed');
    const unrelatedTheme = await peer('intent-stale-playback', 'inspect', {
      preferenceCommand: 'prepare-theme', preferenceValue: 'violet'
    });
    check(unrelatedTheme.pendingPreferenceIntentCount === 2 && unrelatedTheme.pendingPlaybackAudioLang === 'de'
      && unrelatedTheme.pendingPlaybackRequiresResolution && unrelatedTheme.pendingPreferenceGroups.includes('theme'),
      'an unrelated theme edit preserves the unresolved playback intent instead of replacing its journal receipt');
    const staleConflictPush = await peer('intent-stale-playback', 'push');
    check(staleConflictPush.accepted && staleConflictPush.host.profiles[owner].fields.playback.value.audioLang === 'fr'
      && staleConflictPush.pendingPlaybackAudioLang === 'de' && staleConflictPush.pendingPlaybackRequiresResolution,
      'replay keeps the peer playback value and durable edited draft until explicit conflict resolution');

    const localRevert = await peer('intent-local-revert', 'inspect', { preferenceCommand: 'local-revert-cycle' });
    check(localRevert.failedNativeSaveAccepted === false && localRevert.sameProcessLocalRevertAuthorized
      && localRevert.localRevertPendingAccent === 'ember',
      'same-process failed local theme save retains a positive admission witness that authorizes explicit revert');
    const coldRevertPrepared = await peer('intent-local-revert-cold', 'inspect', { preferenceCommand: 'local-revert-prepare' });
    const coldRevert = await peer('intent-local-revert-cold', 'inspect', { preferenceCommand: 'local-revert-cold-check' });
    check(coldRevertPrepared.pendingThemeAccent === 'violet' && !coldRevert.coldStartLocalRevertAuthorized
      && coldRevert.pendingThemeAccent === 'violet',
      'cold restart cannot treat the stored pending edit alone as evidence of a local revert');
    const retiredRevert = await peer('intent-local-revert-retired', 'inspect', { preferenceCommand: 'local-revert-retired' });
    check(retiredRevert.failedNativeSaveAccepted === false && !retiredRevert.retiredTargetLocalRevertAuthorized
      && retiredRevert.pendingThemeAccent === 'violet',
      'retired target/key generation invalidates the in-memory revert witness without erasing its durable intent');

    const capturedRevert = await peer('intent-capture-revert', 'inspect', { preferenceCommand: 'capture-revert-cycle' });
    check(capturedRevert.capturedLocalPlayback === 'hi' && JSON.stringify(capturedRevert.captureIntentGroups) === JSON.stringify(['playback'])
      && capturedRevert.captureRevertUpdateCount === 2 && capturedRevert.captureRevertedToNilCarrier
      && JSON.stringify(capturedRevert.captureRevertGroups) === JSON.stringify(['playback']),
      'actual capturePlayback restores the original nil/inherited carrier when a same-process edit returns to effective en');
    const coldDefaultEcho = await peer('intent-capture-cold-echo', 'inspect', { preferenceCommand: 'capture-cold-default-echo' });
    check(coldDefaultEcho.coldDefaultEchoUpdateCount === 0 && coldDefaultEcho.coldDefaultEchoKeptNilCarrier,
      'actual capturePlayback ignores unchanged cold-mount defaults without materializing optional nil playback');

    const digest = async path => createHash('sha256').update(await readFile(path)).digest('hex');
    await writeFile(join(root, 'receipt.json'), JSON.stringify({ result: failures ? 'FAIL' : 'GREEN', failures, wire, members,
      managerSHA256: await digest('app/SourcesShared/VortXSyncManager.swift'), compiledMethodsSHA256: await digest(join(root, 'Combined.swift')),
      binarySHA256: await digest(peerBinary), librarySHA256: process.env.VORTX_SYNC_TEST_LIBRARY_SHA256,
      headerSHA256: process.env.VORTX_SYNC_TEST_HEADER_SHA256,
      boundary: 'Actual extracted manager upload/merge/crypto/ACK/retry/queue plus native preference context/value/snapshot/admission/prepare/finish/replay, startup intent wake, local settings dirty detection, projection quarantine/mount gate and cloud receipt ACK methods; actual Profiles.saveNative and preference projection acknowledgement helpers. Real NativePreferenceIntentStore encrypted journal, native C ABI sessions, profile mutation/project converters and checkpoint stores. Journal directory and synthetic key are injected only by the peer fixture; no user Application Support or Keychain is read. Loopback blind relay contract model. Session mount, credential and legacy UserDefaults collaborators are synthetic. Does not exercise installed app/UI, complete syncDown, providers, WebSocket or deployed worker.' }, null, 2));
    if (failures) process.exitCode = 1;
  }
  console.log(`Receipt: ${join(root, 'receipt.json')}`);
} finally { await new Promise(resolve => server.close(resolve)); }
