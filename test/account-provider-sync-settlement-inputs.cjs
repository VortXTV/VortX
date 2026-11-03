#!/usr/bin/env node
'use strict';
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const {extractDeclaration} = require('./xperience-harness-inputs.cjs');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function extract(root, directory) {
  root = fs.realpathSync(root); directory = fs.realpathSync(directory);
  const build = fs.realpathSync(path.join(root, 'app/build'));
  function inside(child, parent) { const rel = path.relative(parent, child); return rel && rel !== '..' && !rel.startsWith('..' + path.sep) && !path.isAbsolute(rel); }
  assert(inside(build, root) && inside(directory, build));
  const hashes = {}, declarations = [];
  function read(relative) { const bytes = fs.readFileSync(path.join(root, relative)); hashes[relative] = sha(bytes); return bytes.toString('utf8'); }
  function select(relative, header) {
    const source = read(relative), text = extractDeclaration(source, header), start = source.indexOf(header);
    assert.equal(text, source.slice(start, start + text.length));
    declarations.push({source: relative, header, sha256: sha(Buffer.from(text)), transformations: []}); return text + '\n';
  }
  const shared = 'app/SourcesShared/';
  const generated = 'import Foundation\nimport CoreFoundation\nimport CryptoKit\n' +
    select(shared + 'CredentialScope.swift', 'enum CredentialMutationResult: Equatable, Sendable {') +
    select(shared + 'CredentialScope.swift', 'enum CredentialDurableReadResult: Equatable, Sendable {') +
    select(shared + 'VortxResourceBridge.swift', 'indirect enum VortxJSON: Codable, Equatable, Sendable {') +
    select(shared + 'Keychain.swift', 'final class KeychainFailureClosedStore: @unchecked Sendable {') +
    select(shared + 'MediaServerProvider.swift', 'enum MediaServerKind: String, Sendable, CaseIterable {') +
    select(shared + 'MediaServerProvider.swift', 'struct MediaServerConfig: Sendable, Equatable {');
  const generatedPath = path.join(directory, 'ActualProviderSupport.swift'); fs.writeFileSync(generatedPath, generated, {flag: 'wx'});
  const whole = [shared + 'OwnerHistoryExactJSON.swift', shared + 'AccountProviderSyncBlob.swift',
    shared + 'MediaServerStore.swift', shared + 'IPTVPlaylistStore.swift', 'app/Tests/AccountProviderSyncSettlementTests.swift'];
  for (const relative of whole) read(relative);
  read('test/account-provider-sync-settlement-inputs.cjs'); read('test/xperience-harness-inputs.cjs');
  const result = {scope: 'whole actual provider store methods and actual failure-closed credential CAS; explicit synthetic backend/defaults/coordinator/owner boundary',
    compilerInputs: [generatedPath, ...whole.map(relative => path.join(root, relative))], sourceHashes: hashes, declarations,
    generatedHashes: {[generatedPath]: sha(Buffer.from(generated))},
    limitations: ['no real Keychain, UserDefaults, coordinator provider actors, owner registry, network, native ABI, manager integration or device proof',
      'credential generation races and ownership/cancellation are deliberately injected synchronous boundaries; fixture IO is test-flag-only',
      'coordinator adapter and real platform persistence behavior require separate app/source integration validation']};
  fs.writeFileSync(path.join(directory, 'inputs.json'), JSON.stringify(result, null, 2) + '\n', {flag: 'wx'});
}
module.exports = {extract};
if (require.main === module) { assert.equal(process.argv.length, 4); extract(process.argv[2], process.argv[3]); }
