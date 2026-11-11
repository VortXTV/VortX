#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const sourceRef = '85a46ac4b3ce5ebc75084383d00dc9152b738cb8';
const managerPath = 'app/SourcesShared/VortXSyncManager.swift';
const corePath = 'app/SourcesShared/CoreBridge.swift';
const sessionPath = 'app/SourcesShared/VortxNativeSession.swift';
const resourcePath = 'app/SourcesShared/VortxResourceBridge.swift';
const addonPath = 'app/SourcesShared/AddonTombstones.swift';
const watchedPath = 'app/SourcesShared/VortxLegacyWatchedMetadataTransport.swift';
const fixturePath = fileURLToPath(new URL('./AppleWebsiteRosterFixture.swift.in', import.meta.url));
assert.equal(process.argv.length, 4, 'usage: extract-apple-website-roster.mjs APP_REPOSITORY EXISTING_CAUSAL_EXTRACT_DIRECTORY');
const repo = realpathSync(process.argv[2]);
const output = realpathSync(process.argv[3]);
assert(output.startsWith(join(repo, 'app', 'build') + '/'), 'expected an owned ignored fixture directory');
const sha = value => createHash('sha256').update(value).digest('hex');
function git(...args) {
  return execFileSync('git', ['-C', repo, ...args], { maxBuffer: 16 * 1024 * 1024 }).toString('utf8');
}
const receipts = { sourceRef, files: {}, declarations: [], fixtureChanges: [], outputs: {} };
function production(path) {
  const frozen = git('show', `${sourceRef}:${path}`);
  receipts.files[path] = sha(frozen);
  return frozen;
}
function read(name) { return readFileSync(join(output, name), 'utf8'); }
function emit(name, value) {
  writeFileSync(join(output, name), value, { flag: 'wx' });
  receipts.outputs[name] = sha(value);
}
function unique(source, needle) {
  const index = source.indexOf(needle);
  assert(index >= 0 && source.indexOf(needle, index + needle.length) < 0, `missing or repeated anchor: ${needle}`);
  return index;
}
function replace(source, before, after, label) {
  const index = unique(source, before);
  receipts.fixtureChanges.push({ label, beforeSHA256: sha(before), afterSHA256: sha(after) });
  return source.slice(0, index) + after + source.slice(index + before.length);
}
function member(source, marker, inlineLines = 1) {
  // This Swift source uses four-space member indentation. Do not treat default closure
  // arguments, dictionary expressions, nested types or comments as the function body.
  let start = unique(source, marker);
  const markerStart = start;
  while (start > 0) {
    const prior = source.lastIndexOf('\n', start - 2) + 1;
    if (!source.slice(prior, start).trimStart().startsWith('@')) break;
    start = prior;
  }
  let lineEnd = source.indexOf('\n', markerStart);
  for (let i = 1; i < inlineLines; i++) lineEnd = source.indexOf('\n', lineEnd + 1);
  const end = source.slice(markerStart, lineEnd).trimEnd().endsWith('}')
    ? lineEnd : source.indexOf('\n    }', markerStart) + 6;
  assert(end > markerStart, `unterminated member: ${marker}`);
  return source.slice(start, end);
}
function actual(source, path, marker, singleLine = false) {
  const start = unique(source, marker);
  const selected = singleLine ? source.slice(start, source.indexOf('\n', start)) : member(source, marker);
  receipts.declarations.push({ path, marker, sha256: sha(selected) });
  return selected;
}
function section(name) {
  const first = '// BEGIN ' + name + '\n', end = '// END ' + name;
  const start = unique(fixture, first) + first.length;
  return fixture.slice(start, unique(fixture, end));
}

const fixture = readFileSync(fixturePath, 'utf8');
receipts.fixtureSHA256 = sha(fixture);
const causal = JSON.parse(read('causal-extraction.json'));
let combined = read('Combined.swift');
assert.equal(causal.combinedSHA256, sha(combined), 'causal extracted input changed');
assert(causal.productionMatches.some(entry => entry.path === managerPath && entry.ref === sourceRef),
  'existing causal extraction must use the exact app source');
receipts.causalCombinedSHA256 = sha(combined);
const manager = production(managerPath);
const core = production(corePath);
const session = production(sessionPath);
const resources = production(resourcePath);
const addons = production(addonPath);
production(watchedPath);
production('app/SourcesShared/VXProbeRedaction.swift');

