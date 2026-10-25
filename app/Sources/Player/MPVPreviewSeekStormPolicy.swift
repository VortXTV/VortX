import Foundation

/// Bounds observational SEEK/RESTART work without dropping native settlement events or errors.
/// The controller serializes this state with load ownership under loadTokenLock.
struct MPVNativeSeekDiagnosticPolicy<Owner: Equatable> {
    struct Admission: Equatable, Sendable {
        let suppressedEvents: Int
    }

    private var owner: Owner?
    private var initialEventsRemaining = 4
    private var lastSampleTime: TimeInterval?
    private var suppressedEvents = 0

    mutating func reset(owner: Owner?) {
        self.owner = owner
        initialEventsRemaining = 4
        lastSampleTime = nil
        suppressedEvents = 0
    }

    /// Keep the first four events, then at most four full native diagnostic samples per second.
    /// An old load cannot consume a successor's quota or reset its sampling clock.
    mutating func admit(owner: Owner, now: TimeInterval) -> Admission? {
        guard self.owner == owner, now.isFinite else { return nil }
        if initialEventsRemaining > 0 {
            initialEventsRemaining -= 1
        } else if let lastSampleTime, now >= lastSampleTime, now - lastSampleTime < 0.25 {
            if suppressedEvents < Int.max { suppressedEvents += 1 }
            return nil
        }
        let admission = Admission(suppressedEvents: suppressedEvents)
        suppressedEvents = 0
        lastSampleTime = now
        return admission
    }
}

/// Containment for a decorative, full-file looping preview only. It never seeks/reloads media,
/// classifies EOF as successful playback, or participates in the main player's recovery policy.
/// Every observation and reset is serialized by the controller's loadTokenLock.
struct MPVPreviewSeekStormPolicy<Owner: Equatable> {
    struct Sample {
        let position: Double?
        let seeking: Bool?
        let paused: Bool?
        let cacheSeconds: Double?
        let forwardBytes: Int?
    }

    private var owner: Owner?
    private var stalledSince: TimeInterval?
    private var anchorPosition: Double?
    private var seekCount = 0
    private var failed = false

    mutating func reset(owner: Owner?) {
        self.owner = owner
        failed = false
        clearStall()
    }

    func hasFailed(owner: Owner) -> Bool {
        self.owner == owner && failed
    }

    mutating func recordNativeSeek(owner: Owner) {
        guard self.owner == owner, !failed else { return }
        if seekCount < Int.max { seekCount += 1 }
    }

    /// A settled native sample interrupts the continuous no-progress interval.
    /// Reset only the stall window, not the failure latch or diagnostic sampling quota.
    mutating func recordSettledPlayback(owner: Owner) {
        guard self.owner == owner, !failed else { return }
        clearStall()
    }

    /// Fail once after >=2 seconds, >=64 further native seeks, and repeated positive evidence
    /// of a running, continuously seeking, empty-cache player at an unchanged position.
    /// Missing/paused/refilling samples cannot authorize containment. Short normal loops have
    /// settled playback between their seeks and therefore continually reset this window.
    mutating func observe(owner: Owner, now: TimeInterval, sample: Sample) -> Bool {
        guard self.owner == owner, !failed else { return false }
        guard now.isFinite,
              sample.seeking == true, sample.paused == false,
              let position = sample.position, position.isFinite, position >= 0,
              let seconds = sample.cacheSeconds, seconds.isFinite, seconds == 0,
              sample.forwardBytes == 0 else {
            clearStall()
            return false
        }
        guard let started = stalledSince, let anchor = anchorPosition,
              now >= started, abs(position - anchor) <= 0.25 else {
            stalledSince = now
            anchorPosition = position
            seekCount = 0
            return false
        }
        guard now - started >= 2, seekCount >= 64 else { return false }
        failed = true
        return true
    }

    private mutating func clearStall() {
        stalledSince = nil
        anchorPosition = nil
        seekCount = 0
    }
}

// Owner identity is the only generic payload retained by these pure policies.
extension MPVNativeSeekDiagnosticPolicy: Sendable where Owner: Sendable {}
extension MPVPreviewSeekStormPolicy: Sendable where Owner: Sendable {}
