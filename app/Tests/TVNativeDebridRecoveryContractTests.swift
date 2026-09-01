// Static contract for tvOS native-debrid fresh-link and raw-torrent remount recovery.
//
// Run from repository root:
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/tv-native-debrid-recovery-contract \
//     app/Tests/TVNativeDebridRecoveryContractTests.swift && \
//   /tmp/tv-native-debrid-recovery-contract

import Foundation

@main @MainActor
private enum TVNativeDebridRecoveryContractTests {
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
            contentsOf: root.appendingPathComponent("app/SourcesTV/TVPlayerView.swift"),
            encoding: .utf8
        )

        check(
            "one fresh native-debrid link is allowed per current mount",
            source.contains("nativeDebridFreshLinkRecovery.freshLinkUsed")
                && source.contains("nativeDebridFreshLinkRecovery.beginFreshLink")
                && source.contains("freshLinkUsed = true")
        )
        check(
            "the generalized recovery owner preserves TorBox provider identifiers",
            source.contains("torrentId: ref.torrentId, fileId: ref.fileId, fileIdx: ref.fileIdx")
                && source.contains("torrentId: ref.torrentId, fileId: ref.fileId, fileIdx: ref.fileIdx")
        )
        check(
            "late provider results are fenced by every active media identity",
            source.contains("retryEpisodeGeneration == episodeSwitchGeneration")
                && source.contains("retrySourceGeneration == sourceSwitchGeneration")
                && source.contains("coordinator.player?.activeLoadToken == retryToken")
                && source.contains("activeRef == ref, curURL == retryURL, curSourceStream == retrySource")
        )
        check(
            "the recovery owner carries semantic track and paused intent",
            source.contains("captureRecoverySelections()")
                && source.contains("queueIncomingTransportIntent(paused: pausedIntent)")
                && source.contains("let resume = max(currentTime, suppressedResumeFloor")
        )
        check(
            "explicit picks refresh once before terminal behavior",
            source.contains("if recoverCurrentNativeDebridLink(reason: msg) { return }")
                && source.contains("if currentPickWasExplicit && !currentPlaybackIsResume")
        )
        check(
            "direct URLs without a native reference remain outside provider recovery",
            source.contains("let retryRef = pendingAdvance?.debridRef ?? curDebridRef")
                && source.contains("guard !nativeDebridFreshLinkRecovery.freshLinkUsed,")
                && source.contains("let ref = retryRef, !ref.infoHash.isEmpty else { return false }")
        )
        check(
            "an engine switch during reconnect refreshes before constructing the requested engine",
            source.contains("needsFreshNativeDebridLink = reconnecting || autoRetryTask != nil")
                && source.contains("recoverCurrentNativeDebridLink(reason: \"engine switch\", requestedEngine: toAVPlayer)")
                && source.contains("engineSurfaceURLOverride = fresh")
                && source.contains(".play(engineSurfacePlayback.url, headers: engineSurfacePlayback.headers")
        )
        check(
            "a fresh-link engine handoff preserves the recovery generation instead of incrementing twice",
            source.contains("preservingNativeDebridRecoveryGeneration: true")
                && source.contains("if !preservingNativeDebridRecoveryGeneration {")
        )
        check(
            "healthy engine switches remain provider-free",
            source.contains("if needsFreshNativeDebridLink,")
                && source.contains("performPlayerEngineSwitch(toAVPlayer: toAVPlayer)")
        )
        check(
            "an engine switch joins an in-flight fresh-link recovery instead of mounting stale transport",
            source.contains("nativeDebridFreshLinkRecovery.freshLinkInFlight")
                && source.contains("nativeDebridFreshLinkRecovery.joinEngineSwitch(toAVPlayer)")
                && source.contains("let recoveryID = nativeDebridFreshLinkRecovery.beginFreshLink")
                && source.contains("nativeDebridFreshLinkRecovery.finishFreshLink(ownedBy: recoveryID)")
                && source.contains("nativeDebridFreshLinkRecovery.retireFreshLink(ownedBy: recoveryID)")
        )
        check(
            "a provider fresh-link clears old add-on credentials before either player mounts it",
            URL(string: "https://addon.example.invalid/stream")?.host
                != URL(string: "https://provider.example.invalid/download")?.host
                && ["Authorization": "Bearer addon-token", "Cookie": "addon-session", "Referer": "https://addon.example.invalid"]
                    .keys.count == 3
                && source.contains("curURL = fresh")
                && source.contains("curHeaders = nil")
                && source.contains("loadIntoPlayer(fresh, headers: curHeaders")
                && source.contains("engineSurfaceHeadersOverride = curHeaders")
        )
        check(
            "only a raw torrent rebind creates before a replacement load",
            source.contains("private func prepareRawTorrentAfterLoopbackRebind")
                && source.contains("curDebridRef == nil")
                && source.contains("stream.url == nil")
                && source.contains("previous.port != replacement.port")
                && source.contains("prepareTorrent(stream)")
        )
        check(
            "foreground, stall, and retry replacement paths invoke the raw-torrent rebind owner",
            source.components(separatedBy: "prepareRawTorrentAfterLoopbackRebind").count >= 4
        )

        if failures > 0 { exit(1) }
    }
}
