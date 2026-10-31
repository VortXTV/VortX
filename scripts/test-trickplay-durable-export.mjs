#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

// Compile the maintained data-only durable-export tests against actual policy/timeline sources.
// Synthetic fixture bytes only: no image decoder, live cache, app, player, account or network.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
process.umask(0o077);
const output = path.join(root, 'app/build');
fs.mkdirSync(output, {recursive:true});
const directory = fs.mkdtempSync(path.join(output, 'trickplay-durable-export.'));
const fixtures = path.join(directory, 'fixtures');
fs.mkdirSync(fixtures);
const binary = path.join(directory, 'run');
const environment = {...process.env, SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS:'1'};
console.log('Disposable durable-export fixtures: ' + directory);

function run(command, args, log, timeout) {
  const result = spawnSync(command, args, {encoding:'utf8', timeout, maxBuffer:4 * 1024 * 1024,
    cwd:root, env:environment});
  const stdout = result.stdout ?? '', stderr = result.stderr ?? '';
  fs.writeFileSync(path.join(directory, log), stdout + stderr);
  process.stdout.write(stdout); process.stderr.write(stderr);
  if (result.error) process.stderr.write(String(result.error) + '\n');
  if (result.signal) process.stderr.write('Terminated by signal: ' + result.signal + '\n');
  if (result.error || result.signal || result.status !== 0) process.exit(result.status || 1);
}

// Same compilation shape as the genuine ROOT-OPS/run-pure-v1.sh 53-check job:
// complete CommunityTrickplay + actual disk policy + maintained test, with no extraction or stubs.
// xcrun uses the selected Xcode's macOS compiler/SDK; Root binds that toolchain for actual runs.
run('xcrun', ['--sdk', 'macosx', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
  '-warnings-as-errors', '-O', '-j', '1', '-num-threads', '1', '-parse-as-library',
  '-D', 'TRICKPLAY_E2E_POLICY_TESTING', '-module-cache-path', path.join(directory, 'module-cache'),
  path.join(root, 'app/SourcesShared/CommunityTrickplay.swift'),
  path.join(root, 'app/SourcesShared/TrickplayUploadPolicy.swift'),
  path.join(root, 'app/Tests/TrickplayDurableExportTests.swift'), '-o', binary], 'compile.log', 60000);
run(binary, [fixtures], 'run.log', 10000);
