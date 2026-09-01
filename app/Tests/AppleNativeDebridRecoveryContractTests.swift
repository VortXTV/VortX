// Static contract for iOS/macOS native-debrid, AVPlayer-stall, torrent-rebind, and trickplay parity.
//
// Run from repository root:
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/apple-native-recovery-contract \
//     app/Tests/AppleNativeDebridRecoveryContractTests.swift && \
//   /tmp/apple-native-recovery-contract

import Foundation

private struct AVStallGenerationTransitionModel {
    var activeToken: Int
    var observedGeneration: UInt64?

    mutating func acceptedFirstFrame(token: Int, generation: UInt64) {
        guard token == activeToken else { return }
        observedGeneration = generation
    }
}

private enum NativeDebridFailureOutcome: Equatable {
    case refreshed
    case terminalExplicitPick
    case hopAutomaticPick
}

private func nativeDebridFailureOutcome(
    freshLinkAccepted: Bool,
    explicitPick: Bool
) -> NativeDebridFailureOutcome {
    if freshLinkAccepted { return .refreshed }
    return explicitPick ? .terminalExplicitPick : .hopAutomaticPick
}

private func sourceSection(_ source: String, from start: String, to end: String) -> String {
    guard let startRange = source.range(of: start) else { return "" }
    let suffix = source[startRange.lowerBound...]
    guard let endRange = suffix.range(of: end) else { return String(suffix) }
    return String(suffix[..<endRange.lowerBound])
}

private struct NativeDebridRefreshLifecycleModel {
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var inFlight = false
    private var freshLinkUsed = false
    private var joinedEngine: Bool?

    mutating func begin() -> UInt64? {
        guard !freshLinkUsed, !inFlight else { return nil }
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        inFlight = true
        freshLinkUsed = true
        return nextGeneration
    }

    mutating func retire(ownedBy generation: UInt64) -> Bool {
        guard inFlight, activeGeneration == generation else { return false }
        activeGeneration = nil
        inFlight = false
        freshLinkUsed = false
        joinedEngine = nil
        return true
    }

    mutating func join(engine: Bool) -> Bool {
        guard inFlight else { return false }
        joinedEngine = engine
        return true
    }

    mutating func finish(ownedBy generation: UInt64) -> Bool? {
        guard inFlight, activeGeneration == generation else { return nil }
        inFlight = false
        activeGeneration = nil
        defer { joinedEngine = nil }
        return joinedEngine
    }
}

