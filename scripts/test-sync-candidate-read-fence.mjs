#!/usr/bin/env node
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
import fixtureInputs from '../test/xperience-harness-inputs.cjs';
process.chdir(resolve(import.meta.dirname, '..'));
const path = 'app/SourcesShared/VortXSyncManager.swift';
const current = readFileSync(path, 'utf8');
const manager = process.argv[2] === '--baseline-ref'
  ? execFileSync('git', ['show', `${process.argv[3]}:${path}`], {encoding: 'utf8'}) : current;
const start = manager.indexOf('    private func mergeLocalIntoDoc(');
const exportMarker = '\n        // The native CRDT is a TOP-LEVEL sibling';
const exportStart = manager.indexOf(exportMarker, start);
const legacyGuard = '\n#if VORTX_NATIVE_DATA_ENGINE';
const end = manager.slice(0, exportStart).endsWith(legacyGuard) ? exportStart - legacyGuard.length : exportStart;
assert(start >= 0 && end > start);
const pull = fixtureInputs.extractDeclaration(manager, '    private enum VersionedPull {');
const completePull = pull.includes('case ownerHistory(');
const boundary = fixtureInputs.extractDeclaration(current, '    private struct DerivedSyncDoc {') + '\n'
  + pull + '\n' + manager.slice(start, end)
  + (manager.slice(start, end).includes('let cloudAuthority =') ? '\n        _ = cloudAuthority' : '')
  + '\n        return DerivedSyncDoc(document: doc, baseRevision: baseRevision, credentialCapture: capture, sourceIsCurrent: { true }'
  + (completePull ? ', plaintextData: originalPlaintext' : '') + ')\n    }';
mkdirSync('app/build', {recursive: true});
const directory = mkdtempSync('app/build/sync-candidate-read.');
const output = join(directory, 'ProductionReadAdmission.swift');
writeFileSync(output, readFileSync('app/Tests/SyncCandidateReadFenceTests.swift', 'utf8').replace('    /* PRODUCTION_READ_BOUNDARY */', boundary));
execFileSync('/usr/bin/xcrun', ['swiftc', '-j', '1', '-num-threads', '1', '-parse-as-library', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
  '-D', 'VORTX_NATIVE_DATA_ENGINE', ...(completePull ? ['-D', 'VORTX_COMPLETE_VERSIONED_PULL'] : []),
  output, '-o', join(directory, 'checks')], {stdio: 'inherit'});
execFileSync(join(directory, 'checks'), [], {stdio: 'inherit'});
console.log(`Retained actual candidate read-admission boundary: ${resolve(directory)}`);
