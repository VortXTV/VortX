import Foundation

/// Prior-launch termination evidence (Beta 26 lane 6).
///
/// Problem this solves: when users report "the app just closed" or "it restarted by itself", the
/// exported diagnostic log cannot distinguish a user exit, a background jetsam kill, a watchdog
/// termination, and a crash. VortXCrashReporter already covers real crashes (signals); everything
/// else was invisible. This keeps a tiny JSON session receipt in Caches that is refreshed while the
/// process runs and CLASSIFIED on the next launch, then folded into the exportable probe log.
///
/// Split mirrors VortXCrashReporter: writes are cheap bounded JSON (atomic replace, no growth);
/// classification is pure and unit-tested in the harness; folding respects VXProbe.enabled like the
/// crash fold does (receipt is preserved, never deleted, when diagnostics is off so a later
/// diagnostics-on launch can still report it).
enum TerminationReceiptPolicy {

    /// Last-known session state persisted by the runtime helper.
    struct Receipt: Codable, Equatable {
        var startedAtEpoch: TimeInterval
        var lastHeartbeatEpoch: TimeInterval
        var lastPhase: String            // "active" | "inactive" | "background" | "terminating"
        var lastMemoryWarningEpoch: TimeInterval?
        var lastMemoryWarningFootprintMB: Int64?

        static func initial(now: TimeInterval) -> Receipt {
            Receipt(startedAtEpoch: now, lastHeartbeatEpoch: now,
                    lastPhase: TerminationReceiptPolicy.phaseActive,
                    lastMemoryWarningEpoch: nil, lastMemoryWarningFootprintMB: nil)
        }
    }

    static let phaseActive = "active"
    static let phaseInactive = "inactive"
    static let phaseBackground = "background"
    static let phaseTerminating = "terminating"

    enum Decision: Equatable {
        case firstRun                       // no receipt from any prior run
        case cleanExit                      // prior run reached an explicit terminate path
        case crash                          // crash marker present alongside an unclean receipt
        case likelyJetsamWhileBackgrounded  // died backgrounded with a fresh heartbeat
        case likelyForegroundKill           // died "active"/"inactive" with a fresh heartbeat
        case staleUncertain                 // receipt too old to attribute confidently
    }

    /// A heartbeat older than this makes attribution unreliable (clock skew, restored backup,
    /// long device-off period): report it, but as uncertain rather than blaming the OS.
    static let staleAfterSeconds: TimeInterval = 24 * 60 * 60

    /// Classify how the PRIOR run ended. Pure so the harness can pin every branch.
    static func classify(receipt: Receipt?, crashMarkerExists: Bool, now: TimeInterval) -> Decision {
        guard let r = receipt else { return .firstRun }
        if r.lastPhase == phaseTerminating { return .cleanExit }
        if crashMarkerExists {
            // A crash marker wins over phase heuristics: the signal handler observed the death.
            return .crash
        }
        guard now - r.lastHeartbeatEpoch <= staleAfterSeconds else { return .staleUncertain }
        if r.lastPhase == phaseBackground || r.lastPhase == phaseInactive {
            return .likelyJetsamWhileBackgrounded
        }
        return .likelyForegroundKill
    }

    /// Human-readable line folded into the probe log. Includes the evidence fields owners paste
    /// into reports: age at death, last phase, and the last memory-warning snapshot when present.
    static func summaryLine(_ decision: Decision, receipt: Receipt?) -> String {
        switch decision {
        case .firstRun:
            return "no prior-session receipt"
        case .cleanExit:
            return "prior run exited cleanly"
        case .crash:
            return "prior run ended in a captured crash"
        case .likelyJetsamWhileBackgrounded:
            return evidence("terminated while backgrounded (likely jetsam)", receipt)
        case .likelyForegroundKill:
            return evidence("terminated while foregrounded without a crash marker (watchdog or jetsam)", receipt)
        case .staleUncertain:
            return "stale prior-session receipt, cause uncertain"
        }
    }

    private static func evidence(_ cause: String, _ receipt: Receipt?) -> String {
        guard let r = receipt else { return cause }
        var parts = [cause]
        let ran = r.lastHeartbeatEpoch - r.startedAtEpoch
        parts.append(String(format: "session ran %.0fs", max(0, ran)))
        parts.append("last phase \(r.lastPhase)")
        if let warn = r.lastMemoryWarningEpoch, let mb = r.lastMemoryWarningFootprintMB {
            let beforeDeath = max(0, r.lastHeartbeatEpoch - warn)
            parts.append(String(format: "last memory warning %.0fs before last heartbeat (%lld MB footprint)",
                                beforeDeath, mb))
        } else {
            parts.append("no memory warning recorded")
        }
        return parts.joined(separator: ", ")
    }
}
