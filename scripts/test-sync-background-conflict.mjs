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
const [manager, view, policy, pushPolicy, template] = await Promise.all([
  source('app/SourcesShared/VortXSyncManager.swift'), source('app/SourcesShared/SyncSettingsView.swift'),
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
const merge = block(manager, '    @discardableResult func mergeBoth()');
const resolution = block(view, '    private func resolveConflict(');
function action(label) {
  const line = view.split('\n').find(line => line.includes(`Button("${label}")`));
  assert(line, `missing production conflict action ${label}`);
  const start = line.indexOf('resolveConflict {'); assert(start >= 0);
  return line.slice(start, line.lastIndexOf(' }'));
}
const pullWrapper = fixed
  ? 'return await syncDown(force: force, reportOutcome: { self.pullOutcomes.append($0) })'
  : 'return await syncDown(force: force)';
const useWrapper = fixed ? 'return await useAccountData()' : 'await useAccountData(); return nil';
const resolutionWrapper = fixed ? 'resolveConflict { outcome }' : 'resolveConflict { _ = outcome }';
let combined = template.replace('/* PRODUCTION_MANAGER */', [outcomeLine, background, upload, pullControl, useAccount, merge, helpers].join('\n'))
  .replace('/* PRODUCTION_RESOLUTION */', resolution)
  .replace('/* PULL_WRAPPER */', pullWrapper).replace('/* ACCOUNT_WRAPPER */', useWrapper)
  .replace('/* RESOLUTION_WRAPPER */', resolutionWrapper)
  .replace('/* RELEASE_WRAPPER */', fixed ? 'finishSyncUp(id)' : 'if activeSyncUp?.id == id { activeSyncUp = nil }')
  .replace('/* MERGE_ACTION */', action('Merge both (keep all profiles)'))
  .replace('/* KEEP_ACTION */', action('Keep this device'))
  .replace('/* USE_ACTION */', action("Use account's data"))
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
