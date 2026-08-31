// Static integration contract for the Apple external-source reliability path.
//
// Run from the repository root:
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/tv-source-reliability-contract \
//     app/Tests/TVSourceReliabilityContractTests.swift && \
//   /tmp/tv-source-reliability-contract
//
// This deliberately reads the production surface rather than duplicating the routing ladder. It protects the
// privacy and fidelity contract that a community source's declared headers reach both Apple engines unchanged,
// while diagnostics describe only safe header characteristics.

import Foundation

@main @MainActor
private enum TVSourceReliabilityContractTests {
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
        let tvPlayer = try String(
            contentsOf: root.appendingPathComponent("app/SourcesTV/TVPlayerView.swift"),
            encoding: .utf8
        )
        let playerScreen = try String(
            contentsOf: root.appendingPathComponent("app/Sources/PlayerScreen.swift"),
            encoding: .utf8
        )

        check(
            "AVPlayer receives the original URL and declared headers",
            tvPlayer.contains("url, headers: headers, live: live, audioSidecar: sidecar")
        )
        check(
            "header-gated libmpv streams use the embedded proxy with the original header map",
            tvPlayer.contains("StremioServer.proxiedURL(for: url, headers: h)")
        )
        check(
            "direct libmpv fallback preserves the active raw URL and only proxies declared headers",
            tvPlayer.contains("private var mpvSurfacePlayback")
                && tvPlayer.contains("let activeURL = avEngineFailed ? (curURL ?? url) : url")
                && tvPlayer.contains("let activeHeaders = avEngineFailed ? curHeaders : headers")
                && tvPlayer.contains("StremioServer.proxiedURL(for: activeURL, headers: activeHeaders)")
        )
        check(
            "diagnostics report header characteristics without interpolating header values",
            tvPlayer.contains("safeHeaderReceipt")
                && tvPlayer.contains("hasRange=")
                && !tvPlayer.contains("headers=\\(headers)")
        )
        check(
            "source-hop diagnostics use a fixed failure class instead of a source label",
            tvPlayer.contains("reason=\\(safeFailureClass(reason)) next=candidate")
                && !tvPlayer.contains("source hop \\(hops)/\\(maxSourceHops) (\\(reason)) -> \\(sourceLabel(stream).prefix(40))")
        )
        check(
            "direct AVPlayer no-frame records a generation-fenced one-source fallback",
            tvPlayer.contains("DirectAVNoFrameRecovery(")
                && tvPlayer.contains("episodeGeneration: episodeSwitchGeneration")
                && tvPlayer.contains("sourceGeneration: sourceSwitchGeneration")
        )
        check(
            "a second frame-less engine attempt uses the normal source-hop choke point",
            tvPlayer.contains("direct AVPlayer and libmpv produced no frame")
                && tvPlayer.contains("hopToNextSource(reason:")
        )
        check(
            "a frame-less fallback terminals explicit picks only after its one native-debrid fresh-link recovery",
            tvPlayer.contains("if currentPickWasExplicit {")
                && tvPlayer.contains("This source didn't produce playable media. Choose another source.")
                && tvPlayer.contains("recoverCurrentNativeDebridLink(reason: \"fallback MPV produced no frame\")")
                && tvPlayer.contains("nativeDebridFreshLinkRecoveryUsed")
        )
        check(
            "cold-resume nudge is bounded and stays on the relative-seek path",
            tvPlayer.contains("TVLibMPVStartupNudgePolicy.decision")
                && tvPlayer.contains("coordinator.player?.seek(by: 0.1)")
                && tvPlayer.contains("waiting 4s before source hop")
        )
        check(
            "AV-to-mpv fallback waits for a producer acknowledgement before mounting",
            tvPlayer.contains("stopForMPVFallback()")
                && tvPlayer.contains("await quiescence.wait(timeout: .seconds(2))")
                && tvPlayer.contains("VortXRemuxHandoffPolicy.canMountMPV")
                && tvPlayer.contains("avToMPVHandoff != nil")
        )
        check(
            "the replacement watchdog is armed only after the mounted mpv owns a token",
            tvPlayer.contains("awaitReplacementMPVMount(for: handoff)")
                && tvPlayer.contains("let mpvToken = mounted.token")
                && tvPlayer.contains("mpv.activeLoadToken == mpvToken")
                && tvPlayer.contains("stage=mpv-load outcome=issued")
        )
        check(
            "fallback attempt diagnostics carry an opaque non-content identity across the handoff",
            tvPlayer.contains("attemptID: UUID().uuidString")
                && tvPlayer.contains("fallback attempt=\\(fallbackAttemptID) stage=av-retire")
                && tvPlayer.contains("fallback attempt=\\(handoff.attemptID) stage=mpv-load")
        )
        check(
            "prepared remux cannot survive an AV-to-mpv handoff",
            tvPlayer.contains(#"invalidateNextEpisodePreparation(reason: "AV-to-mpv handoff")"#)
                && tvPlayer.contains("VortXRemuxHandoffPolicy.canRetainPreparedTransport")
        )
        check(
            "iOS and macOS use the same producer receipt before constructing their MPV fallback",
            playerScreen.contains("invalidatePreparedEpisode(reason: \"AV-to-mpv handoff\")")
                && playerScreen.contains("stopForMPVFallback()")
                && playerScreen.contains("await quiescence.wait(timeout: .seconds(2))")
                && playerScreen.contains("awaitReplacementMPVMount(for: handoff)")
                && playerScreen.contains("mpv.activeLoadToken == mounted?.token")
        )
        check(
            "iOS and macOS mount MPV with the live source tuple rather than the immutable launch tuple",
            playerScreen.contains("private var mpvSurfacePlayback")
                && playerScreen.contains("let activeURL = usesFallbackSource ? (curURL ?? url) : url")
                && playerScreen.contains(".play(mpvSurfacePlayback.url, headers: mpvSurfacePlayback.headers")
        )
        check(
            "fallback MPV terminal failures bind the active MPV token and bypass ordinary same-source retry",
            tvPlayer.contains("recovery.mpvLoadToken == loadToken")
                && tvPlayer.contains("loadToken == coordinator.player?.activeLoadToken")
                && tvPlayer.contains("retryResumeSameSource()")
        )

        if failures > 0 { exit(1) }
    }
}
