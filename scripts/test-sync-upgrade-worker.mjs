#!/usr/bin/env node
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
process.chdir(resolve(import.meta.dirname, '..'));
const source = 'app/SourcesShared/VortXSyncManager.swift';
const baseline = process.argv[2] === '--baseline-ref';
const manager = baseline ? execFileSync('git', ['show', `${process.argv[3]}:${source}`], {encoding: 'utf8'}) : readFileSync(source, 'utf8');
function block(text, marker) {
  const start = text.indexOf(marker), end = text.indexOf('\n    }', start);
  assert(start >= 0 && end > start, marker); return text.slice(start, end + 6);
}
const worker = block(manager, '    func requestSyncSoon()').replaceAll('Task.sleep(nanoseconds:', 'FixtureSleep.sleep(nanoseconds:');
const queue = block(readFileSync('app/SourcesShared/NativeForegroundSyncPolicy.swift', 'utf8'), '    struct PushQueue:');
const fixture = readFileSync('app/Tests/SyncUpgradeWorkerTests.swift', 'utf8');
const current = readFileSync(source, 'utf8');
const receiveStart = current.indexOf('        let received = await pullDocVersionedRetrying(');
const receiveEnd = current.indexOf('        switch received {', receiveStart);
assert(receiveStart >= 0 && receiveEnd > receiveStart);
const receive = current.slice(receiveStart, receiveEnd);
const settlementStart = current.indexOf('        guard isCurrent(capture), dataKey == capturedDataKey, !providerSettlement.superseded,');
const settlementEnd = current.indexOf('        if !providerSettlement.completed', settlementStart);
assert(settlementStart >= 0 && settlementEnd > settlementStart);
const settlement = current.slice(settlementStart, settlementEnd);
if (!baseline) {
  assert(block(manager, '    func syncDown(').includes('backupUploadFailure != .upgradeRequired'), 'upgrade latch also protects pending local edits from forced receive');
}
mkdirSync('app/build', {recursive: true});
const directory = mkdtempSync('app/build/sync-upgrade-worker.');
const output = join(directory, 'ProductionWorker.swift');
writeFileSync(output, `enum NativeForegroundSyncPolicy {\n${queue}\n}\n` + fixture.replace('    /* PRODUCTION_WORKER */', worker)
  .replace('        /* PRODUCTION_RECEIVE_ADMISSION */', receive)
  .replace('        /* PRODUCTION_SETTLEMENT_ADMISSION */', settlement));
for (const native of [true, false]) {
  const binary = join(directory, native ? 'native-checks' : 'lite-checks');
  execFileSync('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
    ...(native ? ['-D', 'VORTX_NATIVE_DATA_ENGINE'] : []), 'app/SourcesShared/SyncBackupUploadFailure.swift', output, '-o', binary], {stdio: 'inherit'});
  execFileSync(binary, [], {stdio: 'inherit'});
}
console.log(`Retained actual worker fixture (clock delay injected): ${resolve(directory)}`);
