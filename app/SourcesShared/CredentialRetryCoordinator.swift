import Foundation

enum CredentialOwnerRetryOutcome<Value: Sendable>: Sendable {
    case acquired(Value)
    case exhausted
    case superseded
}

struct CredentialProviderRetryOutcome: Equatable, Sendable {
    let firstCompleted: Bool
    let secondCompleted: Bool
    let superseded: Bool

    var completed: Bool { firstCompleted && secondCompleted }
}

/// Exact sign-out transaction ordering shared by the immediate and retry paths. Durable deletion happens
/// while the pre-sign-out capture is still current. Only a second exact fence check can authorize binding
/// every credential store to the signed-out owner and publishing the live signed-out projection.
@MainActor
enum CredentialSignOutCoordinator {
    static func complete(
        isPreSignOutCurrent: () -> Bool,
        deletePersistedSession: () -> CredentialMutationResult,
        bindSignedOutOwner: () -> Bool,
        publishSignedOutState: () -> Void
    ) -> Bool {
        guard isPreSignOutCurrent() else { return false }
        guard deletePersistedSession() == .success else { return false }
        guard isPreSignOutCurrent() else { return false }
        guard bindSignedOutOwner() else { return false }
        publishSignedOutState()
        return true
    }
}

/// Small injected coordinator shared by the production owner and provider retry paths. Keeping the loop here
/// makes its bounded suspension, generation checks, and per-provider completion state executable without the
/// app graph; all actual credential mutation remains in the main-actor closures supplied by the manager.
@MainActor
enum CredentialRetryCoordinator {
    static func launch<Success: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Success
    ) -> Task<Success, Never> {
        Task { @MainActor in await operation() }
    }

    static func acquireOwner<Value: Sendable>(
        attempts: ClosedRange<Int>,
        delayBeforeFirstAttempt: Bool = false,
        isCurrent: @MainActor () -> Bool,
        tryAcquire: @MainActor (Int) -> Value?,
        denied: @MainActor (Int) -> Void,
        exhausted: @MainActor () -> Void,
        dropped: @MainActor () -> Void = {},
        sleepBeforeRetry: @MainActor () async -> Bool
    ) async -> CredentialOwnerRetryOutcome<Value> {
        var shouldDelay = delayBeforeFirstAttempt
        for attempt in attempts {
            guard !Task.isCancelled, isCurrent() else {
                dropped()
                return .superseded
            }
            if shouldDelay {
                guard await sleepBeforeRetry() else {
                    dropped()
                    return .superseded
                }
            }
            guard !Task.isCancelled, isCurrent() else {
                dropped()
                return .superseded
            }
            if let value = tryAcquire(attempt) { return .acquired(value) }
            denied(attempt)
            guard attempt != attempts.upperBound else {
                exhausted()
                return .exhausted
            }
            shouldDelay = true
        }
        exhausted()
        return .exhausted
    }

    /// Each provider owns independent completion state under the same capture fence. A successful provider
    /// is never claimed or finalized again while the other provider consumes its remaining bounded retries.
    static func finalizeProviders<Claim>(
        maximumAttempts: Int,
        isCurrent: @MainActor () -> Bool,
        firstClaim: @MainActor () -> Claim,
        firstClaimSucceeded: @MainActor (Claim) -> Bool,
        firstNeedsFinalization: @MainActor (Claim) -> Bool,
        firstFinalize: @MainActor () async -> Bool,
        secondClaim: @MainActor () -> Claim,
        secondClaimSucceeded: @MainActor (Claim) -> Bool,
        secondNeedsFinalization: @MainActor (Claim) -> Bool,
        secondFinalize: @MainActor () async -> Bool,
        sleepBeforeRetry: @MainActor () async -> Bool
    ) async -> CredentialProviderRetryOutcome {
        var firstCompleted = false
        var secondCompleted = false

        guard maximumAttempts > 0 else {
            return CredentialProviderRetryOutcome(
                firstCompleted: false,
                secondCompleted: false,
                superseded: false)
        }

        for attempt in 1...maximumAttempts {
            guard !Task.isCancelled, isCurrent() else {
                return CredentialProviderRetryOutcome(
                    firstCompleted: firstCompleted,
                    secondCompleted: secondCompleted,
                    superseded: true)
            }

            if !firstCompleted {
                let claim = firstClaim()
                if firstClaimSucceeded(claim) {
                    if firstNeedsFinalization(claim) {
                        let finalized = await firstFinalize()
                        guard !Task.isCancelled, isCurrent() else {
                            return CredentialProviderRetryOutcome(
                                firstCompleted: firstCompleted,
                                secondCompleted: secondCompleted,
                                superseded: true)
                        }
                        firstCompleted = finalized
                    } else {
                        firstCompleted = true
                    }
                }
            }

            if !secondCompleted {
                let claim = secondClaim()
                if secondClaimSucceeded(claim) {
                    if secondNeedsFinalization(claim) {
                        let finalized = await secondFinalize()
                        guard !Task.isCancelled, isCurrent() else {
                            return CredentialProviderRetryOutcome(
                                firstCompleted: firstCompleted,
                                secondCompleted: secondCompleted,
                                superseded: true)
                        }
                        secondCompleted = finalized
                    } else {
                        secondCompleted = true
                    }
                }
            }

            if firstCompleted && secondCompleted {
                return CredentialProviderRetryOutcome(
                    firstCompleted: true,
                    secondCompleted: true,
                    superseded: false)
            }
            guard attempt < maximumAttempts, await sleepBeforeRetry() else { break }
        }

        return CredentialProviderRetryOutcome(
            firstCompleted: firstCompleted,
            secondCompleted: secondCompleted,
            superseded: Task.isCancelled || !isCurrent())
    }
}
