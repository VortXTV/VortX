// Bounded source contracts for the Apple auto-skip integration.
//
// This executable intentionally avoids importing SwiftUI/AVFoundation. It protects the seams that a pure
// state-machine test cannot see: automatic skips use the seek fence, transport/source changes invalidate the
// pending decision, and the tvOS remote exposes the X action without routing it to the primary Skip action.
//
//     swiftc -parse-as-library -o /tmp/vortx-auto-skip-wiring-tests \
//         app/Tests/AutoSkipCountdownWiringContractTests.swift \
//     && /tmp/vortx-auto-skip-wiring-tests

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

@MainActor private func source(_ path: String) -> String {
    do {
        return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        failures += 1
        print("FAIL  read \(path): \(error)")
        return ""
    }
}

private func section(_ text: String, from start: String, to end: String) -> String {
    guard let startRange = text.range(of: start) else { return "" }
    let tail = text[startRange.lowerBound...]
    guard let endRange = tail.range(of: end) else { return String(tail) }
    return String(tail[..<endRange.lowerBound])
}

@main
@MainActor
enum AutoSkipCountdownWiringContractTests {
    static func main() {
        let player = source("app/Sources/PlayerScreen.swift")
        let tv = source("app/SourcesTV/TVPlayerView.swift")

        let playerSkip = section(player, from: "private func updateCurrentSkip(at time:", to: "private func refreshSkipSegments()")
        check(playerSkip.contains("issueSeek(to: target, reason: \"automatic-skip\")"),
              "iOS automatic skips use the issueSeek choke point")
        check(!playerSkip.contains("coordinator.player?.seek(to: target)"),
              "iOS automatic skips do not bypass seek fencing")

        let tvSkip = section(tv, from: "private func updateCurrentSkip(at time:", to: "private func refreshSkipSegments()")
        check(tvSkip.contains("issueSeek(to: target, reason: \"automatic-skip\")"),
              "tvOS automatic skips use the issueSeek choke point")

        let playerIssueSeek = section(player, from: "private func issueSeek(to target:", to: "private func seekBy(_ delta:")
        let tvIssueSeek = section(tv, from: "private func issueSeek(to target:", to: "private func seek(_ delta:")
        check(playerIssueSeek.contains("AutoSkipCountdownPolicy.invalidatePending"),
              "iOS absolute transport seeks invalidate pending countdowns")
        check(tvIssueSeek.contains("AutoSkipCountdownPolicy.invalidatePending"),
              "tvOS absolute transport seeks invalidate pending countdowns")
        let tvRelativeSeek = section(tv, from: "private func seek(_ delta:", to: "/// Jump back to the very start")
        check(tvRelativeSeek.contains("AutoSkipCountdownPolicy.invalidatePending"),
              "tvOS relative transport seeks invalidate pending countdowns")

        let playerSwitch = section(player, from: "private func switchStream(to stream:", to: "private var navigationEpisodeSource")
        let tvSwitch = section(tv, from: "private func switchStream(to stream:", to: "private func nextUntriedStream()")
        check(playerSwitch.contains("AutoSkipCountdownPolicy.invalidatePending"),
              "iOS source replacement fences stale countdown telemetry")
        check(tvSwitch.contains("AutoSkipCountdownPolicy.invalidatePending"),
              "tvOS source replacement fences stale countdown telemetry")
        let playerLoad = section(player, from: "private func loadIntoPlayer(_ u:", to: "private func retryResumeTarget()")
        let tvLoad = section(tv, from: "private func loadIntoPlayer(_ url:", to: "private func resolveAndSwitchStream")
        check(playerLoad.contains("AutoSkipCountdownPolicy.invalidatePending"),
              "iOS accepted source/rebind loads fence stale countdown telemetry")
        check(tvLoad.contains("AutoSkipCountdownPolicy.invalidatePending"),
              "tvOS accepted source/rebind loads fence stale countdown telemetry")
        check(playerLoad.contains("currentSkip = nil") && playerSwitch.contains("currentSkip = nil"),
              "iOS source replacement immediately withdraws the outgoing skip segment")
        check(tvLoad.contains("currentSkip = nil") && tvSwitch.contains("currentSkip = nil"),
              "tvOS source replacement immediately withdraws the outgoing skip segment")
        check(player.contains("if hasStartedPlaying, let seg = currentSkip"),
              "iOS cannot render a skip prompt before the accepted file starts")
        let tvPill = section(tv, from: "private var skipPillSegment:", to: "private func skipPill(")
        check(tvPill.contains("guard hasStartedPlaying, !loadFailed"),
              "tvOS visible and remote skip affordances require current started playback")
        let playerManual = section(player, from: "private func skipImmediately(", to: "private func cancelAutomaticSkip(")
        check(playerManual.contains("currentSkip == segment"),
              "a stale iOS button closure cannot seek the outgoing segment")
        let tvManual = section(tv, from: "private func skipTo(", to: "private func hiddenSeek(")
        check(tvManual.contains("guard skipPillSegment == segment"),
              "a stale tvOS button closure cannot seek the outgoing segment")
        let playerCancel = section(player, from: "private func cancelAutomaticSkip(", to: "private func skipPill(")
        let tvCancel = section(tv, from: "private func cancelAutomaticSkip(", to: "private func updateCurrentSkip(")
        check(playerCancel.contains("currentSkip == segment"),
              "iOS cancellation requires the current visible segment")
        check(tvCancel.contains("guard skipPillSegment == segment"),
              "tvOS cancellation requires the current visible and remote segment")
        for (name, text) in [("iOS", player), ("tvOS", tv)] {
            let pill = section(text, from: "private func skipPill(", to: "\n    ///")
            check(pill.contains("let interactionMediaID = autoSkipMediaIdentity") &&
                  pill.contains("let interactionEpoch = autoSkipCountdown.epoch") &&
                  pill.components(separatedBy: "AutoSkipCountdownPolicy.isCurrent(").count == 3,
                  "\(name) Skip and X closures capture immutable media and countdown ownership")
            let watchCredits = section(text, from: "private func watchCredits()", to: "\n    private func")
            check(watchCredits.contains("AutoSkipCountdownPolicy.cancel") &&
                  watchCredits.contains("upNextSuppressed = true"),
                  "\(name) Watch Credits cancels both the credits skip and auto-next band")
            let update = section(text, from: "private func updateCurrentSkip(", to: "private func refreshSkipSegments()")
            check(update.contains("&& promptAvailable") &&
                  update.contains("skip?.kind != .credits || !upNextSuppressed"),
                  "\(name) hidden prompts and Watch Credits cannot spend an automatic-skip countdown")
        }

        let playerNowPlaying = section(player, from: "NowPlayingCenter.wireCommands(", to: "updateNowPlaying(at: d, force: true)")
        let tvNowPlaying = section(tv, from: "NowPlayingCenter.wireCommands(", to: "refreshNowPlaying(at: d, force: true)")
        check(playerNowPlaying.contains("seekBy: { delta in") &&
              playerNowPlaying.contains("AutoSkipCountdownPolicy.invalidatePending"),
              "iOS system transport seeks invalidate countdowns")
        check(tvNowPlaying.contains("seekBy: { delta in") &&
              tvNowPlaying.contains("AutoSkipCountdownPolicy.invalidatePending"),
              "tvOS system transport seeks invalidate countdowns")

        let tvRemote = section(tv, from: "private func handlePress(_ type:", to: "// MARK: -")
        check(tvRemote.contains("if let seg = skipPillSegment { cancelAutomaticSkip(seg) }"),
              "tvOS Back cancels and suppresses the active countdown")
        check(tvRemote.contains("if skipPillFocusedCancel { cancelAutomaticSkip(seg) } else { skipTo(seg) }"),
              "tvOS center activates the focused Skip or X action")

        let tvAccessibility = section(tv, from: "private var remoteAccessibilityItems:", to: "private func timeString")
        check(tvAccessibility.contains("id: \"skip.cancel\""),
              "tvOS accessibility exposes a distinct cancel action")
        check(tvAccessibility.contains("identity == \"skip.cancel\""),
              "tvOS accessibility activation routes X to cancellation")
        check(tvAccessibility.contains("identity == \"skip.primary\""),
              "tvOS accessibility keeps immediate Skip as a separate action")
        let accessibilityPlay = section(tvAccessibility, from: "case \"up-next.play\":", to: "case \"up-next.credits\":")
        let accessibilityCredits = section(tvAccessibility, from: "case \"up-next.credits\":", to: "default: break")
        for (name, text) in [("Play Next", accessibilityPlay), ("Watch Credits", accessibilityCredits)] {
            check(text.contains("guard controlsHidden, upNextRemaining != nil || isCreditsUpNext else { return }"),
                  "tvOS stale accessibility \(name) requires a live Up Next band")
        }
        let catcher = section(tv, from: "func updateAccessibility(", to: "private func layoutAccessibilityControls()")
        check(catcher.contains("for element in accessibilityControls where !liveIDs.contains(element.stableID)") &&
              catcher.contains("element.activateAction = nil") && catcher.contains("element.focusAction = nil"),
              "withdrawn accessibility elements cannot retain stale activation or focus callbacks")

        check(player.contains("UserDefaults.didChangeNotification") &&
              player.contains("refreshAutoSkipSettings()"),
              "iOS player refreshes delay state after settings changes")
        check(tv.contains("UserDefaults.didChangeNotification") &&
              tv.contains("refreshAutoSkipSettings()"),
              "tvOS player refreshes delay state after settings changes")
        check(tv.contains("Cancel automatic skip for \\(segment.kind.rawValue)"),
              "tvOS X remains remotely and accessibly labelled")

        print("")
        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILED")
            Foundation.exit(1)
        }
    }
}
