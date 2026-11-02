#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const {recipe, extract} = require('./account-backup-repair-inputs.cjs');
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
// Reused by the pre-existing service harness: exact same admission declarations, no alternate checker.
function addAdmission(recipe) {
  const parser = recipe.outputs.find(x => x.name === 'ActualAccountRawParser.swift');
  assert(parser);
  parser.parts = [{literal:'import Foundation\nimport CoreFoundation\n'},
    {source:'app/SourcesShared/VortxNativeBootstrapArchive.swift',kind:'declaration',header:'enum VortxNativeBootstrapArchive {'}];
  const cold = recipe.outputs.find(x => x.name === 'ActualColdSession.swift');
  assert(cold && cold.parts.at(-1).literal === '}\n');
  cold.parts.splice(cold.parts.length-1,0,{source:'app/SourcesShared/VortxNativeSession.swift',kind:'body',
    header:'    nonisolated static func detachedFileRestoreState(scope: VortxAccountScope,\n        nativeSync: VortxJSON, abi: any VortxRuntimeABI) throws -> VortxJSON {'});
  recipe.outputs.push({name:'ActualRestoreAdmission.swift',parts:[
    {literal:'import Foundation\nimport CryptoKit\n'},
    {source:'app/SourcesShared/VortxAccountFileRestore.swift',kind:'between',
      start:'enum VortxAccountFileRestoreFailure:',end:'\nactor VortxAccountFileRestoreWorker {'}
  ]});
}
function compose(root,directory) {
  root=fs.realpathSync(root);directory=fs.realpathSync(directory);
  const oldMain='app/Tests/VortxAccountBackupRepairTests.swift';
  assert.equal(recipe.wholeFiles.filter(x=>x===oldMain).length,1);
  recipe.wholeFiles=recipe.wholeFiles.filter(x=>x!==oldMain);
  recipe.wholeFiles.push('app/Tests/VortxAccountFileRestoreAdmissionTests.swift',
    'app/SourcesShared/SyncDocumentRevisionPolicy.swift','app/SourcesShared/VortxAccountFileRestoreJournal.swift');
  const model=recipe.outputs.find(x=>x.name==='ActualModels.swift');
  assert(model && model.parts.at(-1).literal==='}\n');
  model.parts.splice(model.parts.length-1,0,
    {literal:'static let shared = CredentialScopeRegistry()\nprivate let lock = NSLock()\nprivate var scope: CredentialScope\nprivate var generation: UInt64\nprivate var establishedGeneration: UInt64?\n'},
    ...['    init(initialScope: CredentialScope = .signedOutDevice) {','    func capture() -> Capture {',
      '    func isCurrent(_ capture: Capture) -> Bool {','    func isMigrationEligible(_ capture: Capture) -> Bool {']
      .map(header=>({source:'app/SourcesShared/CredentialScope.swift',kind:'body',header})),
    {literal:'func fixtureEstablish(_ next: CredentialScope) -> Capture { lock.lock(); defer { lock.unlock() }; scope=next; generation &+= 1; establishedGeneration=generation; return Capture(scope:scope,generation:generation) }\n'});
  recipe.outputs.push({name:'ActualFileRepairService.swift',parts:[{literal:'import Foundation\nimport CryptoKit\n'},
    {source:'app/SourcesShared/VortxAccountFileRepairService.swift',kind:'declaration',header:'enum VortxAccountFileRepairService {'}]});
  recipe.outputs.push({name:'ActualStorageAndLimits.swift',parts:[{literal:'import Foundation\n'},
    {source:'app/SourcesShared/VortxNativeSession.swift',kind:'declaration',header:'enum VortxNativeStorage {'},
    {literal:'enum AuthenticatedHTTPTransport {\n'},
    {source:'app/SourcesShared/AuthenticatedHTTPTransport.swift',kind:'between',
      start:'    static let controlResponseLimit = ',end:'\n    private let protocolClasses:'},
    {literal:'}\n'}]});
  addAdmission(recipe);
  // The journal accepts a concrete manager-minted evidence type. This existing C ABI suite does
  // not mint it; add its exact declaration rather than an alternate constructible protocol/model.
  recipe.outputs.push({name:'ActualLocalAdoptionEvidence.swift',parts:[{literal:'import Foundation\n'},
    {literal:'enum PlaybackMutationOwnershipPolicy {\n'},
    {source:'app/SourcesShared/PlaybackMutationOwnershipPolicy.swift',kind:'declaration',header:'    enum Target: Hashable, Sendable {'},
    {source:'app/SourcesShared/PlaybackMutationOwnershipPolicy.swift',kind:'declaration',header:'    struct NativeBinding: Hashable, Sendable {'},
    {literal:'}\ntypealias PlaybackMutationTarget=PlaybackMutationOwnershipPolicy.Target\nenum VortXSyncManager {\n'},
    {source:'app/SourcesShared/VortXSyncManager.swift',kind:'declaration',header:'    struct CompletedFileRestoreReceive: Sendable {'},
    {literal:'}\n'}]});
  const manifest=extract(root,directory);
  for(const relative of ['test/account-file-restore-inputs.cjs','app/SourcesShared/VortXSyncManager.swift',
    'app/SourcesShared/NativePreferenceIntentStore.swift']) manifest.sourceHashes[relative]=hash(fs.readFileSync(path.join(root,relative)));
  manifest.scope='actual file admission, source-conserving repair/reimport, one cold generic validator and encrypted journal; real linked native ABI';
  manifest.limitations=['manager CAS/await interleaving and scoped native inventory are not executed by this fixture',
    'no live HTTP/token/keychain/UI/profile-adoption/schema6 proof; registry establishment and journal root are explicit synthetic seams',
    'tagged owner/shared-child Repair-to-Restore positive requires separately reviewed archive display-role fix'];
  fs.writeFileSync(path.join(directory,'inputs.json'),JSON.stringify(manifest,null,2)+'\n');
  return manifest;
}
module.exports={addAdmission,compose};
if(require.main===module){
  assert.equal(process.argv.length,4,'usage: node test/account-file-restore-inputs.cjs ROOT EXISTING_BUILD_DIRECTORY');
  const manifest=compose(process.argv[2],process.argv[3]);
  process.stdout.write(JSON.stringify({scope:manifest.scope,compilerInputs:manifest.compilerInputs.length})+'\n');
}
