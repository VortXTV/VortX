#!/usr/bin/env node
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

process.chdir(resolve(import.meta.dirname, '..'));
const manager = readFileSync('app/SourcesShared/VortXSyncManager.swift', 'utf8');
const tvBackup = readFileSync('app/SourcesTV/BackupExportView.swift', 'utf8');
function method(source, marker) {
  const start = source.indexOf(`\n    ${marker}`);
  const end = source.indexOf('\n    }', start + 1);
  assert(start >= 0 && start === source.lastIndexOf(`\n    ${marker}`) && end > start, marker);
  return source.slice(start, end + 6);
}
const methods = [
  'private func finishSyncUp(', 'private func finishSyncDown(', 'private func finishSyncWaiters(',
  'private func awaitSyncCompletion(', 'private func recoverInitialBackupWinner(',
  'func reconcileAfterSignIn(', '@discardableResult func useAccountData(',
  'private func syncConflictPull(', '@discardableResult func mergeBoth(',
].map(marker => method(manager, marker));
for (const marker of ['enum ConflictResolutionOutcome:', 'enum SignInReconcile:', 'enum AccountDataProbe:']) {
  const declaration = manager.split('\n').find(line => line.startsWith(`    ${marker}`));
  assert(declaration, marker);
  methods.push(declaration);
}
const receiveStart = manager.indexOf('        guard activeSyncDown?.capture != capture, activeSyncUp?.capture != capture else {');
const receiveEnd = manager.indexOf('        // PENDING-EDIT GUARD.', receiveStart);
assert(receiveStart > 0 && receiveEnd > receiveStart);
const uploadStart = manager.indexOf('        if activeSyncUp?.capture == capture || activeSyncDown?.capture == capture {');
const uploadEnd = manager.indexOf('        let operationID = UUID()', uploadStart);
assert(uploadStart > 0 && uploadEnd > uploadStart);
assert(manager.includes('await recoverInitialBackupWinner(operationID: operationID, capture: capture)'));
const tvMethods = ['private func isCurrent(', 'private func finishPairing(', 'private func retry()', 'private func resolve(']
  .map(marker => method(tvBackup, marker));
for (const marker of ['private enum Status:', 'private enum BackupDecision']) {
  const declaration = tvBackup.split('\n').find(line => line.startsWith(`    ${marker}`));
  assert(declaration, marker);
  tvMethods.push(declaration.replace('private enum', 'enum'));
}
const fixture = readFileSync('app/Tests/AppleSyncRecoveryTests.swift', 'utf8')
  .replace('    /* PRODUCTION_METHODS */', methods.join('\n'))
  .replace('    /* PRODUCTION_TV_METHODS */', tvMethods.join('\n'))
  .replace('        /* PRODUCTION_RECEIVE_SLOT */', manager.slice(receiveStart, receiveEnd))
  .replace('        /* PRODUCTION_UPLOAD_QUEUE */', manager.slice(uploadStart, uploadEnd));
mkdirSync('app/build', { recursive: true });
const directory = mkdtempSync('app/build/apple-sync-recovery.');
const source = join(directory, 'Combined.swift');
const binary = join(directory, 'checks');
writeFileSync(source, fixture);
execFileSync('/usr/bin/nice', ['-n', '15', 'xcrun', 'swiftc', '-j', '1', '-num-threads', '1', '-parse-as-library',
  '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', source, '-o', binary], { stdio: 'inherit' });
execFileSync(binary, [], { stdio: 'inherit' });
