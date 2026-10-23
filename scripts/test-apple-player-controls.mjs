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

const source=read('app/Sources/PlayerScreen.swift');
const markers=['private func scheduleHide()','private var controlsAutoHideEligible:',
 'private func refreshControlsAutoHide()','private func startControlsHideIfNeeded()',
 'private func setVolumeEditing(','private func macPointerMoved()'];
const holder=block(source,'private final class ControlsHideClock');
const methods=markers.map(m=>block(source,m)).join('\n');
if(!source.includes('.onChange(of: controlsAutoHideEligible) { _ in refreshControlsAutoHide() }'))throw Error('Eligibility observer disconnected');
if(!source.includes('if case .active = phase { macPointerMoved() }'))throw Error('Pointer input disconnected');
if(!source.includes('onEditingChanged: setVolumeEditing'))throw Error('Volume hold disconnected');
for(const line of source.split('\n'))if(line.includes('hideTask?.cancel()')&&!line.includes('hideTask = nil'))throw Error('Cancelled timer handle retained');
const controlled=methods.replaceAll('ProcessInfo.processInfo.systemUptime','clock.uptime')
 .replaceAll('Date().addingTimeInterval(4)','clock.now.addingTimeInterval(4)')
 .replaceAll('let now = Date()','let now = clock.now')
 .replaceAll('controlsHideClock.deadline.timeIntervalSinceNow','controlsHideClock.deadline.timeIntervalSince(clock.now)')
 .replaceAll('if Date() < controlsHideClock.deadline','if clock.now < controlsHideClock.deadline')
 .replaceAll('Task.sleep(for:','clock.sleep(for:')
 .replaceAll('private func ','func ').replaceAll('private var ','var ');
const harness=read('app/Tests/PlayerControlsAutoHideContractTests.swift');
const runtime=harness.replace('    // __PRODUCTION_CLOCK_HOLDER__',holder.replace('private final class','final class'))
 .replace('    // __PRODUCTION_CONTROL_METHODS__',controlled);
if(runtime.includes('__PRODUCTION_'))throw Error('Unfilled production marker');
compileRun('player-controls-auto-hide',runtime);
const observer=source.match(/        \.onChange\(of: controlsAutoHideEligible\)[^\n]+/)[0];
const pointer=source.match(/        \.onContinuousHover \{ phase in\n[^\n]+\n        \}/)[0];
const volume=source.slice(source.indexOf('    private var volumeControl:'),source.indexOf('    private var centerTransport:'));
const slider=block(read('app/SourcesShared/VortXControls.swift'),'struct VortXSlider:');
const sdkFixture='import SwiftUI\n'+
'enum Theme { enum Palette { static let textPrimary=Color.white; static let accent=Color.orange }; enum Motion { static let state=Animation.easeOut(duration: 0.18) } }\n'+
'@propertyWrapper struct ReducedMotion: DynamicProperty { var wrappedValue: Bool { false } }\n'+slider+'\n'+
'@MainActor struct ModifierProbe: View {\n'+
['controlsVisible=true','isLocked=false','playerMuted=false','playerVolume=50.0','hasStartedPlaying=false','isPaused=false','scrubbing=false','editingVolume=false',
'panel: Int?','grabbedFrame: Int?','touchOptionsVisible=false','skipEditActive=false','loadFailed=false','playbackExited=false','showExternalChooser=false','showShare=false',
'externalLinkDead=false','subtitleLoadFailed=false','stillWatchingPrompt=false','hideTask: Task<Void,Never>?'].map(v=>'@State private var '+v).join('\n')+'\n'+
'@State private var controlsHideClock=ControlsHideClock()\n'+holder+'\n'+methods+'\n'+
'var volumeGlyph: String { "speaker" }; func noteInteraction() {}; func togglePlayerMute() {}; func setPlayerVolume(_ value: Double) {}\n'+
'var body: some View { Color.black\n'+observer+'\n#if os(macOS)\n'+pointer+'\n#endif\n'+
'.overlay { Color.clear.opacity(controlsVisible && !isLocked ? 1 : 0).allowsHitTesting(controlsVisible && !isLocked) }\n}\n'+volume+'\n}';
const sdkFile=path.join(output,'player-controls-swiftui.swift');fs.writeFileSync(sdkFile,sdkFixture);
sdkCheck(sdkFile,'macosx','arm64-apple-macos14.0');
sdkCheck(sdkFile,'iphonesimulator','arm64-apple-ios16.0-simulator');
console.log('PLAYER_CONTROLS_AUTO_HIDE_CONTRACTS_GREEN '+output);
