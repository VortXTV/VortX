// Standalone regressions for the production WatchPartyClientSession.
// Run from the repository root on macOS with Swift 6:
//   python3 scripts/test-watch-party-regressions.py
// Sources under app/SourcesShared provide Session, auth, credential authority,
// HTTP transport, admission policy and wire codec. Transport scheduling and
// playback/native boundaries are synthetic; no live account or network is used.
// The runner compiles this @main separately from the model regression @main.
import Foundation

@MainActor
private final class SessionFixture {
    let transport: ControlledTransport
    let authority: CredentialScopeRegistry
    let auth: VortXWatchPartyAuthSnapshot
    var currentAuth: VortXWatchPartyAuthSnapshot?
    let session: WatchPartyClientSession
    let ownerGeneration = UUID()
    let target = PlaybackMutationTarget(syntheticID: UUID())
    let loadToken = PlayerLoadToken(syntheticID: UUID())
    private(set) var roomKey = Data(repeating: 0x42, count: 32)
    private var cancellations: [@MainActor () -> Void] = []

    init() throws {
        let transport = ControlledTransport()
        let authority = CredentialScopeRegistry()
        self.transport = transport
        self.authority = authority
        let accountID = "01234567-89ab-cdef-0123-456789abcdef"
        guard let scope = CredentialScope(canonicalRemoteAccountID: accountID),
              let credential = authority.tryBind(scope),
              authority.establishAuthenticatedOwner(credential) != nil,
              let captured = VortXWatchPartyAuthCapturePolicy.capture(
                isSignedIn: true, bearer: "synthetic-account-session-only", accountID: accountID,
                profileID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
                generation: 7, credential: credential, authority: authority,
                profileGeneration: UUID()) else {
            throw AsyncHarnessError.assertion("real isolated auth capture")
        }
        auth = captured
        currentAuth = captured
        session = WatchPartyClientSession(testing: transport.dependencies,
                                          monotonicNow: { transport.scheduler.now })
        session.onControl = { [weak self] control, sequence in
            guard let self,
                  let admitted = self.session.admit(control, sequence: sequence,
                    current: self.owner, currentAuth: { self.currentAuth }) else { return false }
            return self.session.apply(admitted, current: self.owner,
                currentAuth: { self.currentAuth }, perform: { _ in true })
        }
    }

    var owner: WatchPartyClientSession.ApplyContext {
        .init(target: target, auth: auth, titleToken: SyntheticParty.title,
              playbackSessionID: "synthetic-playback-session", loadToken: loadToken,
              localOwnerGeneration: ownerGeneration)
    }

    func job<Value>(_ operation: @MainActor @escaping () async throws -> Value) -> AsyncHarnessJob<Value> {
        let job = AsyncHarnessJob(operation)
        cancellations.append { job.cancel() }
        return job
    }

    @discardableResult
    func establish(sequence: Int64 = 40, leader: Bool = false,
                   beforeInitialProof: (@MainActor (ControlledSocket) throws -> Void)? = nil) async throws -> ControlledSocket {
        let snapshot: WatchPartyClientSession.Snapshot
        if leader {
            transport.http.enqueue(.created(sequence))
            let result = try await session.create(auth: auth, currentAuth: { self.currentAuth })
            snapshot = result.0.snapshot
            roomKey = result.1
        } else {
            transport.http.enqueue(.joined(sequence, role: "guest"))
            let receipt = try await session.join(roomId: SyntheticParty.room,
                inviteCode: SyntheticParty.invite, roomKey: roomKey, auth: auth,
                currentAuth: { self.currentAuth })
            snapshot = receipt.snapshot
        }
        transport.http.enqueue(.ticket)
        let priorSocketCount = transport.sockets.count
        let connect = job {
            try await self.session.connect(snapshot: snapshot,
                localOwnerGeneration: self.ownerGeneration, auth: self.auth,
                currentAuth: { self.currentAuth })
        }
        try await asyncEventually("socket factory") { self.transport.sockets.count > priorSocketCount }
        guard let socket = transport.sockets.last else { throw AsyncHarnessError.missingHandle }
        try await asyncEventually("initial challenge and receive") {
            socket.challenges.count == 1 && socket.pending.count == 1
        }
        guard let nonce = socket.challenges.first?.nonce else { throw AsyncHarnessError.missingHandle }
        try beforeInitialProof?(socket)
        try socket.deliver(.proof(nonce, sequence: sequence))
        try await connect.value("public connect completed")
        try await asyncEventually("real receive and liveness loops entered") {
            socket.receiveCalls >= 2 && !socket.pending.isEmpty &&
                self.transport.scheduler.pending.contains { $0.nanoseconds == 10_000_000_000 }
        }
        await asyncDrain()
        try asyncRequire(socket.resumed && transport.http.boundaryValid && transport.socketBoundaryValid,
                         "real Session supplies hardened endpoint and protocol boundaries")
        try asyncRequire(session.testingState.socketID == ObjectIdentifier(socket),
                         "Session retains the exact controlled socket identity")
        try asyncRequire(session.testingState.serverSequence == sequence &&
                         session.testingState.leaseDeadline == transport.scheduler.now + 30_000,
                         "actual initial proof installs sequence and anchored lease")
        return socket
    }

