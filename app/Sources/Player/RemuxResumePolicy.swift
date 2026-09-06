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
/// `presented(playerSeconds:origin:)`, and every requested seek goes through `mountedSeekAction`. Targets the
/// current item serves then use `playerSeek`, which clamps in source time, maps through the origin, and clamps
/// in player time.
///
/// # Reaching content outside the current mount
///
/// Content before the origin or beyond the produced edge is not in the current stream. An in-item seek still
/// clamps to the bytes that item can serve, but the engine now asks `mountedSeekAction` first. A target outside
/// the current served window opens a fresh remux at that source second, using the same one-shot input seek and
/// timeline mapping as initial resume. This keeps ordinary in-window seeks cheap while making long scrubs and
/// backward seeks real instead of silently pinning them to the first few produced seconds.
enum RemuxResumePolicy {

    // MARK: - Should this mount start part-way in?

    /// The launch contract is now complete: the chrome configures a one-shot origin before `loadFile`, the
    /// AVPlayer engine consumes it before constructing the remux mount, and every reported/accepted clock is
    /// mapped through the achieved origin. Keep this explicit so a rollback can disable the feature without
    /// weakening the sanitisation or timeline-mapping tests below.
    static let isEnabledByDefault = true

    /// An internal retry owns the consumed origin even before its first item/intent exists.
    /// An unrelated source never inherits it. Explicit zero still overrides a previous resume.
    static func originForLoad(configuredOrigin: Double?, sameLogicalRequest: Bool,
                              previousOrigin: Double) -> Double {
        if let configuredOrigin { return originRequest(resumeSeconds: configuredOrigin) }
        return sameLogicalRequest ? originRequest(resumeSeconds: previousOrigin) : 0
    }

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

    /// The source second the remux should begin producing at, or 0 for "start at the beginning." Zero disables
    /// the resume input seek and keeps the public source origin at zero. A fresh HLS mount may still subtract a
    /// positive container timestamp from all tracks so its produced presentation begins at title zero.
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

    enum InputSeekOutcome: Equatable, Sendable {
        case primary
        case fallback
        case unavailable
    }

    /// Resolve the two FFmpeg input-seek attempts without ever treating a requested resume as "start at zero."
    /// A failed precise range seek may fall back to av_seek_frame after the demuxer is flushed. If neither
    /// succeeds, the remux must terminate so the existing libmpv recovery can reopen the same source at the
    /// preserved resume point.
    static func inputSeekOutcome(
        seekable: Bool,
        primaryResult: Int32?,
        fallbackResult: Int32?
    ) -> InputSeekOutcome {
        guard seekable, let primaryResult else { return .unavailable }
        if primaryResult >= 0 { return .primary }
        if let fallbackResult, fallbackResult >= 0 { return .fallback }
        return .unavailable
    }

    /// A nonnegative FFmpeg return code only means the demuxer accepted the seek operation. Some indexed
    /// network inputs still return success after landing at the beginning of the file. Accept the landing only
    /// when the mapped base-video clock proves that it reached the requested neighborhood. Otherwise the remux
    /// must fail before publishing bytes so the existing recovery can reopen the same target with libmpv.
    static func inputSeekLandingIsUsable(
        requestedSourceSeconds: Double,
        achievedOriginSeconds: Double
    ) -> Bool {
        let requested = originRequest(resumeSeconds: requestedSourceSeconds)
        guard requested > 0,
              achievedOriginSeconds.isFinite,
              achievedOriginSeconds >= 0 else { return false }
        let offset = achievedOriginSeconds - requested
        if offset > 0 {
            return offset <= forwardLandingToleranceSeconds
        }
        return -offset <= originToleranceSeconds
    }

