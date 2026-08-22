import Foundation

/// Bounds how far ahead of the confirmed playhead the remux producer is allowed to run (root-cause report
/// section 6).
///
/// Before this existed, the producer's only backpressure was the session spool's PHYSICAL byte ceiling
/// (`VortXHLSSessionSpool.capacityBytes`, ~1 GiB): as long as produced bytes fit under that cap, the producer
/// kept muxing ahead with no notion of the viewer's actual position. A high-bitrate 4K remux could then run
/// several MINUTES ahead of playback while still comfortably under the byte ceiling - exactly the field
/// timeline the report captured (playhead at 125.9s, ~428s of media already advertised). That unseen
/// produced-ahead suffix then crowded out `VortXHLSConsumptionWindowPolicy.floor`'s SEPARATE, smaller
/// `retainedWindowMaximumBytes` accounting, which is the direct cause of the failed ten-second rewind: the
/// floor computation walks segments newest-first, so a large ahead-of-frontier volume can exhaust that budget
/// before the loop ever reaches a single behind-frontier (rewind) segment.
///
/// This is a genuinely SEPARATE constraint from the rewind floor, not a replacement for it: bounding the
/// producer's lead keeps the ahead-of-frontier volume small so it can no longer starve the rewind reservation,
/// while `VortXHLSConsumptionWindowPolicy.floor` independently guarantees the behind-frontier history itself
/// (see that type's own header for the two-pool accounting fix).
enum VortXRemuxProducerLeadPolicy {
    /// One ordinary on-device session has one current and one recently superseded retained window, plus the
    /// operational and safety reservations: `2W + O + H = C`. An unseen producer tail may consume at most one
    /// window share. This keeps a high-bitrate remux from consuming the bytes reserved for the just-replaced
    /// playlist while AVPlayer is still legally entitled to read it.
    static let maximumAheadBytes = VortXHLSConsumptionWindowPolicy.retainedWindowMaximumBytes
    /// Stop producing once the produced tail is at least this far (in source seconds) ahead of the confirmed
    /// playhead.
    static let pauseAheadSeconds: Double = 90
    /// Resume only once the lead has fallen back below this. The gap between `pauseAheadSeconds` and this
    /// value is the hysteresis band: without it, a lead sitting exactly on one boundary would flip the gate on
    /// every publication cycle as ordinary segment-duration jitter crosses back and forth over a single value.
    static let resumeBelowSeconds: Double = 60

    /// Window publication policy is orthogonal to producer safety. In particular, the anchor-off rollback
    /// keeps a startup window pinned but must still apply the same local producer bound; only a hosted retaining
    /// mount and true EOF are exempt.
    static func shouldDriveProducerGate(consumptionAnchored: Bool,
                                        retainsFullTimeline: Bool,
                                        reachedEndOfStream: Bool) -> Bool {
        _ = consumptionAnchored
        return !retainsFullTimeline && !reachedEndOfStream
    }

    /// Pure hysteresis decision. `leadSeconds` is `producedEnd - confirmedPlayheadSeconds`; a non-finite value
    /// (playhead not yet known, e.g. before the first playback receipt) still honours the physical byte
    /// reservation.  A clockless startup is exactly when a fast remux used to fill the spool, so an unknown
    /// clock may never lift a byte-cap pause.
    static func shouldPauseProducer(leadSeconds: Double,
                                    aheadBytes: Int? = nil,
                                    currentlyPaused: Bool) -> Bool {
        guard aheadBytes.map({ $0 >= 0 }) ?? true else { return currentlyPaused }
        let overByteBudget = aheadBytes.map { $0 >= maximumAheadBytes } ?? false
        if overByteBudget { return true }
        guard leadSeconds.isFinite else { return currentlyPaused }
        if currentlyPaused {
            // "resume below 60s" (report section 6): resume ONLY once strictly under the resume line, so a
            // lead sitting exactly on it stays paused rather than flapping.
            return !(leadSeconds < resumeBelowSeconds && !overByteBudget)
        }
        return leadSeconds >= pauseAheadSeconds || overByteBudget
    }
}

/// Couples the PLAYER's steady-state forward-buffer appetite to the PRODUCER's byte ceiling
/// (Beta 25 diag 6, 2026-08-22).
///
/// The two sides were tuned independently and never checked against each other. After the first rendered
/// frame, `VortXRemuxForwardBufferPolicy.steadyStateSeconds` told AVPlayer to hold THIRTY seconds of media,
/// while `maximumAheadBytes` (352 MiB) lets the producer keep only what fits one retained window share. On
/// the Beta 25 field stream (~86.4 Mb/s, see `highThroughputProducerCannotConsumeTheRetainedWindowBudget`)
/// that ceiling is ~34 s of media: after AVPlayer filled its own 30 s target, ONE more published segment
/// (~6-12 s of media at 4K bitrates) crossed the byte cap and parked production. The playlist then froze
/// until the playhead consumed a full segment, AVPlayer tipped into
/// `AVPlayerWaitingToMinimizeStallsReason` on any jitter, and the stall watchdog remounted the whole remux -
/// sixteen-plus times in one episode (diag 6, ~323 s of visible buffering).
///
/// The fix keeps the spool reservation algebra untouched (`maximumAheadBytes` stays exactly one window
/// share, protecting the rewind floor) and instead sizes the player's ask to what production may legally
/// supply: target = affordable seconds - one conservative EXT-X-TARGETDURATION of fetch/granularity margin,
/// floored so an extreme-bitrate stream still gets a viable target rather than zero.
enum VortXRemuxForwardBufferCoupling {
    /// Fetch-latency + segment-granularity headroom demanded between the player target and the byte ceiling.
    /// One conservative EXT-X-TARGETDURATION (12 s here): a parked-gap of up to one target must never reach
    /// the playhead while AVPlayer still holds its full target.
    static let safetySeconds: TimeInterval = 12
    /// Floor for extreme bitrates, where even the ceiling affords little more than the margin itself. Well
    /// above the 4 s startup floor, so the coupled target never drops below proven-startable territory.
    static let minimumSteadyStateSeconds: TimeInterval = 8

