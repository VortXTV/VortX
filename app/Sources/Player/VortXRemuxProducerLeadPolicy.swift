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

    /// Fraction of the byte ceiling the producer must drain back to before a byte-cap park may lift. Mirrors
    /// the time-leg hysteresis gap (`resumeBelowSeconds` vs `pauseAheadSeconds`) on the byte leg: without it, a
    /// pause the byte cap forced with only a hair of margin insta-resumed one byte under the ceiling and
    /// re-parked production on the next published segment (Beta 26 F3 aheadBytes sawtooth around
    /// `retainedWindowMaximumBytes`).
    static let byteResumeFraction: Double = 0.85

    /// Absolute byte resume line: `maximumAheadBytes` scaled by `byteResumeFraction`.
    static let byteResumeThreshold = Int(Double(maximumAheadBytes) * byteResumeFraction)

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
            // A byte-cap park additionally demands a real down-drain below `byteResumeThreshold`: an unknown
            // byte count fails OPEN (nil resumes), but a measured count that is only a hair under the ceiling
            // stays paused, otherwise one published segment right after resuming re-crossed the cap and
            // re-parked production on the next segment (Beta 26 F3 sawtooth).
            let underByteResume = aheadBytes.map { $0 < byteResumeThreshold } ?? true
            return !(leadSeconds < resumeBelowSeconds && underByteResume)
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

    // MARK: Generation-owned evidence phase (branch review finding 2)

    /// The first rendered frame can beat the remux server's minimum sampling window (10 s of produced
    /// media), and the HLS `signaling.bandwidth` may not be parsed yet either. A ONE-SHOT coupling at the
    /// first-frame latch therefore missed permanently on fast starts and left the uncoupled 30 s ask in
    /// place for the whole item. The periodic observer runs much faster than the server's evidence window, so
    /// this must be elapsed-time driven rather than callback-count driven. A 0.25 s observer must never spend
    /// eight seconds of evidence time in one second of wall-clock playback.
    static let sampleRetryIntervalSeconds: TimeInterval = 2
    /// At this point the item still needs a survivable local-remux target even if no byte-backed estimate has
    /// arrived. The fallback deliberately matches the proven viable floor, but is NOT a terminal decision:
    /// sampling continues until real evidence can replace it.
    static let conservativeFallbackSeconds: TimeInterval = minimumSteadyStateSeconds
    static let fallbackElapsedSeconds: TimeInterval = 8
    /// Local-remux bitrate accounting needs approximately ten seconds of produced media before it becomes a
    /// trustworthy coupling input. Earlier declared values are retained as evidence but cannot finish the
    /// phase by themselves.
    static let minimumEvidenceElapsedSeconds: TimeInterval = 10

    /// Coupling ownership for exactly one player-item generation. A replaced mount/item resets the attempt
    /// timing anchor and the estimate; stale callbacks from the old generation can never retune the new item.
    /// `finished` latches the end of the evidence phase so steady-state ticks pay nothing. `lastSampleElapsed`
    /// makes the two-second rate limit explicit and generation-owned instead of coupling it to observer tick
    /// frequency.
    struct AttemptState: Equatable {
        let generation: UInt64
        var lastSampleElapsedSeconds: TimeInterval?
        var samplesTaken: Int
        var bestBitsPerSecond: Double?
        var fallbackApplied: Bool
        var finished: Bool = false

        init(generation: UInt64 = 0, attemptsUsed: Int = 0, bestBitsPerSecond: Double? = nil) {
            self.generation = generation
            self.lastSampleElapsedSeconds = nil
            self.samplesTaken = attemptsUsed
            self.bestBitsPerSecond = bestBitsPerSecond
            self.fallbackApplied = false
        }

        /// Kept as a source-compatible diagnostic count while callers migrate to the elapsed-time API. It is
        /// observability only, never an evidence budget.
        var attemptsUsed: Int {
            get { samplesTaken }
            set { samplesTaken = newValue }
        }
    }

    /// Monotonic estimate merge. An EARLY low sample must never pull the estimate down for a stream whose
    /// later segments are materially larger (variable-bitrate sources), so the best-known value only ever
    /// rises within one generation. The authoritative declared bandwidth participates on equal terms.
    static func effectiveEstimate(observed: Double?, indicated: Double?, best: Double?) -> Double? {
        [observed, indicated, best]
            .compactMap { $0 }
            .filter { $0.isFinite && $0 > 0 }
            .max()
    }

    /// A completed schedule is inert for its owning item. A new item generation is due immediately even when
    /// the prior generation finished, because its bitrate evidence and configured AVPlayerItem are different.
    static func isAttemptDue(state: AttemptState, currentGeneration: UInt64) -> Bool {
        state.generation != currentGeneration || !state.finished
    }

    /// Returns whether a real evidence sample may run now. Invalid or regressing elapsed time fails safely:
    /// it leaves the current generation's state untouched and cannot consume a sample. A newly observed
    /// generation begins at elapsed zero, so its first actual sample is due no earlier than two seconds.
    static func isAttemptDue(state: AttemptState,
                             currentGeneration: UInt64,
                             elapsedSinceFirstFrame: TimeInterval) -> Bool {
        guard elapsedSinceFirstFrame.isFinite, elapsedSinceFirstFrame >= 0 else { return false }
        guard state.generation == currentGeneration else {
            return elapsedSinceFirstFrame >= sampleRetryIntervalSeconds
        }
        guard !state.finished else { return false }
        guard let lastSampleElapsedSeconds = state.lastSampleElapsedSeconds else {
            return elapsedSinceFirstFrame >= sampleRetryIntervalSeconds
        }
        guard elapsedSinceFirstFrame >= lastSampleElapsedSeconds else { return false }
        return elapsedSinceFirstFrame - lastSampleElapsedSeconds >= sampleRetryIntervalSeconds
    }

    /// Elapsed-time evidence phase for exactly one local-remux item generation. It samples at most once every
    /// two seconds; after eight seconds of missing evidence it actively applies an eight-second fallback but
    /// stays live; at ten seconds or later a valid observed/indicated estimate replaces that fallback with the
    /// byte-budget-coupled target and finishes the phase. Direct and remote mounts remain outside this policy
    /// because their callers never invoke it.
    static func nextCouplingAttempt(state: AttemptState,
                                    currentGeneration: UInt64,
                                    elapsedSinceFirstFrame: TimeInterval,
                                    observedBitsPerSecond: Double?,
                                    indicatedBitsPerSecond: Double?,
                                    aheadByteBudget: Int,
                                    baseDuration: TimeInterval)
        -> (state: AttemptState, applyDuration: TimeInterval?, finished: Bool) {
        guard elapsedSinceFirstFrame.isFinite, elapsedSinceFirstFrame >= 0 else {
            return (state, nil, state.finished)
        }
        var next = state.generation == currentGeneration
            ? state
            : AttemptState(generation: currentGeneration)
        guard !next.finished else { return (next, nil, true) }
        guard isAttemptDue(
            state: next,
            currentGeneration: currentGeneration,
            elapsedSinceFirstFrame: elapsedSinceFirstFrame
        ) else {
            return (next, nil, false)
        }

        next.lastSampleElapsedSeconds = elapsedSinceFirstFrame
        next.samplesTaken += 1
        next.bestBitsPerSecond = effectiveEstimate(
            observed: observedBitsPerSecond,
            indicated: indicatedBitsPerSecond,
            best: next.bestBitsPerSecond)

        // Wait until the remux has had enough media time to produce an evidence-backed coupling. The fallback
        // exists only for the no-evidence case, and applying it does not stop this state machine.
        if elapsedSinceFirstFrame >= minimumEvidenceElapsedSeconds,
           let bps = next.bestBitsPerSecond {
            next.finished = true
            let duration = steadyStateDuration(
                aheadByteBudget: aheadByteBudget,
                observedBitsPerSecond: bps,
                unconstrainedDuration: baseDuration)
            return (next, duration, true)
        }
        if elapsedSinceFirstFrame >= fallbackElapsedSeconds,
           next.bestBitsPerSecond == nil,
           !next.fallbackApplied {
            next.fallbackApplied = true
            return (next, conservativeFallbackSeconds, false)
        }
        return (next, nil, false)
    }

    /// Compatibility entry point for callers that have not yet supplied an item-relative elapsed clock. It
    /// preserves the pre-existing bounded behaviour so this policy can land before the engine wiring changes.
    /// Local-remux production must use the elapsed-time overload above; this wrapper intentionally cannot
    /// promise observer-rate independence because it has no clock input.
    static func nextCouplingAttempt(state: AttemptState,
                                    currentGeneration: UInt64,
                                    observedBitsPerSecond: Double?,
                                    indicatedBitsPerSecond: Double?,
                                    aheadByteBudget: Int,
                                    baseDuration: TimeInterval)
        -> (state: AttemptState, applyDuration: TimeInterval?, finished: Bool) {
        var next = state.generation == currentGeneration
            ? state
            : AttemptState(generation: currentGeneration)
        if next.finished { return (next, nil, true) }
        let merged = effectiveEstimate(
            observed: observedBitsPerSecond,
            indicated: indicatedBitsPerSecond,
            best: next.bestBitsPerSecond)
        if let bps = merged {
            next.bestBitsPerSecond = bps
            next.finished = true
            let duration = steadyStateDuration(
                aheadByteBudget: aheadByteBudget,
                observedBitsPerSecond: bps,
                unconstrainedDuration: baseDuration)
            return (next, duration, true)
        }
        if next.samplesTaken + 1 >= 5 {
            next.finished = true
            return (next, nil, true)
        }
        next.samplesTaken += 1
        return (next, nil, false)
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

    /// Only an accepted post-seek clock may reset the monotonic frontier. Rebuild from the real retained
    /// window: the compacted consumption ledger no longer contains segments a backward seek can revisit.
    mutating func reanchor(to seconds: Double, retainedSegments: [Segment]) {
        guard seconds.isFinite, seconds >= 0 else { return }
        self = Self()
        for segment in retainedSegments { recordProduced(segment) }
        recordPlayback(seconds)
    }

    mutating func recordProduced(_ segment: Segment) {
        guard segment.id > latestSegmentID,
              segment.end.isFinite,
              segment.byteLength >= 0 else { return }
        latestSegmentID = segment.id
        segments.append(segment)
        let (next, overflow) = aheadBytes.addingReportingOverflow(segment.byteLength)
        aheadBytes = overflow ? Int.max : next
        // A boundary callback may arrive after a seek receipt already moved past that segment. Account it
        // once, then consume it once; excluding the addition but later subtracting it undercounted the lead.
        if let latestPlayhead { recordPlayback(latestPlayhead) }
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
