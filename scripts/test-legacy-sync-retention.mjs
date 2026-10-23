#!/usr/bin/env node
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
process.chdir(resolve(import.meta.dirname, '..'));
const source = 'app/SourcesShared/VortXSyncManager.swift';
const manager = process.argv[2] === '--baseline-ref'
  ? execFileSync('git', ['show', `${process.argv[3]}:${source}`], {encoding: 'utf8'}) : readFileSync(source, 'utf8');
const start = manager.indexOf('    private func vortxSummary(');
const end = manager.indexOf('\n    }', start);
const method = manager.slice(start, end);
const result = method.split('\n').filter(line => /^        return /.test(line)).at(-1);
assert(result, 'production summary publication boundary must exist');
mkdirSync('app/build', {recursive: true});
const directory = mkdtempSync('app/build/legacy-retention.');
const fixture = readFileSync('app/Tests/LegacySyncRetentionTests.swift', 'utf8');
const output = join(directory, 'ProductionSummaryBoundary.swift');
writeFileSync(output, fixture.replace('    /* PRODUCTION_SUMMARY_RETURN */', result));
execFileSync('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
  'app/SourcesShared/LegacySyncRetention.swift', output, '-o', join(directory, 'checks')], {stdio: 'inherit'});
execFileSync(join(directory, 'checks'), [], {stdio: 'inherit'});
console.log(`Retained actual summary publication-boundary fixture: ${resolve(directory)}`);