    /// Pure decision. Unknown bitrate or a non-positive budget fails OPEN to `unconstrainedDuration`
    /// (today's behaviour), because a missing measurement must never shrink the player's buffer blindly.
    static func steadyStateDuration(aheadByteBudget: Int,
                                    observedBitsPerSecond: Double?,
                                    unconstrainedDuration: TimeInterval) -> TimeInterval {
        guard let bps = observedBitsPerSecond, bps > 0, bps.isFinite, aheadByteBudget > 0 else {
            return unconstrainedDuration
        }
        let affordableSeconds = Double(aheadByteBudget) * 8 / bps
        guard affordableSeconds.isFinite, affordableSeconds > 0 else { return unconstrainedDuration }
        let capped = affordableSeconds - safetySeconds
        guard capped < unconstrainedDuration else { return unconstrainedDuration }
        return max(minimumSteadyStateSeconds, capped)
    }
}

/// A single serialized frontier for producer-boundary and consumer-clock receipts.  It deliberately keeps
/// only the not-yet-consumed byte ledger instead of repeatedly copying the complete HLS window.  Receipt
/// ordering is monotonic: an old boundary or an old playhead can never reverse a newer gate decision.
struct VortXRemuxProducerLeadLedger: Sendable {
    struct Segment: Sendable {
        let id: Int
        let end: Double
        let byteLength: Int
    }

    private var segments: [Segment] = []
    private var firstUnconsumed = 0
    private var latestSegmentID = -1
    private var latestPlayhead: Double?
    private var aheadBytes = 0

    mutating func recordProduced(_ segment: Segment) {
        guard segment.id > latestSegmentID,
              segment.end.isFinite,
              segment.byteLength >= 0 else { return }
        latestSegmentID = segment.id
        segments.append(segment)
        if latestPlayhead.map({ segment.end > $0 }) ?? true {
            let (next, overflow) = aheadBytes.addingReportingOverflow(segment.byteLength)
            aheadBytes = overflow ? Int.max : next
        }
    }

    mutating func recordPlayback(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0,
              latestPlayhead.map({ seconds >= $0 }) ?? true else { return }
        latestPlayhead = seconds
        while firstUnconsumed < segments.count, segments[firstUnconsumed].end <= seconds {
            aheadBytes -= segments[firstUnconsumed].byteLength
            firstUnconsumed += 1
        }
        // A bounded compact keeps this O(1) amortized across a full title.
        if firstUnconsumed > 128, firstUnconsumed * 2 >= segments.count {
            segments.removeFirst(firstUnconsumed)
            firstUnconsumed = 0
        }
    }

    var producedEnd: Double? { segments.last?.end }
    var playbackSeconds: Double? { latestPlayhead }
    var outstandingBytes: Int { max(0, aheadBytes) }
    var outstandingSegmentCount: Int { max(0, segments.count - firstUnconsumed) }
}

/// Repeatable pause/resume gate for producer-lead backpressure. Unlike `VortXRemuxPreparationGate` (a
/// deliberately ONE-SHOT park/adopt/resume built for the single prepared-remux handoff, which permanently
/// disables further parking after its first `resume()`), this gate is driven by a live hysteresis decision
/// that legitimately flips many times across one session, so `setPaused(false)` here only lifts the CURRENT
/// pause - it never disables the gate. Checked at the SAME closed-segment-boundary point the preparation gate
/// already uses (`VortXMKVRemuxStream`'s HLS publish loop), so a pause can only ever land between fragments,
/// never split a GOP or leave a partial fragment unpublished, and can never be mistaken for a fatal condition:
/// this gate has no `failed`/terminal state of its own, only paused/not-paused/cancelled.
final class VortXRemuxProducerLeadGate: @unchecked Sendable {
    enum BoundaryOutcome: Equatable, Sendable {
        case continued
        case cancelled
    }

    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    /// Called from the consumer side (today: `VortXRemuxHLSServer`, the one object with a live playhead) with
    /// the fresh hysteresis decision on every publication cycle. Idempotent: setting the same value twice is a
    /// no-op, so a steady-state lead does not broadcast on every reload.
    func setPaused(_ newValue: Bool) {
        condition.lock()
        guard !cancelled, paused != newValue else {
            condition.unlock()
            return
        }
        paused = newValue
        condition.broadcast()
        condition.unlock()
    }

    /// Called from the producer thread at a closed-segment boundary. Blocks while paused; wakes immediately on
    /// cancellation so teardown is never delayed behind a stale pause.
    func waitAtClosedSegmentBoundaryIfPaused() -> BoundaryOutcome {
        condition.lock()
        while paused, !cancelled {
            condition.wait()
        }
        let outcome: BoundaryOutcome = cancelled ? .cancelled : .continued
        condition.unlock()
        return outcome
    }

    /// Wakes a parked producer permanently and stops honouring further `setPaused(true)` calls. Mirrors
    /// `VortXRemuxPreparationGate.cancel()`: session teardown must never leave the producer thread blocked.
    func cancel() {
        condition.lock()
        guard !cancelled else {
            condition.unlock()
            return
        }
        cancelled = true
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }
}
