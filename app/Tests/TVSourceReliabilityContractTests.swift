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

        check(
            "AVPlayer receives the original URL and declared headers",
            tvPlayer.contains("url, headers: headers, live: live, audioSidecar: sidecar")
        )
        check(
            "header-gated libmpv streams use the embedded proxy with the original header map",
            tvPlayer.contains("StremioServer.proxiedURL(for: url, headers: h)")
        )
        check(
            "direct libmpv fallback retains the original URL and declared headers",
            tvPlayer.contains("url, headers: headers, live: live, audioSidecar: sidecar")
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
            "cold-resume nudge is bounded and stays on the relative-seek path",
            tvPlayer.contains("TVLibMPVStartupNudgePolicy.decision")
                && tvPlayer.contains("coordinator.player?.seek(by: 0.1)")
                && tvPlayer.contains("waiting 4s before source hop")
        )

        if failures > 0 { exit(1) }
    }
}
