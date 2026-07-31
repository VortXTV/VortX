import Foundation

// =============================================================================
// Player-rework ACCEPTANCE CONTRACT (REQ-260722-09 + REQ-260722-04 consensus).
//
// This file encodes the numeric contract ONCE, so every check reads the same
// constants. The harness verifies the RUNTIME BEHAVIOUR of the local HLS server
// (VortXRemuxHLSServer) against these values; it never asserts on source text.
//
// The plain remux lane and the Dolby Vision lane share the two mechanisms the
// contract governs - the startup gate in `serveMedia` and the playlist builder
// `VortXRemuxHLSServer.buildMediaBody` (which delegates the WHOLE body to the
// dependency-free `DVPlaybackPolicy.mediaPlaylistLines`). So every behaviour
// below is observable with a plain (non-DV) MKV, which is all this machine has.
//
// EVERY NUMBER HERE IS A MIRROR OF A SHIPPED PRODUCT SYMBOL, and `driftAgainstProduct()`
// at the bottom of this file proves it, naming the symbol when it stops being true.
// The selftest runs that check FIRST, so a product floor change fails the harness
// loudly instead of letting the gate keep grading against a snapshot.
// =============================================================================

enum Contract {
    /// (1) Startup cohort. The FIRST media playlist may only be served once the
    /// produced stream has at least this many CLOSED segments AND advertises at
    /// least `minStartupMs` of media. Both floors, ANDed. Duration is compared
    /// as INTEGER milliseconds derived from the exact three-decimal EXTINF TEXT
    /// (never a float, never an internal packet double).
    ///
    /// These are literals ONLY so `run-conformance.sh`'s `contract_int` can read them
    /// without running the binary; `driftAgainstProduct()` is what keeps them true.
    ///
    /// DRIFT FIXED: these read 6 segments / 15 000 ms, the build-189 floor. The shipped
    /// floor is TWO segments and FOUR seconds of rendered media
    /// (`VortXHLSStartupReadiness.startupFloorMilliseconds` = 4_000 and the
    /// `minimumSegmentCount: Int = 2` default that `VortXRemuxHLSServer.init` uses,
    /// DVPlaybackPolicy.swift:984-993, VortXRemuxHLSServer.swift:166). The old numbers
    /// made this gate grade a passing product as RED: the server opens at 2 segments,
    /// so `firstMediaSegs >= 6` could never hold on a conforming session.
    static let minStartupSegments = 2
    static let minStartupMs = 4_000

    /// (6) Startup latency SLO: mount -> readyToPlay.
    static let sloMountToReadyMs = 30_000

    /// (7) The single fail-soft event the rework must emit EXACTLY ONCE on a
    /// cohort timeout (then a 404 into the libmpv demotion). Zero of them on a
    /// successful start or a user cancellation.
    static let cohortTimeoutEvent = "hls_startup_cohort_timeout"

    // --- Values mirrored from shipped source, used only to REASON about observed
    //     behaviour (e.g. to recognise a fail-soft-length segment or size the
    //     resident window). They are not themselves the contract. ---

    /// `VortXHLSBoundaryPolicy.decision`'s `targetSeconds`, supplied in production by
    /// `VortXMKVRemuxStream.hlsTargetSegmentSecs` (VortXMKVRemuxStream.swift:485,:2594):
    /// a segment closes at the first CONFIRMED IDR at or past this elapsed time.
    static let segmentCutFloorSecs = 1.0
    /// `VortXHLSBoundaryPolicy.decision`'s fail-soft ceiling: an open segment that runs
    /// past the frozen target without a confirmed IDR fails the remux soft rather than
    /// hard-cutting mid-GOP (DVPlaybackPolicy.swift:1136-1140).
    ///
    /// DRIFT FIXED: this file used to carry `hardCutSecs = 4.0` and
    /// `hardCutBytes = 32 << 20`, citing `VortXMKVRemuxStream.hlsMaxSegmentSecs` and
    /// `.hlsMaxSegmentBytes`. NEITHER SYMBOL EXISTS ANY MORE. The non-keyframe hard cut
    /// (MIS-260722-07) was retired: `VortXHLSBoundaryPolicy` returns `.open`/`.cut` only
    /// when `incomingIsIDR && incomingHasKeyFlag`, so a mid-GOP segment start is no
    /// longer reachable through the boundary decision at all. The trace channel's
    /// "segment is exactly the hard cut -> the next one starts mid-GOP" heuristic was
    /// therefore reasoning about a mechanism the product no longer has.
    static let segmentFailSoftSecs = 12
    /// EXT-X-TARGETDURATION as the server renders it: `startupReadiness.frozenTarget.seconds`
    /// (VortXRemuxHLSServer.swift:1018-1019), which production freezes to
    /// `VortXHLSTargetPolicy.conservativeSeconds` (VortXMKVRemuxStream.swift:138).
    ///
    /// DRIFT FIXED: this read 5, and cited a `VortXMKVRemuxStream.hlsTargetDuration`
    /// stored constant. That property is now a computed mirror of the frozen target and
    /// the shipped value is 12. A harness building fixture playlists at TARGETDURATION 5
    /// while the server emits 12 is measuring a playlist the product never serves.
    static let hlsTargetDuration = 12
    /// VortXRemuxBuffer window floor (`RemoteConfigDefaults.dvRemuxWindowMiB`,
    /// SourcesShared/RemoteConfig.swift:48, floored by the private
    /// `VortXRemuxBuffer.windowFloorMinMiB`) in MiB. The resident sliding window is
    /// roughly this plus the producer lead; used ONLY for point 4's diagnostic
    /// prediction, which never decides a verdict.
    static let windowFloorMiB = 64

    // MARK: - Anti-rot check