    func wakeLiveness() async throws {
        try await asyncEventually("liveness cadence scheduled") {
            self.transport.scheduler.pending.contains {
                !$0.cancelled && $0.nanoseconds >= 500_000_000 && $0.nanoseconds <= 10_000_000_000
            }
        }
        guard let sleep = transport.scheduler.pending.last(where: {
            !$0.cancelled && $0.nanoseconds >= 500_000_000 && $0.nanoseconds <= 10_000_000_000
        }) else { throw AsyncHarnessError.missingHandle }
        transport.scheduler.now = max(transport.scheduler.now,
            sleep.started + Double(sleep.nanoseconds) / 1_000_000)
        try transport.scheduler.complete(sleep.id)
    }

    func primePendingChallenge(_ socket: ControlledSocket) async throws -> String {
        transport.http.enqueue(.renewed(40))
        try await wakeLiveness()
        try await asyncEventually("ordinary liveness challenge at sequence 40") {
            self.session.testingState.pendingSequence == 40 && socket.challenges.count == 2
        }
        guard let nonce = session.testingState.pendingNonce else { throw AsyncHarnessError.missingHandle }
        return nonce
    }

    func emit(_ frame: SyntheticServerFrame, on socket: ControlledSocket) async throws {
        try await asyncEventually("receive ready") { !socket.pending.isEmpty }
        let calls = socket.receiveCalls
        try socket.deliver(frame)
        try await asyncEventually("frame processed") {
            socket.receiveCalls > calls || socket.closeCount > 0
        }
    }

    func cleanup() {
        session.onControl = nil
        session.onDisconnected = nil
        session.onMemberJoined = nil
        session.onMemberReady = nil
        for cancellation in cancellations { cancellation() }
        cancellations.removeAll()
        session.cancel()
        transport.cleanup() // releases even explicitly retained canceled waits
    }

    func emitOwnSealedEcho(on socket: ControlledSocket, publicationIndex: Int = 0) async throws {
        try await asyncEventually("own publication sent before echo") {
            socket.publishes.count > publicationIndex
        }
        let publish = socket.publishes[publicationIndex]
        guard let sequence = publish.serverSequence, let ciphertext = publish.ciphertext else {
            throw AsyncHarnessError.missingHandle
        }
        var echo = SyntheticServerFrame.event("sealed", sequence: sequence)
        echo.ciphertext = ciphertext
        try await emit(echo, on: socket)
    }
}

@MainActor
private final class OwnEchoObservation {
    var localPosition: Int64
    var fingerprint: WatchPartyWire.Control
    var applications = 0
    var lastAdmitted: WatchPartyClientSession.AdmittedControl?

    init(_ control: WatchPartyWire.Control) {
        localPosition = control.positionMs
        fingerprint = control
    }
}

private struct SessionDigest: Equatable {
    let generation: UUID
    let socketID: ObjectIdentifier?
    let sequence: Int64?
    let deadline: Double?
    let pendingNonce: String?
    let pendingSequence: Int64?
    let latestLeaseSequence: Int64?
    let needsMemberRefresh: Bool
    let restartID: UUID?
    let isRechallenging: Bool
    let hasReservation: Bool

    @MainActor
    init(_ session: WatchPartyClientSession) {
        let value = session.testingState
        generation = value.generation; socketID = value.socketID
        sequence = value.serverSequence; deadline = value.leaseDeadline
        pendingNonce = value.pendingNonce; pendingSequence = value.pendingSequence
        latestLeaseSequence = value.latestLeaseSequence; needsMemberRefresh = value.needsMemberRefresh
        restartID = value.restartID; isRechallenging = value.isRechallenging
        hasReservation = value.hasReservation
    }
}

@main
struct WatchPartyClientSessionAsyncTestRunner {
    @MainActor
    static func replacementRace(secondEvent: String) async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        let socket = try await fixture.establish()
        let retiredNonce = try await fixture.primePendingChallenge(socket)
        let originalDeadline = fixture.session.testingState.leaseDeadline
        let initialChallengeCount = socket.challenges.count

        fixture.transport.http.retainNextRequestAfterCancellation = true
        try await fixture.emit(.event("lease-renewed", sequence: 41), on: socket)
        try await asyncEventually("replacement refresh R1 suspended") {
            fixture.transport.http.pending(.renew).count == 1
        }
        guard let r1 = fixture.transport.http.pending(.renew).first,
              let firstRestartID = fixture.session.testingState.restartID else {
            throw AsyncHarnessError.missingHandle
        }
        try asyncRequire(fixture.session.testingState.pendingNonce == nil &&
                         fixture.session.testingState.needsMemberRefresh,
                         "first lease event retires proof and requires member refresh")

        try await fixture.emit(.event(secondEvent, sequence: 42), on: socket)
        try await asyncEventually("replacement R2 suspended and R1 canceled") {
            r1.cancelled && fixture.transport.http.pending(.renew).contains { $0.id != r1.id }
        }
        guard let r2 = fixture.transport.http.pending(.renew).first(where: { $0.id != r1.id }),
              let secondRestartID = fixture.session.testingState.restartID else {
            throw AsyncHarnessError.missingHandle
        }
        try asyncRequire(secondRestartID != firstRestartID && fixture.session.testingState.isRechallenging,
                         "second event owns a distinct live restart")
        try asyncRequire(fixture.session.testingState.needsMemberRefresh,
                         "refresh obligation is sticky for a non-lease second event too")

