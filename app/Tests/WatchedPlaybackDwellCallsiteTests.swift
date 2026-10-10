import Foundation

// MODELS
// Only the clock and effect ports are inert; watched and exit methods are extracted verbatim.
private var clock = 0.0
private struct ProcessInfo {
    static var processInfo: ProcessInfo { ProcessInfo() }
    var systemUptime: Double { clock }
}
private struct Date { var timeIntervalSinceReferenceDate: Double { clock } }
private struct Meta {
    var libraryId = "fixture-title"
    var videoId = "fixture-episode"
    var usesSeriesLifecycle = false
}
private final class Core {
    var marks = 0
    var finishes = 0
    func markPlaybackWatched(_ meta: Meta, target: Int, allowEngineWrite: Bool) { marks += 1 }
    func finishedWatching(libraryId: String, target: Int) { finishes += 1 }
}
private struct Sanity { var accepted = true; func isAccepted(owner: PlayerLoadToken?) -> Bool { accepted } }
private final class Player { var activeLoadToken: PlayerLoadToken? = PlayerLoadToken() }
private struct Coordinator { var player: Player? = Player() }
private struct Gate { var permitsExitProgressFlush = true; mutating func issueTerminalRewind() -> Bool { permitsExitProgressFlush = false; return true } }
private enum EpisodePlaybackIdentity { static func engineWritesAllowed(boundVideoID: String?, displayedVideoID: String) -> Bool { true } }

private class State {
    var coordinator = Coordinator()
    var committedLoadToken: PlayerLoadToken? { coordinator.player?.activeLoadToken }
    var pendingAdvance: Int? = nil
    var supersededAdvance: Int? = nil
    var core = Core()
    var curMeta: Meta? = Meta()
    var assetSanityAttempt = Sanity()
    var markedWatched = false
    var watchedZoneSince: Double?
    var watchedDwell = WatchedPlaybackDwell<PlayerLoadToken>()
    var episodeSwitchGeneration = 0
    var sourceSwitchGeneration = 0
    var playbackMutationTarget = 0
    var engineWritesOpen = true
    var enginePlayerVideoId: String? = "fixture-episode"
    var isEpisodePlaybackContext = false
    var effectivelyLive = false
    var isCurrentLiveStream = false
    var scrubbing = false
    var isPaused = false
    var buffering = false
    var hasStartedPlaying = true
    var speed = 1.0
    var playSpeed = 1.0
    var duration = 1000.0
    var currentTime = 0.0
    var persistenceBlockedForExit = false
    var terminalRewindGate = Gate()
    func sample(_ seconds: Double, at now: Double, settled: Bool = true, owner: PlayerLoadToken? = nil,
                evidence: MPVSeekSettlementEvidence? = nil) {
        clock = now
        currentTime = seconds
        evaluate(PlayerTimePositionEvent(seconds: seconds, loadToken: owner ?? coordinator.player!.activeLoadToken!, mpvSeekSettlement: evidence, positionSettled: settled))
    }
    func resetCandidate() { watchedDwell.reset() }
    func evaluate(_ event: PlayerTimePositionEvent) { fatalError("abstract") }
    func eof() { fatalError("abstract") }
    func exit() {
        let assetSanityAccepted = assetSanityAttempt.accepted
        // EXIT_MARK
    }
}
private final class IOS: State {
    override func evaluate(_ event: PlayerTimePositionEvent) { updateWatchedDwell(with: event) }
    // IOS_METHOD
    override func eof() {
        // IOS_EOF
    }
}
private final class TV: State {
    override func evaluate(_ event: PlayerTimePositionEvent) { updateWatchedDwell(with: event) }
    // TV_METHOD
    override func eof() {
        // TV_EOF
    }
}

