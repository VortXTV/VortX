#!/usr/bin/env node
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
import xperienceInputs from '../test/xperience-harness-inputs.cjs';
const root = resolve(import.meta.dirname, '..');
process.chdir(root);
let manager = readFileSync('app/SourcesShared/VortXSyncManager.swift', 'utf8');
if (process.argv[2] === '--baseline-ref') {
  manager = execFileSync('git', ['show', `${process.argv[3]}:app/SourcesShared/VortXSyncManager.swift`], {encoding: 'utf8'});
  // Signature-only adapter lets today's fixture exercise the unchanged old transport body.
  manager = manager.replace('version: Int, credentialCapture suppliedCapture:',
    'version: Int, baseRevision: Int?, sourceIsCurrent: () -> Bool = { true }, credentialCapture suppliedCapture:');
}
const start = manager.indexOf('    private func pushSyncDocAt(');
const end = manager.indexOf('\n    }', start);
assert(start >= 0 && end > start);
let verdict = manager.split('\n').find(line => line.includes('private enum PushOutcome'));
if (process.argv[2] === '--baseline-ref') verdict = verdict.replace('case error', 'case upgradeRequired; case error');
assert(verdict);
const template = readFileSync('app/Tests/SyncBackupUploadTransportTests.swift', 'utf8');
mkdirSync('app/build', {recursive: true});
const directory = mkdtempSync('app/build/sync-backup-upload.');
const source = join(directory, 'ProductionUpload.swift');
const readStart = manager.indexOf('    private func pullDocVersionedResult(');
const readEnd = manager.indexOf('\n    }', readStart);
assert(readStart >= 0 && readEnd > readStart);
const readVerdict = manager.split('\n').find(line => line.includes('private enum VersionedPull'));
const observation = xperienceInputs.observationProperty(manager);
const observationSources = xperienceInputs.observationInputs(readFileSync(xperienceInputs.observationInputList, 'utf8'));
writeFileSync(source, template.replace('    /* PRODUCTION_UPLOAD */', observation + '\n' + verdict + '\n' + manager.slice(start, end + 6)
  + '\n' + readVerdict + '\n' + manager.slice(readStart, readEnd + 6)));
for (const native of [true, false]) {
  const binary = join(directory, native ? 'native-checks' : 'lite-checks');
  execFileSync('/usr/bin/nice', ['-n', '15', 'xcrun', 'swiftc', '-j', '1', '-num-threads', '1', '-whole-module-optimization', '-parse-as-library', '-swift-version', '6', '-strict-concurrency=complete',
    '-warnings-as-errors', ...(native ? ['-D', 'VORTX_NATIVE_DATA_ENGINE'] : []),
    ...observationSources,
    'app/SourcesShared/SyncBackupUploadFailure.swift', 'app/SourcesShared/SyncDocumentRevisionPolicy.swift',
    source, '-o', binary], {stdio: 'inherit'});
  execFileSync(binary, [], {stdio: 'inherit'});
}
console.log(`Retained actual upload-method fixture: ${resolve(directory)}`);
