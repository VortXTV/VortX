import Foundation

/// One original login/import gesture. Only this real producer pairs the outcome with
/// the Session-created raw bundle and real complete-account preparation. No UUID-only
/// pairing, late source recapture, native action translation, receipt or persistence.
struct OwnerHistoryLoginPreparation: Sendable {
    struct Incomplete: Error {
        enum Reason: Sendable { case pendingMetadata, importUnavailable }
        let reason: Reason
    }
    let acknowledged: VortxNativeSession.OwnerHistoryAcknowledgedRead
    let account: OwnerHistoryAccountPreparation
    let outcome: VortxNativeOwnerHistoryPreparation.Outcome

    private init(acknowledged: VortxNativeSession.OwnerHistoryAcknowledgedRead,
        account: OwnerHistoryAccountPreparation, outcome: VortxNativeOwnerHistoryPreparation.Outcome) {
        self.acknowledged = acknowledged; self.account = account; self.outcome = outcome
    }

    static func prepare(acknowledged: VortxNativeSession.OwnerHistoryAcknowledgedRead,
        account: OwnerHistoryAccountPreparation, authKey: String) async throws -> Self {
        let read = acknowledged.originalRead
        guard account.originalAcknowledgedRead.originalRead === read else { throw VortxNativeError.superseded }
        try read.withActive {}
        let frame = try await VortxNativeOwnerHistoryPreparation.fetch(capture: acknowledged.source,
            authKey: authKey, authority: read)
        try read.withActive {}
        let outcome = try await VortxNativeOwnerHistoryPreparation.prepare(frame: frame, authority: read)
        try read.withActive {}
        return Self(acknowledged: acknowledged, account: account, outcome: outcome)
    }
}
