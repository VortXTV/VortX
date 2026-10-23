#!/usr/bin/env node
// One bounded host replay, no application build/launch, network, GPU or real persistence.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const args=process.argv.slice(2);
const option=flag=>{const i=args.indexOf(flag);return i<0?undefined:args[i+1];};
const root=path.resolve(option('--root')??path.join(path.dirname(fileURLToPath(import.meta.url)),'..'));
const candidate=option('--candidate-prefix');
const output=option('--output');
if(!output||!path.isAbsolute(output)||!fs.statSync(output).isDirectory())throw Error('Pass --output with an existing absolute receipt directory');
const read=file=>fs.readFileSync(candidate?candidate+path.basename(file):path.join(root,file),'utf8');
function block(text,marker){const start=text.indexOf(marker),open=text.indexOf('{',start);if(start<0)throw Error('Missing '+marker);let depth=1,end=open+1;for(;depth&&end<text.length;end++){if(text[end]==='{')depth++;if(text[end]==='}')depth--;}if(depth)throw Error('Unbalanced '+marker);return text.slice(start,end);}
const policy=read('app/Sources/Player/CacheShedPolicy.swift');
const controller=read('app/Sources/Player/MPVMetalViewController.swift');
const views=['app/Sources/PlayerScreen.swift','app/SourcesTV/TVPlayerView.swift'].map(read);
const completion=read('app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift');
const fixture=candidate?fs.readFileSync(candidate+'ReplayTests.swift','utf8'):fs.readFileSync(path.join(root,'app/Tests/SeekEOFRecoveryReplayTests.swift'),'utf8');
const helpers=text=>['private func handleExhaustedSeekEOFRecovery(','private func rejectPrematureEOFIfNeeded(']
 .map(marker=>block(text,marker).replace('private func ','func ')).join('\n');
const production=[block(policy,'struct SeekEOFRecoveryExhaustion:'),block(policy,'struct SeekEOFTerminalParkPolicy<'),block(policy,'enum SeekEOFRecoveryContinuationPolicy'),block(policy,'struct SeekEOFRecoveryPolicy<')].join('\n');
const baselinePath=option('--baseline-witness');
const controllerFixture=candidate?fs.readFileSync(candidate+'ControllerTests.swift','utf8'):fs.readFileSync(path.join(root,'app/Tests/SeekEOFControllerExtractionTests.swift'),'utf8');
const controllerMethods=[
 'private func acceptsCurrentSeekEvent(', 'private func acceptsCurrentTerminalSeekEvent(',
 'private func acceptsCurrentPosition(', 'private func emit(', 'private func emitEndFileEOF(',
 'private func handleEndFileEOF(', 'func parkAfterExhaustedSeekEOF(',
 'private func failSeekEOFRecovery(', 'func play()', 'var requestedPauseIntent:',
 'func pause()', 'func togglePause()'
].map(marker=>block(controller,marker).replace('private func ','func ')).join('\n');
function dispatchBefore(marker){const end=controller.indexOf(marker);if(end<0)throw Error(marker);
 const start=controller.lastIndexOf('DispatchQueue.main.async { [weak self] in',end);
 return block(controller.slice(start),'DispatchQueue.main.async { [weak self] in');}
const loadGuard='        loadTokenLock.unlock()\n        if commandResult >= 0 {\n            if !preservingSeekEOFRecovery {';
const loadGuardAt=controller.indexOf(loadGuard);
if(loadGuardAt<0)throw Error('Missing exact accepted-load admission boundary');
const loadGuardStart=controller.indexOf('if commandResult >= 0 {',loadGuardAt);
const loadGuardEnd=controller.indexOf('            seekEOFReloadSource =',loadGuardStart);
const loadAdmission=controller.slice(loadGuardStart,loadGuardEnd).trimEnd()+'\n}';
const nativeReplay=controllerFixture
 .replace('/* __PRODUCTION_SETTLEMENT__ */',[block(completion,'struct MPVSeekSettlementEvidence:'),block(completion,'struct MPVSeekSettlementPolicy<')].join('\n'))
 .replace('/* __PRODUCTION_CONTROLLER_METHODS__ */',controllerMethods)
 .replace('/* __PRODUCTION_RAW_EOF__ */',dispatchBefore('self.handleEndFileEOF(loadToken: loadToken, seekEvidence: rawTerminalSeekEvidence)'))
 .replace('/* __PRODUCTION_RAW_ERROR__ */',dispatchBefore('reason: "reopen failed before seek restoration"'))
 .replace('/* __PRODUCTION_LOAD_ADMISSION__ */',loadAdmission);
const source=fixture.replace('/* __PRODUCTION_POLICY__ */',production)
 .replace('/* __PRODUCTION_COMPLETION__ */',block(completion,'struct PlaybackCompletionEvidence<'))
 .replace('/* __PRODUCTION_SHARED_METHODS__ */',helpers(views[0]))
 .replace('/* __PRODUCTION_TV_METHODS__ */',helpers(views[1]))
 .replace('/* __BASELINE_WITNESS__ */',baselinePath?fs.readFileSync(baselinePath,'utf8'):'')
 .replace('/* __CONTROLLER_EXTRACTION_REPLAYS__ */',nativeReplay);
