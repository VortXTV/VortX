// Executable harness for the prior-launch termination receipt policy (Beta 26 lane 6).
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors
//     -o /tmp/termination-receipt-policy-test
//     app/SourcesShared/TerminationReceiptPolicy.swift
//     app/Tests/TerminationReceiptPolicyTests.swift
//
// Pure policy harness: no file I/O, no MetricKit. It pins every classify branch and the
// summary lines owners paste into bug reports.

import Foundation

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

@main
@MainActor
enum TerminationReceiptPolicyTests {
    static func main() {
        noReceiptIsFirstRun()
        terminatingPhaseIsCleanExit()
        crashMarkerWinsOverPhaseHeuristics()
        freshBackgroundHeartbeatIsJetsam()
        freshInactiveHeartbeatIsJetsam()
        freshActiveHeartbeatIsForegroundKill()
        oldHeartbeatIsStaleUncertain()
        boundaryExpiryIsStaleNotAttributed()
        summariesCarryEvidenceFields()
        summaryLinesAreStable()
        print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        if failures > 0 { exit(1) }
    }

    static func noReceiptIsFirstRun() {
        let d = TerminationReceiptPolicy.classify(receipt: nil, crashMarkerExists: false, now: 1000)
        check("a missing receipt is a first run", d == .firstRun)
    }

    static func terminatingPhaseIsCleanExit() {
        var r = TerminationReceiptPolicy.Receipt.initial(now: 1000)
        r.lastPhase = TerminationReceiptPolicy.phaseTerminating
        r.lastHeartbeatEpoch = 1100
        // Clean exit wins even with a stale heartbeat: the explicit terminate path is authoritative.
        let d = TerminationReceiptPolicy.classify(receipt: r, crashMarkerExists: false, now: 999_999)
        check("an explicit terminating phase is a clean exit regardless of age", d == .cleanExit)
    }

    static func crashMarkerWinsOverPhaseHeuristics() {
        let r = TerminationReceiptPolicy.Receipt.initial(now: 1000)
        let d = TerminationReceiptPolicy.classify(receipt: r, crashMarkerExists: true, now: 1100)
        check("a crash marker classifies as a crash even while foregrounded", d == .crash)
    }

    static func freshBackgroundHeartbeatIsJetsam() {
        var r = TerminationReceiptPolicy.Receipt.initial(now: 1000)
        r.lastPhase = TerminationReceiptPolicy.phaseBackground
        r.lastHeartbeatEpoch = 1600
        let d = TerminationReceiptPolicy.classify(receipt: r, crashMarkerExists: false, now: 1700)
        check("dying backgrounded with a fresh heartbeat is likely jetsam",
              d == .likelyJetsamWhileBackgrounded)
    }

    static func freshInactiveHeartbeatIsJetsam() {
        var r = TerminationReceiptPolicy.Receipt.initial(now: 1000)
        r.lastPhase = TerminationReceiptPolicy.phaseInactive
        r.lastHeartbeatEpoch = 1600
        let d = TerminationReceiptPolicy.classify(receipt: r, crashMarkerExists: false, now: 1700)
        check("dying inactive with a fresh heartbeat is likely jetsam",
              d == .likelyJetsamWhileBackgrounded)
    }

    static func freshActiveHeartbeatIsForegroundKill() {
        let r = TerminationReceiptPolicy.Receipt.initial(now: 1000)
        let d = TerminationReceiptPolicy.classify(receipt: r, crashMarkerExists: false, now: 1100)
        check("dying active without a crash marker is a foreground kill",
              d == .likelyForegroundKill)
    }

    static func oldHeartbeatIsStaleUncertain() {
        var r = TerminationReceiptPolicy.Receipt.initial(now: 0)
        r.lastPhase = TerminationReceiptPolicy.phaseActive
        r.lastHeartbeatEpoch = 0
        let d = TerminationReceiptPolicy.classify(
            receipt: r, crashMarkerExists: false, now: TerminationReceiptPolicy.staleAfterSeconds + 60)
        check("a heartbeat older than the staleness window is uncertain, not attributed",
              d == .staleUncertain)
    }

    static func boundaryExpiryIsStaleNotAttributed() {
        var r = TerminationReceiptPolicy.Receipt.initial(now: 0)
        r.lastHeartbeatEpoch = 0
        // Exactly at the window edge the receipt is still trustworthy.
        let atEdge = TerminationReceiptPolicy.classify(
            receipt: r, crashMarkerExists: false, now: TerminationReceiptPolicy.staleAfterSeconds)
        check("a heartbeat exactly at the staleness edge still attributes",
              atEdge == .likelyForegroundKill)
        let pastEdge = TerminationReceiptPolicy.classify(
            receipt: r, crashMarkerExists: false, now: TerminationReceiptPolicy.staleAfterSeconds + 1)
        check("one second past the staleness edge turns uncertain", pastEdge == .staleUncertain)
    }

    static func summariesCarryEvidenceFields() {
        var r = TerminationReceiptPolicy.Receipt.initial(now: 0)
        r.lastPhase = TerminationReceiptPolicy.phaseBackground
        r.lastHeartbeatEpoch = 300
        r.lastMemoryWarningEpoch = 250
        r.lastMemoryWarningFootprintMB = 1400
        let line = TerminationReceiptPolicy.summaryLine(.likelyJetsamWhileBackgrounded, receipt: r)
        check("the jetsam summary names the cause", line.contains("(likely jetsam)"))
        check("the jetsam summary carries session runtime", line.contains("session ran"))
        check("the jetsam summary carries the last phase", line.contains("last phase background"))
        check("the jetsam summary carries the memory warning snapshot",
              line.contains("memory warning") && line.contains("1400 MB footprint"))
        let noWarn = TerminationReceiptPolicy.summaryLine(.likelyForegroundKill, receipt: .initial(now: 5))
        check("a receipt without warnings says so", noWarn.contains("no memory warning recorded"))
    }

    static func summaryLinesAreStable() {
        check("first-run line",
              TerminationReceiptPolicy.summaryLine(.firstRun, receipt: nil) == "no prior-session receipt")
        check("clean-exit line",
              TerminationReceiptPolicy.summaryLine(.cleanExit, receipt: nil) == "prior run exited cleanly")
        check("crash line",
              TerminationReceiptPolicy.summaryLine(.crash, receipt: nil) == "prior run ended in a captured crash")
        check("stale line",
              TerminationReceiptPolicy.summaryLine(.staleUncertain, receipt: nil) == "stale prior-session receipt, cause uncertain")
    }
}