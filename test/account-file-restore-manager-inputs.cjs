#!/usr/bin/env node
'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {extractDeclaration}=require('./xperience-harness-inputs.cjs');
const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
function extract(root,directory){
 root=fs.realpathSync(root);directory=fs.realpathSync(directory);
 const build=fs.realpathSync(path.join(root,'app/build'));
 function descendant(child,parent){const relative=path.relative(parent,child);return relative&&relative!=='..'&&!relative.startsWith('..'+path.sep)&&!path.isAbsolute(relative);}
 assert(descendant(build,root)&&descendant(directory,build),'fixture output escaped actual app/build');
 const sources=new Map(),declarations=[],generated=[],compilerInputs=[];
 function read(relative){
  assert(/^(app\/(SourcesShared|Tests)|test)\/[A-Za-z0-9_.-]+$/.test(relative),'unexpected source path');
  if(!sources.has(relative))sources.set(relative,fs.readFileSync(path.join(root,relative)));
  return sources.get(relative).toString('utf8');
 }
 function unique(source,anchor){const begin=source.indexOf(anchor);assert(begin>=0&&source.indexOf(anchor,begin+anchor.length)<0,'missing/ambiguous actual-source anchor: '+anchor);return begin;}
 function select(sourcePath,header,kind='declaration',end){
  const source=read(sourcePath),begin=unique(source,header);let text;
  if(kind==='between'){const stop=unique(source,end);assert(stop>begin);text=source.slice(begin,stop);}
  else if(kind==='body'){
   assert(header.endsWith('{'));const at=begin+header.length-1,marker='@@restore-manager-production-body@@';assert(!source.includes(marker));
   text=source.slice(begin,at)+extractDeclaration(marker+source.slice(at),marker).slice(marker.length);
  }else text=extractDeclaration(source,header);
  assert.equal(source.slice(begin,begin+text.length),text,'production source transformed');
  assert(/^(?:\s|$)/.test(source.slice(begin+text.length,begin+text.length+1)),'declaration ended inside a token');
  declarations.push({source:sourcePath,header,kind,end,startLine:source.slice(0,begin).split('\n').length,sha256:hash(Buffer.from(text)),declarationTransformations:[]});
  return text+'\n';
 }
 function output(name,text){const destination=path.join(directory,name);fs.writeFileSync(destination,text,{flag:'wx'});compilerInputs.push(destination);generated.push({name,sha256:hash(Buffer.from(text))});}
 const shared='app/SourcesShared/';
 const wholeFiles=['VortXSyncCrypto.swift','VortxAccountBackupFile.swift','OwnerHistoryExactJSON.swift','SyncDocumentRevisionPolicy.swift'].map(x=>shared+x)
   .concat(['app/Tests/VortxAccountFileRestoreManagerTests.swift']);
 for(const file of wholeFiles){read(file);compilerInputs.push(path.join(root,file));}
 output('ActualRestoreModels.swift','import Foundation\nimport CoreFoundation\nimport CryptoKit\n'+
  select(shared+'CredentialScope.swift','enum CredentialDurableReadResult: Equatable, Sendable {')+
  select(shared+'CredentialScope.swift','enum CredentialScope: Equatable, Hashable, Sendable {')+
  select(shared+'VortxResourceBridge.swift','indirect enum VortxJSON: Codable, Equatable, Sendable {')+
  select(shared+'VortxNativeRuntime.swift','enum VortxNativeError: Error, Equatable {')+
  select(shared+'VortxNativeSession.swift','struct VortxAccountScope: Codable, Hashable, Sendable {')+
  select(shared+'AuthenticatedHTTPTransport.swift','struct AuthenticatedHTTPResponse: Sendable {')+
  'final class CredentialScopeRegistry: @unchecked Sendable {\nstatic let shared=CredentialScopeRegistry()\nprivate let lock=NSLock()\nprivate var scope: CredentialScope\nprivate var generation: UInt64\nprivate var establishedGeneration: UInt64?\n'+
  select(shared+'CredentialScope.swift','    struct Capture: Equatable, Hashable, Sendable {')+
  ['    init(initialScope: CredentialScope = .signedOutDevice) {','    func capture() -> Capture {','    func isCurrent(_ capture: Capture) -> Bool {','    func isMigrationEligible(_ capture: Capture) -> Bool {'].map(header=>select(shared+'CredentialScope.swift',header,'body')).join('\n')+
  'func fixtureEstablish(_ next: CredentialScope) -> Capture { lock.lock(); defer { lock.unlock() }; scope=next; generation &+= 1; establishedGeneration=generation; return Capture(scope:scope,generation:generation) }\nfunc fixtureRevokeAuthentication(){lock.lock();defer{lock.unlock()};establishedGeneration=nil}\n}\n');
 output('ActualRestoreArchive.swift','import Foundation\nimport CoreFoundation\n'+select(shared+'VortxNativeBootstrapArchive.swift','enum VortxNativeBootstrapArchive {'));
 output('ActualRestoreFence.swift','import Foundation\nimport CryptoKit\nenum VortxAccountBackupRepair {\n'+
  select(shared+'VortxAccountBackupRepair.swift','    enum Failure: String, Error, Sendable {')+'}\nenum VortxAccountFileRepairService {\n'+
  select(shared+'VortxAccountFileRepairService.swift','    static let lifetimeNanoseconds:','between','    enum Failure:')+
  select(shared+'VortxAccountFileRepairService.swift','    enum Failure: Error, Sendable, LocalizedError {')+
  select(shared+'VortxAccountFileRepairService.swift','    struct Input: Sendable {')+
  select(shared+'VortxAccountFileRepairService.swift','    final class Fence: @unchecked Sendable {')+
  select(shared+'VortxAccountFileRepairService.swift','    static func digest(_ bytes: Data) -> String {','body')+'}\n');
 output('ActualRestoreValues.swift','import Foundation\nimport CryptoKit\n'+
  select(shared+'VortxAccountFileRestore.swift','enum VortxAccountFileRestoreFailure: String, Error, Sendable, LocalizedError {')+
  select(shared+'VortxAccountFileRestore.swift','enum VortxAccountFileRestoreResult: Sendable {')+
  'enum VortxAccountFileRestore {\n typealias Exact=OwnerHistoryExactJSON\n'+
  ['    struct Prepared: Sendable {','    struct Intent: Codable, Sendable {',
   '    enum Verdict: String, Codable, Sendable {','    struct Receipt: Codable, Sendable {']
   .map(header=>select(shared+'VortxAccountFileRestore.swift',header)).join('\n')+
  ['    static func digest(_ data: Data) -> String {','    static func head(_ response: Data) throws -> VortxAccountBackupFile.Inspection {',
   '    static func acceptedVerdict(status: Int, body: Data) -> Bool? {','    static func confirms(_ response: Data, intent: Intent, key: Data) -> Bool {']
   .map(header=>select(shared+'VortxAccountFileRestore.swift',header,'body')).join('\n')+'}\n');
 let seam=read('app/Tests/AccountFileRestoreManagerSeams.swift');
 const block=select(shared+'VortXSyncManager.swift','    // MARK: - Dedicated encrypted account file restore\n','between',
  '    /// DEPRECATED single-state pull: collapses "no backup yet", "network/server failure", and\n');
 const manager=read(shared+'VortXSyncManager.swift');
 // Source-bound integration obligations beyond the extracted block. These assertions are NOT a
 // claim that this fixture executes normal sync/mount paths; the separate tests cover those paths.
 assert(manager.includes('guard !accountFileRestoreBusy, isCurrent(capture), nativeCheckpointGeneration == generation else {'),'post-drain checkpoint gate missing');
 assert(manager.includes('guard !accountFileRestoreBusy else { return false }\n        activeSyncUp = (operationID, capture)'),'post-await sync-up gate missing');
 for(const marker of ['    // @@ACTUAL_RESTORE_MANAGER_BLOCK@@','    // @@ACTUAL_HTTP_LIMITS@@'])assert.equal(seam.split(marker).length,2,'seam placeholder missing/duplicate');
 seam=seam.replace('    // @@ACTUAL_RESTORE_MANAGER_BLOCK@@',block);
 const limits=select(shared+'AuthenticatedHTTPTransport.swift','    static let controlResponseLimit = ','between','\n    private let protocolClasses:');
 seam=seam.replace('    // @@ACTUAL_HTTP_LIMITS@@',limits);
 output('ActualRestoreManagerWithSyntheticCollaborators.swift',seam);
 read('test/xperience-harness-inputs.cjs');read('test/account-file-restore-manager-inputs.cjs');
 const manifest={scope:'unchanged production restore manager block; real capture/fence, exact framing/crypto/verdict/readback; explicit synthetic transport/prep/absence/journal suspension seams',wholeFiles,
  sourceHashes:Object.fromEntries([...sources].map(([name,bytes])=>[name,hash(bytes)])),declarations,generated,compilerInputs,
  productionManagerBlockSHA256:hash(Buffer.from(block.slice(0,-1))),
  limitations:['no native SDK linked; no candidate admission or native inventory/filesystem proof',
   'synthetic journal persistence models orchestration only; real encrypted journal has its separate actual-source ABI fixture',
   'no actual auth/session-renewal transport/UI/local-adoption proof; provider/keychain reads are explicit seam values',
   'normal checkpoint/sync entry gates are source asserted; whole normal methods are not executed here']};
 fs.writeFileSync(path.join(directory,'inputs.json'),JSON.stringify(manifest,null,2)+'\n',{flag:'wx'});return manifest;
}
module.exports={extract};
if(require.main===module){assert.equal(process.argv.length,4,'usage: node test/account-file-restore-manager-inputs.cjs ROOT EXISTING_BUILD_DIRECTORY');const inputs=extract(process.argv[2],process.argv[3]);process.stdout.write(JSON.stringify({scope:inputs.scope,compilerInputs:inputs.compilerInputs.length})+'\n');}
