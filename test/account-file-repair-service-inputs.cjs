#!/usr/bin/env node
'use strict';
// Compose the already-reviewed cold converter recipe with the ACTUAL file-service enum and
// ACTUAL manager operation block. The explicit seams are auth/transport and a post-worker hook;
// no converter/parser/native candidate is replaced or rewritten.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { recipe, extract } = require('./account-backup-repair-inputs.cjs');
const { extractDeclaration } = require('./xperience-harness-inputs.cjs');
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function compose(root, directory) {
  root = fs.realpathSync(root); directory = fs.realpathSync(directory);
  const oldMain = 'app/Tests/VortxAccountBackupRepairTests.swift';
  assert.equal(recipe.wholeFiles.filter(x => x === oldMain).length, 1);
  recipe.wholeFiles = recipe.wholeFiles.filter(x => x !== oldMain);
  recipe.wholeFiles.push('app/Tests/VortxAccountFileRepairServiceTests.swift');
  const model = recipe.outputs.find(x => x.name === 'ActualModels.swift');
  assert(model && model.parts.at(-1).literal === '}\n');
  // Keep real Capture and real lock-protected query methods. Only generation establishment
  // is a synthetic setter, because this fixture deliberately never calls keychain/auth APIs.
  model.parts.splice(model.parts.length - 1, 0,
    { literal: 'static let shared = CredentialScopeRegistry()\nprivate let lock = NSLock()\nprivate var scope: CredentialScope\nprivate var generation: UInt64\nprivate var establishedGeneration: UInt64?\n' },
    ...[
      '    init(initialScope: CredentialScope = .signedOutDevice) {',
      '    func capture() -> Capture {',
      '    func isCurrent(_ capture: Capture) -> Bool {',
      '    func isMigrationEligible(_ capture: Capture) -> Bool {'
    ].map(header => ({source:'app/SourcesShared/CredentialScope.swift', kind:'body', header})),
    { literal: 'func fixtureEstablish(_ next: CredentialScope) -> Capture { lock.lock(); defer { lock.unlock() }; scope = next; generation &+= 1; establishedGeneration = generation; return Capture(scope: scope, generation: generation) }\n' });
  recipe.outputs.push({name:'ActualFileRepairService.swift', parts:[
    {literal:'import Foundation\nimport CryptoKit\n'},
    {source:'app/SourcesShared/VortxAccountFileRepairService.swift', kind:'declaration', header:'enum VortxAccountFileRepairService {'}
  ]});
  const seamPath = 'app/Tests/AccountFileRepairBoundarySeams.swift';
  const seamBytes = fs.readFileSync(path.join(root, seamPath));
  const pieces = seamBytes.toString('utf8').split('    // @@ACTUAL_FILE_REPAIR_MANAGER_BLOCK@@');
  assert.equal(pieces.length, 2, 'missing/duplicate actual-manager insertion point');
  recipe.outputs.push({name:'ActualManagerFileRepair.swift', parts:[
    {literal: pieces[0]},
    {source:'app/SourcesShared/VortXSyncManager.swift', kind:'between',
      start:'    // MARK: - File-only account repair\n',
      end:'    /// DEPRECATED single-state pull: collapses "no backup yet", "network/server failure", and\n'},
    {literal: pieces[1]}
  ]});
  const managerBytes = fs.readFileSync(path.join(root, 'app/SourcesShared/VortXSyncManager.swift'));
  const managerSource = managerBytes.toString('utf8');
  for (const needle of [
    'guard let capture = credentialAuthority.tryBind(scope) else { return nil }\n        retireAccountFileRepairForOwnerTransition()',
    'guard let capture = credentialAuthority.tryBind(scope, certifying: certifying) else { return nil }\n        retireAccountFileRepairForOwnerTransition()'
  ]) assert(managerSource.includes(needle), 'owner transition retirement hook missing');
  const manifest = extract(root, directory);
  manifest.sourceHashes[seamPath] = hash(seamBytes);
  manifest.sourceHashes['test/account-file-repair-service-inputs.cjs'] = hash(fs.readFileSync(__filename));
  // Keep an exact source receipt for the production worker even though this boundary fixture
  // substitutes a hook-bearing actor with the SAME actual service+real-CABI call.
  const service = fs.readFileSync(path.join(root,'app/SourcesShared/VortxAccountFileRepairService.swift'), 'utf8');
  const worker = extractDeclaration(service, 'actor VortxAccountFileRepairWorker {');
  manifest.productionWorkerSHA256 = hash(Buffer.from(worker));
  manifest.scope = 'actual file-service enum and manager operation; real generic converter ABI; explicit synthetic auth/GET and post-worker suspension seams';
  manifest.limitations = [
    'registry establishment is synthetic; actual auth lifecycle/session renewal/HTTP behavior is not certified',
    'production worker body is source-hashed; boundary actor adds one hook after actual service+real-CABI work',
    'no UI/exporter/disk-save/PUT/native-adoption/schema6 proof'
  ];
  fs.writeFileSync(path.join(directory,'inputs.json'), JSON.stringify(manifest,null,2)+'\n');
  return manifest;
}
module.exports = {compose};
if (require.main === module) {
  assert.equal(process.argv.length,4,'usage: node test/account-file-repair-service-inputs.cjs ROOT EXISTING_BUILD_DIRECTORY');
  const manifest = compose(process.argv[2],process.argv[3]);
  process.stdout.write(JSON.stringify({scope:manifest.scope,compilerInputs:manifest.compilerInputs.length})+'\n');
}