if(source.includes('__PRODUCTION_'))throw Error('Unfilled production marker');
function contract(ok,message){if(!ok)throw Error('Source wiring: '+message);}
contract(controller.includes('!self.seekEOFRecovery.acceptsExhaustion(exhaustion, owner: capturedToken)'), 'queued error source and seek-generation fence');
contract(controller.includes('data: exhaustion, loadToken: loadToken'),'EOF carries captured recovery context');
contract(controller.includes('self.handleEndFileEOF(loadToken: loadToken, seekEvidence: rawTerminalSeekEvidence)'), 'raw-dequeue generation fences first EOF enqueue');
contract(controller.includes('guard self.acceptsCurrentTerminalSeekEvent(seekEvidence, owner: loadToken) else { return }'),'second EOF enqueue retains original seek generation');
contract(controller.includes('reason: "reopen failed before seek restoration"'),'raw native error during reopen spends existing attempt');
contract(controller.includes('reason: "source failed again after its seek reopen"'),'raw native error after restored landing retains still-valid spent receipt');
contract(controller.includes('if seekEOFTerminalPark.updateIntent(paused: false) { return }')&&controller.includes('if seekEOFTerminalPark.updateIntent(paused: true) { return }'),'terminal park cannot be released by a stray transport key');
contract(controller.includes('if let paused = seekEOFTerminalPark.acceptedFreshLoad()'),'only accepted fresh load restores prior park intent');
contract(controller.includes('settled: self.acceptsSettledPosition(rawSeekEvidence, owner: loadToken)'),'progress rearm requires actual attributed settled evidence');
contract(controller.includes('if !preservingSeekEOFRecovery {\n                seekEOFRecoveryTimeout?.cancel(); seekEOFRecoveryTimeout = nil\n                seekEOFRecovery.reset()'),'automatic internal reopen preserves budget, accepted fresh load resets it');
for(const view of views){
 const eof=view.slice(view.indexOf('case MPVProperty.endFileEof:'),view.indexOf('case MPVProperty.endFileEof:')+6500);
 contract(eof.indexOf('rejectPrematureEOFIfNeeded')<eof.indexOf('markedWatched'),'completion evidence precedes watched/advance');
 const helper=block(view,'private func handleExhaustedSeekEOFRecovery(');
 contract(!helper.includes('markPlaybackWatched')&&!helper.includes('finishedWatching')&&!helper.includes('reportProgress'),'exhaustion does not invent persistence/completion');
 contract(view.includes('handleExhaustedSeekEOFRecovery(exhaustion, loadToken: loadToken)'),'typed inner timeout wired before generic error ladder');
 contract(view.includes('knownDurationFallback: seekEOF?.duration'),'owned finite receipt protects a missing replacement-duration notification');
}
const file=path.join(output,'seek-eof-replay.swift');fs.writeFileSync(file,source);
const sha=text=>crypto.createHash('sha256').update(text).digest('hex');
const receipt={root,candidatePrefix:candidate??null,sourceSHA256:sha(source),policySHA256:sha(policy),controllerSHA256:sha(controller),viewSHA256:views.map(sha),compiled:false,ran:false,
 limitations:'Actual production policy, completion gate, complete UI continuation methods, selected controller queue/park/transport methods, actual raw terminal dispatch closures and accepted-load park-release admission fragment with fake collaborators. Not complete readEvents/loadFile/controller or libmpv linking/native queue/event decoding; no app/media/network/progress backend/physical playback proof.'};
fs.writeFileSync(path.join(output,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');
if(args.includes('--prepare-only')){console.log('PREPARED_ONLY '+output);process.exit(0);}
const executable=path.join(output,'seek-eof-replay');
const compile=spawnSync('/usr/bin/nice',['-n','10','xcrun','swiftc','-swift-version','6','-strict-concurrency=complete','-warnings-as-errors',...(baselinePath?['-D','BASELINE_WITNESS']:[]),'-parse-as-library',file,'-o',executable],{encoding:'utf8'});
fs.writeFileSync(path.join(output,'compile.log'),compile.stdout+compile.stderr);
if(compile.status!==0){process.stderr.write(compile.stderr);process.exit(compile.status??1);}
receipt.compiled=true;
const run=spawnSync('/usr/bin/nice',['-n','10',executable],{encoding:'utf8',timeout:30000});
fs.writeFileSync(path.join(output,'run.log'),run.stdout+run.stderr);process.stdout.write(run.stdout+run.stderr);
receipt.ran=true;receipt.exit=run.status;
fs.writeFileSync(path.join(output,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');
if(run.status!==0)process.exit(run.status??1);
console.log('SEEK_EOF_RECOVERY_REPLAY_GREEN '+output);
