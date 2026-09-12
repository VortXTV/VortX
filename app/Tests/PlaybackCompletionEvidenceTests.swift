import Foundation

// Compile with SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift; execute from the repository root.
@main
private enum PlaybackCompletionEvidenceTests {
    nonisolated(unsafe) private static var checks = 0
    private static func expect(_ result: Bool, _ label: String) {
        precondition(result, label)
        checks += 1
    }

    static func main() throws {
        typealias Evidence = PlaybackCompletionEvidence<Int>
        var evidence = Evidence()
        evidence.begin(owner: 4, mountGeneration: 1)
        evidence.recordDuration(1_320, owner: 4)
        evidence.recordPosition(0.4, owner: 4)
        expect(evidence.consumeEOF(owner: 4, isLive: false, isTrailer: false)
               == .premature(position: 0.4, duration: 1_320), "first-frame EOF cannot complete E4")
        expect(evidence.consumeEOF(owner: 4, isLive: false, isTrailer: false) == .ignore,
               "duplicate EOF cannot spend recovery budget twice")
        evidence.begin(owner: 4, mountGeneration: 1)
        expect(evidence.consumeEOF(owner: 4, isLive: false, isTrailer: false) == .ignore,
               "same item callback cannot reset its terminal latch")

        // AVPlayer deliberately reuses a logical request token on physical item recovery.
        evidence.begin(owner: 4, mountGeneration: 2)
        evidence.recordDuration(1_320, owner: 4)
        evidence.recordPosition(1_319, owner: 4)
        expect(evidence.consumeEOF(owner: 4, isLive: false, isTrailer: false) == .allowCompletion,
               "recovered same-token item can genuinely finish")
        evidence.begin(owner: 4, mountGeneration: 3)
        expect(evidence.consumeEOF(owner: 4, isLive: false, isTrailer: false) == .allowCompletion,
               "new physical item cannot inherit old position or duration")
        evidence.recordPosition(600, owner: 4)
        evidence.recordDuration(1_320, owner: 4)
        expect(evidence.consumeEOF(owner: 4, isLive: false, isTrailer: false)
               == .premature(position: 600, duration: 1_320), "recovered mount has its own early-EOF budget")

        // libmpv assigns a fresh token even for a same-source reload.
        evidence.begin(owner: 5, mountGeneration: 0)
        evidence.recordPosition(1_319, owner: 4)
        evidence.recordDuration(1_320, owner: 4)
        expect(evidence.consumeEOF(owner: 4, isLive: false, isTrailer: false) == .ignore,
               "retired load cannot complete the incoming episode")
        expect(evidence.consumeEOF(owner: 5, isLive: false, isTrailer: false) == .allowCompletion,
               "stale telemetry is not evidence for the incoming episode")
        evidence.recordDuration(1_320, owner: 5)
        evidence.recordPosition(1_310, owner: 5)
        expect(evidence.consumeEOF(owner: 5, isLive: false, isTrailer: false) == .allowCompletion,
               "small final tail remains a normal completion")
        evidence.recordPosition(600, owner: 5)
        evidence.recordDuration(0, owner: 5)
        evidence.recordDuration(.nan, owner: 5)
        evidence.recordPosition(.infinity, owner: 5)
        expect(evidence.consumeEOF(owner: 5, isLive: false, isTrailer: false)
               == .premature(position: 600, duration: 1_320),
               "real backward seek replaces prior tail; invalid retirement duration cannot erase evidence")

        for (live, trailer) in [(true, false), (false, true)] {
            var special = Evidence()
            special.begin(owner: 1, mountGeneration: 0)
            special.recordDuration(600, owner: 1)
            special.recordPosition(1, owner: 1)
            expect(special.consumeEOF(owner: 1, isLive: live, isTrailer: trailer) == .allowCompletion,
                   "live reconnect and trailer semantics stay unchanged")
        }
        for duration in [10.0, 100.0, 1_320.0, 10_000.0] {
            let tolerance = min(30, max(2, duration * 0.01))
            var boundary = Evidence()
            boundary.begin(owner: 1, mountGeneration: 0)
            boundary.recordDuration(duration, owner: 1)
            boundary.recordPosition(duration - tolerance, owner: 1)
            expect(boundary.consumeEOF(owner: 1, isLive: false, isTrailer: false) == .allowCompletion,
                   "tail boundary remains playable at duration \(duration)")
            boundary.recordPosition(duration - tolerance - 1, owner: 1)
            expect(boundary.consumeEOF(owner: 1, isLive: false, isTrailer: false)
                   == .premature(position: duration - tolerance - 1, duration: duration),
                   "known premature end outside tolerance is rejected at duration \(duration)")
        }

        let root = FileManager.default.currentDirectoryPath
        for path in ["app/Sources/PlayerScreen.swift", "app/SourcesTV/TVPlayerView.swift"] {
            let source = try String(contentsOfFile: root + "/" + path, encoding: .utf8)
            let handler = source.components(separatedBy: "private func handleProperty(")[1]
            expect(handler.range(of: "completionEvidence.begin(owner: loadToken,")!.lowerBound
                   < handler.range(of: "beginAssetSanityAttemptIfNeeded(")!.lowerBound,
                   "mount-generation reset is not behind logical-token sanity gate: \(path)")
            expect(handler.contains("as? AVPlayerEngineController)?.currentItemGeneration ?? 0"),
                   "evidence uses exact AV item generation: \(path)")
            let eof = handler.components(separatedBy: "case MPVProperty.endFileEof:")[1]
            expect(eof.range(of: "rejectPrematureEOFIfNeeded")!.lowerBound
                   < eof.range(of: "terminalAction(")!.lowerBound,
                   "early EOF guard precedes completion ownership/side effects: \(path)")
            let rejection = source.components(separatedBy: "private func rejectPrematureEOFIfNeeded(")[1]
                .components(separatedBy: "private func handleMidPlayFailure(")[0]
            expect(rejection.contains("kind: .error") && rejection.contains("resumeOverride: position")
                   && !rejection.contains("suppressedResumeFloor") && !rejection.contains("markWatched"),
                   "early EOF uses error ownership and raw position, never a watched action: \(path)")
        }
        print("PlaybackCompletionEvidenceTests: \(checks) checks passed")
    }
}
