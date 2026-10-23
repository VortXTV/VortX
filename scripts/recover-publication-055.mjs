#!/usr/bin/env node
// One release only. Reuses independently accepted CI bytes; never builds or signs an app.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash, createHmac } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

export const PIN = Object.freeze({
  repo: 'VortXTV/VortX', tag: 'v0.5.5', release: 415681390,
  source: '35761135a71867d23a9c4ee83cbdb31fe65747bd',
  tagObject: 'c89a4a24326a8683910afc28b569ca783cfcad7a',
  main: '7b3d0d7204f423fe0dd7119d14e80e561c838c6b',
  appleRun: 38966779038, androidRun: 38966783085,
  appleArtifact: 12079715882,
  artifactSha: '7b6e2965eceacdf353325cf31484d1fd44bd0d81b859944f2469d5ff24df5b7a',
  feedHelper: 'a300d6d785523cedcf7cda0a4d6a4c1b545440605b5c0154c4ef59628bc4d36a',
  notes: '12256859071830b0b1352f74fbafdd606d93c0c81145b91c260ef416ee35a4f7',
});
export const ASSETS = Object.freeze({
  'VortX-iOS-v0.5.5-ci.ipa': [52081677, '251d758ddca153760d1fc1d18e3332318a3a32de3a1435a88c63dfa88b883faf'],
  'VortX-tvOS-v0.5.5-ci.ipa': [50690612, '7c3a8e37fa5a22d0cf8218afef0a8ea3205d6ced40dfa7aa949dfc463b1edd6b'],
  'VortX-tvOS-lite-v0.5.5-ci.ipa': [50441886, 'e4365ed0bcd453dd3f774a48195729bec170000e7ef9bb8ca62c4885d1403ce8'],
  'VortX-macOS-v0.5.5-ci.dmg': [65244070, '05dc06cea0baac9b4c2e435b5e1f67b3333b752d0d2a17515d806e27769ad795'],
  'VortX-0.5.5-full-mpv-universal.apk': [156009286, 'b61a02a8da6dfd2aa24cb56e0f17c8b73a24605fac8583538437f873f5e73a69'],
  'VortX-0.5.5-play-media3-universal.apk': [77116459, 'e630a09fe3d91fcb2e5c280a7813aebf085df9ef4cb556fe049dabb34d77b7cb'],
  'VortX-0.5.5-play-media3.aab': [50499787, '617df98e6033de3158d351ccb150bd7f9e9e7880713eae111db4348e4488d73f'],
  'SHA256SUMS-ci.txt': [369, 'd3776f1ea139ebcb69c86c749dbca4cdc348f485eec300c851886d9d4c8861cf'],
  'SHA256SUMS-android.txt': [299, '4e52b495a783289b14d3bb8580702ebf16ef3aaceeb2897fb6da8a00b83eb2a5'],
  'SIGNING_PROVENANCE.txt': [4198, 'e42939673bec0dff481c5b885d228f3c285978bf033497525e31b6c60d3dafc7'],
});
export function insist(ok, message) { if (!ok) throw new Error(message); }
export function hash(bytes) { return createHash('sha256').update(bytes).digest('hex'); }
let ioDeadline = Infinity;
export function remainingBudget(deadline,now,maximum) {
  const left=deadline-now; insist(left>0,'publication deadline reached; reserved compensation begins');
  return Math.min(left,maximum);
}
function budget(maximum) {return remainingBudget(ioDeadline,Date.now(),maximum);}
export function releasePatchBody(body,tag=PIN.tag) {
  insist(tag===PIN.tag||tag==='v0.5.4','unexpected release patch tag');
  return {...body,tag_name:tag}; // GitHub may assign an untagged draft if the tag is omitted.
}
export function validateRelease(r, draft, expectedAssets) {
  insist(r.id === PIN.release && r.tag_name === PIN.tag && r.draft === draft && r.prerelease === false, 'release identity/state changed');
  insist(hash(r.body) === PIN.notes, 'release notes changed');
  insist(r.assets.length === Object.keys(ASSETS).length, 'unexpected release asset count');
  for (const [name, [size, sha]] of Object.entries(ASSETS)) {
    const all = r.assets.filter(a => a.name === name);
    insist(all.length === 1 && all[0].state === 'uploaded' && all[0].size === size && all[0].digest === `sha256:${sha}`, `asset identity changed: ${name}`);
    if (expectedAssets) insist(all[0].id === expectedAssets[name], `asset ID changed: ${name}`);
  }
}
function gh(path, body, method) {
  const args = ['api', `repos/${PIN.repo}/${path}`];
  if (body !== undefined) args.push('--method', method || 'POST', '--input', '-');
  return JSON.parse(execFileSync('gh', args, { input: body === undefined ? undefined : JSON.stringify(body), encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, timeout:budget(25000) }));
}
async function publicBody(url) {
  const r = await fetch(url, { signal: AbortSignal.timeout(budget(30000)), cache: 'no-store' });
  insist(r.ok, `public request failed: ${r.status} ${url}`);
  return { text: await r.text(), generation: r.headers.get('x-vortx-feed-generation'), headers: Object.fromEntries(r.headers) };
}
async function snapshot() {
  const out = {};
  for (const name of ['altstore.json', 'vortx-altstore.json', 'appcast.json']) out[name] = await publicBody(`https://vortx.tv/${name}`);
  insist(out['altstore.json'].generation && Object.values(out).every(x => x.generation === out['altstore.json'].generation), 'feed generation disagrees');
  insist(out['altstore.json'].text === out['vortx-altstore.json'].text, 'compatibility route differs');
  return out;
}
function sourceAt(ref) {
  const r = gh(`contents/altstore/source.json?ref=${ref}`);
  return { text: Buffer.from(r.content, 'base64').toString(), blob: r.sha };
}
async function identities() {
  const t = gh(`git/ref/tags/${PIN.tag}`);
  insist(t.object.type === 'tag' && t.object.sha === PIN.tagObject, 'final tag object changed');
  insist(gh(`git/tags/${PIN.tagObject}`).object.sha === PIN.source, 'final tag target changed');
  const rc = gh('git/ref/tags/v0.5.5-rc.1');
  insist(rc.object.type === 'commit' && rc.object.sha === PIN.source, 'original RC tag changed');
  for (const id of [PIN.appleRun, PIN.androidRun]) {
    for(const path of [`actions/runs/${id}`,`actions/runs/${id}/attempts/1`]) {
      const r = gh(path), workflow = id===PIN.appleRun?'release-tvos.yml':'android-release.yml';
      insist(r.id === id && r.head_sha === PIN.source && r.head_branch === 'v0.5.5-rc.1' && r.event === 'workflow_dispatch' && r.status === 'completed' && r.conclusion === 'success' && r.run_attempt === 1 && r.repository.full_name===PIN.repo && r.head_repository.full_name===PIN.repo && r.path===`.github/workflows/${workflow}`, 'original/latest CI identity failed');
    }
  }
  const a = gh(`actions/artifacts/${PIN.appleArtifact}`);
  insist(!a.expired && a.name === 'VortX-tvOS-ci' && a.digest === `sha256:${PIN.artifactSha}` && a.workflow_run.id === PIN.appleRun && a.workflow_run.head_sha === PIN.source, 'immutable Apple artifact changed');
}
export function validateReceipt(receipt) {
  const m = receipt.manifest;
  insist(receipt.schemaVersion === 2 && receipt.action === 'stage' && m.schemaVersion === 2 && m.tag === PIN.tag && m.sourceCommit === PIN.source && String(m.releaseId) === String(PIN.release) && m.build === 274 && m.prerelease === false && m.android === null, 'wrong staged identity');
  for (const [key, name] of [['ios','VortX-iOS-v0.5.5-ci.ipa'],['tvos','VortX-tvOS-v0.5.5-ci.ipa'],['tvosLite','VortX-tvOS-lite-v0.5.5-ci.ipa'],['mac','VortX-macOS-v0.5.5-ci.dmg']]) {
    const a = m.assets[key], [size, sha] = ASSETS[name];
    insist(a.name === name && a.size === size && a.sha256 === sha && a.state === 'uploaded' && Number.isSafeInteger(a.assetId) && a.assetId > 0 && a.url === `https://github.com/${PIN.repo}/releases/download/${PIN.tag}/${name}`, `wrong staged asset ${key}`);
  }
  insist(m.sourceSha256 === hash(receipt.source) && m.appcastSha256 === hash(receipt.appcast) && m.checksumSha256 === hash(receipt.checksum), 'feed file hash mismatch');
  const digest = hash(`${receipt.source}\n${receipt.appcast}\n${receipt.checksum}`);
  insist(m.feedSha256 === digest && m.generation === `${PIN.tag}:274:${digest}`, 'feed generation mismatch');
}
async function prepare(root, upload, out) {
  await identities();
  const r = gh(`releases/${PIN.release}`); validateRelease(r, true);
  insist(gh('git/ref/heads/main').object.sha === PIN.main, 'main moved before preparation');
  const previous = sourceAt(PIN.main), before = await snapshot();
  insist(previous.text === before['altstore.json'].text, 'main source and live source differ');
  const latest = gh('releases/latest'); insist(latest.tag_name === 'v0.5.4', 'Latest moved before preparation');
  insist(hash(readFileSync(join(root,'scripts/release-feed.mjs'))) === PIN.feedHelper, 'feed builder differs from frozen source');
  for (const [name, [size, sha]] of Object.entries(ASSETS)) {
    const body = readFileSync(join(upload,name)); insist(body.length === size && hash(body) === sha, `local package changed: ${name}`);
  }
  mkdirSync(out, { recursive: true }); writeFileSync(join(out,'previous-source.json'), previous.text);
  const { buildReleaseFeedArtifact } = await import(pathToFileURL(join(root,'scripts/release-feed.mjs')));
  const built = buildReleaseFeedArtifact({ tag: PIN.tag, build: 274, sourceCommit: PIN.source, sourceTemplate: join(out,'previous-source.json'), output: join(out,'feed'),
    iosFile:join(upload,'VortX-iOS-v0.5.5-ci.ipa'),tvosFile:join(upload,'VortX-tvOS-v0.5.5-ci.ipa'),tvosLiteFile:join(upload,'VortX-tvOS-lite-v0.5.5-ci.ipa'),macFile:join(upload,'VortX-macOS-v0.5.5-ci.dmg'),
    checksumFile:join(upload,'SHA256SUMS-ci.txt'), date:'2026-10-17', prerelease:false, name:r.name,
    note:'0.5.5: stable legacy-conversion fingerprints, lighter fallback polling with live updates retained, restored hero trailers, and improved episode positioning and watched-card dimming.', releaseId:PIN.release });
  for (const a of Object.values(built.manifest.assets)) { a.assetId = r.assets.find(x => x.name === a.name).id; a.state = 'uploaded'; }
  const receipt = { schemaVersion:2, action:'stage', manifest:built.manifest, source:built.sourceText, appcast:built.appcastText, checksum:built.checksumText };
  validateReceipt(receipt);
  const plan = { schema:1, releaseId:PIN.release, tag:PIN.tag, source:PIN.source, previousMain:PIN.main, previousSource:previous.text, previousSourceBlob:previous.blob,
    previousLatest:latest.id, previousLatestTag:latest.tag_name, before:Object.fromEntries(Object.entries(before).map(([name,value])=>[name,{text:value.text,generation:value.generation}])), receipt,
    assets:Object.fromEntries(r.assets.map(a=>[a.name,a.id])), notes:r.body, notesSha:PIN.notes };
  writeFileSync(join(out,'publication-plan.json'),JSON.stringify(plan,null,2)+'\n');
  console.log(JSON.stringify({prepared:true,planSha:hash(readFileSync(join(out,'publication-plan.json'))),generation:built.manifest.generation}));
}
async function signed(body, secret) {
  const bytes = JSON.stringify(body), signature = createHmac('sha256',secret).update(bytes).digest('hex');
  const attempts=['stage','promote','read-active-receipt'].includes(body.action)?3:1;
  for(let attempt=0;attempt<attempts;attempt++) {
    try {
      const r = await fetch('https://vortx.tv/__release/receipt',{method:'POST',headers:{'content-type':'application/json','x-vortx-receipt':`sha256=${signature}`},body:bytes,signal:AbortSignal.timeout(budget(25000))});
      if(!r.ok){const e=new Error(`feed operation rejected (${r.status})`);e.name='FeedRejected';throw e;}
      return await r.json();
    } catch(error) {if(error.name==='FeedRejected'||attempt===attempts-1)throw error;await delay(budget(1500));}
  }
}
export function commitSource(text, parent, message, arm = () => {}, api = gh) {
  insist(api('git/ref/heads/main').object.sha === parent, 'main CAS predecessor changed');
  const blob = api('git/blobs',{content:text,encoding:'utf-8'});
  const tree = api('git/trees',{base_tree:api(`git/commits/${parent}`).tree.sha,tree:[{path:'altstore/source.json',mode:'100644',type:'blob',sha:blob.sha}]});
  const identity = {name:'mamaclapper',email:'50227842+mamaclapper@users.noreply.github.com'};
  const commit = api('git/commits',{message,tree:tree.sha,parents:[parent],author:identity,committer:identity});
  insist(api('git/ref/heads/main').object.sha === parent,'main CAS predecessor raced');
  arm(commit.sha); // A lost PATCH ACK cannot erase this attempted write's compensation identity.
  try { api('git/refs/heads/main',{sha:commit.sha,force:false},'PATCH'); }
  catch(error) { if(api('git/ref/heads/main').object.sha!==commit.sha) throw error; }
  insist(api('git/ref/heads/main').object.sha === commit.sha,'main CAS result differs'); return commit.sha;
}
export function compensateSource(text, original, candidate, api=gh) {
  const current=api('git/ref/heads/main').object.sha;
  if(current===candidate) commitSource(text,candidate,'chore(release): restore 0.5.5 feed predecessor [skip ci]',()=>{},api);
  else insist(current===original,'main no longer ours; source rollback refused');
  const content=api(`contents/altstore/source.json?ref=${api('git/ref/heads/main').object.sha}`);
  insist(Buffer.from(content.content,'base64').toString()===text,'restored source bytes differ');
}
async function retryCheck(check) { let last; for(let i=0;i<18;i++){budget(1);try{return await check();}catch(e){last=e;if(i<17)await delay(budget(5000));}} throw last; }
async function verifyRoutes(plan, generation) {
  const routes = await snapshot();
  for(const r of Object.values(routes)) insist(/^application\/json/.test(r.headers['content-type']||'')&&r.headers['cache-control']==='public, max-age=120, s-maxage=120, must-revalidate','canonical feed headers differ');
  insist(routes['altstore.json'].generation === generation && routes['altstore.json'].text === plan.receipt.source,'active source bytes/generation differ');
  const a = JSON.parse(routes['appcast.json'].text), expected = JSON.parse(plan.receipt.appcast);
  // An Apple stage retains the already-verified previous Android entries until the separate signed augmentation.
  const inherited = JSON.parse(plan.before['appcast.json'].text).android;
  insist(JSON.stringify(a) === JSON.stringify({...expected,android:inherited}), 'active appcast differs from new Apple + retained Android');
  for(const name of Object.keys(routes)) {
    const q=await publicBody(`https://vortx.tv/${name}?release-check=${PIN.release}`);
    insist(q.generation===generation && q.text===routes[name].text,'query variant differs');
    insist(/^application\/json/.test(q.headers['content-type']||'') && q.headers['cache-control']==='public, max-age=120, s-maxage=120, must-revalidate','feed response headers differ');
  }
  insist((await publicBody(`https://raw.githubusercontent.com/${PIN.repo}/main/altstore/source.json`)).text===plan.receipt.source,'raw main source differs');
  return routes;
}
async function publicAssets(plan) {
  const result=[];
  for(const [name,[size,sha]] of Object.entries(ASSETS)) {
    const r=await fetch(`https://github.com/${PIN.repo}/releases/download/${PIN.tag}/${name}`,{signal:AbortSignal.timeout(budget(180000))});
    insist(r.ok,`public asset unavailable: ${name}`); const digest=createHash('sha256'); let count=0;
    for await(const chunk of r.body){digest.update(chunk);count+=chunk.length;}
    insist(count===size&&digest.digest('hex')===sha,`public asset mismatch: ${name}`); result.push({name,size,sha256:sha,assetId:plan.assets[name]});
  } return result;
}
function authenticatedAssets(plan) {
  for(const [name,[size,sha]] of Object.entries(ASSETS)) {
    const body=execFileSync('gh',['api','-H','Accept: application/octet-stream',`repos/${PIN.repo}/releases/assets/${plan.assets[name]}`],{maxBuffer:200*1024*1024,timeout:budget(180000)});
    insist(body.length===size&&hash(body)===sha,`authenticated draft bytes differ: ${name}`);
    console.log(`Verified authenticated draft bytes: ${name}`);
  }
}
function originalAppleArtifact() {
  const bytes=execFileSync('gh',['api',`repos/${PIN.repo}/actions/artifacts/${PIN.appleArtifact}/zip`],{maxBuffer:300*1024*1024,timeout:budget(180000)});
  insist(hash(bytes)===PIN.artifactSha,'original immutable app artifact archive digest differs');
  insist(process.env.RUNNER_TEMP,'original artifact proof requires the runner scratch directory');
  const file=join(process.env.RUNNER_TEMP,'accepted-original-apple.zip');writeFileSync(file,bytes);
  const entries=execFileSync('unzip',['-Z1',file],{encoding:'utf8'}).trim().split('\n');
  const body=name=>{insist(entries.filter(x=>x===name).length===1,'original artifact member missing/duplicated');return execFileSync('unzip',['-p',file,name],{maxBuffer:100*1024*1024});};
  for(const [original,renamed] of [['VortX-iOS-ci.ipa','VortX-iOS-v0.5.5-ci.ipa'],['VortX-tvOS-ci.ipa','VortX-tvOS-v0.5.5-ci.ipa'],['VortX-tvOS-lite-ci.ipa','VortX-tvOS-lite-v0.5.5-ci.ipa'],['VortX-macOS-ci.dmg','VortX-macOS-v0.5.5-ci.dmg']]) {
    const value=body(original),[size,sha]=ASSETS[renamed];insist(value.length===size&&hash(value)===sha,'original CI package differs from accepted upload');
  }
  const provenance=JSON.parse(body('native-workflow-provenance.json'));
  insist(provenance.sourceCommit===PIN.source&&provenance.workflowCommit===PIN.source&&provenance.runId===PIN.appleRun&&provenance.attempt===1&&provenance.verifierSha256==='fc5f52893f465290aed4ae0f9cf5336c2773541aba45396f38f7fb085434c41a','original CI native provenance differs');
  console.log('Verified the original immutable CI archive and all four unchanged Apple packages');
}
async function publish(planFile, expectedSha, resultFile) {
  insist(process.env.GITHUB_REPOSITORY===PIN.repo&&process.env.GITHUB_REF==='refs/tags/v0.5.5-publication.1'&&process.env.GITHUB_EVENT_NAME==='workflow_dispatch'&&process.env.GITHUB_JOB==='publish-existing-055','not the exact protected publication job');
  const jobs=gh(`actions/runs/${process.env.GITHUB_RUN_ID}/attempts/${process.env.GITHUB_RUN_ATTEMPT}/jobs?per_page=100`).jobs.filter(j=>j.name==='publish-existing-055'&&j.status==='in_progress'&&j.head_sha===process.env.GITHUB_SHA);
  insist(jobs.length===1&&Number.isFinite(Date.parse(jobs[0].started_at)),'cannot bind the actual job deadline');
  const jobStart=Date.parse(jobs[0].started_at), compensationDeadline=jobStart+33*60000;
  ioDeadline=jobStart+25*60000; // 35-minute job: eight minutes reserved for compensation, two for shutdown.
  const bytes=readFileSync(planFile); insist(hash(bytes)===expectedSha,'reviewed plan bytes differ'); const p=JSON.parse(bytes), m=p.receipt.manifest;
  validateReceipt(p.receipt); insist(p.previousMain===PIN.main&&p.releaseId===PIN.release&&p.source===PIN.source&&p.notesSha===PIN.notes,'plan identity differs');
  for(const a of Object.values(m.assets)) insist(a.assetId===p.assets[a.name],'staged asset ID differs from reviewed release asset');
  const secret=process.env.RELEASE_FEED_RECEIPT_SECRET; insist(secret,'receipt secret missing');
  await identities(); validateRelease(gh(`releases/${PIN.release}`),true,p.assets);
  originalAppleArtifact();
  authenticatedAssets(p);
  insist(gh('releases/latest').id===p.previousLatest&&gh('git/ref/heads/main').object.sha===PIN.main,'predecessor moved');
  insist(sourceAt(PIN.main).text===p.previousSource,'source predecessor bytes differ');
  const before=await snapshot(); for(const name of Object.keys(before)) insist(before[name].text===p.before[name].text&&before[name].generation===p.before[name].generation,'live predecessor changed');
  let sourceCommit=null,promotionAttempted=false,publishedAt=null,publishAttempted=false;
  try {
    insist(budget(5*60000)===5*60000,'insufficient pre-stage operation/compensation budget');
    const staged=await signed(p.receipt,secret); insist(staged.staged===true&&staged.generation===m.generation,'stage ACK differs');
    sourceCommit=commitSource(p.receipt.source,PIN.main,'chore(release): publish verified 0.5.5 install feed [skip ci]',candidate=>{sourceCommit=candidate;});
    // Record attempted writes before dispatch so an ambiguous/lost ACK still enters guarded compensation.
    promotionAttempted=true;
    const body={action:'promote',operationId:`publish-055:${PIN.release}:${m.generation}`,releaseId:String(PIN.release),generation:m.generation,expectedActiveGeneration:p.before['altstore.json'].generation};
    const promoted=await signed(body,secret); insist(promoted.promoted===true&&promoted.generation===m.generation,'promote ACK differs');
    await retryCheck(()=>verifyRoutes(p,m.generation));
    validateRelease(gh(`releases/${PIN.release}`),true,p.assets);
    publishAttempted=true; let release;
    try { release=gh(`releases/${PIN.release}`,releasePatchBody({draft:false,make_latest:'false'}),'PATCH'); }
    catch { release=gh(`releases/${PIN.release}`); }
    validateRelease(release,false,p.assets); publishedAt=release.published_at; insist(publishedAt,'publication timestamp missing');
    gh(`releases/${PIN.release}`,releasePatchBody({make_latest:'true'}),'PATCH');
    await retryCheck(async()=>{const r=gh(`releases/${PIN.release}`);validateRelease(r,false,p.assets);insist(r.published_at===publishedAt&&gh('releases/latest').id===PIN.release,'Latest/publication identity differs');});
    const assets=await publicAssets(p); await retryCheck(()=>verifyRoutes(p,m.generation));
    const active=await signed({action:'read-active-receipt'},secret);
    insist(active.active.manifest.generation===m.generation,'active receipt changed');
    writeFileSync(resultFile,JSON.stringify({published:true,releaseId:PIN.release,tag:PIN.tag,source:PIN.source,publishedAt,sourceCommit,generation:m.generation,receiptSha256:active.active.receiptSha256,sourceSha256:m.sourceSha256,appcastSha256:m.appcastSha256,assets,androidAugmentationPending:true},null,2)+'\n');
    console.log(JSON.stringify({published:true,releaseId:PIN.release,generation:m.generation,androidAugmentationPending:true}));
  } catch(error) {
    ioDeadline=compensationDeadline;
    const failures=[];
    if(publishAttempted) try {
      const r=gh(`releases/${PIN.release}`); validateRelease(r,r.draft,p.assets);
      if(!r.draft){insist(!publishedAt||r.published_at===publishedAt,'publication changed; refuse rollback');gh(`releases/${PIN.release}`,releasePatchBody({draft:true}),'PATCH');}
      const latest=gh('releases/latest'); if(latest.id===PIN.release)gh(`releases/${p.previousLatest}`,releasePatchBody({make_latest:'true'},p.previousLatestTag),'PATCH');
      insist(gh(`releases/${PIN.release}`).draft===true&&gh('releases/latest').id===p.previousLatest,'release rollback did not converge');
    } catch(e){failures.push(`release: ${e.message}`);}
    if(promotionAttempted) try {
      const active=await signed({action:'read-active-receipt'},secret);
      if(active.active.manifest.generation===m.generation) await signed({action:'rollback',expectedCurrentGeneration:m.generation,restoreGeneration:p.before['altstore.json'].generation},secret);
      const after=await snapshot();for(const n of Object.keys(after))insist(after[n].generation===p.before[n].generation&&after[n].text===p.before[n].text,'feed rollback differs');
    } catch(e){failures.push(`feed: ${e.message}`);}
    if(sourceCommit) try {
      compensateSource(p.previousSource,PIN.main,sourceCommit);
      await retryCheck(async()=>insist((await publicBody(`https://raw.githubusercontent.com/${PIN.repo}/main/altstore/source.json`)).text===p.previousSource,'raw source rollback not converged'));
    } catch(e){failures.push(`source: ${e.message}`);}
    throw new Error(`${error.message}; compensation ${failures.length?'INCOMPLETE: '+failures.join('; '):'verified'}`);
  }
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
  const [mode,...args]=process.argv.slice(2);
  if(mode==='prepare')await prepare(...args);
  else if(mode==='publish')await publish(...args);
  else throw new Error('use prepare ROOT UPLOAD OUT or publish PLAN REVIEWED_SHA RESULT');
}
