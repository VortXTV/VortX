import Foundation
import CoreFoundation

/// Missing provenance is not proof of guest ownership. A durable account exclusion is never cleared
/// merely by a failed session restore or another account bind; only a genuinely fresh device can mint
/// its initial guest receipt before the engine reads its persisted storage.
enum BecauseYouWatchedGuestProvenancePolicy {
    static func exclusionReceipt(from raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func acceptsDeviceHistory(exclusionReceipt: Bool?, isSignedOutDevice: Bool) -> Bool {
        isSignedOutDevice && exclusionReceipt == false
    }

    static func canEstablishCleanDevice(
        exclusionReceipt: Bool?, isSignedOutDevice: Bool, storageIsKnownFresh: Bool
    ) -> Bool {
        exclusionReceipt == nil && isSignedOutDevice && storageIsKnownFresh
    }

    static func storageIsKnownFresh(at directory: URL, fileManager: FileManager = .default) -> Bool {
        do {
            return try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty
        } catch {
            let failure = error as NSError
            return failure.domain == NSCocoaErrorDomain &&
                (failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError)
        }
    }
}

/// Foundation-only admission for account-owned Home recommendation history.
///
/// A settled UID is not sufficient: CoreBridge can still expose the prior account's published history
/// until a newer `library`/`continue_watching_preview` receipt arrives. Keeping this policy independent
/// from SwiftUI and the recommendation client lets tests exercise the exact production boundary.
enum BecauseYouWatchedHistoryPolicy {
    static let historyFields: Set<String> = ["library", "continue_watching_preview"]

    struct Owner: Equatable {
        let profileID: UUID
        let keychainAccount: String
        /// A non-nil UID proves a settled Stremio engine principal. `nil` is an explicit local-owner
        /// authority (signed-out or imported-away VortX history), never a wildcard for an unresolved UID.
        let uid: String?
        let generation: UInt64
    }

    struct Snapshot: Equatable {
        let owner: Owner?
        let revision: Int
        let changedFields: Set<String>
    }

    enum Decision: Equatable {
        case overlay
        case unsettledEngine
        case awaitingHistorySnapshot
        case readyEngine
    }

    /// Decide whether a call may use engine-backed watch history after a known owner boundary.
    static func decision(
        usesEngineHistory: Bool,
        activeProfileID: UUID?,
        activeKeychainAccount: String,
        snapshot: Snapshot?,
        minimumRevision: Int?
    ) -> Decision {
        guard usesEngineHistory else { return .overlay }
        guard let snapshot, let owner = snapshot.owner,
              owner.profileID == activeProfileID,
              owner.keychainAccount == activeKeychainAccount else {
            return .unsettledEngine
        }
        guard let minimumRevision,
              snapshot.revision > minimumRevision,
              !snapshot.changedFields.isDisjoint(with: historyFields) else {
            return .awaitingHistorySnapshot
        }
        return .readyEngine
    }
}

/// Stateful owner/revision latch used by `BecauseYouWatchedModel`.
///
/// `generation` is a completion fence for recommendation work. It advances on owner changes and on a
/// ready-owner mismatch, so a delayed response cannot repopulate a rail after the admission boundary.
/// The latch deliberately retains a boundary after Home has been cleared while a binding is unsettled:
/// the first exact current-owner history receipt is still useful even when it has the same engine
/// revision that was visible immediately before the clear. Dropping that boundary would leave the rail
/// waiting for an unrelated second engine event forever.
struct BecauseYouWatchedHistoryAdmission {
    private(set) var generation: UInt64 = 0
    private(set) var owner: BecauseYouWatchedHistoryPolicy.Owner?
    private(set) var ownerKey: String?
    private(set) var minimumRevision: Int?
    private(set) var isReady = false
    private var requiresNewBinding = false
    private var acceptsFirstCurrentOwnerReceipt = false

