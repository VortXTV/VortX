import Foundation

/// Pure decision logic for RESUMING a Dolby Vision (or plain) remux mount part-way into a title, deliberately
/// kept in a file that imports nothing but Foundation so a standalone harness can call the real functions.
/// Same reasoning as `DVPlaybackPolicy`: the code that uses these decisions lives in files that pull in
/// AVFoundation, Network and libav, so a test that could only scan their source text would prove a line exists,
/// not that it runs.
///
/// # The shape of the fix
///
/// The remux is a FORWARD-ONLY producer: one demux thread reads the source straight through, one muxer writes
/// into one linear in-memory buffer, and the HLS index addresses segments as byte ranges into that buffer. A
/// seek issued after the mount therefore lands in bytes that do not exist, no frame arrives, and the start
/// watchdog demotes the whole session to libmpv, which is why the chrome suppresses the resume seek entirely.
///
/// What this policy enables instead: the INPUT is seeked ONCE, before any byte is muxed, to the keyframe at or
/// before the resume point. Production then runs forward from there exactly as it always has, and every packet
/// is rebased so the produced stream still starts at zero. Nothing about the buffer, the segment index, the
/// playlist or the muxer changes. The one new fact in the system is the TIMELINE ORIGIN: the source second the
/// produced stream now begins at.
///
/// # Why the origin has to be mapped, not ignored
///
/// The chrome speaks SOURCE seconds everywhere: the stored resume point, the scrubber, progress saves, chapter
/// marks, skip segments, trickplay keys. The player speaks PLAYER seconds, which now start at the origin. If
/// the two are not reconciled at a single point, a resumed title saves its progress an hour early and wipes the
/// viewer's real position. So the engine converts at its one chokepoint: everything it REPORTS is
/// `presented(playerSeconds:origin:)`, and everything it is ASKED to seek to goes through
/// `playerSeek(sourceSeconds:origin:producedEdgePlayerSeconds:)`.
///
/// # What is deliberately NOT reachable
///
/// Content before the origin is not in the produced stream and cannot be, so a backward seek past it CLAMPS to
/// the origin rather than failing. That is the whole cost of resuming this way, and it is bounded and visible:
/// the clamp is in one function, the chrome's clamps read the same produced edge, and no path can strand the
/// mount frameless. Serving arbitrary positions on demand needs a different production model entirely; see the
/// note at the foot of this file.
enum RemuxResumePolicy {

    // MARK: - Should this mount start part-way in?

    /// This policy is deliberately dark. It may be linked and tested, but no launch path may act on it until
    /// the full origin lifecycle has an independently reviewed caller.
    static let isEnabledByDefault = false

    /// The smallest resume point worth seeking the input for.
    ///
    /// Below this the seek costs a keyframe hunt (a real network round trip on a debrid link, inside the cold
    /// start window that the watchdog is already watching) to skip an amount of content the viewer would not
    /// notice missing. It matches the chrome's own "ignore trivial positions" floor so the two agree about
    /// which resume points are real.
    static let minimumResumeSeconds: Double = 5.0

    /// A hard conversion bound. Seven days is beyond supported media duration and keeps the FFmpeg
    /// microsecond timestamp many orders of magnitude below `Int64.max`.
    static let maximumResumeSeconds: Double = 7.0 * 24 * 60 * 60

    /// The source second the remux should begin producing at, or 0 for "start at the beginning" (which
    /// reproduces today's behavior byte for byte, because 0 disables the input seek AND the packet rebase).
    ///
    /// Returns 0 rather than the raw value for anything not worth or not safe to act on: a non-finite value, a
    /// negative one, or a position inside the trivial floor.
    static func originRequest(resumeSeconds: Double) -> Double {
        guard resumeSeconds.isFinite,
              resumeSeconds > minimumResumeSeconds,
              resumeSeconds <= maximumResumeSeconds else { return 0 }
        return resumeSeconds
    }

    /// Checked conversion for `av_seek_frame`'s AV_TIME_BASE timestamp. Invalid and inactive requests return
    /// nil before any floating-point-to-integer conversion can trap.
    static func seekTimestampMicroseconds(resumeSeconds: Double) -> Int64? {
        let origin = originRequest(resumeSeconds: resumeSeconds)
        guard origin > 0 else { return nil }
        // `originRequest` has already proved 0 < origin <= seven days. At one million ticks per second the
        // largest result is 604,800,000,000, many orders below Int64.max, so this conversion is bounded by
        // the load-bearing maximum test rather than a second unreachable guard.
        let microseconds = origin * 1_000_000
        return Int64(microseconds.rounded())
    }

    /// The output timeline origin belongs to mapped base video. Audio, subtitles, data streams and unmapped
    /// packets may arrive first after a seek, but none may establish the clock used by every video segment.
    static func canEstablishOrigin(packetStreamIndex: Int,
                                   baseVideoStreamIndex: Int,
                                   isMapped: Bool) -> Bool {
        isMapped && packetStreamIndex >= 0 && packetStreamIndex == baseVideoStreamIndex
    }

    // MARK: - Player time <-> source time