const twoLineStubs = new Set([
  '    private func authorizedWebsiteAccountAdoption(',
  '    func publishNativeWatchedPending(',
  '    private func mergeOwnerHistoryForExport(',
]);
for (const prefix of [
  '    func restoreNativeCheckpoint(credentialCapture capture:',
  '    private func restoreNativeCheckpointWithCloudRead(credentialCapture capture:',
  '    private func authorizedWebsiteAccountAdoption(',
  '    private func prepareNativeLegacyMaterial(_ doc:',
  '    private func prepareNativeLegacyMaterial(_ document:',
  '    private func restoreOwnerHistoryPulledIfNeeded(',
  '    static func resolveRoster(from doc:',
  '    static func nativeWebsiteEvents(',
  '    static func nativeWebsiteAddonEvents(',
  '    func nativeLegacyWatchlists(',
  '    func publishNativeWebsiteOutcome(',
  '    func rememberNativeBackup(',
  '    func publishNativeWatchedPending(',
  '    func publishNativeOwnOverlayPending(',
  '    func publishAppliedAddonOrder(',
  '    func mergeInRoster(',
  '    func applyLocalTombstones(',
  '    static func snapshot(manager: VortXSyncManager,',
  '    private func mergeOwnerHistoryForExport(',
]) {
  const inlineLines = twoLineStubs.has(prefix) ? 2 : 1;
  combined = replace(combined, member(combined, prefix, inlineLines), '', `remove causal-only collaborator: ${prefix}`);
}

const managerAnchor = '@MainActor final class VortXSyncManager {';
const stored = [
  '    private var nativeCheckpointTask:', '    private var nativeCheckpointCapture:',
  '    private var nativeCheckpointProfile:', '    private var nativeRecoveryFailure:',
  '    @Published private(set) var nativeCheckpointStatus',
  '    @Published private(set) var nativeProfileEditConflicts:',
  '    @Published private(set) var nativeAddonEditConflicts:',
  '    @Published private(set) var nativeOwnAccountResyncUnavailable:',
  '    @Published private(set) var nativeOwnAccountOverlayPending:',
  '    @Published private(set) var nativeOwnAccountOverlayUnattributed:',
  '    @Published private(set) var nativeWatchedMigrationPending:',
  '    private var nativeWatchedPendingTask:', '    private var nativeWatchedPendingGeneration',
  '    private var loggedNativeLegacyReconciliation:', '    private var deferredLegacyConversion:',
  '    private static let nativeObservedBackupAccountLimit',
  '    private var nativeObservedBackupAccounts:', '    private var nativeBackupObservationOverflow',
  '    private enum NativeBackupHistory:',
  '    nonisolated private static let kAddonOrderKey', '    nonisolated private static let maxAddonOrderEntries',
  '    nonisolated static let addonOrderChangedNote',
];
combined = replace(combined, managerAnchor, managerAnchor + '\n' +
  stored.map(marker => actual(manager, managerPath, marker, true)).join('\n') + '\n' +
  section('MANAGER STORAGE'), 'restore lifecycle storage');
combined = replace(combined, '    var isSignedIn = true; var hasAppliedAccountDoc = false',
  '    var isSignedIn = true', 'real account-applied accessor');
combined = replace(combined, '    var lastSyncedVersion = 0; var stamped = 0',
  '    var stamped = 0', 'real per-account version accessor');
combined = replace(combined, '    static let writeSyncDocV2 = true',
  actual(manager, managerPath, '    static let writeSyncDocV2 =', true), 'real write-format default');
combined = replace(combined, '    static let appliedAddonOrder: [String] = [] // No legacy add-on carrier in this test.',
  actual(manager, managerPath, '    nonisolated static var appliedAddonOrder:'), 'real add-on order backing');
const defaultsAnchor = '    func dictionary(forKey key: String)';
combined = replace(combined, defaultsAnchor, '    func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }\n' +
  defaultsAnchor, 'memory defaults integer accessor');

