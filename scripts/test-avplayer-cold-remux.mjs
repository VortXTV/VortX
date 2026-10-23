#!/usr/bin/env node
// Exact production extraction only; no application build, playback, socket, GPU or account activity.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync,execFileSync} from 'node:child_process';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const output=process.argv[2] ? path.resolve(process.argv[2]) : (()=>{
 const base=path.join(root,'app/build'); fs.mkdirSync(base,{recursive:true});
 return fs.mkdtempSync(path.join(base,'player-contracts.'));
})();
if(!fs.statSync(output).isDirectory())throw Error('Pass an existing receipt directory');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
function block(text,marker) {
 const start=text.indexOf(marker),open=text.indexOf('{',start);
 if(start<0)throw Error('Missing production declaration: '+marker);
 let depth=1,end=open+1;
 for(;depth&&end<text.length;end++){if(text[end]==='{')depth++;if(text[end]==='}')depth--;}
 if(depth)throw Error('Unbalanced production declaration: '+marker);
 return text.slice(start,end);
}
function compileRun(name,source,extra=[]) {
 const file=path.join(output,name+'.swift');fs.writeFileSync(file,source);
 for(const version of ['5','6']) {
  const exe=path.join(output,name+'-swift'+version);
  const compile=spawnSync('xcrun',['swiftc','-swift-version',version,'-strict-concurrency=complete','-warnings-as-errors','-parse-as-library',file,'-o',exe],{encoding:'utf8'});
  fs.writeFileSync(exe+'.compile.log',compile.stdout+compile.stderr);
  if(compile.status!==0)throw Error(compile.stderr);
  const run=spawnSync(exe,extra,{encoding:'utf8',timeout:30000});
  fs.writeFileSync(exe+'.run.log',run.stdout+run.stderr);process.stdout.write(run.stdout+run.stderr);
  if(run.status!==0)throw Error(name+' runtime exit '+run.status);
 }
 return file;
}
function sdkCheck(file,sdk,target,flags=[]) {
 const sdkPath=execFileSync('xcrun',['--sdk',sdk,'--show-sdk-path'],{encoding:'utf8'}).trim();
 const compile=spawnSync('xcrun',['swiftc','-swift-version','6','-strict-concurrency=complete','-typecheck',...flags,'-sdk',sdkPath,'-target',target,file],{encoding:'utf8'});
 fs.writeFileSync(path.join(output,path.basename(file)+'.'+sdk+'.compile.log'),compile.stdout+compile.stderr);
 if(compile.status!==0)throw Error(compile.stderr);
 console.log('REAL_SDK_PRODUCTION_EXTRACT_TYPECHECKED '+sdk);
}

const source=read('app/Sources/Player/AVPlayerEngine.swift');
function contract(ok,detail){if(!ok)throw Error('Source wiring: '+detail);console.log('SOURCE_WIRING '+detail);}
contract(source.includes('func invalidateLoadToken() {\n        cancelColdLocalRemuxPreparation()'),'token invalidation retires preparation');
contract(source.includes('coldLocalRemuxPreparation?.cancel()\n        coldLocalRemuxMountTask?.cancel()'),'deinit retires preparation');
const load=source.slice(source.indexOf('    func loadFile('),source.indexOf('    private func cancelColdLocalRemuxPreparation()'));
contract(!load.includes('VortXRemuxHLSServer.make('),'no synchronous cold factory in loadFile');
contract(load.indexOf('if let adopted = adoptedPrepared')<load.indexOf('beginColdLocalRemuxMount('),'prepared adoption retains priority');
contract(load.indexOf('beginExternalEngineMount(')<load.indexOf('beginColdLocalRemuxMount('),'external engine retains priority');
contract(source.includes('let work = Task.detached(priority: .utility)'),'factory uses detached utility executor');
const holder=block(source,'final class AVPlayerColdRemuxPreparation:');
const methods=['private func cancelColdLocalRemuxPreparation()','private func beginColdLocalRemuxMount(',
'private func failRemuxMount(','private func finishLoadAsset(','private func pendingLoadIsCurrent(','private func attachPreparedItem(']
.map(m=>block(source,m)).join('\n').replaceAll('private func ','func ');
const fixture=read('app/Tests/AVPlayerColdRemuxContractTests.swift').replace('/* HOLDER */',holder).replace('/* METHODS */',methods);
const file=compileRun('avplayer-cold-remux',fixture);
for(const [sdk,target] of [['macosx','arm64-apple-macos14.0'],['iphonesimulator','arm64-apple-ios17.0-simulator'],['appletvsimulator','arm64-apple-tvos17.0-simulator']])sdkCheck(file,sdk,target,['-D','REAL_SDK','-warnings-as-errors']);
console.log('COLD_REMUX_RESPONSIVENESS_CONTRACTS_GREEN '+output);
