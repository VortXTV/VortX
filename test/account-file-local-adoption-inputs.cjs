#!/usr/bin/env node
'use strict';
// Extract whole production methods unchanged. Every suspension seam is declared in the fixture.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {extractDeclaration}=require('./xperience-harness-inputs.cjs');
const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
function extract(root,directory,f1Baseline=false){
 assert.equal(typeof f1Baseline,'boolean');
 root=fs.realpathSync(root);directory=fs.realpathSync(directory);
 const build=fs.realpathSync(path.join(root,'app/build'));
 const rel=path.relative(build,directory);assert(rel&&!rel.startsWith('..')&&!path.isAbsolute(rel),'output escaped actual app/build');
 const sources=new Map(),declarations=[],compilerInputs=[],generated=[];
 function read(p){if(!sources.has(p))sources.set(p,fs.readFileSync(path.join(root,p)));return sources.get(p).toString('utf8');}
 function select(p,anchor,end){const s=read(p),a=s.indexOf(anchor);assert(a>=0&&s.indexOf(anchor,a+anchor.length)<0,anchor);
  let t;if(end){const b=s.indexOf(end,a+anchor.length);assert(b>a);t=s.slice(a,b);}else t=extractDeclaration(s,anchor);
  assert.equal(s.slice(a,a+t.length),t);declarations.push({source:p,anchor,end,sha256:hash(t),declarationTransformations:[]});return t+'\n';}
 function output(name,t){fs.writeFileSync(path.join(directory,name),t,{flag:'wx'});compilerInputs.push(path.join(directory,name));generated.push({name,sha256:hash(t)});}
 const S='app/SourcesShared/',M=S+'VortXSyncManager.swift',R=S+'VortxAccountFileRestore.swift';
 const wholeFiles=['VortXSyncCrypto.swift','OwnerHistoryExactJSON.swift','SyncDocumentRevisionPolicy.swift','VortxAccountFileRestoreJournal.swift'].map(x=>S+x);
 const frozenExternalInputs={};
 // Sole baseline override: exact immutable V1 journal, never an arbitrary file/ref or body rewrite.
 const baselineJournal='/Users/daksh/VortXTV/_recovery/backup-repair-20261103/restore-local-adoption-proposal/afterimages/app/SourcesShared/VortxAccountFileRestoreJournal.swift';
 const baselineJournalSHA256='553e6266babdfe3b553657a56da3b59d7ebbf2a5a8a403ad62f7a72d2b8ab261';
 for(const p of wholeFiles){
  read(p);
  if(f1Baseline&&p===S+'VortxAccountFileRestoreJournal.swift'){
   const bytes=fs.readFileSync(baselineJournal);
   assert.equal(hash(bytes),baselineJournalSHA256,'immutable F1 V1 journal pin mismatch');
   frozenExternalInputs[baselineJournal]=baselineJournalSHA256;
   output('F1BaselineV1Journal.swift',bytes.toString('utf8'));
   assert.equal(hash(fs.readFileSync(path.join(directory,'F1BaselineV1Journal.swift'))),baselineJournalSHA256,'whole V1 journal bytes transformed');
  }else compilerInputs.push(path.join(root,p));
 }
 output('ActualLocalAdoptionModels.swift','import Foundation\nimport CoreFoundation\nimport CryptoKit\n'+
  select(S+'CredentialScope.swift','enum CredentialScope: Equatable, Hashable, Sendable {')+
  select(S+'VortxNativeSession.swift','struct VortxAccountScope: Codable, Hashable, Sendable {')+
  select(S+'VortxResourceBridge.swift','indirect enum VortxJSON: Codable, Equatable, Sendable {')+
  select(S+'VortxNativeRuntime.swift','enum VortxNativeError: Error, Equatable {')+
  'enum PlaybackMutationOwnershipPolicy {\n'+select(S+'PlaybackMutationOwnershipPolicy.swift','    enum Target: Hashable, Sendable {')+
  select(S+'PlaybackMutationOwnershipPolicy.swift','    struct NativeBinding: Hashable, Sendable {')+'}\ntypealias PlaybackMutationTarget=PlaybackMutationOwnershipPolicy.Target\n'+
  'final class CredentialScopeRegistry: @unchecked Sendable {\nstatic let shared=CredentialScopeRegistry()\nprivate let lock=NSLock()\nprivate var scope: CredentialScope\nprivate var generation: UInt64\nprivate var establishedGeneration: UInt64?\n'+
  select(S+'CredentialScope.swift','    struct Capture: Equatable, Hashable, Sendable {')+
  ['    init(initialScope: CredentialScope = .signedOutDevice) {','    func capture() -> Capture {','    func isCurrent(_ capture: Capture) -> Bool {','    func isMigrationEligible(_ capture: Capture) -> Bool {'].map(a=>select(S+'CredentialScope.swift',a)).join('')+
  'func establish(_ scope: CredentialScope) { lock.lock(); defer {lock.unlock()}; self.scope=scope; generation &+= 1; establishedGeneration=generation }\n}\n'+
  'enum VortxAccountFileRepairService {\nstatic let lifetimeNanoseconds: UInt64=300_000_000_000\nenum Failure: Error {case expired,accountChanged}\n'+
  select(S+'VortxAccountFileRepairService.swift','    final class Fence: @unchecked Sendable {')+
  select(S+'VortxAccountFileRepairService.swift','    static func digest(_ bytes: Data) -> String {')+'}\n'+
  select(R,'enum VortxAccountFileRestoreFailure: String, Error, Sendable, LocalizedError {')+
  select(R,'enum VortxAccountFileRestoreStatus: Sendable {')+select(R,'enum VortxAccountFileRestoreLocalResult: Sendable {')+
  'enum VortxAccountFileRestore {\n'+['    struct Intent: Codable, Sendable {','    enum Verdict: String, Codable, Sendable {','    struct Receipt: Codable, Sendable {','    enum LocalState: String, Sendable {','    enum LocalPendingReason: Equatable, Sendable {', '    struct OperationStatus: Sendable, Equatable {','    struct LocalAdoption: Codable, Sendable {','    static func hasUnacknowledgedProviderCarrier(_ plaintext: Data) -> Bool {', '    static func digest(_ data: Data) -> String {'].map(a=>select(R,a)).join('')+'}\n'+
  select(S+'AddonReorderMove.swift','enum AddonSyncPullPolicy {')+
  'enum NativeForegroundSyncPolicy {\n'+select(S+'NativeForegroundSyncPolicy.swift','    @MainActor\n    static func mayAcknowledgeDocument(')+'}\n');
 const managerBlock=select(M,'    // MARK: - Historical completion of a selected-file restore\n','    // MARK: - Dedicated encrypted account file restore\n');
 const sync=select(M,'    @discardableResult\n    func syncDown(force: Bool = false,');
 // Enforce the real tail and negative paths at source level, then execute the WHOLE method below.
 assert.equal((read(M).match(/return CompletedFileRestoreReceive\(/g)||[]).length,1,'witness has another producer');
 assert.equal((read(M).match(/if let completed = completedFileRestoreReceive\(/g)||[]).length,1,'completion hook has another caller');
 assert(sync.indexOf('completedFileRestoreReceive(')>sync.indexOf('CoreBridge.shared.rebuildContinueWatching()'));
 assert(sync.indexOf('completedFileRestoreReceive(')>sync.indexOf('mayAcknowledgeDocument('));
 assert(sync.indexOf('completedFileRestoreReceive(')>sync.indexOf('pendingProviderApply = nil'));
 assert(!managerBlock.includes('syncDown(force: true'),'Finish weakened force gate');
 assert(!managerBlock.includes('accountFileRestoreOperation ='),'Finish captured restore lock');
 assert(!managerBlock.includes('"PUT"'),'Finish can upload');
 let seam=read('app/Tests/AccountFileLocalAdoptionSeams.swift');
 const actual=managerBlock+select(M,'    private enum VersionedPull {')+select(M,'    private struct NativeReceiveReceipt {')+
  select(M,'    private func conditionalReceiveVersion(')+select(M,'    private func rememberCompletedNativeReceive(')+
  ['    private struct PendingDebridApply:','    private enum ProviderApplyService:','    private enum ProviderApplyValue:','    private struct PendingProviderApply:'].map(a=>select(M,a)).join('')+sync;
 assert.equal(seam.split('// @@ACTUAL_LOCAL_ADOPTION_MANAGER@@').length,2);
 seam=seam.replace('// @@ACTUAL_LOCAL_ADOPTION_MANAGER@@',actual);
 output('ActualLocalAdoptionWithSyntheticNativeProviders.swift',seam);
 read('test/account-file-local-adoption-inputs.cjs');read('test/xperience-harness-inputs.cjs');
 const manifest={wholeFiles,compilerInputs,generated,declarations,f1Baseline,frozenExternalInputs,
  journalSelection:f1Baseline?{kind:'exact-immutable-v1-for-F1-negative-control',path:baselineJournal,sha256:baselineJournalSHA256}:{kind:'actual-current-source',path:S+'VortxAccountFileRestoreJournal.swift'},
  sourceHashes:Object.fromEntries([...sources].map(([p,b])=>[p,hash(b)])),
  scope:'whole unchanged syncDown, exact-source completion finalizer, status and Finish APIs, real purpose-sealed journal; synthetic HTTP/native/provider collaborators',
  limitations:['NOT real native kernel/durable native commit/provider proof; retain separate actual C ABI admission/journal and native durability gates','No network/server/account/installed data. Synthetic GET observation is explicitly transport fixture provenance only.','No SDK/app/device proof. No fixture executed by author.']};
 fs.writeFileSync(path.join(directory,'inputs.json'),JSON.stringify(manifest,null,2)+'\n',{flag:'wx'});return manifest;
}
module.exports={extract};
if(require.main===module){assert(process.argv.length===4||(process.argv.length===5&&process.argv[4]==='--f1-v1-journal'),'only the named fixed F1 baseline is permitted');process.stdout.write(JSON.stringify(extract(process.argv[2],process.argv[3],process.argv.length===5))+'\n');}
