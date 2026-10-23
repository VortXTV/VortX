#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

// Source-extraction host test: no app build, playback, network, account or device.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixtureRoot = path.join(root, 'app/build');
fs.mkdirSync(fixtureRoot, {recursive:true});
const dir = fs.mkdtempSync(path.join(fixtureRoot, 'localized-metadata.'));
let source = fs.readFileSync(path.join(root, 'app/SourcesShared/LocalizedMetadata.swift'), 'utf8');
function seam(before, after) {
  if (!source.includes(before)) throw Error('Production test seam changed: ' + before);
  source = source.replace(before, after);
}
// Only transport/clock/storage/access seams differ. All request, flush, response
// classification, retry, cache load/save, and contribution logic is production.
seam('private init() { loadDiskCache() }', 'init() { loadDiskCache() }');
seam('let cfg = URLSessionConfiguration.default', 'let cfg = URLSessionConfiguration.ephemeral\n        cfg.protocolClasses = [FakeProtocol.self]');
const cacheDeclaration = /    private var cacheURL: URL\? \{[\s\S]*?\n    \}/;
if (!cacheDeclaration.test(source)) throw Error('Production cacheURL declaration changed');
source = source.replace(cacheDeclaration, '    private var cacheURL: URL? { Fixture.cacheURL }');
seam('private static let saveDelayNanoseconds: UInt64 = 1_500_000_000', 'private static let saveDelayNanoseconds: UInt64 = 10_000_000');
source = source.replaceAll('Date()', 'Fixture.now');
fs.writeFileSync(path.join(dir, 'metadata.swift'), source);
fs.copyFileSync(path.join(root, 'app/Tests/LocalizedMetadataStoreTests.swift'), path.join(dir, 'main.swift'));
const binary = path.join(dir, 'run');
const compile = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-o', binary,
                                  path.join(dir, 'metadata.swift'), path.join(dir, 'main.swift')], {encoding:'utf8'});
if (compile.status !== 0) {
  process.stderr.write(compile.stdout + compile.stderr);
  process.exit(compile.status ?? 1);
}
const result = spawnSync(binary, [], {encoding:'utf8', timeout:20000,
                                    env:{...process.env,VORTX_L10N_TEST_DIRECTORY:dir}});
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);
console.log('Host-only localized metadata fixtures: ' + dir);
process.exit(result.status ?? 1);