const keychain = '    static func confirmedString(_ key: String) -> CredentialDurableReadResult { .missing }';
combined = replace(combined, keychain, section('KEYCHAIN ENVIRONMENT'), 'synthetic host actor and backup-seen Keychain slots');
const profileAnchor = '@MainActor\nfinal class ProfileStore {';
combined = replace(combined, profileAnchor, profileAnchor + '\n' + section('PROFILE ENVIRONMENT'), 'synthetic profile presentation boundary');
const sleep = 'try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))';
combined = replace(combined, sleep, 'try await Task.sleep(nanoseconds: UInt64(max(delay, 3600) * 1_000_000_000))',
  'park automatic timer until explicit commands finish, without altering scheduling/admission decisions');

const methods = [
  '    private func versionKey(', '    private var lastSyncedVersion:', '    private func appliedDocKey(',
  '    private var hasAppliedAccountDoc:', '    private func nativeLegacyWatchlists(',
  '    private func rememberNativeBackup(', '    private func nativeHostActor(',
  '    private func applyLaunchNativeLegacyConversion(', '    private func retireNativeWatchedPendingProjection(',
  '    func publishNativeWatchedPending(', '    func publishNativeOwnOverlayPending(',
  '    private func noteNativeLegacyReconciliation(', '    private func prepareNativeLegacyMaterial(',
  '    private static func nativeWebsiteEvents(', '    private static func nativeWebsiteAddonEvents(',
  '    private static func nativeLegacyMaterial(', '    private func publishDetachedNativeSeed(',
  '    private func publishNativeWebsiteOutcome(', '    private func authorizedWebsiteAccountAdoption(',
  '    private func restoreOfflineNativeCheckpoint(', '    private enum NativeRestoreAdmissionFailure:',
  '    private struct NativeRestoreDocument {', '    private func nativeRestoreDocument(',
  '    private static func elapsedMs(', '    func restoreNativeCheckpoint(',
  '    private func restoreNativeCheckpointWithCloudRead(', '    private func pullNativeCheckpointCloudSource(',
  '    static func resolveRoster(', '    @MainActor private func restoreOwnerHistoryPulledIfNeeded(',
  '    private func publishAppliedAddonOrder(',
];
const entry = '@main @MainActor enum NativeCausalRepairPeer';
const entryStart = unique(combined, entry);
receipts.fixtureChanges.push({ label: 'replace causal executable entry point', beforeSHA256: sha(combined.slice(entryStart)),
  afterSHA256: sha(section('EXECUTABLE')) });
combined = combined.slice(0, entryStart)
  + '\nextension VortXSyncManager {\n'
  + methods.map(marker => actual(manager, managerPath, marker)).join('\n') + '\n}\n'
  + 'extension CoreBridge {\n' + actual(core, corePath, '    func captureNativeSourceFence(') + '\n}\n'
  + 'enum AddonOwnerStorage {\n' + ['    static func key(', '    static func currentKey('].map(marker =>
    actual(addons, addonPath, marker)).join('\n') + '\n}\n'
  + section('MANAGER ENVIRONMENT') + section('CORE ENVIRONMENT') + section('EXECUTABLE');

function replaceTopLevel(source, startMarker, endMarker, replacement, label) {
  const start = unique(source, startMarker), end = unique(source, endMarker);
  assert(end > start);
  return replace(source, source.slice(start, end), replacement, label);
}
const localSession = replaceTopLevel(session, 'enum VortxNativeStorage {',
  '/// Native-only exports cannot acknowledge legacy host edits', section('HERMETIC STORAGE'),
  'fixture-owned storage root and installation identity; whole checkpoint and Session retained');
const resourceStart = unique(resources, 'final class VortxCResourceTransport:');
const resourceEnd = resources.indexOf('\n}', resourceStart) + 2;
assert(resourceEnd > resourceStart && resources.slice(resourceEnd).trim() === '',
  'review production transport declaration boundary');
const closedResources = replace(resources, resources.slice(resourceStart, resourceEnd),
  section('NO RESOURCE TRANSPORT'), 'deny external native resource requests');
emit('WebsiteRosterCombined.swift', combined);
emit('WebsiteRosterNativeSession.swift', localSession);
emit('WebsiteRosterResourceBridge.swift', closedResources);
emit('WebsiteRosterWatchedTransport.swift', 'import Foundation\n' + section('NO WATCHED TRANSPORT'));
emit('website-roster-extraction.json', JSON.stringify(receipts, null, 2) + '\n');
