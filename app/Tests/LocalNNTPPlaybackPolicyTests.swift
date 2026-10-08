import Foundation

@main
enum LocalNNTPPlaybackPolicyTests {
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        precondition(value(), name)
        print("PASS \(name)")
    }

    typealias Recovery = LocalNNTPStallRecovery<Int>

    static func sample(
        _ position: Double? = 1.2, cache: Double? = 0, cachePaused: Bool? = true,
        playing: Bool = true, settled: Bool = true, seek: UInt64 = 0
    ) -> LocalNNTPPlaybackSample {
        .init(position: position, cachedAhead: cache, pausedForCache: cachePaused,
              playbackRequested: playing, seekSettled: settled, seekGeneration: seek)
    }

    static func freeze(_ policy: inout Recovery, owner: Int = 1, start: Double,
                       position: Double = 1.2, seek: UInt64 = 0) -> Recovery.Action {
        var result = Recovery.Action.generalWatchdog
        for seconds in stride(from: 0.0, through: 30, by: 6) {
            result = policy.observe(owner: owner, sample: sample(position, seek: seek), now: start + seconds)
            if seconds < 30 { check(result == .wait, "no failure before full starvation window at \(seconds)s") }
        }
        return result
    }

    static func main() throws {
        for host in ["127.0.0.1", "localhost", "[::1]"] {
            for path in ["/nzb/stream?key=synthetic", "/nzb/stream/synthetic/episode.mkv"] {
                let url = URL(string: "http://\(host):11470\(path)")!
                check(LocalNNTPBufferPolicy.isLocalNNTP(url), "recognizes local endpoint or filename on \(host)")
                check(LocalNNTPBufferPolicy.waitSeconds(url: url, live: false, preview: false) == 6,
                      "VOD gets six-second startup and rebuffer cushion")
                check(LocalNNTPBufferPolicy.waitSeconds(url: url, live: true, preview: false) == 1
                      && LocalNNTPBufferPolicy.waitSeconds(url: url, live: false, preview: true) == 1,
                      "live and ambient preview preserve fast profile")
            }
        }
        for text in [
            "http://127.0.0.1:11470/torrent", "http://127.0.0.1:11470/proxy",
            "http://127.0.0.1:11470/nzb/stream-other?key=k", "http://127.0.0.1/nzb/stream",
            "http://localhost/nzb/stream?key=", "http://localhost/nzb/stream?url=remote",
            "http://localhost/nzb/stream?key=k&url=remote", "http://localhost/nzb/stream/k",
            "http://localhost/nzb/stream/k/", "http://localhost/nzb/stream/k/a/b.mkv",
            "http://localhost/nzb/stream/k/a.mkv?url=remote", "http://localhost/nzb/stream//a.mkv",
            "http://localhost/nzb/stream/k/..", "http://localhost/nzb/stream/../a.mkv",
            "http://localhost/nzb/stream?key=k#fragment", "http://user:pass@localhost/nzb/stream?key=k",
            "https://cdn.example/nzb/stream?key=k", "http://192.168.1.10/nzb/stream?key=k",
            "http://localhost.example/nzb/stream?key=k", "file:///nzb/stream/k/a.mkv"
        ] {
            check(LocalNNTPBufferPolicy.waitSeconds(url: URL(string: text)!, live: false, preview: false) == 1,
                  "unrelated/malformed route retains standard profile: \(text)")
        }

        var policy = Recovery()
        check(freeze(&policy, start: 0) == .reload && policy.reloadUsed,
              "empty frozen route gets exactly one retry")
        // Live incident: each accepted reload first-framed at 0.034s and then froze again.
        check(freeze(&policy, owner: 2, start: 40, position: 0.034) == .failover,
              "first frame on same-source reload cannot replenish retry budget")

        var healthy = Recovery()
        for tick in 0...30 {
            check(healthy.observe(owner: 1, sample: sample(Double(tick) * 6, cache: 8, cachePaused: false),
                                  now: Double(tick) * 6) == .generalWatchdog,
                  "healthy advancing source is never classified as starvation")
        }
        check(!healthy.reloadUsed, "healthy source spends no local retry")

        var paused = Recovery()
        for tick in 0...4 { _ = paused.observe(owner: 1, sample: sample(), now: Double(tick) * 6) }
        check(paused.observe(owner: 1, sample: sample(playing: false), now: 30) == .wait,
              "viewer pause prevents recovery")
        check(paused.observe(owner: 1, sample: sample(playing: false), now: 600) == .wait && !paused.reloadUsed,
              "long intentional pause spends no retry")
        check(freeze(&paused, start: 606) == .reload, "resume earns a new full observation window")
        paused.suspend() // production viewerPause, pause echo, and stop/exit guards
        check(paused.reloadUsed, "pause/stop is not evidence of healing")
        check(freeze(&paused, owner: 2, start: 650) == .failover, "resume after brief restart retains spent budget")

        var seeking = Recovery()
        for tick in 0...4 { _ = seeking.observe(owner: 1, sample: sample(90), now: Double(tick) * 6) }
        check(seeking.observe(owner: 1, sample: sample(20, settled: false, seek: 1), now: 30) == .wait,
              "in-flight backward seek is not starvation")
        check(seeking.observe(owner: 1, sample: sample(20, settled: false, seek: 1), now: 600) == .wait,
              "unsettled seek never spends retry")
        check(freeze(&seeking, start: 606, position: 20, seek: 1) == .reload,
              "settled backward seek begins its own observation window")
        for tick in 0...4 { _ = seeking.observe(owner: 1, sample: sample(20, seek: 1), now: 650 + Double(tick) * 6) }
        check(seeking.observe(owner: 1, sample: sample(2, seek: 2), now: 680) == .wait,
              "seek completed between polls invalidates accumulated freeze")
        check(seeking.reloadUsed, "backward seek does not renew recovery budget")

        var renewed = Recovery()
        check(freeze(&renewed, start: 0) == .reload, "prepare spent retry for healthy renewal")
        for tick in 0...9 {
            _ = renewed.observe(owner: 2, sample: sample(Double(tick) * 6, cache: 8, cachePaused: false),
                                now: 40 + Double(tick) * 6)
        }
        check(renewed.reloadUsed, "54 seconds of playback is insufficient to renew retry")
        _ = renewed.observe(owner: 2, sample: sample(60, cache: 8, cachePaused: false), now: 100)
        check(!renewed.reloadUsed, "sixty seconds of continuous raw progress renews retry")
        check(freeze(&renewed, owner: 2, start: 106, position: 60) == .reload,
              "a later independent stall gets one retry after real recovery")

        var jump = Recovery()
        check(freeze(&jump, start: 0) == .reload, "prepare spent retry for discontinuity")
        _ = jump.observe(owner: 2, sample: sample(2, cache: 10, cachePaused: false), now: 40)
        _ = jump.observe(owner: 2, sample: sample(900, cache: 10, cachePaused: false), now: 46)
        check(jump.reloadUsed, "forward position jump cannot fake a minute of playback")
        for tick in 1...8 {
            _ = jump.observe(owner: 2, sample: sample(900 + Double(tick) * 6, cache: 10, cachePaused: false),
                             now: 46 + Double(tick) * 6)
        }
        _ = jump.observe(owner: 2, sample: sample(920, cache: 10, cachePaused: false, seek: 1), now: 100)
        for tick in 1...4 {
            _ = jump.observe(owner: 2, sample: sample(920 + Double(tick) * 6, cache: 10, cachePaused: false, seek: 1),
                             now: 100 + Double(tick) * 6)
        }
        check(jump.reloadUsed, "progress on both sides of a backward seek cannot combine into healthy renewal")
        jump = .init() // accepted manual source/episode replacement, and explicit Retry
        check(!jump.reloadUsed, "manual selection or new episode owns a new retry budget")

        var gradual = Recovery()
        for tick in 0...30 {
            check(gradual.observe(owner: 1, sample: sample(1 + Double(tick) * 0.1), now: Double(tick) * 6) == .wait,
                  "slow cumulative raw progress does not become false zero-progress proof")
        }
        check(!gradual.reloadUsed, "slow input spends no local retry without full frozen window")

        var unknown = Recovery()
        for invalid in [sample(nil), sample(.nan), sample(.infinity), sample(-1),
                        sample(cache: nil), sample(cache: .nan), sample(cache: -1), sample(cachePaused: nil)] {
            check(unknown.observe(owner: 1, sample: invalid, now: 0) == .generalWatchdog,
                  "unknown/invalid telemetry falls back to general recovery, never manufactured zero")
        }
        _ = unknown.observe(owner: 1, sample: sample(), now: 10)
        check(unknown.observe(owner: 1, sample: sample(), now: 500) == .wait && !unknown.reloadUsed,
              "suspended wall time cannot count as continuous starvation")
        check(unknown.observe(owner: 1, sample: sample(), now: 1) == .wait,
              "backwards clock starts fresh observation")

        // Call the production deferred-seek policy, not only its caller: an opening-seconds
        // nudge used to be issued by recovery and then silently cleared by this downstream gate.
        for target in [0.034, 2.0, 5.0] {
            check(DeferredResumePolicy.decision(targetSeconds: target, observedDurationSeconds: 1200,
                      engineDurationSeconds: 1200, deadlineReached: false) == .clear,
                  "ordinary short resume remains ignored at \(target)s")
            check(DeferredResumePolicy.decision(targetSeconds: target, observedDurationSeconds: 1200,
                      engineDurationSeconds: 1200, deadlineReached: false, allowShortResume: true) == .seek(to: target),
                  "local NNTP recovery actually seeks to exact opening position \(target)s")
        }
        check(DeferredResumePolicy.decision(targetSeconds: 2, observedDurationSeconds: 0,
                  engineDurationSeconds: 0, deadlineReached: false, allowShortResume: true) == .wait,
              "short recovery waits for source duration rather than clearing its target")
        check(DeferredResumePolicy.decision(targetSeconds: 2, observedDurationSeconds: 0,
                  engineDurationSeconds: 1200, deadlineReached: false, allowShortResume: true) == .seek(to: 2),
              "short recovery uses direct duration fallback")
        for invalid in [0.0, -1, .nan, .infinity] {
            check(DeferredResumePolicy.decision(targetSeconds: invalid, observedDurationSeconds: 1200,
                      engineDurationSeconds: 1200, deadlineReached: false, allowShortResume: true) == .clear,
                  "short-resume opt-in still rejects zero/invalid target")
        }
        check(DeferredResumePolicy.decision(targetSeconds: 2, observedDurationSeconds: 1200,
                  engineDurationSeconds: 1200, deadlineReached: true, allowShortResume: true) == .clear,
              "short-resume opt-in preserves deadline bound")
        check(DeferredResumeFloorPolicy.armedFloor(targetSeconds: 2) == nil,
              "ordinary short resume does not change persistence policy")
        let shortFloor = DeferredResumeFloorPolicy.armedFloor(targetSeconds: 2, allowShortResume: true)
        check(shortFloor == 2 && !DeferredResumeFloorPolicy.allowsPersistence(positionSeconds: 0.034, currentFloor: shortFloor),
              "local short resume protects saved position from opening-frame persistence")
        check(DeferredResumeFloorPolicy.floorAfterDecision(currentFloor: shortFloor, targetSeconds: 2,
                  decision: .seek(to: 2)) == 2,
              "issued short seek retains its floor until actual landing")
        check(DeferredResumeFloorPolicy.floorAfterAcceptedPlayback(currentFloor: shortFloor, positionSeconds: 2) == nil,
              "accepted short resume landing retires persistence floor")

        // Exercise wiring that cannot run in this dependency-free harness: pre-admission profile,
        // all-Apple compilation, raw ownership, real transport guards, and the existing resume/hop path.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let controller = try String(contentsOf: root.appendingPathComponent("Sources/Player/MPVMetalViewController.swift"), encoding: .utf8)
        let player = try String(contentsOf: root.appendingPathComponent("Sources/PlayerScreen.swift"), encoding: .utf8)
        func section(_ source: String, _ first: String, _ end: String) -> String {
            let start = source.range(of: first)!
            let finish = source.range(of: end, range: start.upperBound..<source.endIndex)!
            return String(source[start.lowerBound..<finish.lowerBound])
        }
        func insideTVOSOnly(_ needle: String) -> Bool {
            var gates: [String] = []
            for line in controller.components(separatedBy: .newlines) {
                let line = line.trimmingCharacters(in: .whitespaces)
                if line.contains(needle) { return gates.contains("#if os(tvOS)") }
                if line.hasPrefix("#if ") { gates.append(line) }
                if line.hasPrefix("#else"), !gates.isEmpty { gates[gates.count - 1] = "#else" }
                if line.hasPrefix("#endif"), !gates.isEmpty { gates.removeLast() }
            }
            preconditionFailure("missing source witness: \(needle)")
        }
        for needle in ["let nextCachePauseWait = LocalNNTPBufferPolicy", "cachePauseWaitSeconds = nextCachePauseWait",
                       "private var cachePauseWaitSeconds", "setString(\"cache-pause-wait\", priorCachePauseWait)"] {
            check(!insideTVOSOnly(needle), "Mac/iOS compile the NNTP buffer profile: \(needle)")
        }
        let beforeAdmission = section(controller, "let priorCachePauseInitial", "loadTokenLock.lock()")
        check(beforeAdmission.contains("setString(\"cache-pause-wait\", String(nextCachePauseWait))"),
              "cache cushion applies before load admission")
        let raw = section(controller, "func localNNTPPlaybackSample", "#if os(tvOS)")
        check(raw.contains("loadProvenance.callbackToken(requiresLoadedFile: true) == owner")
              && raw.contains("diagnosticDouble(MPVProperty.timePos") && raw.contains("seekSettlement.evidence("),
              "watchdog evidence uses exact loaded owner, raw clock, and settled seek generation")
        let watchdog = section(player, "private func startStallWatchdog()", "private func rearmAVStallWatchdogItemGenerationIfOwned")
        check(watchdog.contains("!playbackExited, !scrubbing, pendingAdvance == nil")
              && watchdog.contains("isPaused || playbackDeadlineClock.isPaused")
              && watchdog.contains("LocalNNTPBufferPolicy.isLocalNNTP(curURL ?? url)"),
              "stop, pause, scrubbing, pending episode, and URL scope guard the real watchdog")
        check(watchdog.contains("sample: mpv.localNNTPPlaybackSample(owner: owner)")
              && !watchdog.contains("sample: currentTime"), "UI resume floor cannot manufacture local progress")
        let failover = section(player, "private func recoverFromLocalNNTPStarvation", "private func recoverFromStall(")
        check(failover.contains("coordinator.player?.activeLoadToken == owner")
              && failover.contains("let resume = retryResumeTarget()")
              && failover.contains("hopToNextSource(reason: \"local NNTP repeated starvation\", resumeOverride: resume)"),
              "starvation failover revalidates owner and retains existing exact episode/resume routing")
        check(failover.contains("resume > 0, resume <= 5 { nudgeResume(to: resume, allowShortResume: true) }"),
              "even opening-seconds failover preserves the frozen resume position")
        let recovery = section(player, "private func recoverFromStall(", "/// Show a small transient notice")
        check(recovery.contains("nudgeResume(to: resume, allowShortResume: localNNTPStarvation)")
              && recovery.contains("nudgeResume(to: resume, allowShortResume: true)"),
              "accepted retry and rejected-retry hop opt in to exact short resume")
        let spentBudget = section(recovery, "guard stallRecoveries < 3 else", "// Repeated stalls on one source")
        check(spentBudget.contains("if localNNTPStarvation")
              && spentBudget.contains("recoverFromLocalNNTPStarvation(owner: owner)"),
              "exhausted generic budget retains local short-resume failover")
        let nudge = section(player, "private func nudgeResume(", "/// The pinned source for this title")
        check(nudge.contains("allowShortResume: Bool = false")
              && nudge.components(separatedBy: "allowShortResume: allowShortResume").count == 4,
              "per-call opt-in reaches real deferred policy and persistence floor without changing ordinary callers")
        for (first, end) in [("private func resetRuntimeForIssuedSourceSwitch", "private func resetRuntimeForIssuedEpisode"),
                             ("private func resetRuntimeForIssuedEpisode", "private func switchStream(")] {
            check(section(player, first, end).contains("localNNTPStallRecovery = .init()"),
                  "accepted manual source/episode replacement resets local retry budget")
        }
        print("Local NNTP playback policy and wiring: all checks passed")
    }
}
