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
    /// Stop producing once the produced tail is at least this far (in source seconds) ahead of the confirmed
    /// playhead.
    static let pauseAheadSeconds: Double = 90
    /// Resume only once the lead has fallen back below this. The gap between `pauseAheadSeconds` and this
    /// value is the hysteresis band: without it, a lead sitting exactly on one boundary would flip the gate on
    /// every publication cycle as ordinary segment-duration jitter crosses back and forth over a single value.
    static let resumeBelowSeconds: Double = 60

    /// Pure hysteresis decision. `leadSeconds` is `producedEnd - confirmedPlayheadSeconds`; a non-finite value
    /// (playhead not yet known, e.g. before the first playback receipt) fails closed to whatever the CURRENT
    /// state already is, so an unknown clock can never itself start or lift a pause.
    static func shouldPauseProducer(leadSeconds: Double, currentlyPaused: Bool) -> Bool {
        guard leadSeconds.isFinite else { return currentlyPaused }
        if currentlyPaused {
            // "resume below 60s" (report section 6): resume ONLY once strictly under the resume line, so a
            // lead sitting exactly on it stays paused rather than flapping.
            return !(leadSeconds < resumeBelowSeconds)
        }
        return leadSeconds >= pauseAheadSeconds
    }
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
