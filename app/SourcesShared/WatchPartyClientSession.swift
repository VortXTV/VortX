import CryptoKit
import Foundation
import Security

/// One class identity per connection. Production owns the URLSession, delegate
/// and task together; controlled tests implement this same async boundary.
@MainActor
protocol WatchPartySessionSocket: AnyObject, Sendable {
    func resume()
    func waitForProtocol(timeoutNanoseconds: UInt64) async -> String?
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
}

/// Apple-side transport owner for the v2 ephemeral party service. This is an
/// afterimage only; callers must supply auth and player ownership captures.
@MainActor
final class WatchPartyClientSession {
    typealias Auth = VortXWatchPartyAuthSnapshot

    struct Membership: Codable, Equatable, Sendable {
        let roomId: String
        let id: String
        let capability: String
        let role: String?
        let incarnation: Int?
    }

    struct Snapshot: Codable, Equatable, Sendable {
        let roomGeneration: String
        let leaderTerm: Int64
        let serverSequence: Int64
        let memberCount: Int?
        let leaseRemainingMs: Int64
        let expiresAtMs: Int64?
        let nonce: String?
    }

    struct RoomReceipt: Decodable, Sendable {
        let roomId: String
        let leaderId: String?
        let capability: String
        let inviteCode: String
        let snapshot: Snapshot
    }

    struct JoinReceipt: Decodable, Sendable {
        let roomId: String
        let id: String
        let capability: String
        let role: String?
        let incarnation: Int?
        let snapshot: Snapshot
    }

    struct ControlEnvelope: Decodable, Sendable {
        let kind: String
        let roomGeneration: String?
        let leaderTerm: Int64?
        let serverSequence: Int64?
        let ciphertext: String?
        let type: String?
        let nonce: String?
        let leaseRemainingMs: Int64?
    }

    enum Failure: Error { case signedOut, staleAuth, invalidRoom, rejected, malformed, expired, ownerChanged, reservationRetired }

    struct Dependencies {
        let http: @MainActor (URLRequest, Set<String>, Int) async throws -> AuthenticatedHTTPResponse
        let makeSocket: @MainActor (URL, [String]) -> any WatchPartySessionSocket
        let sleep: @MainActor (UInt64) async throws -> Void

        fileprivate static var live: Dependencies {
            Dependencies(
                http: { request, hosts, limit in
                    try await AuthenticatedHTTPTransport.shared.send(
                        request, allowedHosts: hosts, maxResponseBytes: limit)
                },
                makeSocket: { url, protocols in LiveSocket(url: url, protocols: protocols) },
                sleep: { try await Task.sleep(nanoseconds: $0) })
        }
    }

    private let base = URL(string: "https://api.vortx.tv/v1/watch-parties")!
    private let allowedHosts: Set<String> = ["api.vortx.tv"]
    private let dependencies: Dependencies
    private var socket: (any WatchPartySessionSocket)?
    private let operationFence = WatchPartyOperationFence()
    private var operationGeneration: UUID { operationFence.current }
    private var reservationGeneration: UUID?
    private var reserveWasSent = false
    private var latestReservationRetirementSequence: Int64?
    private struct PendingPublication {
        let reservationID: UUID
        let sequence: Int64
        let ciphertext: String
        var sent = false
        var retired = false
        var outcome: Result<Void, Error>?
        var continuation: CheckedContinuation<Void, Error>?
    }
    private var pendingPublication: PendingPublication?
    private var publicationTimeoutTask: Task<Void, Never>?
    private var member: Membership?
    private var roomKey: Data?
    private var playbackState: WatchPartyClientState?
    private var renewalTask: Task<Void, Never>?
    private var reservationContinuation: CheckedContinuation<Reservation, Error>?
    private var reservationTimeoutTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var receiveTimeout: (id: UUID, task: Task<Void, Never>)?
    private var outgoingTail: Task<Void, Error>?
    private var latestLeaseRenewalSequence: Int64?
    private var leaderRenewalWaiter: (generation: UUID, socket: any WatchPartySessionSocket,
                                     afterSequence: Int64, continuation: CheckedContinuation<Int64, Error>)?
    private var leaderRenewalTimeoutTask: Task<Void, Never>?
    private var challengeTask: Task<Void, Never>?
    private var retiredChallengeNonces: [String] = []
    private var isRechallenging = false
    private var challengeRestartID: UUID?
    private var needsMemberRefreshAfterLeaseEvent = false
    private let monotonicNow: () -> Double

    init(monotonicNow: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime * 1_000 }) {
        self.monotonicNow = monotonicNow
        self.dependencies = .live
    }

#if WATCH_PARTY_ASYNC_TESTS
    init(testing dependencies: Dependencies, monotonicNow: @escaping () -> Double) {
        self.monotonicNow = monotonicNow
        self.dependencies = dependencies
    }

    struct TestingState {
        let generation: UUID
        let socketID: ObjectIdentifier?
        let serverSequence: Int64?
        let leaseDeadline: Double?
        let pendingNonce: String?
        let pendingSequence: Int64?
        let latestLeaseSequence: Int64?
        let needsMemberRefresh: Bool
        let restartID: UUID?
        let isRechallenging: Bool
        let hasReservation: Bool
    }

    var testingState: TestingState {
        TestingState(generation: operationGeneration, socketID: socket.map { ObjectIdentifier($0) },
            serverSequence: playbackState?.lastServerSequence, leaseDeadline: playbackState?.leaseDeadline,
            pendingNonce: playbackState?.pendingChallenge?.nonce,
            pendingSequence: playbackState?.pendingChallenge?.sequence,
            latestLeaseSequence: latestLeaseRenewalSequence,
            needsMemberRefresh: needsMemberRefreshAfterLeaseEvent,
            restartID: challengeRestartID, isRechallenging: isRechallenging,
            hasReservation: reservationContinuation != nil)
    }
#endif

    /// Caller generates/stores the returned roomKey in memory and exposes it only in the
    /// local fragment/QR. The invite code never derives or transports that key.
    func create(auth: Auth, currentAuth: @MainActor () -> Auth?) async throws -> (RoomReceipt, Data) {
        invalidateLocalSession()
        let operation = operationGeneration
        let key = try Self.newRoomKey()
        let receipt: RoomReceipt = try await post("", body: EmptyRequest(), auth: auth, currentAuth: currentAuth)
        guard isCurrent(operation), !Task.isCancelled, currentAuth() == auth,
              Self.validOpaque(receipt.roomId), let leaderId = receipt.leaderId,
              Self.validOpaque(leaderId), Self.validOpaque(receipt.capability),
              Self.validOpaque(receipt.inviteCode), Self.valid(receipt.snapshot) else { throw Failure.malformed }
        guard isCurrent(operation), !Task.isCancelled else { throw Failure.ownerChanged }
        member = Membership(roomId: receipt.roomId, id: leaderId, capability: receipt.capability,
                            role: "leader", incarnation: 1)
        roomKey = key
        return (receipt, key)
    }

    func join(roomId: String, inviteCode: String, roomKey: Data, auth: Auth,
              currentAuth: @MainActor () -> Auth?) async throws -> JoinReceipt {
        guard Self.validOpaque(roomId), Self.validOpaque(inviteCode), roomKey.count == 32 else { throw Failure.invalidRoom }
        invalidateLocalSession()
        let operation = operationGeneration
        let receipt: JoinReceipt = try await post("/\(roomId)/join", body: InviteRequest(inviteCode: inviteCode), auth: auth, currentAuth: currentAuth)
        guard isCurrent(operation), !Task.isCancelled, currentAuth() == auth, receipt.roomId == roomId, Self.validOpaque(receipt.id),
              Self.validOpaque(receipt.capability), Self.valid(receipt.snapshot) else { throw Failure.malformed }
        guard isCurrent(operation), !Task.isCancelled else { throw Failure.ownerChanged }
        member = Membership(roomId: roomId, id: receipt.id, capability: receipt.capability,
                            role: receipt.role, incarnation: receipt.incarnation)
        self.roomKey = roomKey
        return receipt
    }

    /// Single-use ticket is offered as a WebSocket subprotocol only. It is never a URL
    /// component, query parameter, Authorization header, Cookie, or logged value.
    func connect(snapshot: Snapshot, localOwnerGeneration: UUID, auth: Auth,
                 currentAuth: @MainActor @escaping () -> Auth?) async throws {
        guard currentAuth() == auth, let member, let key = roomKey, key.count == 32,
              Self.valid(snapshot) else { throw Failure.signedOut }
        advanceOperationPreservingMembership()
        let operation = operationGeneration
        let ticket: TicketReceipt = try await post("/\(member.roomId)/ticket", body: MemberRequest(member), auth: auth, currentAuth: currentAuth)
        guard isCurrent(operation), !Task.isCancelled, currentAuth() == auth,
              self.member == member, roomKey == key, Self.validOpaque(ticket.ticket) else { throw Failure.staleAuth }
        var components = URLComponents(url: base.appendingPathComponent(member.roomId).appendingPathComponent("connect"), resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        guard let url = components?.url, url.query == nil, url.fragment == nil else { throw Failure.invalidRoom }
        let task = dependencies.makeSocket(url, ["vortx-party-v1", "vortx-ticket.\(ticket.ticket)"])
        socket = task
        task.resume()
        let negotiated = await task.waitForProtocol(timeoutNanoseconds: 8_000_000_000)
        guard isCurrent(operation), !Task.isCancelled, self.socket === task, currentAuth() == auth,
              WatchPartyClientAdmissionPolicy.acceptsSelectedSubprotocol(negotiated) else {
            invalidateIfCurrent(operation, socket: task)
            throw Failure.rejected
        }
        let handshakeStarted = monotonicNow()
        guard handshakeStarted.isFinite, handshakeStarted >= 0 else { invalidateIfCurrent(operation, socket: task); throw Failure.expired }
        playbackState = WatchPartyClientState(roomGeneration: snapshot.roomGeneration, leaderTerm: snapshot.leaderTerm,
            lastServerSequence: snapshot.serverSequence, leaseDeadline: handshakeStarted + 30_000,
            clock: WatchPartyMonotonicClock(epoch: UUID(), last: handshakeStarted),
            localOwnerGeneration: localOwnerGeneration)
        let nonce = try Self.randomOpaqueToken()
        let challengeStarted = monotonicNow()
        guard challengeStarted.isFinite, challengeStarted >= handshakeStarted else { invalidateIfCurrent(operation, socket: task); throw Failure.expired }
        do {
            try await send(SocketRequest(kind: "lease.challenge", nonce: nonce), to: task, generation: operation)
            guard isCurrent(operation), !Task.isCancelled, self.socket === task, currentAuth() == auth else { throw Failure.staleAuth }
            let proof = try await receiveProof(expectedNonce: nonce, deadline: handshakeStarted + 10_000,
                                               generation: operation, expectedSocket: task,
                                               currentAuth: currentAuth, auth: auth, localOwnerGeneration: localOwnerGeneration)
            guard isCurrent(operation), !Task.isCancelled, self.socket === task, currentAuth() == auth else { throw Failure.staleAuth }
            try accept(proof, requestStarted: challengeStarted, localOwnerGeneration: localOwnerGeneration)
        } catch {
            invalidateIfCurrent(operation, socket: task)
            throw error
        }
        beginReceiveLoop(auth: auth, currentAuth: currentAuth, localOwnerGeneration: localOwnerGeneration)
        beginLivenessLoop(auth: auth, currentAuth: currentAuth, localOwnerGeneration: localOwnerGeneration)
    }

    /// Leader-only outbound control. The relay allocates the sequence; ciphertext is
    /// authenticated to that exact reservation before it is published.
    func sendControl(_ control: WatchPartyWire.Control, currentOwner: @MainActor () -> ApplyContext?,
                     auth: Auth, currentAuth: @MainActor () -> Auth?) async throws {
        guard pendingPublication == nil, let capturedOwner = currentOwner(),
              capturedOwner.target.stillOwnsCurrentContext(core: CoreBridge.shared),
              WatchPartyClientAdmissionPolicy.admitsTitle(controlToken: control.mediaId,
                currentToken: capturedOwner.titleToken),
              currentAuth() == auth, member?.role == "leader",
              let socket, var state = playbackState, observe(monotonicNow(), state: &state), !state.cancelled,
              state.clock.last.map({ $0 < state.leaseDeadline }) == true,
              ["play", "pause", "seek"].contains(control.action), control.positionMs >= 0,
              control.positionMs <= 86_400_000 else { throw Failure.ownerChanged }
        playbackState = state
        let operation = operationGeneration
        let reservationID = UUID()
        let reservation = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reservation, Error>) in
                guard reservationContinuation == nil, reservationGeneration == nil,
                      isCurrent(operation), self.socket === socket else {
                    continuation.resume(throwing: Failure.rejected); return
                }
                reservationContinuation = continuation
                reservationGeneration = reservationID
                reserveWasSent = false
                reservationTimeoutTask?.cancel()
                reservationTimeoutTask = Task { [weak self, sleep = self.dependencies.sleep] in
                    do { try await sleep(5_000_000_000) }
                    catch { return }
                    guard let self, self.isCurrent(operation), self.reservationGeneration == reservationID,
                          let pending = self.reservationContinuation else { return }
                    self.reservationContinuation = nil
                    self.reservationTimeoutTask = nil
                    pending.resume(throwing: Failure.expired)
                    // An unanswered reservation may still arrive; close this socket so it
                    // cannot be mistaken for a later reservation on the same connection.
                    self.invalidateIfCurrent(operation, socket: socket)
                }
                Task { [weak self] in
                    do {
                        guard let self, self.isCurrent(operation), self.socket === socket else { throw Failure.expired }
                        try await self.send(ReserveRequest(kind: "reserve"), to: socket,
                            generation: operation, reservationID: reservationID, reserving: true)
                    } catch {
                        guard let self, self.isCurrent(operation), self.reservationGeneration == reservationID,
                              let pending = self.reservationContinuation else { return }
                        self.reservationContinuation = nil
                        self.reservationTimeoutTask?.cancel(); self.reservationTimeoutTask = nil
                        pending.resume(throwing: error)
                        self.invalidateIfCurrent(operation, socket: socket)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelReservation(reservationID, generation: operation) }
        })
        guard reservationGeneration == reservationID else { throw Failure.reservationRetired }
        guard isCurrent(operation), !Task.isCancelled, currentAuth() == auth, self.socket === socket,
              reservationGeneration == reservationID,
              var currentState = playbackState, observe(monotonicNow(), state: &currentState),
              currentState.clock.last.map({ $0 < currentState.leaseDeadline }) == true,
              let refreshedOwner = currentOwner(), Self.samePlaybackOwner(capturedOwner, refreshedOwner),
              refreshedOwner.target.stillOwnsCurrentContext(core: CoreBridge.shared),
              !currentState.cancelled,
              currentState.roomGeneration == reservation.roomGeneration,
              currentState.leaderTerm == reservation.leaderTerm,
              currentState.lastServerSequence < Int64.max,
              currentState.lastServerSequence + 1 == reservation.serverSequence,
              let key = roomKey,
              let ciphertext = WatchPartyWire.seal(control, roomKey: key,
                roomGeneration: reservation.roomGeneration, leaderTerm: reservation.leaderTerm,
                serverSequence: reservation.serverSequence) else {
            invalidateIfCurrent(operation, socket: socket)
            throw Failure.ownerChanged
        }
        playbackState = currentState
        guard isCurrent(operation), !Task.isCancelled, self.socket === socket else { throw Failure.ownerChanged }
        pendingPublication = PendingPublication(reservationID: reservationID,
            sequence: reservation.serverSequence, ciphertext: ciphertext)
        publicationTimeoutTask?.cancel()
        publicationTimeoutTask = Task { [weak self, sleep = self.dependencies.sleep] in
            do { try await sleep(5_000_000_000) } catch { return }
            guard let self, self.isCurrent(operation), self.socket === socket,
                  let pending = self.pendingPublication,
                  pending.reservationID == reservationID, pending.outcome == nil else { return }
            self.invalidateIfCurrent(operation, socket: socket)
        }
        do {
            try await send(PublishRequest(kind: "publish", reservationId: reservation.reservationId,
                roomGeneration: reservation.roomGeneration, leaderTerm: reservation.leaderTerm,
                serverSequence: reservation.serverSequence, ciphertext: ciphertext), to: socket,
                generation: operation, reservationID: reservationID, publishing: true)
            try await waitForPublication(reservationID, generation: operation, socket: socket)
        } catch {
            clearPublication(reservationID)
            if let failure = error as? Failure, case .reservationRetired = failure {
                if reservationGeneration == reservationID {
                    reservationGeneration = nil
                    reserveWasSent = false
                }
                throw error
            }
            invalidateIfCurrent(operation, socket: socket)
            throw error
        }
        clearPublication(reservationID)
        guard reservationGeneration == reservationID else { throw Failure.reservationRetired }
        guard isCurrent(operation), !Task.isCancelled, self.socket === socket,
              reservationGeneration == reservationID,
              currentAuth() == auth,
              let finalOwner = currentOwner(), Self.samePlaybackOwner(capturedOwner, finalOwner),
              finalOwner.target.stillOwnsCurrentContext(core: CoreBridge.shared) else {
            invalidateIfCurrent(operation, socket: socket)
            throw Failure.ownerChanged
        }
        reservationGeneration = nil
        reserveWasSent = false
    }

    func leave(auth: Auth, currentAuth: @MainActor () -> Auth?) async {
        let oldMember = member
        invalidateLocalSession() // revoke locally before the network await
        let operation = operationGeneration
        guard let oldMember, currentAuth() == auth else { return }
        do {
            let _: EmptyReceipt? = try await post("/\(oldMember.roomId)/leave", body: MemberRequest(oldMember), auth: auth, currentAuth: currentAuth)
        } catch { /* local leave is already complete; network cleanup is best effort */ }
        guard isCurrent(operation), !Task.isCancelled else { return }
    }

    struct ApplyContext {
        let target: PlaybackMutationTarget
        let auth: Auth
        let titleToken: String
        let playbackSessionID: String
        let loadToken: PlayerLoadToken
        let localOwnerGeneration: UUID
    }

    struct ApplyGuard {
        let roomGeneration: String
        let leaderTerm: Int64
        let sequence: Int64
        let clockEpoch: UUID
        let localOwnerGeneration: UUID
        let titleToken: String
        let playbackSessionID: String
        let loadToken: PlayerLoadToken
        let target: PlaybackMutationTarget
        let auth: Auth
    }

    struct AdmittedControl { let control: WatchPartyWire.Control; let guardValue: ApplyGuard }

    /// Decrypt and sequence admission stays on MainActor; the caller supplies a fresh
    /// owner snapshot from PlayerScreen/TVPlayerView in the same actor turn.
    private static func samePlaybackOwner(_ lhs: ApplyContext, _ rhs: ApplyContext) -> Bool {
        lhs.target == rhs.target && lhs.titleToken == rhs.titleToken &&
            lhs.playbackSessionID == rhs.playbackSessionID && lhs.loadToken == rhs.loadToken &&
            lhs.localOwnerGeneration == rhs.localOwnerGeneration && lhs.auth == rhs.auth
    }

    func admit(_ control: WatchPartyWire.Control, sequence: Int64, current: ApplyContext?,
               currentAuth: @MainActor () -> Auth?) -> AdmittedControl? {
        guard var state = playbackState, !state.cancelled, let current,
              currentAuth() == current.auth,
              current.target.stillOwnsCurrentContext(core: CoreBridge.shared) else { return nil }
        guard let permit = WatchPartyClientAdmissionPolicy.admit(state: &state, sequence: sequence,
            roomGeneration: state.roomGeneration, leaderTerm: state.leaderTerm,
            controlToken: control.mediaId, currentToken: current.titleToken,
            currentOwner: current.localOwnerGeneration, now: monotonicNow()) else {
            playbackState = state
            return nil
        }
        playbackState = state
        return AdmittedControl(control: control, guardValue: ApplyGuard(
            roomGeneration: permit.roomGeneration, leaderTerm: permit.leaderTerm, sequence: permit.sequence,
            clockEpoch: permit.clockEpoch, localOwnerGeneration: permit.localOwnerGeneration,
            titleToken: current.titleToken, playbackSessionID: current.playbackSessionID,
            loadToken: current.loadToken, target: current.target, auth: current.auth))
    }

    /// Recheck and consume in one MainActor turn immediately before the synchronous player mutation.
    func apply(_ admitted: AdmittedControl, current: ApplyContext?,
               currentAuth: @MainActor () -> Auth?, perform: (WatchPartyWire.Control) -> Bool) -> Bool {
        let expected = admitted.guardValue
        guard var state = playbackState, !state.cancelled, let current,
              expected.roomGeneration == state.roomGeneration,
              expected.leaderTerm == state.leaderTerm,
              expected.sequence == state.lastServerSequence,
              expected.clockEpoch == state.clock.epoch,
              expected.localOwnerGeneration == state.localOwnerGeneration,
              currentAuth() == expected.auth, current.auth == expected.auth,
              current.localOwnerGeneration == expected.localOwnerGeneration,
              current.titleToken == expected.titleToken,
              current.playbackSessionID == expected.playbackSessionID,
              current.loadToken == expected.loadToken,
              current.target == expected.target,
              current.target.stillOwnsCurrentContext(core: CoreBridge.shared) else { return false }
        let permit = WatchPartyAdmissionPermit(roomGeneration: expected.roomGeneration,
            leaderTerm: expected.leaderTerm, sequence: expected.sequence, clockEpoch: expected.clockEpoch,
            localOwnerGeneration: expected.localOwnerGeneration, deadline: state.leaseDeadline)
        guard WatchPartyClientAdmissionPolicy.consume(permit, state: &state,
            currentOwner: current.localOwnerGeneration, now: monotonicNow()) else {
            playbackState = state
            return false
        }
        playbackState = state
        return perform(admitted.control)
    }

    func cancel() { invalidateLocalSession() }

    private func invalidateLocalSession() {
        let hadOwnership = member != nil || socket != nil || playbackState != nil ||
            reservationContinuation != nil || pendingPublication != nil
        operationFence.advance() // fence all suspended continuations before cancellation/close
        abandonPublication()
        renewalTask?.cancel(); renewalTask = nil
        receiveTask?.cancel(); receiveTask = nil
        receiveTimeout?.task.cancel(); receiveTimeout = nil
        outgoingTail?.cancel(); outgoingTail = nil
        reservationTimeoutTask?.cancel(); reservationTimeoutTask = nil
        leaderRenewalTimeoutTask?.cancel(); leaderRenewalTimeoutTask = nil
        challengeTask?.cancel(); challengeTask = nil
        isRechallenging = false
        challengeRestartID = nil
        needsMemberRefreshAfterLeaseEvent = false
        retiredChallengeNonces.removeAll(keepingCapacity: false)
        if let waiter = leaderRenewalWaiter {
            leaderRenewalWaiter = nil
            waiter.continuation.resume(throwing: Failure.expired)
        }
        latestLeaseRenewalSequence = nil
        latestReservationRetirementSequence = nil
        reservationGeneration = nil
        reserveWasSent = false
        if let pending = reservationContinuation { reservationContinuation = nil; pending.resume(throwing: Failure.expired) }
        socket?.close(); socket = nil
        playbackState = nil; member = nil; roomKey = nil
        // Notify a real transition once. A callback may defensively call cancel()
        // again after teardown; an already-disconnected owner must not re-notify.
        if hadOwnership { onDisconnected?() }
    }

    private func isCurrent(_ generation: UUID) -> Bool { operationFence.matches(generation) }

    private func advanceOperationPreservingMembership() {
        operationFence.advance() // revoke old callbacks first
        abandonPublication()
        renewalTask?.cancel(); renewalTask = nil
        receiveTask?.cancel(); receiveTask = nil
        receiveTimeout?.task.cancel(); receiveTimeout = nil
        outgoingTail?.cancel(); outgoingTail = nil
        reservationTimeoutTask?.cancel(); reservationTimeoutTask = nil
        leaderRenewalTimeoutTask?.cancel(); leaderRenewalTimeoutTask = nil
        challengeTask?.cancel(); challengeTask = nil
        isRechallenging = false
        challengeRestartID = nil
        needsMemberRefreshAfterLeaseEvent = false
        retiredChallengeNonces.removeAll(keepingCapacity: false)
        if let waiter = leaderRenewalWaiter {
            leaderRenewalWaiter = nil
            waiter.continuation.resume(throwing: Failure.expired)
        }
        latestLeaseRenewalSequence = nil
        latestReservationRetirementSequence = nil
        reservationGeneration = nil
        reserveWasSent = false
        if let pending = reservationContinuation { reservationContinuation = nil; pending.resume(throwing: Failure.expired) }
        socket?.close(); socket = nil
        playbackState = nil
    }

    private func invalidateIfCurrent(_ generation: UUID, socket expectedSocket: (any WatchPartySessionSocket)? = nil) {
        guard isCurrent(generation), expectedSocket == nil || socket === expectedSocket else { return }
        invalidateLocalSession()
    }

    private func cancelReservation(_ id: UUID, generation: UUID) {
        guard isCurrent(generation), reservationGeneration == id,
              let pending = reservationContinuation else { return }
        let expectedSocket = socket
        reservationGeneration = nil; reservationContinuation = nil
        reserveWasSent = false
        reservationTimeoutTask?.cancel(); reservationTimeoutTask = nil
        pending.resume(throwing: CancellationError())
        if let expectedSocket { invalidateIfCurrent(generation, socket: expectedSocket) }
    }

    /// Advancing room metadata retires a server sequence reservation. Release the
    /// old caller before notifying UI so it can reserve a fresh latest snapshot.
    private func retireReservationAfterEvent(sequence: Int64) {
        latestReservationRetirementSequence = sequence
        if var publication = pendingPublication, publication.sent,
           publication.outcome == nil, sequence >= publication.sequence {
            // No request IDs exist on errors. Keep the original operation in its
            // slot until its own echo or known stale error has been consumed.
            publication.retired = true
            pendingPublication = publication
            return
        }
        // A reserve already sent may still return its grant. Consume that exact
        // response before permitting any successor reserve on this socket.
        if reservationContinuation != nil, reserveWasSent { return }
        guard reservationGeneration != nil || reservationContinuation != nil else { return }
        if let publication = pendingPublication { clearPublication(publication.reservationID) }
        reservationGeneration = nil
        reserveWasSent = false
        reservationTimeoutTask?.cancel(); reservationTimeoutTask = nil
        if let pending = reservationContinuation {
            reservationContinuation = nil
            pending.resume(throwing: Failure.reservationRetired)
        }
    }

    private func finishPublication(_ id: UUID, outcome: Result<Void, Error>) {
        guard var pending = pendingPublication, pending.reservationID == id,
              pending.outcome == nil else { return }
        pending.outcome = outcome
        let continuation = pending.continuation
        pending.continuation = nil
        pendingPublication = pending
        publicationTimeoutTask?.cancel(); publicationTimeoutTask = nil
        continuation?.resume(with: outcome)
    }

    private func clearPublication(_ id: UUID) {
        guard let pending = pendingPublication, pending.reservationID == id else { return }
        pendingPublication = nil
        publicationTimeoutTask?.cancel(); publicationTimeoutTask = nil
        pending.continuation?.resume(throwing: Failure.expired)
    }

    private func abandonPublication() {
        let pending = pendingPublication
        pendingPublication = nil
        publicationTimeoutTask?.cancel(); publicationTimeoutTask = nil
        pending?.continuation?.resume(throwing: Failure.expired)
    }

    private func waitForPublication(_ id: UUID, generation: UUID,
                                    socket expectedSocket: any WatchPartySessionSocket) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard isCurrent(generation), socket === expectedSocket, !Task.isCancelled,
                      var pending = pendingPublication, pending.reservationID == id,
                      pending.continuation == nil else {
                    continuation.resume(throwing: Failure.expired); return
                }
                if let outcome = pending.outcome { continuation.resume(with: outcome); return }
                pending.continuation = continuation
                pendingPublication = pending
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.invalidateIfCurrent(generation, socket: expectedSocket) }
        })
    }

    private func observe(_ now: Double, state: inout WatchPartyClientState) -> Bool {
        guard state.clock.observe(now) != nil else {
            state.cancelled = true
            playbackState = state
            return false
        }
        return true
    }

    private func post<Body: Encodable, Response: Decodable>(_ suffix: String, body: Body, auth: Auth,
            currentAuth: @MainActor () -> Auth?) async throws -> Response {
        guard currentAuth() == auth, !auth.bearer.isEmpty else { throw Failure.staleAuth }
        guard let endpoint = URL(string: base.absoluteString + suffix) else { throw Failure.invalidRoom }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(auth.bearer)", forHTTPHeaderField: "authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let response = try await dependencies.http(request, allowedHosts,
            AuthenticatedHTTPTransport.controlResponseLimit)
        guard currentAuth() == auth else { throw Failure.staleAuth }
        guard response.data.count <= AuthenticatedHTTPTransport.controlResponseLimit else { throw Failure.malformed }
        guard (200..<300).contains(response.statusCode) else { throw Failure.rejected }
        return try AuthenticatedHTTPTransport.decodeJSON(Response.self, from: response.data)
    }

    private func send<T: Encodable>(_ value: T, to expectedSocket: any WatchPartySessionSocket,
                                    generation: UUID, reservationID: UUID? = nil,
                                    reserving: Bool = false, publishing: Bool = false) async throws {
        guard isCurrent(generation), socket === expectedSocket, !Task.isCancelled else { throw Failure.expired }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 12_000 else { throw Failure.malformed }
        let previous = outgoingTail
        let write = Task { @MainActor [weak self] in
            if let previous { do { try await previous.value } catch { /* drain the old failed write */ } }
            try Task.checkCancellation()
            guard let self, self.isCurrent(generation), self.socket === expectedSocket else { throw Failure.expired }
            if let reservationID, self.reservationGeneration != reservationID { throw Failure.reservationRetired }
            if reserving { self.reserveWasSent = true }
            if publishing, var pending = self.pendingPublication,
               pending.reservationID == reservationID {
                pending.sent = true
                self.pendingPublication = pending
            }
            try await expectedSocket.send(.data(data))
            guard self.isCurrent(generation), self.socket === expectedSocket, !Task.isCancelled else { throw Failure.expired }
            if let reservationID, self.reservationGeneration != reservationID { throw Failure.reservationRetired }
        }
        outgoingTail = write
        try await withTaskCancellationHandler(operation: { try await write.value }, onCancel: { write.cancel() })
    }

    private func receiveProof(expectedNonce: String, deadline: Double, generation: UUID,
                              expectedSocket: any WatchPartySessionSocket,
                              currentAuth: @MainActor () -> Auth?, auth: Auth,
                              localOwnerGeneration: UUID) async throws -> Proof {
        do {
        while monotonicNow() < deadline {
            guard isCurrent(generation), socket === expectedSocket, !Task.isCancelled,
                  currentAuth() == auth else { throw Failure.staleAuth }
            let remaining = deadline - monotonicNow()
            guard remaining.isFinite, remaining > 0 else { throw Failure.expired }
            let timeout = Task { [weak self, sleep = self.dependencies.sleep] in
                do { try await sleep(UInt64(remaining * 1_000_000)) }
                catch { return }
                guard let self, self.isCurrent(generation), self.socket === expectedSocket else { return }
                expectedSocket.close()
            }
            let message: URLSessionWebSocketTask.Message
            do { message = try await expectedSocket.receive() }
            catch { timeout.cancel(); throw error }
            timeout.cancel()
            guard isCurrent(generation), socket === expectedSocket, !Task.isCancelled,
                  currentAuth() == auth, monotonicNow() < deadline else { throw Failure.expired }
            let data: Data
            switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: throw Failure.malformed }
            guard data.count <= 12_000 else { throw Failure.malformed }
            let frame = try JSONDecoder().decode(ServerFrame.self, from: data)
            guard frame.kind != "error" else { throw Failure.rejected }
            if frame.kind == "connected" {
                guard let generation = frame.roomGeneration, generation == playbackState?.roomGeneration,
                      let term = frame.leaderTerm, term >= (playbackState?.leaderTerm ?? Int64.max),
                      let sequence = frame.serverSequence, sequence >= (playbackState?.lastServerSequence ?? Int64.max),
                      var state = playbackState else { throw Failure.malformed }
                state.leaderTerm = term
                state.lastServerSequence = sequence
                playbackState = state
                continue
            }
            guard frame.kind == "lease.proof" else { continue }
            guard let roomGeneration = frame.roomGeneration, let leaderTerm = frame.leaderTerm,
                  let serverSequence = frame.serverSequence,
                  frame.nonce == expectedNonce, roomGeneration == playbackState?.roomGeneration,
                  leaderTerm == playbackState?.leaderTerm, serverSequence == playbackState?.lastServerSequence,
                  let remaining = frame.leaseRemainingMs, (1_000...30_000).contains(remaining),
                  playbackState?.localOwnerGeneration == localOwnerGeneration else { throw Failure.malformed }
            return Proof(nonce: expectedNonce, roomGeneration: roomGeneration, leaderTerm: leaderTerm,
                         serverSequence: serverSequence, leaseRemainingMs: remaining)
        }
        throw Failure.expired
        } catch {
            invalidateIfCurrent(generation, socket: expectedSocket)
            throw error
        }
    }

    private func accept(_ proof: Proof, requestStarted: Double, localOwnerGeneration: UUID) throws {
        guard var state = playbackState, !state.cancelled,
              proof.nonce.count >= 22, proof.roomGeneration == state.roomGeneration,
              proof.leaderTerm == state.leaderTerm, proof.serverSequence == state.lastServerSequence,
              state.localOwnerGeneration == localOwnerGeneration,
              proof.leaseRemainingMs >= 1_000, proof.leaseRemainingMs <= 30_000 else { throw Failure.malformed }
        guard let deadline = WatchPartyClientAdmissionPolicy.deadline(requestStarted: requestStarted,
            leaseRemainingMs: proof.leaseRemainingMs, now: monotonicNow()) else { throw Failure.expired }
        guard observe(monotonicNow(), state: &state) else { throw Failure.expired }
        guard state.clock.last.map({ deadline > $0 }) ?? false else { throw Failure.expired }
        state.leaseDeadline = deadline
        playbackState = state
    }

    private func clearReceiveTimeout(_ id: UUID, generation: UUID, socket expectedSocket: any WatchPartySessionSocket) {
        guard isCurrent(generation), socket === expectedSocket, receiveTimeout?.id == id else { return }
        receiveTimeout = nil
    }

    private func beginReceiveLoop(auth: Auth, currentAuth: @MainActor @escaping () -> Auth?, localOwnerGeneration: UUID) {
        let generation = operationGeneration
        receiveTask = Task { [weak self] in
            guard let self, let socket = self.socket else { return }
            defer { self.invalidateIfCurrent(generation, socket: socket) }
            while !Task.isCancelled, self.operationGeneration == generation, currentAuth() == auth {
                do {
                    let beforeReceive = self.playbackState?.leaseDeadline ?? self.monotonicNow()
                    let remaining = beforeReceive - self.monotonicNow()
                    guard remaining.isFinite, remaining > 0 else { return }
                    let timeoutID = UUID()
                    let receiveTimeout = Task { [weak self, sleep = self.dependencies.sleep] in
                        do { try await sleep(UInt64(remaining * 1_000_000)) }
                        catch { return }
                        guard let self, self.isCurrent(generation), self.socket === socket,
                              self.receiveTimeout?.id == timeoutID,
                              let currentState = self.playbackState, !currentState.cancelled,
                              self.monotonicNow() >= currentState.leaseDeadline else { return }
                        socket.close()
                    }
                    self.receiveTimeout = (id: timeoutID, task: receiveTimeout)
                    let message: URLSessionWebSocketTask.Message
                    do { message = try await socket.receive() }
                    catch {
                        receiveTimeout.cancel()
                        self.clearReceiveTimeout(timeoutID, generation: generation, socket: socket)
                        throw error
                    }
                    receiveTimeout.cancel()
                    self.clearReceiveTimeout(timeoutID, generation: generation, socket: socket)
                    guard self.operationGeneration == generation, currentAuth() == auth,
                          var state = self.playbackState, !state.cancelled,
                          self.observe(self.monotonicNow(), state: &state),
                          state.clock.last.map({ $0 < state.leaseDeadline }) == true,
                          state.localOwnerGeneration == localOwnerGeneration else { return }
                    self.playbackState = state
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let text): data = Data(text.utf8); @unknown default: return }
                    guard data.count <= 12_000 else { return }
                    let frame = try JSONDecoder().decode(ServerFrame.self, from: data)
                    if frame.kind == "lease.proof" {
                        if WatchPartyClientAdmissionPolicy.isRetiredChallengeProof(
                            nonce: frame.nonce, pendingNonce: state.pendingChallenge?.nonce,
                            retiredNonces: self.retiredChallengeNonces) { continue }
                        guard let pending = state.pendingChallenge,
                              WatchPartyClientAdmissionPolicy.proofMatchesCurrentChallenge(
                              nonce: frame.nonce, pending: pending,
                              roomGeneration: frame.roomGeneration, leaderTerm: frame.leaderTerm,
                              proofSequence: frame.serverSequence, currentSequence: state.lastServerSequence),
                              let remaining = frame.leaseRemainingMs, (1_000...30_000).contains(remaining) else { return }
                        let proofReceivedAt = self.monotonicNow()
                        guard self.observe(proofReceivedAt, state: &state),
                              let deadline = WatchPartyClientAdmissionPolicy.deadline(
                                requestStarted: pending.requestStarted, leaseRemainingMs: remaining,
                                now: proofReceivedAt) else { return }
                        state.leaseDeadline = deadline
                        state.pendingChallenge = nil
                        self.playbackState = state
                        continue
                    }
                    if frame.kind == "reservation" {
                        guard let pending = self.reservationContinuation,
                              let reservationId = frame.reservationId,
                              let generationValue = frame.roomGeneration,
                              let termValue = frame.leaderTerm,
                              let sequenceValue = frame.serverSequence else { return }
                        guard self.reservationGeneration != nil, self.operationGeneration == generation,
                              self.socket === socket else { return }
                        self.reservationContinuation = nil
                        self.reservationTimeoutTask?.cancel(); self.reservationTimeoutTask = nil
                        if let retiredAt = self.latestReservationRetirementSequence,
                           sequenceValue <= state.lastServerSequence, sequenceValue <= retiredAt {
                            self.reservationGeneration = nil
                            self.reserveWasSent = false
                            pending.resume(throwing: Failure.reservationRetired)
                            continue
                        }
                        pending.resume(returning: Reservation(reservationId: reservationId,
                            roomGeneration: generationValue, leaderTerm: termValue, serverSequence: sequenceValue))
                        continue
                    }
                    if frame.kind == "error" {
                        if frame.code == "stale-reservation", let publication = self.pendingPublication,
                           publication.sent, publication.retired, publication.outcome == nil,
                           state.lastServerSequence >= publication.sequence,
                           let retiredAt = self.latestReservationRetirementSequence,
                           retiredAt >= publication.sequence {
                            self.finishPublication(publication.reservationID,
                                outcome: .failure(Failure.reservationRetired))
                            continue
                        }
                        if let pending = self.reservationContinuation {
                            self.reservationContinuation = nil; self.reservationGeneration = nil
                            self.reservationTimeoutTask?.cancel(); self.reservationTimeoutTask = nil
                            pending.resume(throwing: Failure.rejected)
                        }
                        return
                    }
                    let type = frame.type
                    guard frame.roomGeneration == state.roomGeneration,
                          let term = frame.leaderTerm, let sequence = frame.serverSequence,
                          state.lastServerSequence < Int64.max,
                          sequence == state.lastServerSequence + 1 else { return }
                    if type == "sealed" {
                        let interruptedChallenge = state.pendingChallenge
                        guard term == state.leaderTerm, let ciphertext = frame.ciphertext,
                              let key = self.roomKey,
                              let control = WatchPartyWire.open(ciphertext, roomKey: key,
                                roomGeneration: state.roomGeneration, leaderTerm: term,
                                serverSequence: sequence),
                              self.onControl?(control, sequence) == true,
                              self.playbackState?.lastServerSequence == sequence else { return }
                        if let publication = self.pendingPublication, publication.sent,
                           !publication.retired, publication.sequence == sequence,
                           publication.ciphertext == ciphertext {
                            self.finishPublication(publication.reservationID, outcome: .success(()))
                        }
                        if let interruptedChallenge {
                            self.retireChallenge(interruptedChallenge.nonce)
                            if var currentState = self.playbackState {
                                currentState.pendingChallenge = nil
                                self.playbackState = currentState
                            }
                            self.restartChallengeAfterEvent(refreshMember: false, auth: auth,
                                currentAuth: currentAuth, localOwnerGeneration: localOwnerGeneration,
                                generation: generation, socket: socket)
                        }
                        continue
                    }
                    let isHandoff = state.leaderTerm < Int64.max && term == state.leaderTerm + 1 && type == "member-left"
                    guard term == state.leaderTerm || isHandoff,
                          ["member-joined", "member-ready", "member-left", "lease-renewed", "room-closed"].contains(type ?? "") else { return }
                    state.leaderTerm = term
                    state.lastServerSequence = sequence
                    let challengeWasInterrupted = state.pendingChallenge != nil || self.isRechallenging
                    if let pending = state.pendingChallenge { self.retireChallenge(pending.nonce) }
                    state.pendingChallenge = nil
                    if type == "lease-renewed" {
                        self.latestLeaseRenewalSequence = sequence
                        self.needsMemberRefreshAfterLeaseEvent = true
                        if let waiter = self.leaderRenewalWaiter,
                           waiter.generation == generation, waiter.socket === socket,
                           sequence > waiter.afterSequence {
                            self.leaderRenewalWaiter = nil
                            self.leaderRenewalTimeoutTask?.cancel()
                            self.leaderRenewalTimeoutTask = nil
                            waiter.continuation.resume(returning: sequence)
                        }
                    }
                    if type == "room-closed" { state.cancelled = true }
                    self.playbackState = state
                    if state.cancelled { self.invalidateIfCurrent(generation, socket: socket); return }
                    self.retireReservationAfterEvent(sequence: sequence)
                    if type == "member-joined" {
                        self.onMemberJoined?()
                        guard self.isCurrent(generation), self.socket === socket,
                              currentAuth() == auth else { return }
                    }
                    if type == "member-ready" {
                        self.onMemberReady?()
                        guard self.isCurrent(generation), self.socket === socket,
                              currentAuth() == auth else { return }
                    }
                    if challengeWasInterrupted {
                        self.restartChallengeAfterEvent(refreshMember: type == "lease-renewed", auth: auth,
                            currentAuth: currentAuth, localOwnerGeneration: localOwnerGeneration,
                            generation: generation, socket: socket)
                    }
                } catch { return }
            }
        }
    }

    /// Wait for the authenticated relay event that follows a leader-only server lease
    /// renewal. A member HTTP renewal does not extend the room lease, and a challenge
    /// proof sent before this event can only prove the old, nearly-expired deadline.
    private func waitForLeaderLeaseRenewal(after sequence: Int64, generation: UUID,
                                            socket expectedSocket: any WatchPartySessionSocket) async throws -> Int64 {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int64, Error>) in
                guard isCurrent(generation), socket === expectedSocket, !Task.isCancelled,
                      leaderRenewalWaiter.map({ _ in false }) ?? true else {
                    continuation.resume(throwing: Failure.expired)
                    return
                }
                if let seen = latestLeaseRenewalSequence, seen > sequence {
                    continuation.resume(returning: seen)
                    return
                }
                leaderRenewalWaiter = (generation, expectedSocket, sequence, continuation)
                leaderRenewalTimeoutTask?.cancel()
                leaderRenewalTimeoutTask = Task { [weak self, sleep = self.dependencies.sleep] in
                    do { try await sleep(5_000_000_000) }
                    catch { return }
                    guard let self, self.isCurrent(generation), self.socket === expectedSocket,
                          let waiter = self.leaderRenewalWaiter,
                          waiter.generation == generation, waiter.socket === expectedSocket else { return }
                    self.leaderRenewalWaiter = nil
                    self.leaderRenewalTimeoutTask = nil
                    waiter.continuation.resume(throwing: Failure.expired)
                    self.invalidateIfCurrent(generation, socket: expectedSocket)
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.isCurrent(generation), self.socket === expectedSocket,
                      let waiter = self.leaderRenewalWaiter,
                      waiter.generation == generation, waiter.socket === expectedSocket else { return }
                self.leaderRenewalWaiter = nil
                self.leaderRenewalTimeoutTask?.cancel()
                self.leaderRenewalTimeoutTask = nil
                waiter.continuation.resume(throwing: CancellationError())
            }
        })
    }

    private func retireChallenge(_ nonce: String) {
        retiredChallengeNonces.append(nonce)
        if retiredChallengeNonces.count > 4 { retiredChallengeNonces.removeFirst(retiredChallengeNonces.count - 4) }
    }

    /// A sequenced event can arrive between a challenge and its proof. Retire that nonce,
    /// incorporate the event first, refresh membership after a room lease renewal, and
    /// issue a new challenge for the now-current sequence. Late proofs for retired nonces
    /// are ignored; unknown or mismatched proofs still fail closed.
    private func restartChallengeAfterEvent(refreshMember: Bool, auth: Auth,
        currentAuth: @MainActor @escaping () -> Auth?, localOwnerGeneration: UUID,
        generation: UUID, socket expectedSocket: any WatchPartySessionSocket) {
        challengeTask?.cancel()
        let restartID = UUID()
        challengeRestartID = restartID
        isRechallenging = true
        challengeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.challengeRestartID == restartID {
                    self.challengeRestartID = nil
                    self.isRechallenging = false
                    self.challengeTask = nil
                }
            }
            do {
                guard self.isCurrent(generation), self.socket === expectedSocket,
                      !Task.isCancelled, currentAuth() == auth else { return }
                if refreshMember || self.needsMemberRefreshAfterLeaseEvent {
                    guard let member = self.member else { throw Failure.ownerChanged }
                    var refreshedAfterLatestLease = false
                    for _ in 0..<3 {
                        let leaseSequenceAtRequest = self.latestLeaseRenewalSequence
                        let _: RenewReceipt = try await self.post("/\(member.roomId)/renew",
                            body: MemberRequest(member), auth: auth, currentAuth: currentAuth)
                        guard self.isCurrent(generation), self.socket === expectedSocket,
                              !Task.isCancelled, currentAuth() == auth else { return }
                        if WatchPartyClientAdmissionPolicy.memberRefreshMustRetry(
                            leaseSequenceAtRequest: leaseSequenceAtRequest,
                            currentLeaseSequence: self.latestLeaseRenewalSequence) { continue }
                        self.needsMemberRefreshAfterLeaseEvent = false
                        refreshedAfterLatestLease = true
                        break
                    }
                    guard refreshedAfterLatestLease else {
                        self.invalidateIfCurrent(generation, socket: expectedSocket)
                        return
                    }
                }
                guard var state = self.playbackState, !state.cancelled,
                      state.localOwnerGeneration == localOwnerGeneration,
                      state.pendingChallenge == nil,
                      self.isCurrent(generation), self.socket === expectedSocket else { return }
                let started = self.monotonicNow()
                guard self.observe(started, state: &state),
                      state.clock.last.map({ $0 < state.leaseDeadline }) == true else {
                    self.invalidateIfCurrent(generation, socket: expectedSocket)
                    return
                }
                let nonce = try Self.randomOpaqueToken()
                state.pendingChallenge = WatchPartyPendingChallenge(nonce: nonce, requestStarted: started,
                    roomGeneration: state.roomGeneration, leaderTerm: state.leaderTerm,
                    sequence: state.lastServerSequence)
                self.playbackState = state
                try await self.send(SocketRequest(kind: "lease.challenge", nonce: nonce),
                    to: expectedSocket, generation: generation)
                guard self.isCurrent(generation), self.socket === expectedSocket,
                      !Task.isCancelled, currentAuth() == auth else { return }
            } catch {
                if !Task.isCancelled { self.invalidateIfCurrent(generation, socket: expectedSocket) }
            }
        }
    }

    private func beginLivenessLoop(auth: Auth, currentAuth: @MainActor @escaping () -> Auth?, localOwnerGeneration: UUID) {
        let generation = operationGeneration
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.operationGeneration == generation,
                      var beforeSleep = self.playbackState, !beforeSleep.cancelled,
                      beforeSleep.localOwnerGeneration == localOwnerGeneration,
                      self.observe(self.monotonicNow(), state: &beforeSleep),
                      let observedNow = beforeSleep.clock.last else {
                    self?.invalidateIfCurrent(generation)
                    return
                }
                let remainingBeforeSleep = beforeSleep.leaseDeadline - observedNow
                guard remainingBeforeSleep.isFinite, remainingBeforeSleep > 0 else {
                    self.invalidateIfCurrent(generation)
                    return
                }
                self.playbackState = beforeSleep
                let cadenceMs = min(10_000.0, max(500.0, remainingBeforeSleep / 3.0))
                do { try await self.dependencies.sleep(UInt64(cadenceMs * 1_000_000)) }
                catch { return }
                guard self.operationGeneration == generation, !Task.isCancelled, currentAuth() == auth,
                      var state = self.playbackState, !state.cancelled,
                      state.localOwnerGeneration == localOwnerGeneration else { return }
                guard self.observe(self.monotonicNow(), state: &state), state.clock.last.map({ $0 < state.leaseDeadline }) == true else {
                    self.invalidateIfCurrent(generation); return
                }
                self.playbackState = state
                do {
                    if state.pendingChallenge != nil || self.isRechallenging { continue }
                    guard let member = self.member, let capturedSocket = self.socket else { return }
                    var leaderRenewalBaseline: Int64?
                    var leaderRenewalSequence: Int64?
                    if member.role == "leader" {
                        let beforeLeaderRenewal = state.lastServerSequence
                        leaderRenewalBaseline = beforeLeaderRenewal
                        try await self.send(SocketRequest(kind: "renew", nonce: nil), to: capturedSocket,
                                            generation: generation)
                        guard self.isCurrent(generation), !Task.isCancelled,
                              self.socket === capturedSocket, currentAuth() == auth else { return }
                        leaderRenewalSequence = try await self.waitForLeaderLeaseRenewal(after: beforeLeaderRenewal,
                            generation: generation, socket: capturedSocket)
                        guard self.isCurrent(generation), !Task.isCancelled,
                              self.socket === capturedSocket, currentAuth() == auth,
                              let postRenewalState = self.playbackState,
                              !postRenewalState.cancelled,
                              postRenewalState.localOwnerGeneration == localOwnerGeneration else { return }
                        state = postRenewalState
                    }
                    // Member expiry is capped by the current room lease. Renewing the
                    // member after a leader renewal is required to move that cap forward.
                    let leaseSequenceAtRequest = self.latestLeaseRenewalSequence
                    let _: RenewReceipt = try await self.post("/\(member.roomId)/renew", body: MemberRequest(member),
                        auth: auth, currentAuth: currentAuth)
                    let afterRenewNow = self.monotonicNow()
                    guard self.operationGeneration == generation, !Task.isCancelled,
                          self.socket === capturedSocket, currentAuth() == auth,
                          self.observe(afterRenewNow, state: &state), afterRenewNow < state.leaseDeadline,
                          let refreshedState = self.playbackState, !refreshedState.cancelled,
                          refreshedState.localOwnerGeneration == localOwnerGeneration,
                          refreshedState.pendingChallenge == nil else { self.invalidateIfCurrent(generation); return }
                    if WatchPartyClientAdmissionPolicy.memberRefreshMustRetry(
                        leaseSequenceAtRequest: leaseSequenceAtRequest,
                        currentLeaseSequence: self.latestLeaseRenewalSequence) {
                        self.needsMemberRefreshAfterLeaseEvent = true
                        continue
                    }
                    self.needsMemberRefreshAfterLeaseEvent = false
                    state = refreshedState
                    guard self.observe(afterRenewNow, state: &state) else { self.invalidateIfCurrent(generation); return }
                    if let baseline = leaderRenewalBaseline, let leaseEvent = leaderRenewalSequence,
                       !WatchPartyClientAdmissionPolicy.leaderRenewalProofIsOrdered(
                         after: baseline, leaseRenewalSequence: leaseEvent,
                         challengeSequence: state.lastServerSequence) {
                        self.invalidateIfCurrent(generation, socket: capturedSocket)
                        return
                    }
                    let nonce = try Self.randomOpaqueToken()
                    let started = self.monotonicNow()
                    guard self.observe(started, state: &state) else { self.invalidateIfCurrent(generation); return }
                    state.pendingChallenge = WatchPartyPendingChallenge(nonce: nonce, requestStarted: started,
                        roomGeneration: state.roomGeneration, leaderTerm: state.leaderTerm,
                        sequence: state.lastServerSequence)
                    self.playbackState = state
                    // For leaders, the challenge is intentionally ordered after the
                    // lease-renewed event. Its proof therefore carries the extended lease
                    // and current relay sequence. Guests challenge the current state directly.
                    guard self.isCurrent(generation), !Task.isCancelled, self.socket === capturedSocket else { return }
                    let activeSocket = capturedSocket
                    try await self.send(SocketRequest(kind: "lease.challenge", nonce: nonce), to: activeSocket, generation: generation)
                    guard self.isCurrent(generation), self.socket === activeSocket, currentAuth() == auth else { return }
                } catch { self.invalidateIfCurrent(generation); return }
            }
        }
    }

    var onControl: (@MainActor (WatchPartyWire.Control, Int64) -> Bool)?
    var onDisconnected: (@MainActor () -> Void)?
    /// A leader may replay its bounded current state through ordinary sealed
    /// controls after this authenticated, ordered membership event is installed.
    var onMemberJoined: (@MainActor () -> Void)?
    /// First-proof readiness metadata uses the normal ordered event path.
    /// A leader replays state here through ordinary sealed control publication.
    var onMemberReady: (@MainActor () -> Void)?

    /// Map the stable PlaybackMeta.videoId (for example the same IMDB episode ID on
    /// both devices) into the shared wire's strict URL-safe token. Hash exact UTF-8
    /// bytes with a domain separator; no title name, URL, stream, or addon is sent.
    static func canonicalTitleToken(forPlaybackVideoID value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 512 else { return nil }
        let input = Data("vortx/watch-party/title/v1\n".utf8) + Data(value.utf8)
        let digest = Data(SHA256.hash(data: input))
        let token = digest.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return WatchPartyWire.canonicalTitleToken(token)
    }

    private static func newRoomKey() throws -> Data {
        guard let key = WatchPartyWire.makeRoomKey() else { throw Failure.malformed }
        return key
    }
    private static func randomOpaqueToken() throws -> String {
        var bytes = Data(repeating: 0, count: 24)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 24, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.malformed }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func validOpaque(_ s: String) -> Bool {
        !s.isEmpty && s.count >= 22 && s.count <= 128 && s.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) ||
            (48...57).contains($0.value) || $0.value == 95 || $0.value == 45
        }
    }
    private static func valid(_ snapshot: Snapshot) -> Bool {
        validOpaque(snapshot.roomGeneration) && snapshot.leaderTerm > 0 && snapshot.serverSequence >= 0 &&
            (1_000...30_000).contains(snapshot.leaseRemainingMs)
    }

    /// Default adapter retains the original ephemeral configuration, protocol
    /// selection deadline, message cap and redirect refusal. No endpoint or TLS
    /// override is exposed by the test-only dependency initializer.
    @MainActor
    private final class LiveSocket: WatchPartySessionSocket {
        private let session: URLSession
        private let delegate: NoRedirectDelegate
        private let task: URLSessionWebSocketTask

        init(url: URL, protocols: [String]) {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let delegate = NoRedirectDelegate()
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.webSocketTask(with: url, protocols: protocols)
            task.maximumMessageSize = 12_000
            self.delegate = delegate
            self.session = session
            self.task = task
        }

        func resume() { task.resume() }
        func waitForProtocol(timeoutNanoseconds: UInt64) async -> String? {
            await delegate.waitForProtocol(task: task, timeoutNanoseconds: timeoutNanoseconds)
        }
        func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
        func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
        func close() {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
    }

    private final class NoRedirectDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var protocolWaiter: CheckedContinuation<String?, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var didResolveProtocol = false
        private var resolvedProtocol: String?

        func waitForProtocol(task: URLSessionWebSocketTask, timeoutNanoseconds: UInt64) async -> String? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if didResolveProtocol {
                    let selected = resolvedProtocol
                    lock.unlock()
                    continuation.resume(returning: selected)
                    return
                }
                protocolWaiter = continuation
                let timeout = Task { [weak self, weak task] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    guard task != nil else { return }
                    self?.resolveProtocol(nil)
                }
                timeoutTask = timeout
                lock.unlock()
            }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didOpenWithProtocol selectedProtocol: String?) {
            resolveProtocol(selectedProtocol)
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            resolveProtocol(nil)
        }

        private func resolveProtocol(_ selected: String?) {
            lock.lock()
            didResolveProtocol = true
            resolvedProtocol = selected
            let waiter = protocolWaiter
            protocolWaiter = nil
            let timeout = timeoutTask
            timeoutTask = nil
            lock.unlock()
            timeout?.cancel()
            waiter?.resume(returning: selected)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private struct EmptyRequest: Encodable {}
    private struct InviteRequest: Encodable { let inviteCode: String }
    private struct MemberRequest: Encodable {
        let memberId: String; let capability: String
        init(_ member: Membership) { memberId = member.id; capability = member.capability }
    }
    private struct TicketReceipt: Decodable { let ticket: String }
    private struct RenewReceipt: Decodable { let expiresAtMs: Int64; let snapshot: Snapshot }
    private struct EmptyReceipt: Decodable {}
    private struct Proof: Sendable { let nonce: String; let roomGeneration: String; let leaderTerm: Int64; let serverSequence: Int64; let leaseRemainingMs: Int64 }
    private struct ServerFrame: Decodable { let kind: String?; let type: String?; let nonce: String?; let roomGeneration: String?; let leaderTerm: Int64?; let serverSequence: Int64?; let leaseRemainingMs: Int64?; let ciphertext: String?; let reservationId: String?; let code: String? }
    private struct Reservation { let reservationId: String; let roomGeneration: String; let leaderTerm: Int64; let serverSequence: Int64 }
    private struct ReserveRequest: Encodable { let kind: String }
    private struct PublishRequest: Encodable { let kind: String; let reservationId: String; let roomGeneration: String; let leaderTerm: Int64; let serverSequence: Int64; let ciphertext: String }
    private struct SocketRequest: Encodable { let kind: String; let nonce: String? }
}