        // A retired proof before the replacement exists must be ignored without
        // extending the lease or consuming the new restart's refresh obligation.
        try await fixture.emit(.proof(retiredNonce, sequence: 40), on: socket)
        try asyncRequire(fixture.session.testingState.leaseDeadline == originalDeadline &&
                         fixture.session.testingState.restartID == secondRestartID &&
                         fixture.session.testingState.needsMemberRefresh,
                         "retired proof before replacement leaves restart and lease intact")

        try fixture.transport.http.complete(r1.id, .renewed(41))
        try await asyncEventually("canceled R1 completion delivered") { r1.returnedToCaller }
        await asyncDrain(128)
        try asyncRequire(socket.challenges.count == initialChallengeCount &&
                         fixture.session.testingState.pendingNonce == nil,
                         "late canceled R1 cannot send a replacement challenge")
        try asyncRequire(fixture.session.testingState.needsMemberRefresh &&
                         fixture.session.testingState.restartID == secondRestartID &&
                         fixture.session.testingState.isRechallenging,
                         "late canceled R1 cannot clear R2 refresh obligation or ownership")
        try asyncRequire(fixture.transport.http.pending(.renew).contains { $0.id == r2.id },
                         "R2 remains suspended after old completion")

        fixture.transport.scheduler.now = 15_000
        try fixture.transport.http.complete(r2.id, .renewed(42))
        try await asyncEventually("replacement challenge bound to sequence 42") {
            fixture.session.testingState.pendingSequence == 42 &&
                socket.challenges.count == initialChallengeCount + 1 &&
                fixture.session.testingState.restartID == nil
        }
        guard let newNonce = fixture.session.testingState.pendingNonce else {
            throw AsyncHarnessError.missingHandle
        }
        try asyncRequire(newNonce != retiredNonce && !fixture.session.testingState.needsMemberRefresh &&
                         !fixture.session.testingState.isRechallenging,
                         "current R2 alone satisfies refresh and releases restart ownership")
        try asyncRequire(fixture.session.testingState.latestLeaseSequence ==
                            (secondEvent == "lease-renewed" ? 42 : 41),
                         "latest lease watermark follows only real lease events")

        fixture.transport.scheduler.now = 15_200
        try await fixture.emit(.proof(retiredNonce, sequence: 40), on: socket)
        try asyncRequire(fixture.session.testingState.pendingNonce == newNonce &&
                         fixture.session.testingState.pendingSequence == 42 &&
                         fixture.session.testingState.leaseDeadline == originalDeadline,
                         "retired proof after replacement cannot clear its proof or extend deadline")

