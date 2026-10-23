#!/usr/bin/env node
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
process.chdir(resolve(import.meta.dirname, '..'));
const path = 'app/SourcesShared/VortXSyncManager.swift';
const current = readFileSync(path, 'utf8');
const manager = process.argv[2] === '--baseline-ref'
  ? execFileSync('git', ['show', `${process.argv[3]}:${path}`], {encoding: 'utf8'}) : current;
const start = manager.indexOf('    private func mergeLocalIntoDoc(');
const end = manager.indexOf('#if VORTX_NATIVE_DATA_ENGINE\n        // The native CRDT', start);
assert(start >= 0 && end > start);
const typeStart = current.indexOf('    private struct DerivedSyncDoc {');
const typeEnd = current.indexOf('\n    }', typeStart);
const boundary = current.slice(typeStart, typeEnd + 6) + '\n'
  + manager.split('\n').find(line => line.includes('private enum VersionedPull')) + '\n'
  + manager.slice(start, end)
  + '\n        return DerivedSyncDoc(document: doc, baseRevision: baseRevision, credentialCapture: capture, sourceIsCurrent: { true })\n    }';
mkdirSync('app/build', {recursive: true});
const directory = mkdtempSync('app/build/sync-candidate-read.');
const output = join(directory, 'ProductionReadAdmission.swift');
writeFileSync(output, readFileSync('app/Tests/SyncCandidateReadFenceTests.swift', 'utf8').replace('    /* PRODUCTION_READ_BOUNDARY */', boundary));
execFileSync('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
  '-D', 'VORTX_NATIVE_DATA_ENGINE', output, '-o', join(directory, 'checks')], {stdio: 'inherit'});
execFileSync(join(directory, 'checks'), [], {stdio: 'inherit'});
console.log(`Retained actual candidate read-admission boundary: ${resolve(directory)}`);
