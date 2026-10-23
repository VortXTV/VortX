import Foundation

@MainActor private var failures = 0
@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

@main @MainActor private enum ApplePlaybackProfileLifecycleTests {
    static func profile(live: Bool, shed: Bool = false) -> [String: NativeValue] {
        ["demuxer-readahead-secs": .scalar(live ? "18" : "300"),
         "demuxer-max-back-bytes": .scalar(live || shed ? "8MiB" : "24MiB"),
         "demuxer-lavf-o": .map(live ? ["live_start_index": "-3"] : [:]),
         "stream-lavf-o": .map(live
            ? ["reconnect": "1", "reconnect_streamed": "0", "reconnect_delay_max": "1"]
            : ["reconnect": "1", "reconnect_streamed": "1", "reconnect_delay_max": "7", "multiple_requests": "1"]),
         "cache-pause-initial": .scalar("no"), "cache-pause-wait": .scalar("1")]
    }

    static func loadTests() {
        let port = NativePort.shared
        for fromLive in [false, true] {
            for toLive in [false, true] {
                for accepted in [false, true] {
                    let old = profile(live: fromLive, shed: true)
                    port.values = old; port.writes = []; port.commands = 0
                    port.commandStatus = accepted ? 0 : -1; port.missingReads = []
                    let player = MPVMetalViewController(); player.configuredLiveMode = fromLive
                    _ = player.loadProfile(live: toLive)
                    let label = "\(fromLive ? "live" : "VOD")->\(toLive ? "live" : "VOD") \(accepted ? "accepted" : "rejected")"
                    check("\(label) executes loadfile", port.commands == 1)
                    let incoming = profile(live: toLive)
                    check("\(label) incoming profile reaches command",
                          port.valuesAtCommand["demuxer-readahead-secs"] == incoming["demuxer-readahead-secs"] &&
                          port.valuesAtCommand["stream-lavf-o"] == incoming["stream-lavf-o"])
                    if accepted {
                        check("\(label) keeps incoming mode", player.configuredLiveMode == toLive)
                        check("\(label) cache pause committed", port.values["cache-pause-wait"] == .scalar("6.0"))
                        check("\(label) normal/small back buffer", port.values["demuxer-max-back-bytes"] == .scalar(toLive ? "8MiB" : "24MiB"))
                    } else {
                        check("\(label) restores exact outgoing options including 8MiB shed", port.values == old)
                        check("\(label) restores mode", player.configuredLiveMode == fromLive)
                        check("\(label) leaves pause and accepted cap bookkeeping", player.paused && player.activeReadAheadCap == "old" && player.pausedCacheClamped)
                    }
                }
            }
        }
        var custom = profile(live: false, shed: true)
        custom["stream-lavf-o"] = .map(["protocol_whitelist": "file,http,https,tcp,tls", "custom": "a=b,\"quoted\""])
        port.values = custom; port.commandStatus = -1
        _ = MPVMetalViewController().loadProfile(live: true)
        check("rejected load restores native maps without reparsing commas equals or quotes", port.values == custom)

        for missing in ["demuxer-readahead-secs", "demuxer-max-back-bytes", "demuxer-lavf-o", "stream-lavf-o", "cache-pause-initial", "cache-pause-wait"] {
            port.values = custom; port.writes = []; port.commands = 0; port.missingReads = [missing]
            let player = MPVMetalViewController()
            _ = player.loadProfile(live: true)
            check("unreadable but writable \(missing) refuses before mutation", port.values == custom && port.writes.isEmpty && port.commands == 0 && !player.configuredLiveMode)
        }
        port.missingReads = []; port.values = custom; port.writes = []; port.commands = 0
        let stopped = MPVMetalViewController(); stopped.mpv = nil
        _ = stopped.loadProfile(live: true)
        check("nil native handle cannot mutate profile or issue load", port.values == custom && port.writes.isEmpty && port.commands == 0 && !stopped.configuredLiveMode)
    }

    static func idleTests() {
        let a = IdlePresentation(), b = IdlePresentation()
        a.appear()
        check("actual A appear disables idle", UIApplication.shared.isIdleTimerDisabled)
        b.appear(); a.disappear()
        check("actual A appear B appear A disappear preserves B idle lease", UIApplication.shared.isIdleTimerDisabled)
        b.disappear()
        check("actual current B disappear releases idle", !UIApplication.shared.isIdleTimerDisabled)
        b.disappear()
        check("duplicate disappear remains released", !UIApplication.shared.isIdleTimerDisabled)
    }

    static func handoffTests() async {
        for tv in [false, true] {
            for scenario in ["half", "double", "edited", "paused", "playing", "cancelled", "failed", "controller", "token", "episode", "source", "resume", "url", "exit", "blocked", "attempt"] {
                let owner: HandoffCollaborators = tv ? TVHandoff() : IOSHandoff()
                let player = MPVMetalViewController()
                let token = PlayerLoadToken(); player.activeLoadToken = token
                player.paused = scenario != "playing"
                owner.coordinator.player = player
                owner.speed = scenario == "double" ? 2 : 0.5
                owner.playSpeed = owner.speed
                let task = Task { @MainActor in
                    if let tv = owner as? TVHandoff { await tv.run() }
                    else if let ios = owner as? IOSHandoff { await ios.run() }
                }
                while owner.mountWaiter == nil { await Task.yield() }
                // Mutate while the actual extracted caller is suspended at its production await. Return
                // a retained old controller/token even for stale routes to exercise final admission.
                switch scenario {
                case "edited": owner.speed = 2; owner.playSpeed = 2
                case "cancelled": task.cancel()
                case "controller": owner.coordinator.player = MPVMetalViewController()
                case "token": player.activeLoadToken = PlayerLoadToken()
                case "episode": owner.episodeSwitchGeneration += 1
                case "source": owner.sourceSwitchGeneration += 1
                case "resume": owner.resumeRetryGeneration += 1
                case "url": owner.curURL = URL(string: "https://example.invalid/new")!
                case "exit": owner.playbackExited = true; owner.leftPlayback = true
                case "blocked": owner.avToMPVHandoffBlocked = true
                case "attempt":
                    if let tv = owner as? TVHandoff { tv.replaceAttempt() }
                    if let ios = owner as? IOSHandoff { ios.replaceAttempt() }
                default: break
                }
                owner.completeMount(scenario == "failed" ? nil : (player, token))
                await task.value
                let admitted = ["half", "double", "edited", "paused", "playing"].contains(scenario)
                let expectedRate = scenario == "edited" || scenario == "double" ? 2.0 : 0.5
                check("\(tv ? "tvOS" : "iOS") \(scenario) actual continuation rate ownership",
                      player.appliedRates == (admitted ? [expectedRate] : []))
                check("\(tv ? "tvOS" : "iOS") \(scenario) speed preserves transport pause", player.paused == (scenario != "playing"))
                check("\(tv ? "tvOS" : "iOS") \(scenario) terminal ownership",
                      owner.terminalFailures == (tv && scenario == "token" ? 1 : 0))
                if !admitted { check("\(tv ? "tvOS" : "iOS") \(scenario) no stale resume adoption", owner.adopted.isEmpty) }
            }
        }
    }

    static func main() async {
        loadTests(); idleTests(); await handoffTests()
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        if failures != 0 { Foundation.exit(1) }
    }
}