    /// Timestamp basis differences can put the mapped presentation origin just after a backward-seek request.
    /// Keep that allowance below one second so a successful return cannot silently skip meaningful content.
    static let forwardLandingToleranceSeconds: Double = 0.25

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
    /// The ordering is the contract. Source and player duration are different domains after a resumed mount:
    /// AVPlayer may say the produced item is 3600s long while the source is 7200s long and begins at 3600s.
    /// Clamping a 5000s SOURCE request against the 3600s PLAYER duration before mapping incorrectly lands at
    /// player zero. Clamp the source target to the authoritative source duration first, subtract the origin,
    /// then apply the player duration and produced edge.
    ///
    /// The remaining boundary clamps keep a seek from stranding the mount with no frame:
    ///  - BELOW the origin: content before the origin was never produced, so the target clamps to the origin
    ///    (player second 0). A backward scrub past the resume point lands at the resume point instead of
    ///    failing. This is the cost named in the type comment.
    ///  - ABOVE the produced edge: unchanged from the pre-resume behavior. `producedEdgePlayerSeconds <= 0`
    ///    means the edge is unknown, in which case nothing is capped (the caller has no better information and
    ///    a wrong cap would be worse than none).
    static func playerSeek(sourceSeconds: Double,
                           origin: Double,
                           authoritativeSourceDurationSeconds: Double? = nil,
                           playerDurationSeconds: Double = 0,
                           producedEdgePlayerSeconds: Double) -> Double {
        guard sourceSeconds.isFinite else { return 0 }
        var sourceTarget = sourceSeconds
        if let sourceDuration = authoritativeSourceDurationSeconds,
           sourceDuration.isFinite, sourceDuration > 0 {
            sourceTarget = min(max(sourceTarget, 0), max(sourceDuration - 1, 0))
        }
        var target = sourceTarget - origin
        if target < 0 { target = 0 }
        if playerDurationSeconds.isFinite, playerDurationSeconds > 0 {
            target = min(target, max(playerDurationSeconds - 1, 0))
        }
        if producedEdgePlayerSeconds > 0, target > producedEdgePlayerSeconds {
            target = producedEdgePlayerSeconds
        }
        return target
    }

    enum MountedSeekAction: Equatable, Sendable {
        /// The current item already serves the target. The associated value is in AVPlayer's local clock.
        case seekPlayer(Double)
        /// The target is outside the current item. Open a new remux for this exact source destination. The
        /// engine separately sanitizes the mount origin, because a target inside the five-second input-seek
        /// floor still needs to restore to its requested second after mounting from zero.
        case remountAtSource(Double)
    }

    /// Equality tolerance for repeated absolute seeks delivered by system transport. Values inside one 60 Hz
    /// frame are the same destination for remount ownership; anything larger is a real newest-wins retarget.
    static let pendingRetargetToleranceSeconds: Double = 1.0 / 60.0

    /// Whether an in-flight remux must be replaced for a newer source destination. The comparison is against
    /// the exact requested destination, not the achieved keyframe origin, which is unavailable until the new
    /// item publishes. This keeps identical MediaRemote repeats inert without preserving the old one-GOP
    /// dead zone that could silently clamp a newer seek after readiness.
    static func pendingMountNeedsRetarget(
        requestedSourceSeconds: Double,
        mountedSourceRequestSeconds: Double
    ) -> Bool {
        guard requestedSourceSeconds.isFinite,
              mountedSourceRequestSeconds.isFinite else { return false }
        return abs(requestedSourceSeconds - mountedSourceRequestSeconds)
            > pendingRetargetToleranceSeconds
    }

    /// Decide whether a source-time seek can stay inside the mounted AVPlayer item or needs a new remux.
    ///
    /// A forward-only HLS item cannot serve bytes before its achieved origin or after its produced edge.
    /// Likewise, a sliding playlist may have evicted old bytes even though they are after the origin. Issuing
    /// an AVPlayer seek into any of those holes either pins the UI to the edge or produces no frame and demotes
    /// Dolby Vision. A fresh remux is the seek operation for those targets.
    ///
    /// `servedStartPlayerSeconds` comes from the earliest current seekable range. A nil value means AVPlayer
    /// has not published the range yet, so only the proven origin and produced-edge boundaries are applied.
    static func mountedSeekAction(
        sourceSeconds: Double,
        origin: Double,
        authoritativeSourceDurationSeconds: Double? = nil,
        playerDurationSeconds: Double = 0,
        servedStartPlayerSeconds: Double? = nil,
        producedEdgePlayerSeconds: Double
    ) -> MountedSeekAction {
        guard sourceSeconds.isFinite else { return .seekPlayer(0) }

        var sourceTarget = sourceSeconds
        if let sourceDuration = authoritativeSourceDurationSeconds,
           sourceDuration.isFinite, sourceDuration > 0 {
            sourceTarget = min(max(sourceTarget, 0), max(sourceDuration - 1, 0))
        } else {
            sourceTarget = max(sourceTarget, 0)
        }

        let playerTarget = sourceTarget - origin
        if playerTarget < 0 {
            return .remountAtSource(sourceTarget)
        }
        if let servedStartPlayerSeconds,
           servedStartPlayerSeconds.isFinite,
           servedStartPlayerSeconds > 0,
           playerTarget < servedStartPlayerSeconds {
            return .remountAtSource(sourceTarget)
        }
        if producedEdgePlayerSeconds > 0, playerTarget > producedEdgePlayerSeconds {
            return .remountAtSource(sourceTarget)
        }
        if producedEdgePlayerSeconds <= 0, playerTarget > originToleranceSeconds {
            return .remountAtSource(sourceTarget)
        }

        return .seekPlayer(playerSeek(
            sourceSeconds: sourceTarget,
            origin: origin,
            authoritativeSourceDurationSeconds: authoritativeSourceDurationSeconds,
            playerDurationSeconds: playerDurationSeconds,
            producedEdgePlayerSeconds: producedEdgePlayerSeconds))
    }