    mutating func evaluate(
        usesEngineHistory: Bool,
        activeProfileID: UUID?,
        activeKeychainAccount: String,
        ownerKey: String,
        snapshot: BecauseYouWatchedHistoryPolicy.Snapshot?
    ) -> BecauseYouWatchedHistoryPolicy.Decision {
        if self.ownerKey != ownerKey {
            let previousOwner = owner
            let snapshotOwner = snapshot?.owner
            let hasHistoryReceipt = !(snapshot?.changedFields.isDisjoint(
                with: BecauseYouWatchedHistoryPolicy.historyFields) ?? true)

            generation &+= 1
            self.ownerKey = ownerKey
            requiresNewBinding = false
            acceptsFirstCurrentOwnerReceipt = false

            guard usesEngineHistory else {
                owner = nil
                minimumRevision = nil
                isReady = true
                return .overlay
            }

            // A changed non-secret owner key can arrive before CoreBridge rotates its settled binding.
            // Keep the old owner as a required fence; an old-A snapshot must never be relabelled B.
            if let previousOwner, snapshotOwner == nil || snapshotOwner == previousOwner {
                owner = previousOwner
                minimumRevision = snapshot?.revision ?? minimumRevision
                requiresNewBinding = true
                acceptsFirstCurrentOwnerReceipt = true
                isReady = false
            } else {
                owner = snapshotOwner
                minimumRevision = snapshot?.revision
                // Initial Home appearance and the first receipt after an explicit unsettled clear are
                // both exact-owner receipts. They may be the only event emitted for this owner, so do
                // not force a second unrelated revision before admitting them.
                acceptsFirstCurrentOwnerReceipt = snapshotOwner != nil
                isReady = hasHistoryReceipt && snapshotOwner != nil
            }
        }

        guard usesEngineHistory else {
            owner = nil
            minimumRevision = nil
            requiresNewBinding = false
            acceptsFirstCurrentOwnerReceipt = false
            isReady = true
            return .overlay
        }

        if requiresNewBinding {
            guard let snapshotOwner = snapshot?.owner,
                  snapshotOwner != owner else {
                // Waiting for the new binding is not itself a new boundary. Keep the generation and
                // baseline stable so a repeated Home render cannot invalidate a delayed completion again.
                isReady = false
                return .awaitingHistorySnapshot
            }
            owner = snapshotOwner
            minimumRevision = snapshot?.revision
            requiresNewBinding = false
            let hasHistoryReceipt = !(snapshot?.changedFields.isDisjoint(
                with: BecauseYouWatchedHistoryPolicy.historyFields) ?? true)
            acceptsFirstCurrentOwnerReceipt = !hasHistoryReceipt
            isReady = hasHistoryReceipt
        }

        if isReady {
            guard let snapshot,
                  snapshot.owner == owner,
                  snapshot.owner?.profileID == activeProfileID,
                  snapshot.owner?.keychainAccount == activeKeychainAccount else {
                invalidate(using: snapshot)
                return .unsettledEngine
            }
            return .readyEngine
        }

        guard let snapshot,
              let snapshotOwner = snapshot.owner,
              snapshotOwner == owner,
              snapshotOwner.profileID == activeProfileID,
              snapshotOwner.keychainAccount == activeKeychainAccount else {
            return .unsettledEngine
        }

        let hasHistoryReceipt = !snapshot.changedFields.isDisjoint(with: BecauseYouWatchedHistoryPolicy.historyFields)
        if acceptsFirstCurrentOwnerReceipt && hasHistoryReceipt {
            isReady = true
            acceptsFirstCurrentOwnerReceipt = false
            return .readyEngine
        }

        let result = BecauseYouWatchedHistoryPolicy.decision(
            usesEngineHistory: true,
            activeProfileID: activeProfileID,
            activeKeychainAccount: activeKeychainAccount,
            snapshot: snapshot,
            minimumRevision: minimumRevision
        )
        if result == .readyEngine {
            isReady = true
            acceptsFirstCurrentOwnerReceipt = false
        }
        return result
    }

    /// Retire visible recommendation work while a selected engine profile has no settled binding.
    /// Preserve the pending owner key and old revision floor so the first exact current-owner history
    /// receipt can complete admission without requiring a later unrelated event.
    mutating func retireForUnsettledHistory(
        ownerKey: String,
        snapshot: BecauseYouWatchedHistoryPolicy.Snapshot?
    ) {
        generation &+= 1
        let previousOwner = owner
        self.ownerKey = ownerKey
        owner = snapshot?.owner ?? previousOwner
        minimumRevision = snapshot?.revision ?? minimumRevision
        requiresNewBinding = previousOwner != nil
        acceptsFirstCurrentOwnerReceipt = true
        isReady = false
    }

    /// Return whether a delayed recommendation completion still belongs to this admission boundary.
    /// Callers use the value-only token without exposing account credentials to the async worker.
    func isCurrent(_ completionGeneration: UInt64) -> Bool {
        completionGeneration == generation
    }

    mutating func reset() {
        generation &+= 1
        owner = nil
        ownerKey = nil
        minimumRevision = nil
        requiresNewBinding = false
        acceptsFirstCurrentOwnerReceipt = false
        isReady = false
    }

    private mutating func invalidate(using snapshot: BecauseYouWatchedHistoryPolicy.Snapshot?) {
        generation &+= 1
        isReady = false
        // Keep the latest observed floor, but allow an exact history receipt after an owner mismatch to
        // re-establish readiness even if the publisher reused the same revision for the boundary event.
        if let revision = snapshot?.revision { minimumRevision = revision }
        acceptsFirstCurrentOwnerReceipt = true
        // `requiresNewBinding` is reserved for a known same-slot replacement handled in the owner-key
        // branch. A ready-owner mismatch is already fenced by the exact `snapshotOwner == owner` check
        // below; setting this flag here would incorrectly reject the first valid receipt for that owner.
        requiresNewBinding = false
    }
}
