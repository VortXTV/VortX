import Foundation

/// Identity-fenced state for AVPlayer operations that may settle after their initiating callback:
/// native legible deselection, admitted seeks and a remount's recovery seek. The engine owns the AVFoundation calls; this
/// type owns only the deterministic intent/receipt rules so they can be exercised without a media provider.
enum AVPlayerRecoverySettlementPolicy {
    struct Ownership: Equatable, Sendable {
        let generation: UInt64
        let mountIdentity: UInt64
        let revision: UInt64
    }

    /// An admitted seek is newer intent than the native clock until its own completion lands.
    /// Keep it separate from presentation/progress so fallback can recover the destination without
    /// reporting that an uncompleted seek has already played those seconds.
    struct SeekDestination: Equatable, Sendable {
        private(set) var ownership: Ownership?
        private(set) var sourceSeconds: Double?

        mutating func record(sourceSeconds: Double, ownership: Ownership) {
            guard sourceSeconds.isFinite else { clear(); return }
            self.ownership = ownership
            self.sourceSeconds = max(0, sourceSeconds)
        }

        func target(ownership: Ownership) -> Double? {
            self.ownership == ownership ? sourceSeconds : nil
        }

        @discardableResult
        mutating func finish(ownership: Ownership) -> Bool {
            guard self.ownership == ownership else { return false }
            clear()
            return true
        }

        mutating func clear() {
            ownership = nil
            sourceSeconds = nil
        }
    }

    /// A ready callback may invoke recovery work that synchronously replaces its item. This receipt fences the
    /// remainder of that old callback before it can publish selection topology or transport for the new mount.
    /// Item identity remains an engine concern; this type owns the generation/mount half of the receipt.
    struct ReadyContinuationOwnership: Equatable, Sendable {
        let generation: UInt64
        let mountIdentity: UInt64

        func isCurrent(generation: UInt64, mountIdentity: UInt64) -> Bool {
            self.generation == generation && self.mountIdentity == mountIdentity
        }
    }

    /// A remux input seek may be accepted just after its requested source timestamp. Recovery must use that
    /// achieved origin as its in-item target; retrying the original timestamp is before the mounted window and
    /// remounts forever. This is recovery-only: ordinary viewer seeks keep the strict mounted-window policy.
    static func normalizedRecoverySourceSeconds(
        requestedSourceSeconds: Double,
        achievedOriginSeconds: Double,
        acceptedForwardLandingTolerance: Double
    ) -> Double {
        guard requestedSourceSeconds.isFinite,
              achievedOriginSeconds.isFinite,
              acceptedForwardLandingTolerance.isFinite,
              acceptedForwardLandingTolerance >= 0 else {
            return requestedSourceSeconds.isFinite ? max(requestedSourceSeconds, 0) : 0
        }
        let requested = max(requestedSourceSeconds, 0)
        let forwardOffset = achievedOriginSeconds - requested
        guard forwardOffset > 0,
              forwardOffset <= acceptedForwardLandingTolerance else { return requested }
        return achievedOriginSeconds
    }

    struct ExternalSubtitleSettlement: Equatable, Sendable {
        private(set) var pending: Ownership?

        var hasPendingIntent: Bool { pending != nil }

        mutating func request(generation: UInt64, mountIdentity: UInt64, revision: UInt64) {
            pending = Ownership(
                generation: generation,
                mountIdentity: mountIdentity,
                revision: revision)
        }

        mutating func clear() {
            pending = nil
        }

        /// Returns true exactly once, and only when the current item reports that native legible selection is
        /// off for the same item/mount/revision that requested the external overlay.
        mutating func consumeIfNativeDeselected(
            generation: UInt64,
            mountIdentity: UInt64,
            revision: UInt64,
            nativeDeselected: Bool
        ) -> Bool {
            guard nativeDeselected,
                  pending == Ownership(
                    generation: generation,
                    mountIdentity: mountIdentity,
                    revision: revision
                  ) else { return false }
            pending = nil
            return true
        }
    }

    struct RecoverySeekTicket: Equatable, Sendable {
        let ownership: Ownership
        let sourceSeconds: Double
        let playbackRequested: Bool
    }

    /// A failed recovery hands the engine an exact bounded remount-or-error repair target. Returning this
    /// receipt rather than a Boolean prevents false/no-callback handling from silently deleting recovery.
    struct RecoverySeekRepair: Equatable, Sendable {
        let sourceSeconds: Double
    }

    struct RecoverySeekSettlement: Equatable, Sendable {
        private(set) var ticket: RecoverySeekTicket?
        private(set) var issuedRequestID: UInt64?

        mutating func issue(
            sourceSeconds: Double,
            playbackRequested: Bool,
            generation: UInt64,
            mountIdentity: UInt64,
            revision: UInt64
        ) -> RecoverySeekTicket {
            let ticket = RecoverySeekTicket(
                ownership: Ownership(
                    generation: generation,
                    mountIdentity: mountIdentity,
                    revision: revision),
                sourceSeconds: sourceSeconds.isFinite ? max(0, sourceSeconds) : 0,
                playbackRequested: playbackRequested)
            self.ticket = ticket
            issuedRequestID = nil
            return ticket
        }

        func owns(_ candidate: RecoverySeekTicket) -> Bool {
            ticket == candidate
        }

        mutating func bind(requestID: UInt64, ticket: RecoverySeekTicket) -> Bool {
            guard self.ticket == ticket else { return false }
            issuedRequestID = requestID
            return true
        }

        mutating func finish(requestID: UInt64) -> Bool {
            guard issuedRequestID == requestID else { return false }
            ticket = nil
            issuedRequestID = nil
            return true
        }

        mutating func fail(requestID: UInt64) -> RecoverySeekRepair? {
            guard issuedRequestID == requestID,
                  let ticket else { return nil }
            self.ticket = nil
            issuedRequestID = nil
            return RecoverySeekRepair(sourceSeconds: ticket.sourceSeconds)
        }

        mutating func supersede() {
            ticket = nil
            issuedRequestID = nil
        }
    }
}