    /// Compare every mirrored number against the SHIPPED symbol it mirrors, and name the
    /// symbol on any mismatch. Run first by the selftest.
    ///
    /// This is the guard that was missing. The harness's numbers had drifted a whole
    /// windowing generation behind the product with nothing to say so, and the failure
    /// mode was the worst kind: the gate still ran, still printed verdicts, and graded a
    /// conforming DV lane RED against a floor the server retired.
    static func driftAgainstProduct() -> [String] {
        var drift: [String] = []
        guard let readiness = VortXHLSStartupReadiness(
            frozenTarget: VortXHLSTargetPolicy.conservativeTarget) else {
            return ["VortXHLSStartupReadiness(frozenTarget: VortXHLSTargetPolicy.conservativeTarget)"
                    + " now returns nil; the production startup gate cannot be constructed the way"
                    + " VortXRemuxHLSServer.init constructs it"]
        }
        if minStartupSegments != readiness.minimumSegmentCount {
            drift.append("Contract.minStartupSegments = \(minStartupSegments) but"
                + " VortXHLSStartupReadiness.minimumSegmentCount = \(readiness.minimumSegmentCount)")
        }
        if minStartupMs != readiness.minimumRenderedDurationMilliseconds {
            drift.append("Contract.minStartupMs = \(minStartupMs) but"
                + " VortXHLSStartupReadiness.startupFloorMilliseconds ="
                + " \(readiness.minimumRenderedDurationMilliseconds)")
        }
        if hlsTargetDuration != readiness.frozenTarget.seconds {
            drift.append("Contract.hlsTargetDuration = \(hlsTargetDuration) but the server renders"
                + " startupReadiness.frozenTarget.seconds = \(readiness.frozenTarget.seconds)")
        }
        if segmentFailSoftSecs != VortXHLSTargetPolicy.conservativeSeconds {
            drift.append("Contract.segmentFailSoftSecs = \(segmentFailSoftSecs) but"
                + " VortXHLSTargetPolicy.conservativeSeconds = \(VortXHLSTargetPolicy.conservativeSeconds)")
        }
        // The cut floor is a default argument on the shipped decision function, so it is
        // proved BEHAVIOURALLY: one tick under the floor must not cut, the floor itself must.
        let justUnder = VortXHLSBoundaryPolicy.decision(
            hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
            elapsed: segmentCutFloorSecs - 0.001, frozenTargetSeconds: Double(segmentFailSoftSecs))
        let atFloor = VortXHLSBoundaryPolicy.decision(
            hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
            elapsed: segmentCutFloorSecs, frozenTargetSeconds: Double(segmentFailSoftSecs))
        if justUnder != .continueOpen || atFloor != .cut {
            drift.append("Contract.segmentCutFloorSecs = \(segmentCutFloorSecs) is no longer"
                + " VortXHLSBoundaryPolicy.decision's default targetSeconds"
                + " (just-under -> \(justUnder), at-floor -> \(atFloor))")
        }
        // The retired hard cut must STAY retired: a non-IDR packet may never open or cut a
        // segment at any elapsed time, which is what makes contract point 2 structural.
        for elapsed in [0.0, segmentCutFloorSecs, Double(segmentFailSoftSecs)] {
            let nonIDR = VortXHLSBoundaryPolicy.decision(
                hasOpenSegment: true, incomingIsIDR: false, incomingHasKeyFlag: false,
                elapsed: elapsed, frozenTargetSeconds: Double(segmentFailSoftSecs))
            if nonIDR == .cut || nonIDR == .open {
                drift.append("VortXHLSBoundaryPolicy.decision cut/opened a segment on a NON-IDR"
                    + " packet at elapsed \(elapsed)s (\(nonIDR)); the non-keyframe hard cut"
                    + " (MIS-260722-07) is back and contract point 2 is no longer structural")
            }
        }
        return drift
    }
}

/// The seven acceptance gates, in contract order.
enum Point: Int, CaseIterable {
    case startupCohort = 1
    case idrStart = 2
    case firstSegmentZero = 3
    case noAdvertised404 = 4
    case spoolBounded = 5
    case startupLatency = 6
    case failSoftCounted = 7

    var title: String {
        switch self {
        case .startupCohort:   return "Startup cohort >= \(Contract.minStartupSegments) segs AND >= \(Contract.minStartupMs) ms (integer-ms from EXTINF text)"
        case .idrStart:        return "Every published segment starts on an IDR frame"
        case .firstSegmentZero:return "First video seg id == 0 AND first alternate-audio seg id == 0"
        case .noAdvertised404: return "No advertised-segment 404 through the RFC 8216 s6.2.2 availability window"
        case .spoolBounded:    return "Spool bounded (Caches, session-global) and reclaimed to zero after session"
        case .startupLatency:  return "Startup latency SLO: mount -> readyToPlay <= 30000 ms"
        case .failSoftCounted: return "Fail-soft counted: exactly one cohort-timeout event + 404 on timeout, none otherwise"
        }
    }
}

/// A single check outcome. RED/GREEN are the acceptance signal; the others are
/// honest non-verdicts for the parts a given observation channel cannot decide.
enum Verdict: String {
    case green         = "GREEN"          // contract satisfied by observed behaviour
    case red           = "RED"            // contract violated by observed behaviour
    case exempt        = "EXEMPT"         // legitimately not applicable (e.g. `ended` short clip)
    case indeterminate = "INDETERMINATE"  // this channel cannot observe it (needs the live/filesystem channel)
    case pending       = "PENDING"        // mechanism absent in beta; positive path needs a fixture

    /// Only GREEN and EXEMPT are acceptable at the gate.
    var acceptable: Bool { self == .green || self == .exempt }
}

struct Finding {
    let point: Point
    let verdict: Verdict
    let evidence: [String]
}
