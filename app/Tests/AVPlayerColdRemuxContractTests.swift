import Foundation
#if REAL_SDK
import AVKit
import AVFoundation
import CoreMedia
#else
final class AVURLAsset { let url: URL; init(url: URL) { self.url = url } }
final class AVPlayerItem { enum Status { case unknown }; let status = Status.unknown; var preferredForwardBufferDuration = 0.0; init(asset: AVURLAsset) {}; func add(_ output: AVPlayerItemVideoOutput) {} }
final class AVPlayerItemVideoOutput { init(pixelBufferAttributes: [String: Int]) {} }
final class AVPlayer { var automaticallyWaitsToMinimizeStalling = false; var allowsExternalPlayback = false; var currentItem: AVPlayerItem?; func replaceCurrentItem(with item: AVPlayerItem?) { currentItem = item } }
let kCVPixelBufferPixelFormatTypeKey = "format"
let kCVPixelFormatType_32BGRA = 42
#endif
struct PlayerLoadToken: Equatable, Sendable { let id = UUID() }
enum MPVProperty { static let endFileError = "error" }
enum DiagnosticsLog { static func log(_ category: String, _ value: String) {} }
enum VXProbe { static func log(_ category: String, _ value: String) {} }
@MainActor final class VXProbeState { static let shared = VXProbeState(); func setPlayer(state: String, source: String?, engine: String) {} }
enum MountKind { case localRemux }
enum VortXRemuxForwardBufferPolicy {
 static func preferredDuration(mount: MountKind, hasProducedFirstFrame: Bool) -> Double { 4 }
 static func automaticallyWaitsToMinimizeStalling(mount: MountKind) -> Bool { true }
}
#if os(tvOS)
enum HDRDisplayMode { static func reset(in: Int?) {} }
#endif
struct TerminalLatch { var hasEmitted = false; mutating func claim(generation: UInt64) -> Bool { if hasEmitted { return false }; hasEmitted = true; return true } }
struct NativePreflightState { mutating func didAttach(generation: UInt64, uptime: Double) {} }
final class FactoryPlan: @unchecked Sendable {
 let entered = DispatchSemaphore(value: 0)
 let release = DispatchSemaphore(value: 0)
 let lock = NSLock()
 let server = VortXRemuxHLSServer()
 var failed = false
 var mainMarker = false
 var markerBeforeRelease = false
 var request: String = ""
 var enteredFlag = false
 var made = false
 func mark() { lock.lock(); mainMarker = true; lock.unlock() }
 func releaseAfterMarkerWindow() { entered.wait(); Thread.sleep(forTimeInterval: 0.12); lock.lock(); markerBeforeRelease = mainMarker; lock.unlock(); release.signal() }
 func snapshot() -> (made: Bool, marker: Bool, before: Bool, request: String, entered: Bool) { lock.lock(); defer { lock.unlock() }; return(made,mainMarker,markerBeforeRelease,request,enteredFlag) }
}
final class FactoryStore: @unchecked Sendable {
 let lock = NSLock(); var plans: [String: FactoryPlan] = [:]
 func set(_ key: String, _ plan: FactoryPlan) { lock.lock(); plans[key]=plan; lock.unlock() }
 func get(_ key: String) -> FactoryPlan { lock.lock(); defer { lock.unlock() }; return plans[key]! }
}
final class TimeoutCounter: @unchecked Sendable {
 let lock = NSLock(); var value = 0
 func increment() { lock.lock(); value += 1; lock.unlock() }
 func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
final class VortXRemuxHLSServer: @unchecked Sendable {
 enum Mode { case plain, dolbyVision }
 static let store = FactoryStore()
 let port = 1234
 let lock = NSLock(); var starts = 0; var invalidations = 0
 var timeout: (@Sendable (VortXRemuxHLSServer) -> Void)?
 static func make(input: URL, headers: [String: String]?, mode: Mode, startAtSeconds: Double, selectedAudioStreamIndex: Int?, preferredAudioLanguages: [String]?, audioRejectTerms: [String]?, onStartupTimeout: @escaping @Sendable (VortXRemuxHLSServer) -> Void) -> (server: VortXRemuxHLSServer, playlistURL: URL)? {
  let plan = store.get(input.lastPathComponent)
  plan.lock.lock(); plan.request = "\(mode)|\(startAtSeconds)|\(selectedAudioStreamIndex ?? -1)|\(preferredAudioLanguages ?? [])|\(audioRejectTerms ?? [])|\(headers?["X-Test"] ?? "")"; plan.lock.unlock()
  plan.lock.lock(); plan.enteredFlag = true; plan.lock.unlock()
  plan.entered.signal(); plan.release.wait()
  plan.lock.lock(); plan.made = true; let failed = plan.failed; plan.lock.unlock()
  if failed { return nil }
  plan.server.timeout = onStartupTimeout
  return(plan.server, URL(string:"http://127.0.0.1:1234/master.m3u8")!)
 }
 func start() { lock.lock(); starts += 1; lock.unlock() }
 func invalidate() { lock.lock(); invalidations += 1; lock.unlock() }
 func snapshot() -> (Int,Int) { lock.lock(); defer { lock.unlock() }; return(starts,invalidations) }
}
/* HOLDER */
@MainActor final class FixtureEngine {
 var coldLocalRemuxPreparation: AVPlayerColdRemuxPreparation?
 var coldLocalRemuxMountTask: Task<Void,Never>?
 var remuxHLSServer: VortXRemuxHLSServer?
 var localRemuxPlaylistURL: URL?
 var activeLoadToken: PlayerLoadToken? = PlayerLoadToken()
 var itemGeneration: UInt64 = 1
 var fatalErrorEmitted = false
 var terminalLatch = TerminalLatch()
 var contentIsDolbyVision = false
 var isRemuxMounted: Bool { remuxHLSServer != nil }
 var forwardBufferMount: MountKind { .localRemux }
 var player = AVPlayer()
 var item: AVPlayerItem?
 var videoOutput: AVPlayerItemVideoOutput?
 var nativePreflightState = NativePreflightState()
 var attaches = 0; var errors: [String] = []; var rollback = false
 func observe(_ item: AVPlayerItem, loadToken: PlayerLoadToken) { attaches += 1 }
 func handleStatus(_ item: AVPlayerItem, loadToken: PlayerLoadToken) {}
 func recoverAudioReplacementIfNeeded(generation: UInt64, reason: String) -> Bool { rollback }
 func emit(_ name: String, _ message: String, loadToken: PlayerLoadToken) { errors.append(message) }
 #if os(tvOS)
 func beginNativeDVPreAttach(asset: AVURLAsset, item: AVPlayerItem, output: AVPlayerItemVideoOutput, loadToken: PlayerLoadToken, generation: UInt64) {}
 #endif
 /* METHODS */
 deinit { coldLocalRemuxPreparation?.cancel(); coldLocalRemuxMountTask?.cancel() }
}
#if !REAL_SDK
@main struct Tests {
 @MainActor static func waitFor(_ predicate: @MainActor () -> Bool) async { for _ in 0..<1000 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(2)) }; fatalError("async test deadline") }
 @MainActor static func launch(_ engine: FixtureEngine, key: String, timeout: @escaping @Sendable(VortXRemuxHLSServer)->Void = {_ in}) {
  engine.beginColdLocalRemuxMount(url:URL(string:"https://example.test/\(key)")!, headers:["X-Test":"captured"], wantsPlainRemux:true, wantsDVRemux:false, startAtSeconds:123, selectedAudioStreamIndex:7, preferredAudioLanguages:["hi","en"],audioRejectTerms:["commentary"],live:false,loadToken:engine.activeLoadToken!,generation:engine.itemGeneration,onStartupTimeout:timeout)
 }
 @MainActor static func main() async {
  let isBaseline = CommandLine.arguments.contains("baseline")
  var failures = 0; var count = 0
  func check(_ ok: Bool, _ name: String) { count += 1; print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
  let engine = FixtureEngine(); let plan = FactoryPlan(); VortXRemuxHLSServer.store.set("responsive",plan)
  let releaseTask = Task.detached { plan.releaseAfterMarkerWindow() }
  let timeoutCounter = TimeoutCounter()
  let start = Task { @MainActor in launch(engine,key:"responsive",timeout:{ _ in timeoutCounter.increment() }) }
  let marker = Task { @MainActor in await waitFor { plan.snapshot().entered }; plan.mark() }
  await start.value; await marker.value; await releaseTask.value
  await waitFor { engine.attaches == 1 }
  check(plan.snapshot().before,"main actor advances while factory remains blocked")
  print("WORKLOAD factory=1 mainActorMarkersBeforeRelease=\(plan.snapshot().before ? 1 : 0) producerStarts=\(plan.server.snapshot().0) attaches=\(engine.attaches)")
  check(plan.snapshot().request == "plain|123.0|7|[\"hi\", \"en\"]|[\"commentary\"]|captured","immutable input, origin, mode and audio preferences survive worker handoff")
  check(plan.server.snapshot().0 == 1 && engine.attaches == 1,"current mount starts and attaches once")
  plan.server.timeout?(plan.server)
  check(timeoutCounter.read() == 1,"original startup timeout callback reaches adopted cold mount")
  if isBaseline { print("BASELINE \(failures) failures / \(count) checks"); exit(failures == 1 ? 1 : 2) }

  let stopped = FixtureEngine(); let late = FactoryPlan(); VortXRemuxHLSServer.store.set("stopped",late)
  launch(stopped,key:"stopped"); await waitFor { late.snapshot().entered }
  stopped.cancelColdLocalRemuxPreparation(); stopped.activeLoadToken = nil; stopped.itemGeneration += 1
  late.release.signal(); await waitFor { late.snapshot().made && late.server.snapshot().1 == 1 }
  check(late.server.snapshot().0 == 0 && stopped.attaches == 0 && stopped.errors.isEmpty,"stop during factory disposes late listener without producer or event")

  let newer = FixtureEngine(); let oldPlan = FactoryPlan(); let newPlan = FactoryPlan()
  VortXRemuxHLSServer.store.set("old-generation",oldPlan); VortXRemuxHLSServer.store.set("new-generation",newPlan)
  launch(newer,key:"old-generation"); await waitFor { oldPlan.snapshot().entered }
  newer.itemGeneration += 1
  launch(newer,key:"new-generation"); await waitFor { newPlan.snapshot().entered }
  newPlan.release.signal(); await waitFor { newer.attaches == 1 }
  oldPlan.release.signal(); await waitFor { oldPlan.snapshot().made && oldPlan.server.snapshot().1 == 1 }
  check(oldPlan.server.snapshot().0 == 0 && newer.remuxHLSServer === newPlan.server && newer.attaches == 1,"same-token newer generation owns final attachment")

  let retired = FixtureEngine(); let retiredPlan = FactoryPlan(); VortXRemuxHLSServer.store.set("retired-generation",retiredPlan)
  launch(retired,key:"retired-generation"); await waitFor { retiredPlan.snapshot().entered }
  retired.itemGeneration += 1; retiredPlan.release.signal(); await waitFor { retiredPlan.server.snapshot().1 == 1 }
  check(retired.attaches == 0 && retiredPlan.server.snapshot().0 == 0,"generation fence rejects stale mount independently of cancellation")

  let failure = FixtureEngine(); let badPlan = FactoryPlan(); badPlan.failed=true; VortXRemuxHLSServer.store.set("failure",badPlan)
  launch(failure,key:"failure"); badPlan.release.signal(); await waitFor { failure.errors.count == 1 }
  check(failure.errors == ["Remux unavailable"] && failure.attaches == 0 && failure.fatalErrorEmitted,"current factory failure keeps typed fail-soft behavior")

  let rollback = FixtureEngine(); rollback.rollback=true; let rollbackPlan = FactoryPlan(); rollbackPlan.failed=true; VortXRemuxHLSServer.store.set("rollback",rollbackPlan)
  launch(rollback,key:"rollback"); rollbackPlan.release.signal(); await waitFor { rollback.coldLocalRemuxMountTask == nil }
  check(rollback.errors.isEmpty && !rollback.fatalErrorEmitted,"audio-replacement rollback precedes terminal mount failure")

  let fatal = FixtureEngine(); let fatalPlan = FactoryPlan(); VortXRemuxHLSServer.store.set("fatal",fatalPlan)
  launch(fatal,key:"fatal"); await waitFor { fatalPlan.snapshot().entered }
  fatal.terminalLatch.hasEmitted=true; fatalPlan.release.signal(); await waitFor { fatalPlan.server.snapshot().1 == 1 }
  check(fatal.attaches == 0 && fatalPlan.server.snapshot().0 == 0,"terminal generation cannot start late producer")

  var released: FixtureEngine? = FixtureEngine(); weak let weakReleased = released
  let releasedPlan = FactoryPlan(); VortXRemuxHLSServer.store.set("released",releasedPlan)
  launch(released!,key:"released"); await waitFor { releasedPlan.snapshot().entered }
  released=nil; releasedPlan.release.signal(); await waitFor { releasedPlan.server.snapshot().1 == 1 }
  check(weakReleased == nil && releasedPlan.server.snapshot().0 == 0,"engine deinit cancels pending listener without retaining UI owner")

  let owned = AVPlayerColdRemuxPreparation(); let takenServer = VortXRemuxHLSServer(); owned.publish((takenServer,URL(string:"http://127.0.0.1/")!)); let taken=owned.take(); owned.cancel()
  check(taken?.server === takenServer && owned.take() == nil && takenServer.snapshot().1 == 0,"transport ownership transfers once and later holder cancellation cannot invalidate owner")
  let buffered = AVPlayerColdRemuxPreparation(); let bufferedServer = VortXRemuxHLSServer(); buffered.publish((bufferedServer,URL(string:"http://127.0.0.1/")!)); buffered.cancel()
  check(buffered.take() == nil && bufferedServer.snapshot().1 == 1,"cancellation retires completed factory result before main actor adoption")
  print("CANDIDATE \(failures) failures / \(count) checks")
  exit(failures == 0 ? 0 : 1)
 }
}
#endif
