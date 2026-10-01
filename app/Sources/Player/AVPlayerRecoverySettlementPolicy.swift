import Foundation

/// Identity-fenced state for the two AVPlayer operations that may settle after their initiating callback:
/// native legible deselection and a remount's recovery seek.  The engine owns the AVFoundation calls; this
/// type owns only the deterministic intent/receipt rules so they can be exercised without a media provider.
enum AVPlayerRecoverySettlementPolicy {
    struct Ownership: Equatable, Sendable {
        let generation: UInt64
        let mountIdentity: UInt64
        let revision: UInt64
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

        mutating func fail(requestID: UInt64) -> Bool {
            finish(requestID: requestID)
        }

        mutating func supersede() {
            ticket = nil
            issuedRequestID = nil
        }
    }
}
