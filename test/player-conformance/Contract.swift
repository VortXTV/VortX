import Foundation

// =============================================================================
// Player-rework ACCEPTANCE CONTRACT (REQ-260722-09 + REQ-260722-04 consensus).
//
// This file encodes the numeric contract ONCE, so every check reads the same
// constants. The harness verifies the RUNTIME BEHAVIOUR of the local HLS server
// (VortXRemuxHLSServer) against these values; it never asserts on source text.
//
// The plain remux lane and the Dolby Vision lane share the two mechanisms the
// contract governs — the startup gate in `serveMedia` and the playlist builder
// `VortXRemuxHLSServer.buildMediaBody` (which delegates the header to the
// dependency-free `DVPlaybackPolicy.mediaPlaylistHeader`). So every behaviour
// below is observable with a plain (non-DV) MKV, which is all this machine has.
// =============================================================================

enum Contract {
    /// (1) Startup cohort. The FIRST media playlist may only be served once the
    /// produced stream has at least this many CLOSED segments AND advertises at
    /// least `minStartupMs` of media. Both floors, ANDed. Duration is compared
    /// as INTEGER milliseconds derived from the exact three-decimal EXTINF TEXT
    /// (never a float, never an internal packet double).
    static let minStartupSegments = 6
    static let minStartupMs = 15_000

    /// (6) Startup latency SLO: mount -> readyToPlay.
    static let sloMountToReadyMs = 30_000

    /// (7) The single fail-soft event the rework must emit EXACTLY ONCE on a
    /// cohort timeout (then a 404 into the libmpv demotion). Zero of them on a
    /// successful start or a user cancellation.
    static let cohortTimeoutEvent = "hls_startup_cohort_timeout"

    // --- Values mirrored from beta source, used only to REASON about observed
    //     behaviour (e.g. to recognise a hard-cut segment or size the resident
    //     window). They are not themselves the contract. ---

    /// VortXMKVRemuxStream.hlsMaxSegmentSecs — the hard time cut that fires on
    /// ANY frame (not only a keyframe). A non-final segment whose media duration
    /// equals this is a hard cut, which begins the NEXT segment mid-GOP: exactly
    /// the (2) non-IDR-start violation the rework must remove.
    static let hardCutSecs = 4.0
    /// VortXMKVRemuxStream.hlsMaxSegmentBytes — the 32 MiB hard byte cut, same
    /// non-keyframe hazard as the time cut.
    static let hardCutBytes = 32 << 20
    /// VortXMKVRemuxStream.hlsTargetDuration — EXT-X-TARGETDURATION (>= every
    /// EXTINF, constant across reloads).
    static let hlsTargetDuration = 5
    /// VortXRemuxBuffer window floor (dvRemuxWindowMiB default) in MiB. The
    /// resident sliding window is roughly this plus the producer lead; used to
    /// compute when an EVENT-advertised low segment has been evicted (point 4).
    static let windowFloorMiB = 64
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
        case .startupCohort:   return "Startup cohort >= 6 segs AND >= 15000 ms (integer-ms from EXTINF text)"
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
