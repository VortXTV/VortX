import Foundation

// swiftc -warnings-as-errors app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift \
//   app/Tests/FreshPlaybackOriginPolicyTests.swift -o <private-output>; run from repository root.
@main
private enum FreshPlaybackOriginPolicyTests {
    nonisolated(unsafe) private static var checks = 0
    private static func expect(_ value: Bool, _ label: String) {
        precondition(value, label); checks += 1
    }

    static func main() throws {
        typealias Policy = FreshPlaybackOriginPolicy<Int>
        var policy = Policy()
        policy.begin(owner: 1, requestedOrigin: 0, live: false, preview: false)
        expect(policy.observe(position: 0, owner: 1) == .forward, "initial zero does not spend positive check")
        expect(policy.observe(position: 4.046, owner: 1) == .correct, "exact field defect caught")
        expect(policy.observe(position: 7.8, owner: 1) == .suppress, "later unrequested position cannot commit")
        policy.observedSeek(owner: 1)
        expect(policy.observe(position: 0, owner: 1) == .suppress, "seek before command admission is not evidence")
        expect(policy.admitCorrection(owner: 1), "one correction admitted")
        expect(!policy.admitCorrection(owner: 1), "duplicate correction refused")
        expect(policy.observe(position: 0.04, owner: 1) == .suppress, "queued low tick before seek is not evidence")
        policy.observedSeek(owner: 1)
        expect(policy.observe(position: 4.3, owner: 1) == .suppress, "stale high tick after seek withheld")
        expect(policy.observe(position: 0, owner: 1) == .recovered, "seek-confirmed zero recovers while playing or paused")
        expect(policy.observe(position: 4.3, owner: 1) == .forward, "normal playback never rechecks and loops")
        expect(!policy.failCorrection(owner: 1), "resolved deadline inert")

        policy.begin(owner: 2, requestedOrigin: 0, live: false, preview: false)
        expect(policy.observe(position: .nan, owner: 2) == .suppress, "NaN does not spend check")
        expect(policy.observe(position: .infinity, owner: 2) == .suppress, "infinity does not spend check")
        expect(policy.observe(position: -1, owner: 2) == .suppress, "negative time does not spend check")
        expect(policy.observe(position: 0.042, owner: 2) == .forward, "normal exact-library first tick untouched")
        expect(policy.observe(position: 10.010, owner: 2) == .forward, "later user seek/normal playback untouched")
        expect(!policy.admitCorrection(owner: 2), "normal start needs no seek")

        for origin in [nil, 0.001, 60.535, Double.nan, Double.infinity] as [Double?] {
            policy.begin(owner: 3, requestedOrigin: origin, live: false, preview: false)
            expect(policy.observe(position: 10.010, owner: 3) == .forward, "nonzero/unconfigured origin excluded")
        }
        for (live, preview) in [(true, false), (false, true), (true, true)] {
            policy.begin(owner: 3, requestedOrigin: 0, live: live, preview: preview)
            expect(policy.observe(position: 45, owner: 3) == .forward, "live/preview semantics retained")
        }
        for beforeAdmission in [true, false] {
            policy.begin(owner: 4, requestedOrigin: 0, live: false, preview: false)
            expect(policy.observe(position: 10.010, owner: 4) == .correct, "large drift caught")
            if !beforeAdmission { expect(policy.admitCorrection(owner: 4), "admit before manual seek") }
            policy.supersede()
            expect(!policy.admitCorrection(owner: 4), "manual seek cancels queued correction")
            policy.observedSeek(owner: 4)
            expect(policy.observe(position: 90, owner: 4) == .forward, "manual/resume target stays in charge")
            expect(!policy.failCorrection(owner: 4), "manual seek cancels deadline")
        }
        for afterSeek in [true, false] {
            policy.begin(owner: 5, requestedOrigin: 0, live: false, preview: false)
            expect(policy.observe(position: 7, owner: 5) == .correct, "failure path drift caught")
            expect(policy.admitCorrection(owner: 5), "failure path admitted")
            if afterSeek { policy.observedSeek(owner: 5) }
            expect(policy.failCorrection(owner: 5), "command/deadline/EOF failure emitted once")
            expect(policy.hasFailed(owner: 5), "EOF cannot complete a failed origin")
            expect(!policy.failCorrection(owner: 5), "duplicate deadline/EOF is inert")
            expect(policy.observe(position: 8, owner: 5) == .suppress, "failed origin cannot commit")
        }
        policy.begin(owner: 6, requestedOrigin: 0, live: false, preview: false)
        expect(!policy.failCorrection(owner: 5), "retired timer cannot fail replacement")
        expect(!policy.hasFailed(owner: 6), "new load has no old error")
        expect(policy.observe(position: 4, owner: 5) == .suppress, "retired callback cannot seek replacement")
        expect(policy.observe(position: 0.042, owner: 6) == .forward, "new load independent")

        let source = try String(contentsOfFile: "app/Sources/Player/MPVMetalViewController.swift", encoding: .utf8)
        expect(source.contains("preservingSeekEOFRecovery ? nil : requestedOrigin"), "internal EOF reload excluded")
        expect(source.contains("freshOrigin.begin(owner: issuedToken"), "origin bound only at accepted load")
        expect(source.contains("if commandResult >= 0 {\n            // Refused replacements"), "rejection retains configuration")
        expect(source.contains("if requestedFreshOriginGeneration == requestedOriginGeneration"), "newer configured origin cannot be cleared")
        expect(source.contains("self.command(\"seek\", args: [\"0\", \"absolute+exact\"]"), "warm exact correction, not reload")
        let intercept = source.range(of: "self.acceptsFreshOriginPosition(value, owner: originOwner)")!
        let coalescing = source.range(of: "let minInterval = PerformanceMode.reduced ? 0.5 : 0.25")!
        expect(intercept.lowerBound < coalescing.lowerBound, "raw origin checked before UI throttling/progress")
        let correction = source.components(separatedBy: "private func acceptsFreshOriginPosition")[1]
            .components(separatedBy: "func readEvents()")[0]
        expect(!correction.contains("setFlag("), "correction never changes user pause intent")
        expect(!correction.contains("loadFile("), "correction never restarts the stream")
        expect(source.contains("guard !originFailed else { return }"), "failed correction EOF fenced")
        print("FreshPlaybackOriginPolicyTests: \(checks)/\(checks) passed")
    }
}
