#!/usr/bin/env node
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
const root = resolve(import.meta.dirname, '..');
process.chdir(root);
const production = readFileSync('app/SourcesShared/SyncSettingsView.swift', 'utf8');
const manager = readFileSync('app/SourcesShared/VortXSyncManager.swift', 'utf8');
function requireSharedRestoreRetry(source) {
  const offset = source.indexOf('    func retryAccountRestore() async -> Bool {');
  assert(offset >= 0, 'missing shared restore retry');
  const conditions = [];
  for (const [, directive, condition] of source.slice(0, offset).matchAll(/^\s*#(if|elseif|else|endif)\b([^\n]*)/gm)) {
    if (directive === 'if') conditions.push(condition);
    else if (directive === 'endif') { assert(conditions.length); conditions.pop(); }
    else if (directive === 'elseif') conditions[conditions.length - 1] += condition;
  }
  assert(!conditions.some(condition => condition.includes('VORTX_NATIVE_DATA_ENGINE')),
    'Settings restore retry must exist in both native and Lite/legacy shells');
}
requireSharedRestoreRetry(manager);
assert.throws(() => requireSharedRestoreRetry(manager.replace('    func retryAccountRestore() async -> Bool {',
  '#if VORTX_NATIVE_DATA_ENGINE\n    func retryAccountRestore() async -> Bool {')),
  /must exist in both native and Lite\/legacy shells/);
function block(startText, endText) {
  const start = production.indexOf(startText);
  const end = production.indexOf(endText, start + startText.length);
  assert(start >= 0 && end > start, `missing production block ${startText}`);
  return production.slice(start + startText.length, end);
}
const reset = block('.onReceive(NotificationCenter.default.publisher(for: VortXSyncManager.credentialScopeDidChangeNote)) { _ in\n', '\n        }');
const recovery = block('.onValueChange(of: sync.lastSyncAt) { stamp in\n', '\n        }');
const methodStart = production.indexOf('    private func syncNow() {');
const methodEnd = production.indexOf('\n    }', methodStart);
assert(methodStart >= 0 && methodEnd > methodStart);
// Historical completion is not permission to suppress a newly failed action.
assert(production.includes('} else if let syncNote {'));
assert(!production.includes('else if let syncNote, !sync.synchronizationIsComplete'));
const template = readFileSync('app/Tests/SyncSettingsOutcomeTests.swift', 'utf8');
mkdirSync('app/build', {recursive: true});
const directory = mkdtempSync('app/build/sync-settings-outcomes.');
const source = join(directory, 'ProductionSettings.swift');
writeFileSync(source, template
  .replace('        /* PRODUCTION_SCOPE_RESET */', reset)
  .replace('        /* PRODUCTION_STAMP_RECOVERY */', recovery)
  .replace('    /* PRODUCTION_SYNC_NOW */', production.slice(methodStart, methodEnd + 6)));
execFileSync('xcrun', ['swiftc', '-j', '1', '-num-threads', '1', '-parse-as-library', '-swift-version', '6', '-strict-concurrency=complete',
  '-warnings-as-errors', source, '-o', join(directory, 'checks')], {stdio: 'inherit'});
execFileSync(join(directory, 'checks'), [], {stdio: 'inherit'});
console.log(`Retained production settings-method fixture: ${resolve(directory)}`);
