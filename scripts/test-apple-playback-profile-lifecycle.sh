#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
mkdir -p app/build
test_dir=$(mktemp -d app/build/apple-playback-profile-lifecycle.XXXXXX)
source_ref="${1:-current}"
if [[ "$source_ref" == "--baseline" ]]; then source_ref=10e425d990036ec801bc2edabd8a688bd0f58e44; fi

# The same Swift assertions run against either tree. Extract complete declarations and exact production
# statement ranges; no candidate body rewrites, regex translations, or expected-failure synthesis.
node - "$test_dir" "$source_ref" <<'NODE'
const fs = require('node:fs');
const cp = require('node:child_process');
const [out, ref] = process.argv.slice(2);
function read(path) { return ref === 'current' ? fs.readFileSync(path, 'utf8') : cp.execFileSync('git', ['show', `${ref}:${path}`], {encoding:'utf8'}); }
function between(s, a, b, start=0) {
  const i=s.indexOf(a,start), j=s.indexOf(b,i+a.length);
  if(i<0||j<0) throw new Error(`Missing source boundary ${a} -> ${b}`);
  return s.slice(i,j);
}
// Braces inside these declarations' strings are balanced. Bodies are retained byte-for-byte, including
// native accessors, guards and failure side effects.
function declaration(s, marker) {
  const i=s.indexOf(marker); if(i<0) throw new Error(`Missing declaration ${marker}`);
  const open=s.indexOf('{',i); let depth=1,j=open+1;
  for(;j<s.length&&depth;j++){ if(s[j]==='{')depth++;if(s[j]==='}')depth--; }
  if(depth)throw new Error(`Unbalanced declaration ${marker}`);
  return s.slice(i,j);
}
const controller=read('app/Sources/Player/MPVMetalViewController.swift');
const player=read('app/Sources/PlayerScreen.swift');
const tv=read('app/SourcesTV/TVPlayerView.swift');
const shared=read('app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift');
const core=read('app/SourcesShared/CoreModels.swift');
const snapshot=shared.includes('struct MPVPlaybackProfileSnapshot') ? declaration(shared,'struct MPVPlaybackProfileSnapshot') : '';
const native=controller.includes('private final class MPVPlaybackProfileOption') ? declaration(controller,'private final class MPVPlaybackProfileOption') : '';
const capture=controller.includes('guard let priorPlaybackProfile') ? between(controller,'guard let priorPlaybackProfile','        // Header-admission transaction') : '';
const loadStart=controller.indexOf('    private func loadFile(');
const handleGuard=declaration(controller.slice(loadStart),'        guard mpv != nil else');
const configure=between(controller,'        configureLiveMode(live)','        let readAhead:',loadStart);
const cache=between(controller,'        // Apply before load admission','        // `loadfile replace`',loadStart);
const command=between(controller,'        var commandNode = mpv_node()','        let entryID:',loadStart);
const settlement=between(controller,'        if commandResult >= 0 {\n            if !preservingSeekEOFRecovery','\n        return issuedToken',loadStart);
function continuation(s) {
  return between(s,'            let mounted = await awaitReplacementMPVMount(for: handoff)','            if followedDeadInput');
}
function callbacks(s) {
  const appear=s.lastIndexOf('            hydrateDirectResumeSeriesInventory()',s.indexOf('if !isTrailer { PlayerOrientation.forceLandscape()'));
  if(appear<0) throw new Error('Missing actual onAppear hydration anchor');
  const disappear=s.indexOf('            NowPlayingCenter.clear()',appear);
  return {
    appear:between(s,'            #if os(iOS)','            if !isTrailer',appear).split('\n').slice(1).join('\n'),
    disappear:between(s,'            #if os(iOS)','            PlayerOrientation.release()',disappear).split('\n').slice(1).join('\n')
  };
}
const idle=player.includes('@MainActor private enum IOSPlaybackIdleTimer') ? declaration(player,'@MainActor private enum IOSPlaybackIdleTimer') : '';
const lifecycle=callbacks(player);
function handoffHarness(s, name) {
return `
@MainActor final class ${name}: HandoffCollaborators {
${declaration(s,'    private struct AVToMPVHandoff: Equatable')}
${declaration(s,'    private struct DirectAVNoFrameRecovery: Equatable')}
    private var avToMPVHandoff: AVToMPVHandoff?
    private var directAVNoFrameRecovery: DirectAVNoFrameRecovery?
    func replaceAttempt() { avToMPVHandoff = makeHandoff() }
    private func makeHandoff() -> AVToMPVHandoff {
        AVToMPVHandoff(url:url, episodeGeneration:0, sourceGeneration:0, resumeGeneration:0${name==='TVHandoff'?', attemptID:"attempt-A"':''})
    }
    private func awaitReplacementMPVMount(for handoff: AVToMPVHandoff) async -> (controller: MPVMetalViewController, token: PlayerLoadToken)? {
        await suspendMount()
    }
    func run() async {
        let handoff=makeHandoff()
${continuation(s)}
    }
}
`;
}
const generated=`
import Foundation
${declaration(core,'struct PlayerLoadToken: Hashable, Sendable')}
${declaration(shared,'struct PlaybackIdleTimerLease')}
${snapshot}
${native}

// Fake only the native API and unrelated collaborators. The mode configuration, command call,
// admission branch and native-node snapshot implementation are production statements.
enum NativeValue: Equatable { case scalar(String); case map([String:String]) }
struct mpv_node { var value: NativeValue? }
let MPV_FORMAT_NODE: Int32 = 6
final class NativePort: @unchecked Sendable {
    static let shared = NativePort()
    var values: [String:NativeValue] = [:]
    var missingReads: Set<String> = []
    var writes: [String] = []
    var commandStatus: Int32 = -1
    var commands = 0
    var valuesAtCommand: [String:NativeValue] = [:]
}
func mpv_get_property(_ handle: OpaquePointer?, _ name: String, _ format: Int32, _ node: inout mpv_node) -> Int32 {
    guard handle != nil, !NativePort.shared.missingReads.contains(name), let value=NativePort.shared.values[name] else { return -1 }
    node.value=value; return 0
}
func mpv_set_property(_ handle: OpaquePointer?, _ name: String, _ format: Int32, _ node: inout mpv_node) -> Int32 {
    guard handle != nil, let value=node.value else { return -1 }
    NativePort.shared.writes.append(name); NativePort.shared.values[name]=value; return 0
}
func mpv_free_node_contents(_ node: inout mpv_node) { node.value=nil }
@discardableResult func mpv_set_property_string(_ handle: OpaquePointer?, _ name:String, _ value:String) -> Int32 {
    guard handle != nil else { return -1 }
    NativePort.shared.writes.append(name)
    if name.hasSuffix("lavf-o") {
        var entries:[String:String]=[:]
        for entry in value.split(separator:",") { let pair=entry.split(separator:"=",maxSplits:1).map(String.init); if pair.count==2 { entries[pair[0]]=pair[1] } }
        NativePort.shared.values[name] = .map(entries)
    } else { NativePort.shared.values[name] = .scalar(value) }
    return 0
}
enum MPVProperty { static let speed="speed"; static let endFileError="end-file-error" }
enum DiagnosticsLog { static func log(_ category:String,_ text:String) {} }
enum LocalNNTPBufferPolicy { static func waitSeconds(url:URL,live:Bool,preview:Bool)->Double { 6 } }
struct Resettable { mutating func reset() {} }
struct CacheFlight { mutating func reset()->Int { 0 } }
struct InitializationFailure {
    func admit(_ token:PlayerLoadToken)->String? { nil }
    func accepts(_ token:PlayerLoadToken)->Bool { false }
}
@MainActor final class Delegate {
    func propertyChange(propertyName:String,data:String,loadToken:PlayerLoadToken) {}
}
struct SeekEOFReloadSource { let url:URL; let headers:[String:String]?; let live:Bool; let audioSidecar:URL? }
@MainActor final class MPVMetalViewController {
    var mpv:OpaquePointer?=OpaquePointer(bitPattern:1)
    var configuredLiveMode=false
    var activeLoadToken:PlayerLoadToken?=PlayerLoadToken()
    var appliedRates:[Double]=[]
    var paused=true
    var startMuted=false
    let loadTokenLock=NSLock()
    var initializationFailure=InitializationFailure()
    var playDelegate:Delegate?
    var seekEOFRecoveryTimeout:Task<Void,Never>?
    var seekEOFRecovery=Resettable()
    var seekEOFReloadSource:SeekEOFReloadSource?
    var cacheFlushFlight=CacheFlight()
    var activeReadAheadCap="old"
    var baselineReadAheadCap="old"
    var cacheReadaheadRampWork:Task<Void,Never>?
    var cacheReadaheadRampGeneration=0
    var pausedCacheClampWork:Task<Void,Never>?
    var pausedCacheClamped=true
    var memoryCacheClamped=true
    var cachePauseWaitSeconds=1.0
    let defaultBackBufferCap="24MiB"
    func finishCacheFlushFlight(_ value:Int,sampleLiveState:Bool) {}
    func armDiskCacheReadaheadRamp() {}
    func checkError(_ status:Int32) { precondition(status>=0) }
    func getString(_ name:String)->String? { if case let .scalar(value)?=NativePort.shared.values[name] { return value }; return nil }
    private func setString(_ name:String,_ value:String) {
        _ = mpv_set_property_string(mpv,name,value)
        if name==MPVProperty.speed { appliedRates.append(Double(value)!) }
        if name=="pause" { paused = value == "yes" }
    }
${declaration(controller,'    func setSpeed(_ speed: Double)')}
${declaration(controller,'    private func configureLiveMode(_ live: Bool)')}
    func commandReturningNode(_ name:String,args:[String],result:inout mpv_node)->Int32 {
        precondition(name=="loadfile")
        NativePort.shared.commands += 1
        NativePort.shared.valuesAtCommand=NativePort.shared.values
        return NativePort.shared.commandStatus
    }
    func loadProfile(live:Bool,usesConfirmedDiskOffload:Bool=false)->PlayerLoadToken {
        let issuedToken=PlayerLoadToken()
        let url=URL(string:"https://example.invalid/video")!
        let playURL=url
        let headers:[String:String]?=nil, audioSidecar:URL?=nil
        let args=[url.absoluteString,"replace"]
        let preservingSeekEOFRecovery=false
        let appliedCap="256MiB"
${handleGuard}
        ${capture}
${configure}
${cache}
${command}
${settlement}
        return issuedToken
    }
}
@MainActor final class UIApplication { static let shared=UIApplication(); var isIdleTimerDisabled=false }
${idle}
@MainActor final class IdlePresentation {
    let playbackIdleTimerOwner=UUID()
    func appear() {
${lifecycle.appear}
    }
    func disappear() {
${lifecycle.disappear}
    }
}
@MainActor class HandoffCollaborators {
    final class Coordinator { var player:MPVMetalViewController? }
    let coordinator=Coordinator()
    var speed=0.5, playSpeed=0.5
    var playbackExited=false, leftPlayback=false, avToMPVHandoffBlocked=false
    var episodeSwitchGeneration=0, sourceSwitchGeneration=0, resumeRetryGeneration=0
    let url=URL(string:"https://example.invalid/video")!
    var curURL:URL?
    var loadErrorMsg=""
    var directFallbackAttempt:String?="attempt-A"
    var adopted:[PlayerLoadToken]=[]
    var terminalFailures=0
    var mountWaiter:CheckedContinuation<(controller:MPVMetalViewController,token:PlayerLoadToken)?,Never>?
    func suspendMount() async -> (controller:MPVMetalViewController,token:PlayerLoadToken)? {
        await withCheckedContinuation { mountWaiter=$0 }
    }
    func completeMount(_ mount:(controller:MPVMetalViewController,token:PlayerLoadToken)?) {
        let waiter=mountWaiter; mountWaiter=nil; waiter?.resume(returning:mount)
    }
    func adoptResumeSurfaceIfCurrent(loadToken:PlayerLoadToken) {
        guard coordinator.player?.activeLoadToken==loadToken else { return }
        adopted.append(loadToken)
    }
    func presentTerminalLoadFailure() { terminalFailures += 1 }
}
${handoffHarness(player,'IOSHandoff')}
${handoffHarness(tv,'TVHandoff')}
`;
fs.writeFileSync(`${out}/Generated.swift`,generated);
fs.writeFileSync(`${out}/source-ref.txt`,`${ref}\n`);
NODE

xcrun swiftc -swift-version 5 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    "$test_dir/Generated.swift" app/Tests/ApplePlaybackProfileLifecycleTests.swift \
    -o "$test_dir/apple-playback-profile-lifecycle"
echo "Evidence: $repo_root/$test_dir (source: $source_ref)"
"$test_dir/apple-playback-profile-lifecycle"
shasum -a 256 app/Sources/Player/MPVMetalViewController.swift app/Sources/PlayerScreen.swift \
    app/SourcesTV/TVPlayerView.swift app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift
