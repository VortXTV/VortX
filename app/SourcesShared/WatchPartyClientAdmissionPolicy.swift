import Foundation

/// Per-client monotonic watermark. A backwards, non-finite or negative sample permanently fails the
/// current epoch closed; a reconnect must create an entirely new ClientState/clockEpoch.
struct WatchPartyMonotonicClock {
    let epoch: UUID
    private(set) var last: Double?
    private(set) var invalid = false

    mutating func observe(_ now: Double) -> Double? {
        guard !invalid, now.isFinite, now >= 0, last.map({ now >= $0 }) ?? true else {
            invalid = true
            return nil
        }
        last = now
        return now
    }
}

struct WatchPartyClientState {
    let roomGeneration: String
    var leaderTerm: Int64
    var lastServerSequence: Int64
    var leaseDeadline: Double
    var clock: WatchPartyMonotonicClock
    let localOwnerGeneration: UUID
    var cancelled = false
    var admittedSequences: Set<Int64> = []
    var appliedSequences: Set<Int64> = []
    var pendingChallenge: WatchPartyPendingChallenge? = nil
}

struct WatchPartyAdmissionPermit: Equatable {
    let roomGeneration: String
    let leaderTerm: Int64
    let sequence: Int64
    let clockEpoch: UUID
    let localOwnerGeneration: UUID
    let deadline: Double
}

enum WatchPartyClientAdmissionPolicy {
    static func acceptsSelectedSubprotocol(_ value: String?) -> Bool { value == "vortx-party-v1" }

    static func deadline(requestStarted: Double, leaseRemainingMs: Int64, now: Double) -> Double? {
        guard requestStarted.isFinite, now.isFinite, requestStarted >= 0,
              now >= requestStarted, (1_000...30_000).contains(leaseRemainingMs) else { return nil }
        let value = requestStarted + Double(leaseRemainingMs)
        guard value.isFinite, now < value else { return nil }
        return value
    }

    static func admitsTitle(controlToken: String, currentToken: String) -> Bool {
        guard WatchPartyWire.canonicalTitleToken(controlToken) != nil,
              WatchPartyWire.canonicalTitleToken(currentToken) != nil else { return false }
        return controlToken == currentToken
    }

    static func sameOwner(expected: UUID, current: UUID) -> Bool { expected == current }

    static func leaderRenewalProofIsOrdered(after startingSequence: Int64,
                                             leaseRenewalSequence: Int64,
                                             challengeSequence: Int64) -> Bool {
        startingSequence >= 0 && startingSequence < Int64.max &&
            leaseRenewalSequence > startingSequence && challengeSequence >= leaseRenewalSequence
    }

    static func isRetiredChallengeProof(nonce: String?, pendingNonce: String?,
                                         retiredNonces: [String]) -> Bool {
        guard let nonce, nonce != pendingNonce else { return false }
        return retiredNonces.contains(nonce)
    }

    static func memberRefreshMustRetry(leaseSequenceAtRequest: Int64?,
                                       currentLeaseSequence: Int64?) -> Bool {
        leaseSequenceAtRequest != currentLeaseSequence
    }

    static func proofMatchesCurrentChallenge(nonce: String?, pending: WatchPartyPendingChallenge?,
                                              roomGeneration: String?, leaderTerm: Int64?,
                                              proofSequence: Int64?, currentSequence: Int64) -> Bool {
        guard let pending, nonce == pending.nonce,
              pending.roomGeneration == roomGeneration,
              pending.leaderTerm == leaderTerm,
              pending.sequence == proofSequence,
              proofSequence == currentSequence else { return false }
        return true
    }

    static func admit(state: inout WatchPartyClientState, sequence: Int64, roomGeneration: String,
                      leaderTerm: Int64, controlToken: String, currentToken: String,
                      currentOwner: UUID, now: Double) -> WatchPartyAdmissionPermit? {
        guard let observed = state.clock.observe(now), !state.cancelled,
              observed < state.leaseDeadline, state.localOwnerGeneration == currentOwner,
              state.roomGeneration == roomGeneration, state.leaderTerm == leaderTerm,
              state.lastServerSequence < Int64.max,
              sequence == state.lastServerSequence + 1,
              !state.admittedSequences.contains(sequence),
              admitsTitle(controlToken: controlToken, currentToken: currentToken) else {
            if state.clock.invalid { state.cancelled = true }
            return nil
        }
        state.lastServerSequence = sequence
        state.admittedSequences.insert(sequence)
        return WatchPartyAdmissionPermit(roomGeneration: roomGeneration, leaderTerm: leaderTerm,
            sequence: sequence, clockEpoch: state.clock.epoch, localOwnerGeneration: currentOwner,
            deadline: state.leaseDeadline)
    }

    /// Consume immediately before the synchronous player mutation; never suspend between consume and apply.
    static func consume(_ permit: WatchPartyAdmissionPermit, state: inout WatchPartyClientState,
                        currentOwner: UUID, now: Double) -> Bool {
        guard let observed = state.clock.observe(now), !state.cancelled, observed < permit.deadline,
              state.localOwnerGeneration == currentOwner,
              permit.localOwnerGeneration == currentOwner,
              permit.roomGeneration == state.roomGeneration,
              permit.leaderTerm == state.leaderTerm,
              permit.sequence == state.lastServerSequence,
              permit.clockEpoch == state.clock.epoch,
              permit.deadline == state.leaseDeadline,
              state.admittedSequences.contains(permit.sequence),
              !state.appliedSequences.contains(permit.sequence) else {
            if state.clock.invalid { state.cancelled = true }
            return false
        }
        state.appliedSequences.insert(permit.sequence)
        return true
    }
}


@MainActor
final class WatchPartyOperationFence {
    private(set) var current = UUID()
    @discardableResult func advance() -> UUID { current = UUID(); return current }
    func matches(_ captured: UUID) -> Bool { current == captured }
}


struct WatchPartyPendingChallenge: Equatable {
    let nonce: String
    let requestStarted: Double
    let roomGeneration: String
    let leaderTerm: Int64
    let sequence: Int64
}

