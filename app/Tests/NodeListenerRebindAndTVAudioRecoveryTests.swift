// Source-contract tests for native server lifecycle wiring and executable policy tests for shared Apple
// same-source remount selection retention. Run with: bash scripts/test-apple-playback-recovery.sh

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
private enum NativeServerAndTVAudioRecoveryTests {
    @MainActor
    static func main() {
        // Node's listener-rebind state machine and preload have been retired with that runtime.
        // Inspect the replacement lifecycle wiring; do not fabricate a second server implementation.
        guard let facade = try? String(contentsOfFile: "app/Sources/NodeServer.swift", encoding: .utf8),
              let native = try? String(contentsOfFile: "app/SourcesShared/VortxNativeServer.swift", encoding: .utf8) else {
            failures += 1
            print("FAIL  native server lifecycle source contract readable")
            finish()
            return
        }
        check("platform facade starts only the native in-process server",
              facade.contains("VortxNativeServer.startIfNeeded()")
              && !facade.contains("node_start(") && !facade.contains("import NodeMobile"))
        check("server ABI remains gated to server-inclusive targets", native.contains("#if VORTX_ENGINE_SERVER"))
        check(
            "native startup serializes ownership and publishes the actual bound port",
            sourceContainsInOrder(native, [
                "static func startIfNeeded()",
                "queue.async {",
                "guard handle == nil else { return }",
                "vortx_server_start($0)",
                "handle = h",
                "let port = Int(vortx_server_port(h))",
                "publish(port: port, baseURL: base)"
            ]))
        check(
            "native shutdown retires handle and address before consuming the server",
            sourceContainsInOrder(native, [
                "private static func stopOnQueue()",
                "guard let h = handle else { return }",
                "handle = nil",
                "publish(port: nil, baseURL: nil)",
                "vortx_server_stop(h)"
            ]))
        check(
            "native background stop enters the lifecycle FIFO immediately",
            sourceContainsInOrder(native, [
                "static func stopOnBackground()",
                "queue.async { stopOnQueue() }"
            ]))

        let manualAudio = PlayerRecoveryAudioChoice(language: " EN ", title: "Main Mix")
        let audioTracks = [MPVTrack(id: 8, type: "audio", title: "main mix", lang: "en", selected: false)]
        let subtitleTracks = [MPVTrack(id: 17, type: "sub", title: "English", lang: "en", selected: false)]
        check("audio-first staged arrival retains pending embedded subtitle", AppleTrackRecoveryPolicy.subtitleAction(
            choice: .embedded(lang: "en", title: "English"), tracks: [], pooledChoiceAvailable: false) == .retain)
        check("audio-first staged arrival restores manual audio", AppleTrackRecoveryPolicy.audioAction(
            choice: manualAudio, tracks: audioTracks, automaticID: nil) == .reapply(8))
        check("later subtitle arrival restores exact embedded selection", AppleTrackRecoveryPolicy.subtitleAction(
            choice: .embedded(lang: "en", title: "English"), tracks: subtitleTracks, pooledChoiceAvailable: false) == .selectEmbedded(17))
        check("subtitle-first staged arrival retains pending manual audio", AppleTrackRecoveryPolicy.audioAction(
            choice: manualAudio, tracks: [], automaticID: nil) == .retain)
        check("subtitle-first staged arrival restores subtitle", AppleTrackRecoveryPolicy.subtitleAction(
            choice: .embedded(lang: "en", title: "English"), tracks: subtitleTracks, pooledChoiceAvailable: false) == .selectEmbedded(17))
        check("later audio arrival restores exact manual audio", AppleTrackRecoveryPolicy.audioAction(
            choice: manualAudio, tracks: audioTracks, automaticID: nil) == .reapply(8))
        check("manual subtitle Off is actionable before track discovery", AppleTrackRecoveryPolicy.subtitleAction(
            choice: .off, tracks: [], pooledChoiceAvailable: false) == .applyImmediately)
        check("manual external subtitle is actionable before track discovery", AppleTrackRecoveryPolicy.subtitleAction(
            choice: .external(url: "https://example.invalid/sub.vtt", title: "English", lang: "en"), tracks: [], pooledChoiceAvailable: false) == .applyImmediately)
        check("manual pool choice is retained before pool arrival", AppleTrackRecoveryPolicy.subtitleAction(
            choice: .pooled(id: 42), tracks: [], pooledChoiceAvailable: false) == .retain)
        check("later pool arrival makes manual choice actionable", AppleTrackRecoveryPolicy.subtitleAction(
            choice: .pooled(id: 42), tracks: [], pooledChoiceAvailable: true) == .applyImmediately)

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
