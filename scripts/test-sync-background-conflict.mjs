#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp } from 'node:fs/promises';
import { execFileSync, spawnSync } from 'node:child_process';
import { resolve, join } from 'node:path';

const root = resolve(import.meta.dirname, '..');
process.chdir(root);
const args = process.argv.slice(2);
assert(args.length === 0 || (args.length === 2 && args[0] === '--baseline-ref'));
const source = path => args.length ? execFileSync('git', ['show', `${args[1]}:${path}`], { encoding: 'utf8' }) : readFile(path, 'utf8');
const [manager, view, backup, policy, pushPolicy, template] = await Promise.all([
  source('app/SourcesShared/VortXSyncManager.swift'), source('app/SourcesShared/SyncSettingsView.swift'),
  source('app/SourcesTV/BackupExportView.swift'),
  readFile('app/SourcesShared/AddonReorderMove.swift', 'utf8'), readFile('app/SourcesShared/NativeForegroundSyncPolicy.swift', 'utf8'),
  readFile('app/Tests/SyncBackgroundConflictTests.swift', 'utf8')
]);
function block(text, marker, indentation = '    ') {
  const start = text.indexOf(marker); assert(start >= 0, `missing production ${marker}`);
  const end = text.indexOf(`\n${indentation}}`, start); assert(end > start, `missing end ${marker}`);
  return text.slice(start, end + indentation.length + 2);
}
const fixed = manager.includes('private func flushBackgroundSync(');
const background = block(manager, '    func syncUpOnBackground()').replaceAll('#if canImport(UIKit) && !os(macOS)', '#if true');
const upload = '@discardableResult\n' + block(manager, '    func syncUp(afterUserChoseThisDevice:')
  .split('#if VORTX_NATIVE_DATA_ENGINE\n        // An already-restored account')[0]
  + '\n        uploadStarts += 1\n        uploadedGenerations.append(nativePushQueue.generation)\n'
  + '        if let gate = uploadGate { uploadGate = nil; await gate.wait() }\n        return uploadAccepted\n    }';
const pull = block(manager, '    func syncDown(force:');
const pullPrefix = pull.slice(0, pull.indexOf('        var doc = pulled.doc'));
assert(pullPrefix.endsWith('\n'));
const pullTailStart = pull.lastIndexOf('        withRemoteApplySuppressed {');
assert(pullTailStart > 0);
// Preserve the production admission/read/no-op and final ACK control. The intervening credential,
// engine and defaults application is a fixture aperture; it does not run in this inert control test.
const pullControl = '@discardableResult\n' + pullPrefix + '        let restored = fixtureRestored\n' + pull.slice(pullTailStart);
const helpers = fixed ? ['    private func finishSyncUp(', '    private func awaitSyncUpCompletion(',
  '    @MainActor private final class BackgroundSyncLease {', '    private func flushBackgroundSync(']
  .map(marker => block(manager, marker)).join('\n') : '';
const outcome = fixed ? block(manager, '    enum ConflictResolutionOutcome:') : '    enum ConflictResolutionOutcome: Equatable { case completed, pending, failed }';
// The enum is one line; block() would otherwise include the next method.
const outcomeLine = outcome.split('\n')[0];
const useAccountMarker = fixed ? '    @discardableResult func useAccountData()' : '    func useAccountData()';
const useAccount = block(manager, useAccountMarker);
const reconcile = block(manager, '    func reconcileAfterSignIn()');
const merge = block(manager, '    @discardableResult func mergeBoth()');
const resolution = block(view, '    private func resolveConflict(');
function action(text, label, handler) {
  const line = text.split('\n').find(line => line.includes(`Button("${label}")`));
  assert(line, `missing production conflict action ${label}`);
  const start = line.indexOf(`${handler} {`); assert(start >= 0);
  return line.slice(start, line.lastIndexOf(' }'));
}
const backupResolution = block(backup, '    private func resolve(');
const poll = block(backup, '    private func pollLoop(');
const signedInStart = poll.indexOf('            case .signedIn:');
const signedInEnd = poll.lastIndexOf('\n                return');
assert(signedInStart > 0 && signedInEnd > signedInStart);
const signedIn = poll.slice(signedInStart + '            case .signedIn:'.length, signedInEnd + '\n                return'.length);
const pullWrapper = fixed
  ? 'return await syncDown(force: force, reportOutcome: { self.pullOutcomes.append($0) })'
  : 'return await syncDown(force: force)';
const useWrapper = fixed ? 'return await useAccountData()' : 'await useAccountData(); return nil';
const resolutionWrapper = fixed ? 'resolveConflict { outcome }' : 'resolveConflict { _ = outcome }';
let combined = template.replace('/* PRODUCTION_MANAGER */', [outcomeLine, background, upload, pullControl, useAccount, merge, reconcile, helpers].join('\n'))
  .replace('/* PRODUCTION_RESOLUTION */', resolution)
  .replace('/* PULL_WRAPPER */', pullWrapper).replace('/* ACCOUNT_WRAPPER */', useWrapper)
  .replace('/* RESOLUTION_WRAPPER */', resolutionWrapper)
  .replace('/* RELEASE_WRAPPER */', fixed ? 'finishSyncUp(id)' : 'if activeSyncUp?.id == id { activeSyncUp = nil }')
  .replace('/* MERGE_ACTION */', action(view, 'Merge both (keep all profiles)', 'resolveConflict'))
  .replace('/* KEEP_ACTION */', action(view, 'Keep this device', 'resolveConflict'))
  .replace('/* USE_ACTION */', action(view, "Use account's data", 'resolveConflict'))
  .replace('/* BACKUP_MERGE_ACTION */', action(backup, 'Merge both (keep all profiles)', 'resolve'))
  .replace('/* BACKUP_KEEP_ACTION */', action(backup, 'Keep this device', 'resolve'))
  .replace('/* BACKUP_USE_ACTION */', action(backup, "Use account's data", 'resolve'))
  .replace('/* BACKUP_RESOLUTION */', backupResolution)
  .replace('/* BACKUP_SIGNED_IN */', signedIn)
  .replace('/* BACKUP_STATUS */', backup.split('\n').find(line => line.includes('private enum Status:')))
  .replace('/* RECONCILE_RESULT */', manager.split('\n').find(line => line.includes('enum SignInReconcile:')))
  .replace('/* PROBE_RESULT */', manager.split('\n').find(line => line.includes('enum AccountDataProbe:')))
  .replace('/* PRODUCTION_PUSH_QUEUE */', block(pushPolicy, '    struct PushQueue: Equatable {'))
  .replace('/* PRODUCTION_PULL_POLICY */', block(policy, 'enum AddonSyncPullPolicy {', ''));
await mkdir('app/build', { recursive: true });
const directory = await mkdtemp(join(root, 'app/build/sync-background-conflict.'));
const swiftPath = join(directory, 'Combined.swift');
await writeFile(swiftPath, combined);
console.log(`Extracted ${fixed ? 'current' : args[1]} production controls to ${swiftPath}`);
execFileSync('xcrun', ['swiftc', '-swift-version', '6', '-parse-as-library', '-strict-concurrency=complete',
  '-warnings-as-errors', '-D', 'VORTX_NATIVE_DATA_ENGINE', swiftPath, '-o', join(directory, 'control-tests')], { stdio: 'inherit' });
const result = spawnSync(join(directory, 'control-tests'), [], { stdio: 'inherit' });
assert.equal(result.signal, null, 'control harness terminated by signal');
process.exit(result.status ?? 1);