@main private enum Tests {
    static var failures = 0
    static var currentImplementation = NEW_IMPLEMENTATION
    static func expect(_ condition: Bool, _ label: String) {
        if !condition { print("FAIL: \(label)"); failures += 1 }
    }
    static func flowing(_ s: State, from start: Double = 0, position: Double = 900, count: Int = 5) {
        for i in 0...count { s.sample(position + Double(i), at: start + Double(i)) }
    }
    static func main() {
        if !currentImplementation {
            // The baseline receipt is intentionally limited to concrete source
            // defects, not new policy invariants whose old outer reset/admission
            // paths are not executed by this inert marker extraction.
            let single = IOS(); single.sample(950, at: 0)
            expect(single.core.marks == 0, "iOS/macOS single settled late tick must not mark watched")
            single.exit(); expect(single.core.finishes == 0, "iOS/macOS single late tick exit must retain CW")
            let provisional = IOS(); provisional.duration = 10; provisional.sample(9.5, at: 0); provisional.exit()
            expect(provisional.core.marks == 0 && provisional.core.finishes == 0, "iOS/macOS provisional duration must not complete film")
            let scrub = IOS(); scrub.scrubbing = true; scrub.sample(950, at: 0)
            expect(scrub.core.marks == 0, "existing iOS/macOS scrub guard remains intact")
            scrub.exit(); expect(scrub.core.finishes == 0, "iOS/macOS scrub-preview exit must retain CW")
            let paused = TV(); paused.sample(900, at: 0); paused.isPaused = true; paused.sample(900, at: 5)
            expect(paused.core.marks == 0, "tvOS pause must not accrue dwell")
            let gap = TV(); gap.sample(900, at: 0); gap.sample(906, at: 6)
            expect(gap.core.marks == 0, "tvOS silent callback gap must not accrue dwell")
            let frozen = TV(); for i in 0...6 { frozen.sample(950, at: Double(i)) }
            expect(frozen.core.marks == 0, "tvOS frozen position must not accrue dwell")
            finish()
            return
        }
        for make: () -> State in [{ IOS() }, { TV() }] {
            let name = String(describing: type(of: make()))
            let single = make(); single.sample(950, at: 0)
            expect(single.core.marks == 0, "\(name) one late tick is not watched")
            if single is IOS { single.exit(); expect(single.core.finishes == 0, "\(name) early film exit retains CW") }
            let provisional = make(); provisional.duration = 10; provisional.sample(9.5, at: 0)
            if provisional is IOS { provisional.exit() }
            expect(provisional.core.marks == 0 && provisional.core.finishes == 0, "\(name) provisional duration does not complete film")
            let scrub = make(); scrub.scrubbing = true; flowing(scrub)
            if scrub is IOS { scrub.exit() }
            expect(scrub.core.marks == 0 && scrub.core.finishes == 0, "\(name) scrubbing and early exit retain CW")
            let paused = make(); paused.sample(900, at: 0); paused.isPaused = true; paused.sample(900, at: 5)
            paused.isPaused = false; paused.sample(901, at: 6)
            expect(paused.core.marks == 0, "\(name) pause does not accrue dwell")
            let gap = make(); gap.sample(900, at: 0); gap.sample(906, at: 6)
            expect(gap.core.marks == 0, "\(name) callback gap does not accrue dwell")
            let frozen = make(); for i in 0...6 { frozen.sample(950, at: Double(i)) }
            expect(frozen.core.marks == 0, "\(name) frozen position is not flowing")
            let unset = make(); for i in 0...6 { unset.sample(900 + Double(i), at: Double(i), settled: false) }
            expect(unset.core.marks == 0, "\(name) optimistic targets are not watching")
            let stable = make(); flowing(stable)
            expect(stable.core.marks == 1, "\(name) five seconds genuine advancement marks once")
            stable.sample(906, at: 6); expect(stable.core.marks == 1, "\(name) marks once")
            if stable is IOS { stable.exit(); expect(stable.core.finishes == 1, "\(name) proven film exit removes CW") }
            let rewind = make(); flowing(rewind); rewind.currentTime = 100
            if rewind is IOS { rewind.exit(); expect(rewind.core.finishes == 0 && rewind.terminalRewindGate.permitsExitProgressFlush, "\(name) watched film rewind retains new resume progress") }
            let eof = make(); eof.duration = 2; eof.currentTime = 2; eof.eof()
            if eof is IOS { eof.exit(); expect(eof.core.finishes == 1, "\(name) true EOF film exit removes CW") }
            expect(eof.core.marks == 1, "\(name) true EOF still completes short film")
            let series = make(); series.curMeta?.usesSeriesLifecycle = true; flowing(series); series.exit()
            expect(series.core.finishes == 0, "\(name) series exit does not dismiss series CW")
            let reenter = make(); flowing(reenter, count: 3); reenter.sample(800, at: 4); reenter.sample(900, at: 5); reenter.sample(901, at: 6)
            expect(reenter.core.marks == 0, "\(name) leaving zone resets dwell")
            let duration = make(); flowing(duration, count: 3); duration.duration = 1001; duration.sample(904, at: 4); duration.sample(905, at: 5)
            expect(duration.core.marks == 0, "\(name) changing duration resets dwell")
            let episode = make(); flowing(episode, count: 3); episode.curMeta?.videoId = "replacement"; episode.sample(904, at: 4); episode.sample(905, at: 5)
            expect(episode.core.marks == 0, "\(name) episode change resets dwell")
            let source = make(); flowing(source, count: 3); source.sourceSwitchGeneration += 1; source.sample(904, at: 4); source.sample(905, at: 5)
            expect(source.core.marks == 0, "\(name) source change resets dwell")
            let owner = make(); flowing(owner, count: 3); owner.coordinator.player?.activeLoadToken = PlayerLoadToken(); owner.sample(904, at: 4); owner.sample(905, at: 5)
            expect(owner.core.marks == 0, "\(name) load change resets dwell")
            let invalid = make(); flowing(invalid, count: 3); invalid.sample(.nan, at: 4); invalid.sample(905, at: 5)
            expect(invalid.core.marks == 0, "\(name) invalid position resets dwell")
            let buffering = make(); flowing(buffering, count: 3); buffering.buffering = true; buffering.sample(904, at: 4); buffering.buffering = false; buffering.sample(905, at: 5)
            expect(buffering.core.marks == 0, "\(name) buffering resets dwell")
            let live = make(); live.effectivelyLive = true; live.isCurrentLiveStream = true; flowing(live)
            expect(live.core.marks == 0, "\(name) live excluded")
            let speed = make(); speed.speed = 2; speed.playSpeed = 2
            for i in 0...5 { speed.sample(900 + 2 * Double(i), at: Double(i)) }
            expect(speed.core.marks == 1, "\(name) two-times playback needs five real seconds")
            let slow = make(); slow.speed = 0.5; slow.playSpeed = 0.5
            for i in 0...5 { slow.sample(900 + 0.5 * Double(i), at: Double(i)) }
            expect(slow.core.marks == 1, "\(name) half-speed genuine advancement qualifies")
            let tiny = make(); for i in 0...6 { tiny.sample(900 + 0.1 * Double(i), at: Double(i)) }
            expect(tiny.core.marks == 0, "\(name) stalled trickle not credited wall-clock dwell")
            let jump = make(); flowing(jump, count: 3); jump.sample(980, at: 4); jump.sample(981, at: 5)
            expect(jump.core.marks == 0, "\(name) seek-sized jump resets")
            let seek = make()
            for i in 0...5 {
                seek.sample(900 + Double(i), at: Double(i), evidence: .init(generation: i < 4 ? 1 : 2, settled: true))
            }
            expect(seek.core.marks == 0, "\(name) native seek generation resets")
            let physical = make()
            for i in 0...5 {
                physical.sample(900 + Double(i), at: Double(i), evidence: .init(generation: 7, settled: true, attributed: false))
            }
            expect(physical.core.marks == 1, "\(name) observed physical playback does not fabricate command attribution")
            let pauseBetween = make(); flowing(pauseBetween, count: 3); pauseBetween.resetCandidate()
            pauseBetween.sample(904, at: 4); pauseBetween.sample(905, at: 5)
            expect(pauseBetween.core.marks == 0, "\(name) pause/seek/scrub between ticks resets")
            flowing(pauseBetween, from: 6, position: 906)
            expect(pauseBetween.core.marks == 1, "\(name) resumed genuine advancement can qualify")
            // Directly exercise new helper admission, without claiming the old
            // extracted marker bypassed all surrounding startup/episode guards.
            if currentImplementation {
                let unaccepted = make(); unaccepted.assetSanityAttempt.accepted = false; flowing(unaccepted)
                expect(unaccepted.core.marks == 0, "\(name) asset sanity admission required")
                let notStarted = make(); notStarted.hasStartedPlaying = false; flowing(notStarted)
                expect(notStarted.core.marks == 0, "\(name) real playback start required")
                let pending = make(); pending.pendingAdvance = 1; flowing(pending)
                expect(pending.core.marks == 0, "\(name) pending episode cannot mark old metadata")
            }
            let stale = make(); let staleOwner = PlayerLoadToken()
            for i in 0...5 { stale.sample(900 + Double(i), at: Double(i), owner: staleOwner) }
            expect(stale.core.marks == 0, "\(name) stale owner rejected")
            for bad in [Double.nan, Double.infinity, 0, -1] {
                let invalidDuration = make(); invalidDuration.duration = bad; flowing(invalidDuration)
                expect(invalidDuration.core.marks == 0, "\(name) invalid duration rejected")
            }
            let overshoot = make(); overshoot.sample(1100, at: 0); overshoot.sample(1105, at: 5)
            expect(overshoot.core.marks == 0, "\(name) provisional short duration overshoot rejected")
        }
        finish()
    }
    static func finish() {
        if failures > 0 { print("RED: \(failures) watched/exit assertions"); Foundation.exit(1) }
        print("PASS: actual iOS/macOS and tvOS watched/EOF/film-exit methods")
    }
}
