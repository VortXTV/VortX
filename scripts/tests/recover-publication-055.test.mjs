import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {PIN,ASSETS,validateRelease,validateReceipt,commitSource,compensateSource,releasePatchBody,remainingBudget} from '../recover-publication-055.mjs';

function fake({lostAck=false,lostRead=false,foreign=false,rejected=false}={}){
  let head=PIN.main, serial=0,armed=null,writes=[],failRead=false;
  const api=(path,body)=>{
    if(path==='git/ref/heads/main') {if(failRead){failRead=false;throw new Error('lost read');}return {object:{sha:head}};}
    if(path.startsWith('git/commits/'))return {tree:{sha:'tree'}};
    if(path==='git/blobs')return {sha:'blob'};
    if(path==='git/trees')return {sha:'tree'};
    if(path==='git/commits')return {sha:`candidate-${++serial}`};
    if(path==='git/refs/heads/main'){
      assert.equal(armed!==null,true,'write must already be armed');assert.equal(body.force,false);writes.push(body.sha);
      if(rejected){rejected=false;throw new Error('ref refused');}
      head=foreign?'third-party-head':body.sha;
      if(lostAck){lostAck=false;throw new Error('lost ACK');}
      if(lostRead){lostRead=false;failRead=true;}
      return {};
    }
    if(path.startsWith('contents/altstore/source.json?ref='))return {content:Buffer.from('old').toString('base64')};
    throw new Error(`unexpected ${path}`);
  };
  return {api,arm:x=>{armed=x;},get head(){return head;},get candidate(){return armed;},writes};
}
test('successful source update is armed before a nonforce write',()=>{const f=fake();assert.equal(commitSource('new',PIN.main,'test',f.arm,f.api),'candidate-1');assert.equal(f.candidate,'candidate-1');});
test('lost PATCH acknowledgement reconciles the exact intended commit',()=>{const f=fake({lostAck:true});assert.equal(commitSource('new',PIN.main,'test',f.arm,f.api),'candidate-1');});
test('failed post-PATCH read still leaves the candidate armed for real compensation',()=>{const f=fake({lostRead:true});assert.throws(()=>commitSource('new',PIN.main,'test',f.arm,f.api),/lost read/);assert.equal(f.candidate,f.head);compensateSource('old',PIN.main,f.candidate,f.api);assert.equal(f.head,'candidate-2');});
test('rejected PATCH does not overwrite the unchanged original during compensation',()=>{const f=fake({rejected:true});assert.throws(()=>commitSource('new',PIN.main,'test',f.arm,f.api));compensateSource('old',PIN.main,f.candidate,f.api);assert.equal(f.head,PIN.main);assert.equal(f.writes.length,1);});
test('third-party head is never overwritten on uncertain write or compensation',()=>{const f=fake({foreign:true});assert.throws(()=>commitSource('new',PIN.main,'test',f.arm,f.api),/result differs/);assert.throws(()=>compensateSource('old',PIN.main,f.candidate,f.api),/no longer ours/);assert.equal(f.writes.length,1);});
test('request budget stops mutation before the reserved compensation window',()=>{
  assert.equal(remainingBudget(10000,2000,25000),8000);assert.equal(remainingBudget(10000,2000,1000),1000);
  assert.throws(()=>remainingBudget(10000,10000,1000),/deadline/);assert.throws(()=>remainingBudget(10000,10001,1000),/deadline/);
});
test('every release mutation retains an explicit tag and GitHub string-valued Latest mode',()=>{
  for(const body of [{draft:false,make_latest:'false'},{make_latest:'true'},{draft:true}])assert.equal(releasePatchBody(body).tag_name,PIN.tag);
  assert.equal(releasePatchBody({make_latest:'true'},'v0.5.4').tag_name,'v0.5.4');
  assert.throws(()=>releasePatchBody({},'foreign'));
  const code=readFileSync(new URL('../recover-publication-055.mjs',import.meta.url),'utf8');
  for(const line of code.split('\n').filter(x=>x.includes('gh(`releases/')&&x.includes("'PATCH'")))assert(line.includes('releasePatchBody('));
});
test('exact ten assets and immutable release state reject mutations',()=>{
  const plan=JSON.parse(readFileSync(new URL('../../.github/release055/publication-plan.json',import.meta.url)));
  const r={id:PIN.release,tag_name:PIN.tag,draft:true,prerelease:false,body:plan.notes,assets:Object.entries(ASSETS).map(([name,[size,sha]])=>({name,size,digest:`sha256:${sha}`,state:'uploaded',id:plan.assets[name]}))};
  validateRelease(r,true,plan.assets);validateReceipt(plan.receipt);
  for(const mutate of [x=>x.id++,x=>x.draft=false,x=>x.prerelease=true,x=>x.body+='drift',x=>x.assets.pop(),x=>x.assets[0].id++,x=>x.assets[0].digest='sha256:'+'0'.repeat(64)]){const x=structuredClone(r);mutate(x);assert.throws(()=>validateRelease(x,true,plan.assets));}
  for(const mutate of [x=>x.manifest.sourceCommit='0'.repeat(40),x=>x.source+=' ',x=>x.manifest.assets.ios.sha256='0'.repeat(64),x=>x.manifest.generation+='x',x=>x.manifest.android={}]){const x=structuredClone(plan.receipt);mutate(x);assert.throws(()=>validateReceipt(x));}
});
test('publication-only wrapper binds reviewed bytes, protection, and no build/checkout',()=>{
  const workflow=readFileSync(new URL('../../.github/workflows/release-tvos.yml',import.meta.url),'utf8');
  const job=workflow.split('  publish-existing-055:\n')[1].split(/\n  [A-Za-z][A-Za-z0-9_-]*:\n/)[0];
  assert.match(job,/environment: release-approval/);assert.match(job,/github\.ref == 'refs\/tags\/v0\.5\.5-publication\.1'/);
  assert.match(job,/contents: write/);assert.doesNotMatch(job,/uses: actions\/checkout|xcodebuild|gradlew/);
  const {createHash}=globalThis.process.getBuiltinModule('node:crypto');
  for(const [name,relative] of [['coordinator','../recover-publication-055.mjs'],['plan','../../.github/release055/publication-plan.json']]){
    const sha=createHash('sha256').update(readFileSync(new URL(relative,import.meta.url))).digest('hex');assert(job.includes(sha),`${name} byte pin missing`);
  }
  assert.match(workflow,/if: github\.event_name != 'release' && inputs\.resume_handoff == '' && inputs\.publish_existing_055 != true/);
  const exact=span=>span.split('  attach-release:\n')[1].split(/\n  [A-Za-z][A-Za-z0-9_-]*:\n/)[0];
  assert.doesNotMatch(exact(workflow),/actions\/checkout/);
  assert.match(exact(workflow.replace('  attach-release:\n','  attach-release:\n      - uses: actions/checkout@evil\n')),/actions\/checkout/);
});