        fixture.transport.scheduler.now = 15_500
        try await fixture.emit(.proof(newNonce, sequence: 42, lease: 20_000), on: socket)
        try asyncRequire(fixture.session.testingState.pendingNonce == nil &&
                         fixture.session.testingState.leaseDeadline == 35_000 && socket.closeCount == 0,
                         "exact new proof anchors deadline to new request start, not arrival or old request")
    }

    @MainActor
    static func ordinaryRefreshRace() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        let socket = try await fixture.establish()
        let originalDeadline = fixture.session.testingState.leaseDeadline
        try await fixture.wakeLiveness()
        try await asyncEventually("ordinary liveness HTTP suspended") {
            fixture.transport.http.pending(.renew).count == 1
        }
        guard let old = fixture.transport.http.pending(.renew).first else {
            throw AsyncHarnessError.missingHandle
        }
        try await fixture.emit(.event("lease-renewed", sequence: 41), on: socket)
        try await fixture.emit(.event("member-joined", sequence: 42), on: socket)
        try asyncRequire(fixture.session.testingState.needsMemberRefresh &&
                         fixture.session.testingState.pendingNonce == nil,
                         "lease event during ordinary HTTP retains refresh obligation")
        try fixture.transport.http.complete(old.id, .renewed(40))
        try await asyncEventually("stale ordinary response delivered") { old.returnedToCaller }
        await asyncDrain(128)
        try asyncRequire(socket.challenges.count == 1 && fixture.session.testingState.pendingNonce == nil &&
                         fixture.session.testingState.needsMemberRefresh && socket.closeCount == 0 &&
                         fixture.session.testingState.leaseDeadline == originalDeadline,
                         "stale ordinary response neither proves nor consumes newer lease obligation")

        try await fixture.wakeLiveness()
        try await asyncEventually("current member refresh precedes new challenge") {
            fixture.transport.http.pending(.renew).contains { $0.id != old.id }
        }
        guard let current = fixture.transport.http.pending(.renew).first(where: { $0.id != old.id }) else {
            throw AsyncHarnessError.missingHandle
        }
        try asyncRequire(socket.challenges.count == 1 && fixture.session.testingState.needsMemberRefresh,
                         "no proof request while current member refresh is suspended")
        let newRequestStarted = fixture.transport.scheduler.now
        try fixture.transport.http.complete(current.id, .renewed(42))
        try await asyncEventually("current ordinary refresh issues sequence 42 challenge") {
            fixture.session.testingState.pendingSequence == 42 && socket.challenges.count == 2
        }
        guard let nonce = fixture.session.testingState.pendingNonce else { throw AsyncHarnessError.missingHandle }
        fixture.transport.scheduler.now += 200
        try await fixture.emit(.proof(nonce, sequence: 42), on: socket)
        try asyncRequire(!fixture.session.testingState.needsMemberRefresh &&
                         fixture.session.testingState.leaseDeadline == newRequestStarted + 30_000,
                         "current refresh precedes proof and proof uses its own start")
    }

    @MainActor
    static func sameSessionGenerationFence() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        var memberCallbacks = 0
        fixture.session.onMemberJoined = { memberCallbacks += 1 }
        let oldSocket = try await fixture.establish()
        guard let oldReceive = oldSocket.pending.first,
              let oldTimer = fixture.transport.scheduler.pending.first(where: {
                  $0.nanoseconds == 30_000_000_000
              }) else { throw AsyncHarnessError.missingHandle }
        oldReceive.retainAfterCancellation = true
        oldTimer.retainAfterCancellation = true
        fixture.transport.http.retainNextRequestAfterCancellation = true
        try await fixture.wakeLiveness()
        try await asyncEventually("old generation HTTP suspended") {
            fixture.transport.http.pending(.renew).count == 1
        }
        guard let oldHTTP = fixture.transport.http.pending(.renew).first else {
            throw AsyncHarnessError.missingHandle
        }
        let oldGeneration = fixture.session.testingState.generation
        let oldSentCount = oldSocket.sent.count
        fixture.session.cancel()
        try await asyncEventually("selected old work records cancellation") {
            oldReceive.cancelled && oldTimer.cancelled && oldHTTP.cancelled
        }
        fixture.transport.scheduler.now = 12_000
        let newSocket = try await fixture.establish(sequence: 70)
        try asyncRequire(fixture.currentAuth == fixture.auth,
                         "fresh generation deliberately reuses exact same auth and Session")
        try asyncRequire(fixture.session.testingState.generation != oldGeneration && oldSocket !== newSocket,
                         "reconnect uses a new generation and stable new socket identity")
        let fresh = SessionDigest(fixture.session)
        let newSentCount = newSocket.sent.count
        try fixture.transport.http.complete(oldHTTP.id, .renewed(40))
        try oldSocket.deliver(.event("member-joined", sequence: 41), to: oldReceive.id)
        try fixture.transport.scheduler.complete(oldTimer.id)
        try await asyncEventually("old HTTP unwound") { oldHTTP.returnedToCaller }
        await asyncDrain(256)
        try asyncRequire(SessionDigest(fixture.session) == fresh,
                         "late old HTTP, receive and timer cannot mutate new generation")
        try asyncRequire(oldSocket.sent.count == oldSentCount && newSocket.sent.count == newSentCount &&
                         newSocket.closeCount == 0 && memberCallbacks == 0,
                         "late old work cannot send through or close the new socket")
    }

    @MainActor
    static func reservationTimeoutFence() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        let oldSocket = try await fixture.establish(leader: true)
        guard let oldReceive = oldSocket.pending.first else { throw AsyncHarnessError.missingHandle }
        oldReceive.retainAfterCancellation = true
        let send = fixture.job {
            try await fixture.session.sendControl(
                .init(action: "pause", mediaId: SyntheticParty.title, positionMs: 123),
                currentOwner: { fixture.owner }, auth: fixture.auth, currentAuth: { fixture.currentAuth })
        }
        try await asyncEventually("leader awaits reservation and timeout") {
            fixture.session.testingState.hasReservation && oldSocket.sent.contains { $0.kind == "reserve" } &&
                fixture.transport.scheduler.pending.contains { $0.nanoseconds == 5_000_000_000 }
        }
        guard let timer = fixture.transport.scheduler.pending.first(where: {
            $0.nanoseconds == 5_000_000_000
        }) else { throw AsyncHarnessError.missingHandle }
        fixture.transport.scheduler.now = timer.started + 5_000
        try fixture.transport.scheduler.complete(timer.id)
        try await asyncEventually("reservation caller fails at timeout") { send.result != nil }
        if case .failure(let error)? = send.result, let failure = error as? WatchPartyClientSession.Failure {
            if case .expired = failure {} else { throw AsyncHarnessError.assertion("reservation timeout category") }
        } else { throw AsyncHarnessError.assertion("reservation timeout fails awaiting call") }
        try asyncRequire(oldSocket.closeCount > 0 && fixture.session.testingState.socketID == nil &&
                         !fixture.session.testingState.hasReservation && oldSocket.publishes.isEmpty,
                         "timed-out reservation tears down old state without publishing")

        let newSocket = try await fixture.establish(sequence: 100, leader: true)
        let fresh = SessionDigest(fixture.session)
        try oldSocket.deliver(.reservation(sequence: 41), to: oldReceive.id)
        await asyncDrain(128)
        try asyncRequire(SessionDigest(fixture.session) == fresh && newSocket.closeCount == 0 &&
                         newSocket.publishes.isEmpty && oldSocket.publishes.isEmpty,
                         "late old reservation cannot publish into freshly created generation")
    }

    @MainActor
    static func reservationSuccessBeforeTimeout() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        let control = WatchPartyWire.Control(action: "seek", mediaId: SyntheticParty.title, positionMs: 456)
        let latestControl = WatchPartyWire.Control(action: "seek", mediaId: SyntheticParty.title, positionMs: 654)
        let observation = OwnEchoObservation(control)
        // Caller contract only; this synthetic variable is not the actual UI coalescer.
        // One exact outstanding own echo consumes admission with a no-op performer.
        fixture.session.onControl = { received, sequence in
            guard let admitted = fixture.session.admit(received, sequence: sequence,
                current: fixture.owner, currentAuth: { fixture.currentAuth }) else { return false }
            observation.lastAdmitted = admitted
            let ownEcho = received == observation.fingerprint
            return fixture.session.apply(admitted, current: fixture.owner,
                currentAuth: { fixture.currentAuth }, perform: { received in
                    if ownEcho { observation.applications += 1 }
                    else { observation.localPosition = received.positionMs }
                    return true
                })
        }
        let socket = try await fixture.establish(leader: true)
        let send = fixture.job {
            try await fixture.session.sendControl(control, currentOwner: { fixture.owner },
                auth: fixture.auth, currentAuth: { fixture.currentAuth })
        }
        try await asyncEventually("successful reservation wait installed") {
            fixture.session.testingState.hasReservation &&
                fixture.transport.scheduler.pending.contains { $0.nanoseconds == 5_000_000_000 }
        }
        guard let timer = fixture.transport.scheduler.pending.first(where: {
            $0.nanoseconds == 5_000_000_000
        }) else { throw AsyncHarnessError.missingHandle }
        timer.retainAfterCancellation = true
        fixture.transport.scheduler.now = timer.started + 4_999
        try await fixture.emit(.reservation(sequence: 41), on: socket)
        try await asyncEventually("old seek publication sent before local seek changes") { socket.publishes.count == 1 }
        observation.localPosition = latestControl.positionMs
        let blocked = fixture.job {
            try await fixture.session.sendControl(latestControl, currentOwner: { fixture.owner },
                auth: fixture.auth, currentAuth: { fixture.currentAuth })
        }
        try await asyncEventually("second seek cannot overtake outstanding own echo") { blocked.result != nil }
        if case .failure? = blocked.result {} else {
            throw AsyncHarnessError.assertion("second seek cannot overtake first publication")
        }
        try asyncRequire(socket.sent.filter { $0.kind == "reserve" }.count == 1 && send.result == nil,
                         "second public seek emits no reserve while first publication awaits outcome")
        try await fixture.emitOwnSealedEcho(on: socket)
        try await send.value("reservation success returns to caller")
        guard let consumed = observation.lastAdmitted else { throw AsyncHarnessError.missingHandle }
        let appliedTwice = fixture.session.apply(consumed, current: fixture.owner,
            currentAuth: { fixture.currentAuth }, perform: { _ in observation.localPosition = -1; return true })
        try asyncRequire(!appliedTwice && observation.applications == 1 && observation.localPosition == latestControl.positionMs,
                         "old own echo consumes actual one-use permit without undoing newer local seek")
        try await asyncEventually("canceled reservation timer retained") { timer.cancelled }
        try asyncRequire(socket.publishes.count == 1 && !fixture.session.testingState.hasReservation,
                         "reservation arriving just before timeout publishes exactly once")
        guard let publish = socket.publishes.first, let ciphertext = publish.ciphertext else {
            throw AsyncHarnessError.missingHandle
        }
        try asyncRequire(publish.serverSequence == 41 && publish.reservationId == SyntheticParty.reservation &&
                         WatchPartyWire.open(ciphertext, roomKey: fixture.roomKey,
                            roomGeneration: SyntheticParty.generation, leaderTerm: 1, serverSequence: 41) == control,
                         "real ciphertext is bound to granted reservation sequence")
        let beforeTimer = SessionDigest(fixture.session)
        fixture.transport.scheduler.now = timer.started + 5_001
        try fixture.transport.scheduler.complete(timer.id)
        await asyncDrain(128)
        try asyncRequire(socket.closeCount == 0 && socket.publishes.count == 1 &&
                         SessionDigest(fixture.session) == beforeTimer,
                         "late canceled timer cannot spuriously close successful reservation")
        observation.fingerprint = latestControl
        let latestSend = fixture.job {
            try await fixture.session.sendControl(latestControl, currentOwner: { fixture.owner },
                auth: fixture.auth, currentAuth: { fixture.currentAuth })
        }
        try await asyncEventually("latest seek reserves after old outcome") {
            fixture.session.testingState.hasReservation && socket.sent.filter { $0.kind == "reserve" }.count == 2
        }
        try await fixture.emit(.reservation(sequence: 42), on: socket)
        try await fixture.emitOwnSealedEcho(on: socket, publicationIndex: 1)
        try await latestSend.value("latest seek completes after its own echo")
        guard let latestCiphertext = socket.publishes.last?.ciphertext else { throw AsyncHarnessError.missingHandle }
        try asyncRequire(socket.publishes.count == 2 && socket.publishes.last?.serverSequence == 42 &&
                         WatchPartyWire.open(latestCiphertext, roomKey: fixture.roomKey,
                            roomGeneration: SyntheticParty.generation, leaderTerm: 1, serverSequence: 42) == latestControl &&
                         observation.applications == 2 && observation.localPosition == latestControl.positionMs && socket.closeCount == 0,
                         "caller contract publishes latest seek after old settlement without replaying old local position")
    }

    @MainActor
    static func unknownNonceCloses() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        let socket = try await fixture.establish()
        _ = try await fixture.primePendingChallenge(socket)
        try await fixture.emit(.proof("unknown_hhhhhhhhhhhhhhhhhhh", sequence: 40), on: socket)
        try await asyncEventually("unknown proof fails closed") {
            fixture.session.testingState.socketID == nil && socket.closeCount > 0
        }
        try asyncRequire(fixture.session.testingState.leaseDeadline == nil &&
                         fixture.session.testingState.pendingNonce == nil,
                         "unknown nonce cannot extend a lease or leave a pending session")
    }

    @MainActor
    static func disconnectCallbackMayCancel() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        fixture.transport.http.enqueue(.joined(40, role: "guest"))
        _ = try await fixture.session.join(roomId: SyntheticParty.room, inviteCode: SyntheticParty.invite,
            roomKey: fixture.roomKey, auth: fixture.auth, currentAuth: { fixture.currentAuth })
        var callbacks = 0
        fixture.session.onDisconnected = {
            callbacks += 1
            fixture.session.cancel() // real reentrant owner callback; must not recurse
        }
        fixture.session.cancel()
        try asyncRequire(callbacks == 1 && fixture.session.testingState.socketID == nil &&
                         fixture.session.testingState.serverSequence == nil &&
                         !fixture.session.testingState.hasReservation,
                         "ownership teardown precedes one reentrant-safe disconnect callback")
        fixture.session.cancel()
        try asyncRequire(callbacks == 1, "canceling an already disconnected session emits no callback")
    }

    @MainActor
    static func memberJoinedCallbackIsSequenced() async throws {
        for eventType in ["member-joined", "member-ready"] {
        for violation in ["duplicate", "sequence-gap", "wrong-generation"] {
            let fixture = try SessionFixture()
            defer { fixture.cleanup() }
            var observedSequences: [Int64] = []
            let observe: @MainActor () -> Void = {
                observedSequences.append(fixture.session.testingState.serverSequence ?? -1)
            }
            if eventType == "member-ready" { fixture.session.onMemberReady = observe }
            else { fixture.session.onMemberJoined = observe }
            let socket = try await fixture.establish()
            if violation == "duplicate" {
                try await fixture.emit(.event(eventType, sequence: 41), on: socket)
                try asyncRequire(observedSequences == [41],
                                 "member callback observes already committed authenticated sequence")
            }
            var invalid = SyntheticServerFrame.event(eventType,
                sequence: violation == "sequence-gap" ? 42 : 41)
            if violation == "wrong-generation" {
                invalid.roomGeneration = "other_generation_iiiiiiiiii"
            }
            try await fixture.emit(invalid, on: socket)
            try await asyncEventually("invalid member event closes") {
                socket.closeCount > 0 && fixture.session.testingState.socketID == nil
            }
            try asyncRequire(observedSequences == (violation == "duplicate" ? [41] : []),
                             "duplicate, gap and wrong-room member events cannot emit callback")
        }
        }

        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        var callbacks = 0
        fixture.session.onMemberJoined = {
            callbacks += 1
            fixture.session.cancel()
        }
        let socket = try await fixture.establish()
        try await fixture.emit(.event("member-joined", sequence: 41), on: socket)
        try asyncRequire(callbacks == 1 && fixture.session.testingState.socketID == nil &&
                         socket.closeCount > 0 && socket.challenges.count == 1,
                         "member callback may tear down ownership without subsequent stale challenge")
    }

    @MainActor
    static func memberReadyRetiresReservation() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        var callbackSequences: [Int64] = []
        var callbackReservations: [Bool] = []
        fixture.session.onMemberReady = {
            callbackSequences.append(fixture.session.testingState.serverSequence ?? -1)
            callbackReservations.append(fixture.session.testingState.hasReservation)
        }
        let socket = try await fixture.establish(leader: true)
        let control = WatchPartyWire.Control(action: "pause", mediaId: SyntheticParty.title, positionMs: 789)
        let oldSend = fixture.job {
            try await fixture.session.sendControl(control, currentOwner: { fixture.owner },
                auth: fixture.auth, currentAuth: { fixture.currentAuth })
        }
        try await asyncEventually("old reservation pending before ready metadata") {
            fixture.session.testingState.hasReservation && socket.sent.filter { $0.kind == "reserve" }.count == 1
        }
        try await fixture.emit(.event("member-ready", sequence: 41), on: socket)
        await asyncDrain()
        try asyncRequire(callbackSequences == [41] && callbackReservations == [true] &&
                         oldSend.result == nil && fixture.session.testingState.hasReservation &&
                         socket.sent.filter { $0.kind == "reserve" }.count == 1 && socket.publishes.isEmpty,
                         "ready metadata retains sent unknown reservation until its old grant is consumed")
        try await fixture.emit(.reservation(sequence: 41), on: socket)
        try await asyncEventually("stale old grant consumed before reservation retirement") { oldSend.result != nil }
        if case .failure(let error)? = oldSend.result,
           let failure = error as? WatchPartyClientSession.Failure {
            if case .reservationRetired = failure {} else {
                throw AsyncHarnessError.assertion("ready metadata retirement category")
            }
        } else { throw AsyncHarnessError.assertion("ready metadata retires old send") }
        try asyncRequire(callbackSequences == [41] && callbackReservations == [true] &&
                         socket.closeCount == 0 && socket.publishes.isEmpty,
                         "consuming old grant retires sender and preserves the live sequenced socket")
        let freshSend = fixture.job {
            try await fixture.session.sendControl(control, currentOwner: { fixture.owner },
                auth: fixture.auth, currentAuth: { fixture.currentAuth })
        }
        try await asyncEventually("fresh reservation after ready metadata") {
            fixture.session.testingState.hasReservation && socket.sent.filter { $0.kind == "reserve" }.count == 2
        }
        try await fixture.emit(.reservation(sequence: 42), on: socket)
        try await fixture.emitOwnSealedEcho(on: socket)
        try await freshSend.value("fresh sender publishes after ready metadata")
        guard let publish = socket.publishes.first, let ciphertext = publish.ciphertext else {
            throw AsyncHarnessError.missingHandle
        }
        try asyncRequire(socket.publishes.count == 1 && publish.serverSequence == 42 &&
                         WatchPartyWire.open(ciphertext, roomKey: fixture.roomKey,
                            roomGeneration: SyntheticParty.generation, leaderTerm: 1, serverSequence: 42) == control &&
                         socket.closeCount == 0,
                         "fresh reservation publishes exactly one real encrypted control at sequence 42")
        try await fixture.emit(.event("member-ready", sequence: 41), on: socket)
        try asyncRequire(callbackSequences == [41] && socket.closeCount > 0,
                         "duplicate ready metadata cannot emit another callback")
    }

    @MainActor
    static func startupMessagesWaitForInitialProof() async throws {
        let readyFixture = try SessionFixture()
        defer { readyFixture.cleanup() }
        var readyCallbacks = 0
        readyFixture.session.onMemberReady = { readyCallbacks += 1 }
        let readySocket = try await readyFixture.establish(beforeInitialProof: { socket in
            try socket.deliver(.event("member-ready", sequence: 41))
        })
        try asyncRequire(readyCallbacks == 0 && readyFixture.session.testingState.serverSequence == 40,
                         "ready frame before initial proof cannot notify or advance playback state")
        try await readyFixture.emit(.event("member-ready", sequence: 41), on: readySocket)
        try asyncRequire(readyCallbacks == 1 && readyFixture.session.testingState.serverSequence == 41,
                         "authenticated ready event after connect notifies once")

        let sealedFixture = try SessionFixture()
        defer { sealedFixture.cleanup() }
        var applied = 0
        sealedFixture.session.onControl = { control, sequence in
            guard let admitted = sealedFixture.session.admit(control, sequence: sequence,
                current: sealedFixture.owner, currentAuth: { sealedFixture.currentAuth }) else { return false }
            return sealedFixture.session.apply(admitted, current: sealedFixture.owner,
                currentAuth: { sealedFixture.currentAuth }, perform: { _ in applied += 1; return true })
        }
        let control = WatchPartyWire.Control(action: "play", mediaId: SyntheticParty.title, positionMs: 321)
        guard let ciphertext = WatchPartyWire.seal(control, roomKey: sealedFixture.roomKey,
            roomGeneration: SyntheticParty.generation, leaderTerm: 1, serverSequence: 41) else {
            throw AsyncHarnessError.missingHandle
        }
        var frame = SyntheticServerFrame.event("sealed", sequence: 41)
        frame.ciphertext = ciphertext
        let sealedSocket = try await sealedFixture.establish(beforeInitialProof: { socket in
            try socket.deliver(frame)
        })
        try asyncRequire(applied == 0 && sealedFixture.session.testingState.serverSequence == 40,
                         "sealed control before initial proof cannot enter real admission or apply")
        try await sealedFixture.emit(frame, on: sealedSocket)
        try asyncRequire(applied == 1 && sealedFixture.session.testingState.serverSequence == 41 &&
                         sealedSocket.closeCount == 0,
                         "same real encrypted control after proof passes actual admit and apply once")
    }

    @MainActor
    static func retiredPublicationWaitsForCorrelatedOutcome() async throws {
        for eventType in ["member-ready", "lease-renewed"] {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        var callbackSequences: [Int64] = []
        var callbackHasReservation: [Bool] = []
        fixture.session.onMemberReady = {
            callbackSequences.append(fixture.session.testingState.serverSequence ?? -1)
            callbackHasReservation.append(fixture.session.testingState.hasReservation)
        }
        let socket = try await fixture.establish(leader: true)
        let oldControl = WatchPartyWire.Control(action: "play", mediaId: SyntheticParty.title, positionMs: 800)
        let oldSend = fixture.job {
            try await fixture.session.sendControl(oldControl, currentOwner: { fixture.owner },
                auth: fixture.auth, currentAuth: { fixture.currentAuth })
        }
        try await asyncEventually("old reserve sent") {
            fixture.session.testingState.hasReservation && socket.sent.filter { $0.kind == "reserve" }.count == 1
        }
        try await fixture.emit(.reservation(sequence: 41), on: socket)
        try await asyncEventually("old publish sent without outcome") { socket.publishes.count == 1 }
        await asyncDrain()
        try asyncRequire(oldSend.result == nil,
                         "socket write completion alone cannot finish publication")
        try await fixture.emit(.event(eventType, sequence: 41), on: socket)
        await asyncDrain()
        let callbackExpected = eventType == "member-ready"
            ? callbackSequences == [41] && callbackHasReservation == [false]
            : callbackSequences.isEmpty && callbackHasReservation.isEmpty
        try asyncRequire(callbackExpected &&
                         oldSend.result == nil && socket.closeCount == 0,
                         "advancing metadata retires sent publication while its server outcome remains pending")
        let blocked = fixture.job {
            try await fixture.session.sendControl(oldControl, currentOwner: { fixture.owner },
                auth: fixture.auth, currentAuth: { fixture.currentAuth })
        }
        try await asyncEventually("fresh send denied until old outcome") { blocked.result != nil }
        if case .failure? = blocked.result {} else {
            throw AsyncHarnessError.assertion("fresh send cannot overtake unresolved publication")
        }
        try asyncRequire(socket.sent.filter { $0.kind == "reserve" }.count == 1 &&
                         socket.publishes.count == 1 && oldSend.result == nil && socket.closeCount == 0,
                         "blocked fresh send emits no reserve or publish before correlated old outcome")

        try await asyncEventually("receive ready") { !socket.pending.isEmpty }
        let calls = socket.receiveCalls
        try socket.deliverRawJSON(#"{"kind":"error","code":"stale-reservation"}"#)
        try await asyncEventually("frame processed") {
            socket.receiveCalls > calls || socket.closeCount > 0
        }
        try await asyncEventually("specific old publication outcome consumed") { oldSend.result != nil }
        if case .failure(let error)? = oldSend.result,
           let failure = error as? WatchPartyClientSession.Failure {
            if case .reservationRetired = failure {} else {
                throw AsyncHarnessError.assertion("correlated retired publication outcome category")
            }
        } else { throw AsyncHarnessError.assertion("old publication returns retirement after its outcome") }
        try asyncRequire(socket.closeCount == 0 && fixture.session.testingState.serverSequence == 41,
                         "known retired publication outcome preserves live sequenced session")

        let latestControl = WatchPartyWire.Control(action: "pause", mediaId: SyntheticParty.title, positionMs: 900)
        let latestSend = fixture.job {
            try await fixture.session.sendControl(latestControl, currentOwner: { fixture.owner },
                auth: fixture.auth, currentAuth: { fixture.currentAuth })
        }
        try await asyncEventually("fresh reserve after old outcome") {
            fixture.session.testingState.hasReservation && socket.sent.filter { $0.kind == "reserve" }.count == 2
        }
        try await fixture.emit(.reservation(sequence: 42), on: socket)
        try await fixture.emitOwnSealedEcho(on: socket, publicationIndex: 1)
        try await latestSend.value("latest publication completes only after sealed echo")
        let publish = socket.publishes[1]
        guard let ciphertext = publish.ciphertext else { throw AsyncHarnessError.missingHandle }
        try asyncRequire(socket.publishes.count == 2 && publish.serverSequence == 42 &&
                         WatchPartyWire.open(ciphertext, roomKey: fixture.roomKey,
                            roomGeneration: SyntheticParty.generation, leaderTerm: 1, serverSequence: 42) == latestControl &&
                         fixture.session.testingState.serverSequence == 42 && socket.closeCount == 0,
                         "fresh latest state is correlated, decrypted and applied at sequence 42")
        }
    }

    @MainActor
    static func main() async {
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("replacement HTTP ownership across two lease events", { try await replacementRace(secondEvent: "lease-renewed") }),
            ("sticky member refresh across member-joined replacement", { try await replacementRace(secondEvent: "member-joined") }),
            ("lease events during ordinary liveness HTTP", ordinaryRefreshRace),
            ("same Session and auth reject late old generation work", sameSessionGenerationFence),
            ("reservation timeout and late old reservation", reservationTimeoutFence),
            ("reservation timeout and own-echo latest-seek caller contract", reservationSuccessBeforeTimeout),
            ("unknown nonce proof fails closed", unknownNonceCloses),
            ("disconnect callback can defensively cancel", disconnectCallbackMayCancel),
            ("member callback follows sequence admission and teardown fence", memberJoinedCallbackIsSequenced),
            ("member-ready metadata retires old reservation and permits fresh publish", memberReadyRetiresReservation),
            ("early startup frames ignored and valid frames redelivered after proof", startupMessagesWaitForInitialProof),
            ("retired publication waits for its correlated server outcome", retiredPublicationWaitsForCorrelatedOutcome),
        ]
        var failed = 0
        for (label, operation) in cases {
            do {
                try await operation()
                await asyncDrain()
                print("PASS actual Session async regression: " + label)
            } catch AsyncHarnessError.assertion(let assertion) {
                failed += 1
                print("FAIL actual Session async regression: " + label + " [" + assertion + "]")
            } catch {
                failed += 1
                // Never interpolate transport errors, headers, URLs or payloads.
                print("FAIL actual Session async regression: " + label + " [unexpected failure category]")
            }
        }
        print("Actual Session async regressions: \(cases.count - failed)/\(cases.count) passed")
        if failed != 0 { Foundation.exit(1) }
    }
}
