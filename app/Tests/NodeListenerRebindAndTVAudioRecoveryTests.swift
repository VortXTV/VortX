// Executable policy and source-contract tests for post-suspension listener recovery and tvOS same-source
// remount selection retention.
//
//   { printf '%s\n' 'import Foundation'; \
//     sed -n '/^enum NodeListenerRebindPolicy {/,/^\/\/ END Node listener rebind policy$/p' \
//       app/Sources/NodeServer.swift | sed '$d'; \
//     sed -n '/^enum TVTrackRecoveryPolicy {/,/^\/\/ END tvOS track recovery policy$/p' \
//       app/SourcesTV/TVPlayerView.swift | sed '$d'; } > /tmp/node-listener-rebind-policy.swift && \
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     /tmp/node-listener-rebind-policy.swift \
//     app/Sources/Player/MPVTrack.swift \
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

        guard case let .start(epoch: firstEpoch, attempt: firstAttempt, attemptID: attemptA) = state.observe(.refused, now: 0, cooldown: cooldown) else {
            check("first refusal starts recovery", false)
            finish()
            return
        }
        check("first refusal starts recovery", firstEpoch == 0 && firstAttempt == 1)
        check("concurrent duplicate is suppressed in flight", state.observe(.refused, now: 1, cooldown: cooldown) == .suppressInFlight)
        state.finishRebind(attemptA, relistened: false)
        check("failed same-episode duplicate is cooldown-suppressed", state.observe(.refused, now: 2, cooldown: cooldown) == .suppressDuplicate)

        var successfulState = NodeListenerRebindPolicy.State()
        guard case let .start(_, _, successfulAttemptA) = successfulState.observe(.refused, now: 0, cooldown: cooldown) else {
            check("confirmed relisten starts an owned attempt", false)
            finish()
            return
        }
        successfulState.finishRebind(successfulAttemptA, relistened: true)
        guard case let .start(epoch: freshEpoch, attempt: freshAttempt, attemptID: attemptB) = successfulState.observe(.refused, now: 22, cooldown: cooldown) else {
            check("confirmed relisten creates a fresh refusal epoch inside cooldown", false)
            finish()
            return
        }
        check("confirmed relisten creates a fresh refusal epoch inside cooldown", freshEpoch == 1 && freshAttempt == 2)
        successfulState.watchdogExpired(successfulAttemptA)
        successfulState.finishRebind(successfulAttemptA, relistened: false)
        check("late A watchdog and settle cannot retire B", successfulState.activeAttemptID == attemptB)
        successfulState.finishRebind(attemptB, relistened: false)
        guard case .start(epoch: 1, attempt: 3, attemptID: _) = successfulState.observe(.refused, now: 83, cooldown: cooldown) else {
            check("second failed attempt starts after same-episode cooldown", false)
            finish()
            return
        }
        check("second failed attempt starts after same-episode cooldown", true)
        successfulState.finishRebind(successfulState.activeAttemptID ?? 0, relistened: false)
        check("failed attempts cap truthfully", successfulState.observe(.refused, now: 144, cooldown: cooldown) == .exhausted(epoch: 1))

        var responseState = NodeListenerRebindPolicy.State()
        check("timeout never rebinds", responseState.observe(.timeoutOrOther, now: 0, cooldown: cooldown) == .ignore)
        check("non-refusal leaves a zero attempt budget", responseState.attempts == 0)
        check("response never rebinds", responseState.observe(.response, now: 1, cooldown: cooldown) == .ignore)
        check("response resets the attempt budget", responseState.attempts == 0)
        check("new wake resets a consumed failure budget", {
            var exhausted = NodeListenerRebindPolicy.State()
            if case let .start(_, _, id) = exhausted.observe(.refused, now: 0, cooldown: cooldown) { exhausted.finishRebind(id, relistened: false) }
            if case let .start(_, _, id) = exhausted.observe(.refused, now: 61, cooldown: cooldown) { exhausted.finishRebind(id, relistened: false) }
            if case let .start(_, _, id) = exhausted.observe(.refused, now: 122, cooldown: cooldown) { exhausted.finishRebind(id, relistened: false) }
            exhausted.beginNewWake()
            guard case .start(epoch: 1, attempt: 1, attemptID: _) = exhausted.observe(.refused, now: 123, cooldown: cooldown) else { return false }
            return exhausted.attempts == 1
        }())
        check("new wake invalidates old listener completion", {
            var wake = NodeListenerRebindPolicy.State()
            guard case let .start(_, _, oldAttempt) = wake.observe(.refused, now: 0, cooldown: cooldown) else { return false }
            wake.beginNewWake()
            wake.finishRebind(oldAttempt, relistened: true)
            return wake.activeAttemptID == nil && !wake.relistenConfirmedSinceRefusal
        }())
        check("stale onListen after terminal error cannot mark relisten", {
            var stale = NodeListenerRebindPolicy.State()
            guard case let .start(_, _, attempt) = stale.observe(.refused, now: 0, cooldown: cooldown) else { return false }
            stale.finishRebind(attempt, relistened: false)
            stale.finishRebind(attempt, relistened: true)
            return !stale.relistenConfirmedSinceRefusal
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
                "function __ownsAttempt(attemptID)",
                "function __retireAttempt(attemptID)",
                "function __beginFreshFailureAfterRelisten()",
                "if(!__rb.relistenConfirmed) return;",
                "__beginFreshFailureAfterRelisten();",
                "skip (same failure episode cooldown)",
                "__rb.relistenConfirmed=true"
            ]))

        let manualAudio = PlayerRecoveryAudioChoice(language: " EN ", title: "Main Mix")
        let audioTracks = [MPVTrack(id: 8, type: "audio", title: "main mix", lang: "en", selected: false)]
        let subtitleTracks = [MPVTrack(id: 17, type: "sub", title: "English", lang: "en", selected: false)]
        check("audio-first staged arrival retains pending embedded subtitle", TVTrackRecoveryPolicy.subtitleAction(
            choice: .embedded(lang: "en", title: "English"), tracks: [], pooledChoiceAvailable: false) == .retain)
        check("audio-first staged arrival restores manual audio", TVTrackRecoveryPolicy.audioAction(
            choice: manualAudio, tracks: audioTracks, automaticID: nil) == .reapply(8))
        check("later subtitle arrival restores exact embedded selection", TVTrackRecoveryPolicy.subtitleAction(
            choice: .embedded(lang: "en", title: "English"), tracks: subtitleTracks, pooledChoiceAvailable: false) == .selectEmbedded(17))
        check("subtitle-first staged arrival retains pending manual audio", TVTrackRecoveryPolicy.audioAction(
            choice: manualAudio, tracks: [], automaticID: nil) == .retain)
        check("subtitle-first staged arrival restores subtitle", TVTrackRecoveryPolicy.subtitleAction(
            choice: .embedded(lang: "en", title: "English"), tracks: subtitleTracks, pooledChoiceAvailable: false) == .selectEmbedded(17))
        check("later audio arrival restores exact manual audio", TVTrackRecoveryPolicy.audioAction(
            choice: manualAudio, tracks: audioTracks, automaticID: nil) == .reapply(8))
        check("manual subtitle Off is actionable before track discovery", TVTrackRecoveryPolicy.subtitleAction(
            choice: .off, tracks: [], pooledChoiceAvailable: false) == .applyImmediately)
        check("manual external subtitle is actionable before track discovery", TVTrackRecoveryPolicy.subtitleAction(
            choice: .external(url: "https://example.invalid/sub.vtt", title: "English", lang: "en"), tracks: [], pooledChoiceAvailable: false) == .applyImmediately)

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
