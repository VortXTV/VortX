// Executable policy and source-contract tests for post-suspension listener recovery and tvOS same-source
// remount selection retention.
//
//   { printf '%s\n' 'import Foundation'; \
//     sed -n '/^enum NodeListenerRebindPolicy {/,/^\/\/ END Node listener rebind policy$/p' \
//       app/Sources/NodeServer.swift | sed '$d'; } > /tmp/node-listener-rebind-policy.swift && \
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     /tmp/node-listener-rebind-policy.swift \
//     app/Sources/Player/PlayerStallPolicy.swift \
//     app/Tests/NodeListenerRebindAndTVAudioRecoveryTests.swift \
//     -o /tmp/node-listener-rebind-and-tv-audio-recovery-test && \
//   /tmp/node-listener-rebind-and-tv-audio-recovery-test

import Foundation

@MainActor private var failures = 0

@MainActor
private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func sourceContainsInOrder(_ source: String, _ needles: [String]) -> Bool {
    var cursor = source.startIndex
    for needle in needles {
        guard let range = source.range(of: needle, range: cursor..<source.endIndex) else { return false }
        cursor = range.upperBound
    }
    return true
}

@main
private enum NodeListenerRebindAndTVAudioRecoveryTests {
    @MainActor
    static func main() {
        let cooldown = 60.0
        var state = NodeListenerRebindPolicy.State()

        check("first refusal starts recovery", state.observe(.refused, now: 0, cooldown: cooldown) == .start(epoch: 0, attempt: 1))
        check("concurrent duplicate is suppressed in flight", state.observe(.refused, now: 1, cooldown: cooldown) == .suppressInFlight)
        state.finishRebind(relistened: false)
        check("failed same-episode duplicate is cooldown-suppressed", state.observe(.refused, now: 2, cooldown: cooldown) == .suppressDuplicate)

        state.finishRebind(relistened: true)
        check("confirmed relisten creates a fresh refusal epoch inside cooldown", state.observe(.refused, now: 22, cooldown: cooldown) == .start(epoch: 1, attempt: 2))
        state.finishRebind(relistened: false)
        check("second failed attempt starts after same-episode cooldown", state.observe(.refused, now: 83, cooldown: cooldown) == .start(epoch: 1, attempt: 3))
        state.finishRebind(relistened: false)
        check("failed attempts cap truthfully", state.observe(.refused, now: 144, cooldown: cooldown) == .exhausted(epoch: 1))

        var responseState = NodeListenerRebindPolicy.State()
        check("timeout never rebinds", responseState.observe(.timeoutOrOther, now: 0, cooldown: cooldown) == .ignore)
        check("non-refusal leaves a zero attempt budget", responseState.attempts == 0)
        check("response never rebinds", responseState.observe(.response, now: 1, cooldown: cooldown) == .ignore)
        check("response resets the attempt budget", responseState.attempts == 0)
        check("new wake resets a consumed failure budget", {
            var exhausted = NodeListenerRebindPolicy.State()
            _ = exhausted.observe(.refused, now: 0, cooldown: cooldown); exhausted.finishRebind(relistened: false)
            _ = exhausted.observe(.refused, now: 61, cooldown: cooldown); exhausted.finishRebind(relistened: false)
            _ = exhausted.observe(.refused, now: 122, cooldown: cooldown); exhausted.finishRebind(relistened: false)
            exhausted.beginNewWake()
            return exhausted.attempts == 0 && exhausted.observe(.refused, now: 123, cooldown: cooldown) == .start(epoch: 1, attempt: 1)
        }())

        let nodeSourcePath = "app/Sources/NodeServer.swift"
        guard let nodeSource = try? String(contentsOfFile: nodeSourcePath, encoding: .utf8),
              let preloadStart = nodeSource.range(of: "var __rb={busy:false,lastAttemptAt:0"),
              let preloadEnd = nodeSource.range(of: "// Event-loop heartbeat", range: preloadStart.upperBound..<nodeSource.endIndex) else {
            failures += 1
            print("FAIL  Node listener rebind preload source contract readable")
            finish()
            return
        }
        let preload = String(nodeSource[preloadStart.lowerBound..<preloadEnd.lowerBound])
        check(
            "Node preload opens a new refusal epoch only after confirmed relisten",
            sourceContainsInOrder(preload, [
                "function __beginFreshFailureAfterRelisten()",
                "if(!__rb.relistenConfirmed) return;",
                "__beginFreshFailureAfterRelisten();",
                "skip (same failure episode cooldown)",
                "__rb.relistenConfirmed=true"
            ]))

        let manualAudio = PlayerRecoveryAudioChoice(language: " EN ", title: "Main Mix")
        let newTrackID = PlayerRecoveryAudioChoice.matchingID(
            for: manualAudio,
            in: [
                .init(id: 8, language: "en", title: "main mix", selectable: true),
                .init(id: 9, language: "en", title: "commentary", selectable: true)
            ])
        check("manual audio is re-identified semantically on a new mount", newTrackID == 8)

        let tvSourcePath = "app/SourcesTV/TVPlayerView.swift"
        guard let tvSource = try? String(contentsOfFile: tvSourcePath, encoding: .utf8),
              let start = tvSource.range(of: "private func healLoopbackMountOnForeground"),
              let end = tvSource.range(of: "private func recoverFromStall", range: start.upperBound..<tvSource.endIndex) else {
            failures += 1
            print("FAIL  tvOS loopback remount source contract readable")
            finish()
            return
        }
        let remount = String(tvSource[start.lowerBound..<end.lowerBound])
        check(
            "tvOS remount snapshots manual audio before resetting track selection",
            sourceContainsInOrder(remount, [
                "pendingAudioReapply = captureSelectedAudioChoice()",
                "pendingSubtitleReapply = userPickedSubtitle ? captureSubtitleChoice() : nil",
                "appliedResume = false; appliedAutoTracks = false"
            ]))
        check(
            "rejected tvOS remount clears both snapshots because the old mount survives",
            sourceContainsInOrder(remount, [
                "pendingAudioReapply = nil",
                "pendingSubtitleReapply = nil",
                "return"
            ]))
        finish()
    }

    @MainActor
    private static func finish() {
        print("")
        if failures == 0 { print("ALL PASS") }
        else { print("\(failures) FAILED"); exit(1) }
    }
}