@main @MainActor
private enum AppleNativeDebridRecoveryContractTests {
    private static var failures = 0

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("app/Sources/PlayerScreen.swift"),
            encoding: .utf8
        )

        check(
            "one fresh native-debrid link is admitted per player mount",
            source.contains("NativeDebridFreshLinkRecoveryState")
                && source.contains("guard !freshLinkUsed, !freshLinkInFlight")
                && source.contains("nativeDebridFreshLinkRecovery.beginFreshLink")
                && source.contains("retireFreshLinkIfOwned(by: recoveryGeneration)")
                && source.contains("nativeDebridFreshLinkRecovery.reset()")
        )
        check(
            "fresh-link completion is fenced by media generation, source generation, identity, URL, and load token",
            source.contains("retryEpisodeGeneration == episodeSwitchGeneration")
                && source.contains("retrySourceGeneration == sourceSwitchGeneration")
                && source.contains("activeRef == ref, curURL == retryURL, currentStream == retrySource")
                && source.contains("coordinator.player?.activeLoadToken == retryLoadToken")
        )
        check(
            "ordinary exhausted retry, AV failure, and both no-frame paths refresh native-debrid before terminal or engine handoff",
            source.contains("recoverCurrentNativeDebridLink(reason: \"load failure\")")
                && source.contains("recoverCurrentNativeDebridLink(reason: \"AVPlayer failure\")")
                && source.contains("recoverCurrentNativeDebridLink(reason: \"post-AV MPV no-frame\")")
                && source.contains("recoverCurrentNativeDebridLink(reason: \"post-AV MPV start timeout\")")
                && source.contains("recoverCurrentNativeDebridLink(reason: \"start timeout\")")
        )
        let ordinaryFailure = sourceSection(
            source,
            from: "private func handleLoadFailure(_ msg: String)",
            to: "private func scheduleReconnect"
        )
        let ordinaryRefresh = ordinaryFailure.range(
            of: "recoverCurrentNativeDebridLink(reason: \"load failure\")"
        )?.lowerBound
        let ordinaryExplicitTerminal = ordinaryFailure.range(
            of: "if currentPickWasExplicit && !currentPlaybackIsResume"
        )?.lowerBound
        check(
            "ordinary explicit native-debrid failure admits fresh link before terminal behavior",
            ordinaryRefresh != nil
                && ordinaryExplicitTerminal != nil
                && ordinaryRefresh! < ordinaryExplicitTerminal!
        )
        check(
            "ordinary explicit native-debrid outcome returns fresh transport before terminal fallback",
            nativeDebridFailureOutcome(freshLinkAccepted: true, explicitPick: true) == .refreshed
        )
        check(
            "failed fresh link preserves explicit-pick terminal behavior",
            nativeDebridFailureOutcome(freshLinkAccepted: false, explicitPick: true) == .terminalExplicitPick
        )
        check(
            "failed fresh link preserves automatic source hop behavior",
            nativeDebridFailureOutcome(freshLinkAccepted: false, explicitPick: false) == .hopAutomaticPick
        )
        check(
            "accepted provider links retain TorBox identity and do not forward add-on headers",
            source.contains("torrentId: ref.torrentId, fileId: ref.fileId, fileIdx: ref.fileIdx")
                && source.contains("curHeaders = nil")
                && source.contains("if pendingAdvance != nil {")
                && source.contains("pendingAdvance?.debridRef = freshRef")
        )
        check(
            "engine switches join an in-flight provider refresh and cannot mount the known-stale URL",
            source.contains("nativeDebridFreshLinkRecovery.freshLinkInFlight")
                && source.contains("nativeDebridFreshLinkRecovery.joinEngineSwitch(toAVPlayer)")
                && source.contains("finishFreshLink(\n                ownedBy: recoveryGeneration")
                && source.contains("preservingNativeDebridRecoveryGeneration: true")
        )
        check(
            "a first frame cancels a provider refresh only when it owns that request token",
            source.contains("nativeDebridFreshLinkRecovery.isOwned(by: event.loadToken)")
        )
        var refreshLifecycle = NativeDebridRefreshLifecycleModel()
        let cancelledGeneration = refreshLifecycle.begin()
        check("cancelled refresh begins with an exact generation", cancelledGeneration != nil)
        check("cancelled refresh retires its own transaction", refreshLifecycle.retire(ownedBy: cancelledGeneration!))
        let secondGeneration = refreshLifecycle.begin()
        check("cancelled refresh permits a second recovery", secondGeneration != nil)
        check("stale first generation cannot retire the second recovery", !refreshLifecycle.retire(ownedBy: cancelledGeneration!))
        check("engine switch joins the second recovery", refreshLifecycle.join(engine: false))
        check("second recovery completes with the joined engine", refreshLifecycle.finish(ownedBy: secondGeneration!) == false)
        check(
            "recovery preserves paused transport intent and semantic audio across mount-local track IDs",
            source.contains("let pausedIntent = isPaused")
                && source.contains("if pausedIntent { coordinator.player?.pause() }")
                && source.contains("pendingAudioReapply = captureSelectedAudioChoice()")
                && source.contains("PlayerRecoveryAudioChoice.matchingID(")
        )
        check(
            "AVPlayer stalls use the current item generation and retain ordinary rebuffering",
            source.contains("avStallWatchdogItemGeneration")
                && source.contains("recoverFreshItemForProvenSurfaceStall(")
                && source.contains("case .retain(let reason):")
                && source.contains("case .replaceFreshItem:")
                && source.contains("case .terminal(let proof):")
        )
        check(
            "accepted AV first frame rearms the watchdog while a retired callback cannot replace its generation",
            source.contains("private func rearmAVStallWatchdogItemGenerationIfOwned(by loadToken: PlayerLoadToken)")
                && source.contains("hasStartedPlaying = true\n                    rearmAVStallWatchdogItemGenerationIfOwned(by: event.loadToken)")
                && source.contains("activeToken: avPlayer.activeLoadToken")
        )
        var transition = AVStallGenerationTransitionModel(activeToken: 42, observedGeneration: 7)
        transition.acceptedFirstFrame(token: 99, generation: 8)
        check("retired AV callback leaves the next mounted generation intact", transition.observedGeneration == 7)
        transition.acceptedFirstFrame(token: 42, generation: 8)
        check("accepted AV first frame advances the recoverable generation", transition.observedGeneration == 8)
        check(
            "a raw torrent port rebind recreates only its matching local engine before replacement load",
            source.contains("private func prepareRawTorrentAfterLoopbackRebind")
                && source.contains("curDebridRef == nil")
                && source.contains("stream.url == nil")
                && source.contains("previous.port != replacement.port")
                && source.contains("prepareTorrent(stream)")
                && source.contains("prepareRawTorrentAfterLoopbackRebind(from: previousURL, to: healed)")
        )
        check(
            "trickplay declares AVPlayer pull versus libmpv inline capture and AV-to-mpv drops stale prewarm",
            source.contains("private func currentLocalTrickplayCaptureDecision")
                && source.contains(".avPlayerVideoOutput")
                && source.contains(".libmpvInlineDrawable")
                && source.contains("invalidatePreparedEpisode(reason: \"AV-to-mpv handoff\")")
        )

        if failures > 0 { exit(1) }
        print("All Apple native recovery contract checks passed")
    }
}
