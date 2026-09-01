// Static contract for iOS/macOS native-debrid, AVPlayer-stall, torrent-rebind, and trickplay parity.
//
// Run from repository root:
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/apple-native-recovery-contract \
//     app/Tests/AppleNativeDebridRecoveryContractTests.swift && \
//   /tmp/apple-native-recovery-contract

import Foundation

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
                && source.contains("let joinedEngine = nativeDebridFreshLinkRecovery.finishFreshLink()")
                && source.contains("preservingNativeDebridRecoveryGeneration: true")
        )
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
