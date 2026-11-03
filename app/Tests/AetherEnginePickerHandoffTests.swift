import Foundation

struct PlayerLoadToken: Equatable, Sendable { let id = UUID() }
@MainActor protocol SyntheticEngine: AnyObject {
    var activeLoadToken: PlayerLoadToken? { get }
    func setSpeed(_ speed: Double)
}
@MainActor final class Gate {
    var started = false
    var waiter: CheckedContinuation<Bool, Never>?
    var acknowledgement: CheckedContinuation<Void, Never>?
    func wait(timeout: Duration) async -> Bool {
        started = true; acknowledgement?.resume(); acknowledgement = nil
        return await withCheckedContinuation { waiter = $0 }
    }
    func awaitStart() async {
        if started { return }
        await withCheckedContinuation { acknowledgement = $0 }
    }
    func finish(_ result: Bool) { waiter!.resume(returning: result); waiter = nil }
}
@MainActor final class AVPlayerEngineController: SyntheticEngine {
    var activeLoadToken: PlayerLoadToken? = PlayerLoadToken()
    let gate = Gate()
    var stops = 0
    func stopForMPVFallback() -> Gate { stops += 1; activeLoadToken = nil; return gate }
    func setSpeed(_ speed: Double) { preconditionFailure("outgoing engine cannot receive incoming rate") }
}
@MainActor final class AetherEngineController: SyntheticEngine {
    var activeLoadToken: PlayerLoadToken? = PlayerLoadToken()
    var speeds: [Double] = []
    func setSpeed(_ speed: Double) { speeds.append(speed) }
}
@MainActor final class PollNotice {
    var observed = false
    var waiter: CheckedContinuation<Void,Never>?
    func signal() { observed = true; waiter?.resume(); waiter = nil }
    func awaitSignal() async {
        if observed { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
@MainActor final class Coordinator {
    private var current: (any SyntheticEngine)?
    var onRead: (() -> Void)?
    var player: (any SyntheticEngine)? {
        get { onRead?(); return current }
        set { current = newValue }
    }
}
struct AVToMPVHandoff: Equatable {
    let url: URL; let episodeGeneration: Int; let sourceGeneration: Int; let resumeGeneration: Int; let attemptID: String
    init(url: URL, episodeGeneration: Int, sourceGeneration: Int, resumeGeneration: Int, attemptID: String = "") {
        self.url = url; self.episodeGeneration = episodeGeneration; self.sourceGeneration = sourceGeneration
        self.resumeGeneration = resumeGeneration; self.attemptID = attemptID
    }
}
struct Transfer { let retiringOwner: PlayerLoadToken; let context: Int }
enum ContextEngine { case libmpv }
struct Deadline { var isPaused = true }
struct Recovery { var freshLinkInFlight = false }
// @source:handoffPolicy
@MainActor class Fixture {
    let coordinator = Coordinator()
    let url = URL(string: "https://example.invalid/active.mkv")!
    var curURL: URL?, curHeaders: [String:String]? = ["Synthetic": "header"]
    var episodeSwitchGeneration = 4, sourceSwitchGeneration = 8, resumeRetryGeneration = 2
    var canUseAetherEngine = true
    var reconnecting = false, autoRetryTask: Bool?
    var nativeDebridFreshLinkRecovery = Recovery()
    var pendingAdvance: Bool?, supersededAdvance: Bool?
    var hasUncommittedIssuedMedia = false
    var avToMPVHandoff: AVToMPVHandoff?, avToMPVHandoffBlocked = false
    var avToMPVHandoffTask: Task<Void,Never>?
    var aetherEngineSwitchReady: Bool { canUseAetherEngine && coordinator.player?.activeLoadToken != nil }
    var engineSurfaceTransfer: Transfer?
    var playbackDeadlineClock = Deadline()
    var pendingAudioReapply: String?, pendingSubtitleReapply: String?
    var userPickedSubtitle = true, hasStartedPlaying = true, resumeIsMidPlayRecovery = false
    var resumeSeconds: Double?
    var directAVNoFrameRecovery: Bool?, demotedEngineLoadToken: PlayerLoadToken?
    var avStartWatchdog: Task<Void,Never>?, loadTimeout: Task<Void,Never>?, libmpvResumeWatchdog: Task<Void,Never>?
    var engineSurfaceURLOverride: URL?, engineSurfaceHeadersOverride: [String:String]?, engineSurfaceUsesActiveTuple = false
    var avSurfaceResumeOrigin: Double?
    var appliedSize = true, appliedVolume = true, appliedAutoTracks = true, appliedResume = true, isSeekable = true, loadFailed = false
    var srcProbeLoadStart = Date(), avDemotedAt = Date(), engineSwitchedAt = Date()
    var addedSubURLs: [String] = [], addedPooledIDs: [String] = []
    var subtitleLoadingURL: String?, buffering = false, loadErrorMsg = "", firstFrameRenderedAt: Date?
    var pendingLibmpvResumeSeek: Double?, inFlightSeekTarget: Double?
    var bufferGraceUsed = 0, lastBufferedAtWatchdog = 0, bufferedTime = 0
    var aetherEngineFailed = true, engineLatch: Bool? = true, manualEngineAVPlayer: Bool? = true, avEngineFailed = false
    var playbackExited = false, leftPlayback = false
    var speed = 1.25, playSpeed = 1.25
    var mountAutomatically = true
    let mountPolling = PollNotice()
    var aetherLatch: Bool? { didSet {
        if aetherLatch == true && mountAutomatically {
            mounts += 1
            precondition(outgoing.gate.started && outgoing.gate.waiter == nil,
                         "Aether cannot mount before acknowledged AV producer retirement")
            coordinator.player = AetherEngineController()
        }
    } }
    var useAetherEngine: Bool { aetherLatch == true && manualEngineAVPlayer == nil && !aetherEngineFailed }
    var mounts = 0, watchdogs = 0, errors = 0
    var adopted: [PlayerLoadToken] = [], transferredOrigin: Double?, queuedPause: Bool?
    let outgoing = AVPlayerEngineController()
    init() {
        coordinator.player = outgoing
        coordinator.onRead = { [weak self] in
            guard let self, aetherLatch == true, !mountAutomatically else { return }
            // The real helper performs this read immediately before its 25ms sleep.
            mountPolling.signal()
        }
    }
    func adoptResumeSurfaceIfCurrent(loadToken: PlayerLoadToken) { adopted.append(loadToken) }
    func captureSelectedAudioChoice() -> String? { "English" }
    func captureSubtitleChoice() -> String? { "Selected subtitle" }
    func captureRecoverySelections() { pendingAudioReapply = captureSelectedAudioChoice(); pendingSubtitleReapply = captureSubtitleChoice() }
    func queueIncomingTransportIntent(paused: Bool) { queuedPause = paused }
    func resetRapidBufferingRecovery(reason: String) {}
    func retryResumeTarget() -> Double { 312 }
    func recoveryResumeTarget() -> Double { 312 }
    func resumeSurfaceContext(engine: ContextEngine) -> Int { 1 }
    func prepareResumeSurfaceTransfer(engine: ContextEngine, origin: Double) { transferredOrigin = origin }
    func invalidatePreparedEpisode(reason: String) {}
    func invalidateNextEpisodePreparation(reason: String) {}
    func cancelPostFrameResumeSeekWatchdog() {}
    func clearPostFrameResumeSeekWatchdog() {}
    func clearCachedAudioOutputTruth() {}
    func invalidateSubtitlePresentationForReplacement() {}
    func presentTerminalLoadFailure() { errors += 1 }
    func startLoadTimeout() { watchdogs += 1 }
}
@MainActor final class MacFixture: Fixture {
// @source:macHandoff
// @source:macMount
    func begin() { switchAVPlayerToAether() }
}
@MainActor final class TVFixture: Fixture {
// @source:tvHandoff
// @source:tvMount
    func begin() { switchAVPlayerToAether() }
}
@main @MainActor enum AetherEnginePickerHandoffTests {
    static var checks = 0
    static func check(_ result: Bool, _ message: String) {
        precondition(result,message); checks += 1; print("PASS \(message)")
    }
    static func exercise(_ fixture: Fixture, begin: () -> Void, invalidation: Int?) async {
        let owner = fixture.outgoing.activeLoadToken!
        begin(); await fixture.outgoing.gate.awaitStart()
        check(fixture.mounts == 0 && fixture.avToMPVHandoff != nil && fixture.outgoing.stops == 1,
              "outgoing producer is retired once and black barrier precedes any Aether mount")
        if let invalidation {
            switch invalidation {
            case 0: fixture.sourceSwitchGeneration += 1
            case 1: fixture.episodeSwitchGeneration += 1
            case 2: fixture.resumeRetryGeneration += 1
            case 3: fixture.curURL = URL(string:"https://example.invalid/successor")!
            case 4: fixture.playbackExited = true; fixture.leftPlayback = true
            case 5: fixture.canUseAetherEngine = false
            case 6: fixture.nativeDebridFreshLinkRecovery.freshLinkInFlight = true
            case 8: fixture.pendingAdvance = true
            case 9: fixture.supersededAdvance = true
            case 10: fixture.hasUncommittedIssuedMedia = true
            default: break
            }
        }
        fixture.outgoing.gate.finish(invalidation == 7 ? false : true)
        await fixture.avToMPVHandoffTask?.value
        if let invalidation {
            check(fixture.mounts == 0 && fixture.watchdogs == 0, "failed/stale handoff cannot mount or arm successor work")
            if invalidation >= 8 {
                check(fixture.errors == 0 && !fixture.avToMPVHandoffBlocked,
                      "new pending-media authority is not failed by a retired picker continuation")
            }
        } else {
            let incoming = fixture.coordinator.player as! AetherEngineController
            check(fixture.mounts == 1 && fixture.watchdogs == 1 && incoming.speeds == [1.25],
                  "acknowledged current handoff admits one Aether mount before rate and watchdog")
            check(incoming.activeLoadToken != owner && fixture.adopted.last == incoming.activeLoadToken,
                  "only fresh incoming owner is adopted")
            check(fixture.avSurfaceResumeOrigin == 312 && fixture.transferredOrigin == 312
                && fixture.engineSurfaceURLOverride == fixture.url && fixture.engineSurfaceHeadersOverride == fixture.curHeaders,
                  "current source headers and exact resume origin survive handoff")
            check(fixture.aetherLatch == true && fixture.manualEngineAVPlayer == nil && fixture.engineLatch == false,
                  "Aether route preserves libmpv fallback destination")
            check(fixture.pendingAudioReapply == "English" && fixture.pendingSubtitleReapply == "Selected subtitle",
                  "semantic subtitle and audio choices survive physical retirement")
        }
    }
    static func invalidateDuringMountPoll(_ fixture: Fixture, begin: () -> Void, reason: Int) async {
        fixture.mountAutomatically = false
        begin(); await fixture.outgoing.gate.awaitStart()
        fixture.outgoing.gate.finish(true)
        // This resumes only after the actual mount helper entered its polling body
        // and yielded into its sleep; it does not cancel before helper entry.
        await fixture.mountPolling.awaitSignal()
        check(fixture.mountPolling.observed && fixture.avToMPVHandoff == nil && fixture.watchdogs == 0,
              "actual replacement mount poll entered before cancellation")
        let successor = AetherEngineController()
        if reason == 1 {
            fixture.sourceSwitchGeneration += 1
            fixture.resumeRetryGeneration += 1
            fixture.curURL = URL(string:"https://example.invalid/new-source")!
            fixture.aetherLatch = false
            fixture.coordinator.player = successor
        } else if reason == 2 {
            fixture.playbackExited = true; fixture.leftPlayback = true
        }
        fixture.avToMPVHandoffTask?.cancel()
        await fixture.avToMPVHandoffTask?.value
        check(!fixture.avToMPVHandoffBlocked && fixture.errors == 0 && fixture.watchdogs == 0,
              "cancellation during mount sleep cannot publish stale terminal failure")
        if reason == 1 {
            check(fixture.coordinator.player === successor && successor.speeds.isEmpty,
                  "source switch during mount sleep retains its own player without old side effects")
        }
    }
    static func main() async {
        let mac = MacFixture(); await exercise(mac, begin:mac.begin, invalidation:nil)
        let tv = TVFixture(); await exercise(tv, begin:tv.begin, invalidation:nil)
        check(tv.queuedPause == true, "tvOS holds paused intent across handoff")
        for reason in 0...10 {
            let mac = MacFixture(); await exercise(mac, begin:mac.begin, invalidation:reason)
            let tv = TVFixture(); await exercise(tv, begin:tv.begin, invalidation:reason)
        }
        for reason in 0...2 {
            let mac = MacFixture(); await invalidateDuringMountPoll(mac, begin:mac.begin, reason:reason)
            let tv = TVFixture(); await invalidateDuringMountPoll(tv, begin:tv.begin, reason:reason)
        }
        print("\(checks) maintained AV-to-Aether handoff checks passed")
    }
}
