// Focused executable harness for the position-driven automatic-skip policy.
//
//     swiftc -o /tmp/vortx-auto-skip-tests \
//         app/Sources/Player/SkipSegments.swift \
//         app/Tests/AutoSkipCountdownPolicyTests.swift \
//     && /tmp/vortx-auto-skip-tests

import Foundation

@MainActor private var failures = 0

@MainActor private func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func intro(start: Double = 5, end: Double = 42) -> SkipSegment {
    SkipSegment(kind: .intro, start: start, end: end)
}

@main
@MainActor
enum AutoSkipCountdownPolicyTests {
    static func main() {
        countdownUsesFiveActivePlaybackSeconds()
        pauseAndBufferingDoNotSpendTime()
        cancellationIsPerSegmentAndPermanentForTheMedia()
        seekOutsideInvalidatesPendingDecision()
        targetEndIsClampedToDuration()
        sourceRebindRetainsMediaMemoryButNewMediaResetsIt()
        staleButtonOwnershipCannotAffectAnIdenticalSegment()
        settingsMigrationPreservesExplicitOffAndDefaultsNewInstallsOn()

        print("")
        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILED")
            Foundation.exit(1)
        }
    }

    private static func staleButtonOwnershipCannotAffectAnIdenticalSegment() {
        let segment = intro()
        var state = AutoSkipCountdownState()
        _ = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-A", segment: segment, position: 5,
            playbackActive: true, delaySeconds: 5
        )
        let oldEpoch = state.epoch
        _ = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-B", segment: segment, position: 5,
            playbackActive: true, delaySeconds: 5
        )
        check(!AutoSkipCountdownPolicy.isCurrent(
            state: state, mediaID: "episode-A", segment: segment, epoch: oldEpoch
        ), "an old button cannot act on an identical segment in a new episode")
        let beforeRebind = state.epoch
        AutoSkipCountdownPolicy.invalidatePending(state: &state, position: 5)
        _ = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-B", segment: segment, position: 5,
            playbackActive: true, delaySeconds: 5
        )
        check(!AutoSkipCountdownPolicy.isCurrent(
            state: state, mediaID: "episode-B", segment: segment, epoch: beforeRebind
        ), "a same-media source rebind invalidates a previously rendered button")
        check(AutoSkipCountdownPolicy.isCurrent(
            state: state, mediaID: "episode-B", segment: segment, epoch: state.epoch
        ), "the current rendered button retains its exact media and source epoch")
    }

    private static func countdownUsesFiveActivePlaybackSeconds() {
        let segment = intro()
        var state = AutoSkipCountdownState()
        let first = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-1", segment: segment, position: 5,
            playbackActive: true, delaySeconds: 5
        )
        check(first == .prompt(segment: AutoSkipSegmentKey(segment: segment), remainingSeconds: 5),
              "entry shows the full five-second prompt and does not seek immediately")

        for position in 6...9 {
            let decision = AutoSkipCountdownPolicy.advance(
                state: &state, mediaID: "episode-1", segment: segment, position: Double(position),
                playbackActive: true, delaySeconds: 5
            )
            check({ if case .prompt(_, let remaining) = decision { return remaining > 0 }; return false }(),
                  "active playback keeps the prompt visible before five seconds")
        }
        let completed = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-1", segment: segment, position: 10,
            playbackActive: true, delaySeconds: 5
        )
        if case .skip(_, let target, _) = completed {
            check(target == 42, "automatic skip fires after five active playback seconds")
        } else {
            check(false, "automatic skip fires after five active playback seconds")
        }
    }

    private static func pauseAndBufferingDoNotSpendTime() {
        let segment = intro()
        var state = AutoSkipCountdownState()
        _ = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-pause", segment: segment, position: 5,
            playbackActive: true, delaySeconds: 5
        )
        let paused = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-pause", segment: segment, position: 5,
            playbackActive: false, delaySeconds: 5
        )
        check({ if case .prompt(_, let remaining) = paused { return remaining == 5 }; return false }(),
              "paused playback leaves the countdown at five seconds")
        let buffering = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-pause", segment: segment, position: 5,
            playbackActive: false, delaySeconds: 5
        )
        check({ if case .prompt(_, let remaining) = buffering { return remaining == 5 }; return false }(),
              "buffering leaves the countdown unchanged")
    }

    private static func cancellationIsPerSegmentAndPermanentForTheMedia() {
        let segment = intro()
        var state = AutoSkipCountdownState()
        _ = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-cancel", segment: segment, position: 5,
            playbackActive: true, delaySeconds: 5
        )
        AutoSkipCountdownPolicy.cancel(state: &state, segment: segment)
        let afterCancel = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-cancel", segment: segment, position: 6,
            playbackActive: true, delaySeconds: 5
        )
        check(afterCancel == .idle, "cancel hides and suppresses the current segment prompt")
        AutoSkipCountdownPolicy.invalidatePending(state: &state, position: 5)
        let seekBack = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-cancel", segment: segment, position: 5,
            playbackActive: true, delaySeconds: 5
        )
        check(seekBack == .idle, "seeking back to a cancelled segment never auto-fires again")
    }

    private static func seekOutsideInvalidatesPendingDecision() {
        let segment = intro()
        var state = AutoSkipCountdownState()
        _ = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-seek", segment: segment, position: 5,
            playbackActive: true, delaySeconds: 5
        )
        let oldEpoch = state.epoch
        AutoSkipCountdownPolicy.invalidatePending(state: &state, position: 60)
        check(state.epoch != oldEpoch, "a manual seek advances the automatic-skip ownership epoch")
        check(AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-seek", segment: nil, position: 60,
            playbackActive: true, delaySeconds: 5
        ) == .idle, "seeking outside the span invalidates the queued decision")
        let reentry = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-seek", segment: segment, position: 5,
            playbackActive: true, delaySeconds: 5
        )
        check({ if case .prompt(_, let remaining) = reentry { return remaining == 5 }; return false }(),
              "a later manual re-entry starts a fresh countdown instead of using stale elapsed time")
    }

    private static func targetEndIsClampedToDuration() {
        let segment = intro(start: 5, end: 110)
        var state = AutoSkipCountdownState()
        _ = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-end", segment: segment, position: 5,
            duration: 100, playbackActive: true, delaySeconds: 1
        )
        let decision = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-end", segment: segment, position: 6,
            duration: 100, playbackActive: true, delaySeconds: 1
        )
        if case .skip(_, let target, _) = decision {
            check(target == 100, "automatic target is clamped to the media duration")
        } else {
            check(false, "automatic target is clamped to the media duration")
        }
    }

    private static func sourceRebindRetainsMediaMemoryButNewMediaResetsIt() {
        let segment = intro()
        var state = AutoSkipCountdownState()
        AutoSkipCountdownPolicy.bindMedia(&state, mediaID: "episode-source-swap")
        AutoSkipCountdownPolicy.complete(state: &state, segment: segment)
        let sameMedia = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-source-swap", segment: segment, position: 5,
            playbackActive: true, delaySeconds: 5
        )
        check(sameMedia == .idle, "source rebind keeps completion memory for the same episode")

        AutoSkipCountdownPolicy.bindMedia(&state, mediaID: "episode-new")
        let newMedia = AutoSkipCountdownPolicy.advance(
            state: &state, mediaID: "episode-new", segment: segment, position: 5,
            playbackActive: true, delaySeconds: 5
        )
        check({ if case .prompt(_, let remaining) = newMedia { return remaining == 5 }; return false }(),
              "new media identity clears the prior segment memory")
    }

    private static func settingsMigrationPreservesExplicitOffAndDefaultsNewInstallsOn() {
        let suiteName = "vortx-auto-skip-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        check(AutoSkipSettings.delaySeconds(in: defaults) == 5,
              "an unconfigured install defaults to a five-second countdown")

        defaults.set(false, forKey: AutoSkipSettings.legacyKey)
        defaults.removeObject(forKey: AutoSkipSettings.delayKey)
        check(AutoSkipSettings.delaySeconds(in: defaults) == 0,
              "an explicit historical legacy Off choice migrates to Off")

        AutoSkipSettings.setDelaySeconds(10, in: defaults)
        check(AutoSkipSettings.delaySeconds(in: defaults) == 10,
              "the configured delay is persisted independently of the legacy Bool")
        for (value, expected) in [(Double.greatestFiniteMagnitude, 120.0),
                                  (-Double.greatestFiniteMagnitude, 0.0),
                                  (Double.infinity, 5.0), (Double.nan, 5.0)] {
            AutoSkipSettings.setDelaySeconds(value, in: defaults)
            check(AutoSkipSettings.delaySeconds(in: defaults) == expected,
                  "synced delay \(value) is bounded without an integer conversion trap")
        }
        defaults.removePersistentDomain(forName: suiteName)
    }
}