    /// Duration published to SOURCE-time chrome. A remux item's finite duration is measured from player zero,
    /// so an unknown source duration needs its achieved origin added back. The demuxer's duration is
    /// authoritative when present. A non-remux value is returned unchanged.
    static func reportedDuration(playerDurationSeconds: Double,
                                 origin: Double,
                                 authoritativeSourceDurationSeconds: Double?,
                                 isRemuxMounted: Bool) -> Double {
        guard isRemuxMounted else { return playerDurationSeconds }
        if let sourceDuration = authoritativeSourceDurationSeconds,
           sourceDuration.isFinite, sourceDuration > 0 {
            return sourceDuration
        }
        guard playerDurationSeconds.isFinite, playerDurationSeconds > 0,
              origin.isFinite else { return playerDurationSeconds }
        let sourceDuration = origin + playerDurationSeconds
        return sourceDuration.isFinite ? sourceDuration : playerDurationSeconds
    }

    // MARK: - The pre-start (resume) seek

    /// What to do with a seek that was issued BEFORE the item became playable, once it is.
    enum PreStartSeek: Equatable, Sendable {
        /// The mount landed AT (or past) the requested point: there is nothing to hide.
        case satisfied
        /// The mount landed on the keyframe AT OR BEFORE the requested point, within one GOP's worth of
        /// preroll (root-cause report section 7). Those extra frames decode correctly - an open GOP needs
        /// them as reference - but must never be PRESENTED: issue exactly one local seek to the associated
        /// PLAYER second once the item is ready, so the first frame the viewer actually sees is the requested
        /// target, not the earlier keyframe. This is well inside the produced startup cohort (readiness itself
        /// already guarantees at least that much is produced), so unlike `.unreachable` it can never land in
        /// unproduced bytes.
        case hidePreroll(Double)
        /// The requested point is ahead of where the mount begins, and the mount is forward-only, so the seek
        /// is DROPPED rather than issued. The associated value is how far ahead, in player seconds, purely so
        /// the caller can log an honest number. Dropping is what protects the session: issuing it would land
        /// in unproduced bytes and demote a true Dolby Vision play to libmpv.
        case unreachable(Double)
    }

    /// How close to the origin still counts as the SAME keyframe landing (vs. a genuinely failed/out-of-reach
    /// origin seek).
    ///
    /// The input seek lands on the keyframe AT OR BEFORE the request, so the mount legitimately starts a little
    /// earlier than asked. A GOP on a 4K source runs to a few seconds, so anything within this band is real
    /// keyframe preroll to hide (`.hidePreroll`, see its case doc); anything beyond it means the origin seek did
    /// not happen (or did not happen for this target) and the target is genuinely out of reach (`.unreachable`).
    static let originToleranceSeconds: Double = 12.0

    /// Resolve a pre-start seek against the mount's origin.
    ///
    /// `target - origin` is already the exact PLAYER-second position of `target` (by definition of the origin
    /// mapping `presented(playerSeconds:origin:) = origin + playerSeconds`), so `.hidePreroll`'s associated
    /// value doubles as the seek destination the caller issues once ready: no separate conversion needed.
    static func preStartSeek(target: Double, origin: Double) -> PreStartSeek {
        guard target.isFinite, origin.isFinite else { return .satisfied }
        let ahead = target - origin
        if ahead <= 0 { return .satisfied }
        if ahead <= originToleranceSeconds { return .hidePreroll(ahead) }
        return .unreachable(ahead)
    }
}

/// One-shot handoff from player chrome to the next engine load.
///
/// `Double?` is intentional: `nil` means the caller did not configure this load, while `.some(0)` means it
/// explicitly asked to begin at the start. That distinction lets an internal retry carrying the same logical
/// load token reuse its already-consumed origin without allowing an unrelated later title to inherit it.
struct RemuxResumeConfiguration {
    private(set) var pendingOriginSeconds: Double?

    mutating func configure(seconds: Double) {
        pendingOriginSeconds = RemuxResumePolicy.isEnabledByDefault
            ? RemuxResumePolicy.originRequest(resumeSeconds: seconds)
            : 0
    }

    mutating func consumeForNextLoad() -> Double? {
        defer { pendingOriginSeconds = nil }
        return pendingOriginSeconds
    }

    mutating func reset() {
        pendingOriginSeconds = nil
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