    /// The SOURCE second to report for a given player clock reading.
    ///
    /// This is what makes a resumed session save its progress at the right place. Non-finite player readings
    /// (AVPlayer reports NaN before the first sample) collapse to the origin, which is where playback is about
    /// to begin, never to 0, because reporting 0 for a resumed title is precisely the value that would
    /// overwrite the stored position with the start of the film.
    static func presented(playerSeconds: Double, origin: Double) -> Double {
        guard playerSeconds.isFinite else { return origin }
        return origin + max(0, playerSeconds)
    }

    /// The PLAYER second to seek to for a seek expressed in source seconds, clamped to what the mount can
    /// actually serve.
    ///
    /// Two clamps, both of which exist to keep a seek from stranding the mount with no frame:
    ///  - BELOW the origin: content before the origin was never produced, so the target clamps to the origin
    ///    (player second 0). A backward scrub past the resume point lands at the resume point instead of
    ///    failing. This is the cost named in the type comment.
    ///  - ABOVE the produced edge: unchanged from the pre-resume behavior. `producedEdgePlayerSeconds <= 0`
    ///    means the edge is unknown, in which case nothing is capped (the caller has no better information and
    ///    a wrong cap would be worse than none).
    static func playerSeek(sourceSeconds: Double,
                           origin: Double,
                           producedEdgePlayerSeconds: Double) -> Double {
        guard sourceSeconds.isFinite else { return 0 }
        var target = sourceSeconds - origin
        if target < 0 { target = 0 }
        if producedEdgePlayerSeconds > 0, target > producedEdgePlayerSeconds {
            target = producedEdgePlayerSeconds
        }
        return target
    }

    // MARK: - The pre-start (resume) seek

    /// What to do with a seek that was issued BEFORE the item became playable, once it is.
    enum PreStartSeek: Equatable, Sendable {
        /// The mount already starts at (or past) the requested point: there is nothing to seek. This is the
        /// case a successful origin seek produces, and it is why resume now works without seeking at all.
        case satisfied
        /// The requested point is ahead of where the mount begins, and the mount is forward-only, so the seek
        /// is DROPPED rather than issued. The associated value is how far ahead, in player seconds, purely so
        /// the caller can log an honest number. Dropping is what protects the session: issuing it would land
        /// in unproduced bytes and demote a true Dolby Vision play to libmpv.
        case unreachable(Double)
    }

    /// How close to the origin counts as "already there".
    ///
    /// The input seek lands on the keyframe AT OR BEFORE the request, so the mount legitimately starts a little
    /// earlier than asked. A GOP on a 4K source runs to a few seconds, and re-seeking forward by that much
    /// would buy nothing and risk the produced edge. Anything beyond one long GOP means the origin seek did not
    /// happen (or did not happen for this target) and the target is genuinely out of reach.
    static let originToleranceSeconds: Double = 12.0

    /// Resolve a pre-start seek against the mount's origin.
    ///
    /// Note what is NOT here: a case that issues the seek. On a forward-only mount there is no pre-start seek
    /// worth issuing, because at the instant the item becomes playable the produced edge is only the startup
    /// segments. Either the origin already put us where we were asked to be, or the request cannot be honored.
    static func preStartSeek(target: Double, origin: Double) -> PreStartSeek {
        guard target.isFinite else { return .satisfied }
        let ahead = target - origin
        if ahead <= originToleranceSeconds { return .satisfied }
        return .unreachable(ahead)
    }
}

// MARK: - What on-demand segment production would require
//
// The alternative design (a full segment plan computed up front from the container keyframe index, segments
// produced ON DEMAND when requested) was rejected for this pass on the following evidence, recorded here so the
// next pass does not rediscover it:
//
//  1. SEGMENTS ARE BYTE RANGES INTO ONE LINEAR BUFFER. `VortXMKVRemuxStream.HLSSegment` is
//     (byteOffset, byteLength) into the single produced stream, and that stream is a SLIDING WINDOW with
//     eviction: an evicted segment already 404s. On-demand production means addressing any segment at any time,
//     which the window cannot back. It would need per-segment storage with its own lifetime.
//  2. ONE MUXER, ONE MOOV. All segments share one `EXT-X-MAP` init segment, so every segment must come from a
//     muxer whose moov is byte-identical to the published one and whose fragment sequence numbers and track
//     timescales continue it. movenc cannot be repositioned, so producing segment N out of order means a second
//     output context, and proving its init matches is a piece of work in itself.
//  3. THE PRODUCE PATH IS NOT RE-ENTRANT. One dedicated thread owns the demuxer, the muxer, the AVIO cursor,
//     the transcoder and the whole HLS cut state, most of it explicitly documented as remux-thread-only and
//     lock-free for that reason. Concurrent production is a rewrite of that ownership model, not an addition.
//  4. THE INPUT IS NOT RELIABLY SEEKABLE. A debrid HTTP link usually honors Range; the 127.0.0.1 torrent
//     loopback historically does not (the trailer Range-403 finding). A plan that assumes random access has no
//     fallback, whereas a single origin seek can simply fail and produce from 0.
//
// What would make it achievable: per-segment storage independent of the sliding window; a proven-identical init
// segment for any producer; a produce path that can be driven by more than one thread OR a work queue in front
// of a single producer that can be repositioned between segments; and a byte-seekability probe on the input
// with the linear path as the fallback. Until all four hold, an origin seek plus honest clamps is the correct
// smaller design.
