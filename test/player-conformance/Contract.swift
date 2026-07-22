import Foundation

// =============================================================================
// Player-rework ACCEPTANCE CONTRACT (REQ-260722-09 + REQ-260722-04 consensus).
//
// This file encodes the numeric contract ONCE, so every check reads the same
// constants. The harness verifies the RUNTIME BEHAVIOUR of the local HLS server
// (VortXRemuxHLSServer) against these values; it never asserts on source text.
//
// The plain remux lane and the Dolby Vision lane share the two mechanisms the
// contract governs - the startup gate in `serveMaster` and the playlist builder
// `VortXRemuxHLSServer.buildMediaBody` (which delegates to the dependency-free
// `DVPlaybackPolicy.mediaPlaylistLines`). So every behaviour below is observable
// with a plain (non-DV) MKV.
// =============================================================================

enum Contract {
    /// (1) Startup cohort. The FIRST media playlist may only be served once the
    /// produced stream has at least this many CLOSED segments AND advertises at
    /// least `minStartupMs` of media. Both floors, ANDed. Duration is compared
    /// as INTEGER milliseconds derived from the exact three-decimal EXTINF TEXT
    /// (never a float, never an internal packet double).
    static let minStartupSegments = 6
    static let minStartupMs = 36_000

    /// (6) Startup latency SLO: mount -> readyToPlay.
    static let sloMountToReadyMs = 30_000

    /// (7) The single fail-soft event the rework must emit EXACTLY ONCE on a
    /// cohort timeout (then a 404 into the libmpv demotion). Zero of them on a
    /// successful start or a user cancellation.
    static let cohortTimeoutEvent = "hls_startup_cohort_timeout"

    /// Frozen conservative segment target. Startup requires three targets of
    /// rendered media, independently of the 30-second wall-clock deadline.
    static let hlsTargetDuration = 12

    /// Exact session-global durable-spool admission ceiling. This is an
    /// admission bound, not an eviction target or a resident-window estimate.
    static let spoolAdmissionBytes = 536_870_912 // 512 * 1024 * 1024
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
        case .startupCohort:   return "Startup cohort >= 6 segs AND >= 36000 rendered-media ms (ended sources exempt)"
        case .idrStart:        return "Every published segment starts on an IDR frame"
        case .firstSegmentZero:return "First video seg id == 0 AND first alternate-audio seg id == 0"
        case .noAdvertised404: return "Every URI in each advertised [seq, seq+segs) window remains fetchable"
        case .spoolBounded:    return "Whole Caches/VortXHLS root <= 512 MiB with one active launch/session; reclaimed after teardown"
        case .startupLatency:  return "Separate wall SLO: mount -> readyToPlay strictly before 30000 ms"
        case .failSoftCounted: return "Timeout tuple: exactly one cohort event + /master.m3u8 404 + no ready"
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
