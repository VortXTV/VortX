// Standalone regressions for the production WatchPartyPanelModel.
// Run from the repository root on macOS with Swift 6:
//   python3 scripts/test-watch-party-regressions.py
// The runner extracts the exact model from app/SourcesShared/WatchPartyRoomPanel.swift
// and compiles its real Session, auth, credential, HTTP, wire and invite helpers.
// The injected player position and transport scheduling are synthetic. No live
// player/account/network or wall-clock sleep is used; sensitive payloads are not printed.
import Foundation

@MainActor
private final class PanelModelFixture {
    let transport: ControlledTransport
    let authority: CredentialScopeRegistry
    let auth: VortXWatchPartyAuthSnapshot
    var currentAuth: VortXWatchPartyAuthSnapshot?
    let client: WatchPartyClientSession
    private(set) var model: WatchPartyPanelModel!
    var ownerGeneration = UUID()
    let target = PlaybackMutationTarget(syntheticID: UUID())
    let loadToken = PlayerLoadToken(syntheticID: UUID())
    var localPosition: Int64 = 100
    var isPlaying = false
    private(set) var snapshotPositions: [Int64] = []
    private(set) var performedControls: [WatchPartyWire.Control] = []
    private(set) var ownerRotations = 0
    private(set) var roomKey: Data?
    private var cancellations: [@MainActor () -> Void] = []

    init() throws {
        let transport = ControlledTransport()
        let authority = CredentialScopeRegistry()
        self.transport = transport
        self.authority = authority
        let accountID = "01234567-89ab-cdef-0123-456789abcdef"
        guard let scope = CredentialScope(canonicalRemoteAccountID: accountID),
              let capture = authority.tryBind(scope),
              authority.establishAuthenticatedOwner(capture) != nil,
              let auth = VortXWatchPartyAuthCapturePolicy.capture(
                isSignedIn: true, bearer: "synthetic-model-account-session-only", accountID: accountID,
                profileID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
                generation: 7, credential: capture, authority: authority, profileGeneration: UUID()) else {
            throw AsyncHarnessError.assertion("real isolated model auth capture")
        }
        self.auth = auth
        currentAuth = auth
        client = WatchPartyClientSession(testing: transport.dependencies,
                                         monotonicNow: { transport.scheduler.now })
        model = WatchPartyPanelModel(client: client,
            performControl: { [weak self] control in
                guard let self else { return false }
                self.performedControls.append(control)
                self.localPosition = control.positionMs
                if control.action == "play" { self.isPlaying = true }
                if control.action == "pause" { self.isPlaying = false }
                return true
            },
            currentAuth: { [weak self] in self?.currentAuth },
            currentContext: { [weak self] in self?.context },
            currentPlaybackSnapshot: { [weak self] in
                guard let self else { return nil }
                self.snapshotPositions.append(self.localPosition)
                return .init(action: self.isPlaying ? "play" : "pause",
                             mediaId: SyntheticParty.title, positionMs: self.localPosition)
            },
            ownerGeneration: { [weak self] in self?.ownerGeneration ?? UUID() },
            ownerWillReconnect: { [weak self] in
                self?.ownerGeneration = UUID()
                self?.ownerRotations += 1
            })
    }

    var context: WatchPartyClientSession.ApplyContext {
        .init(target: target, auth: auth, titleToken: SyntheticParty.title,
              playbackSessionID: "synthetic-model-playback-session", loadToken: loadToken,
              localOwnerGeneration: ownerGeneration)
    }

    func job<Value>(_ operation: @MainActor @escaping () async throws -> Value) -> AsyncHarnessJob<Value> {
        let job = AsyncHarnessJob(operation)
        cancellations.append { job.cancel() }
        return job
    }

    func createHost() async throws -> ControlledSocket {
        transport.http.enqueue(.created(40))
        transport.http.enqueue(.ticket)
        let create = job { await self.model.create() }
        try await asyncEventually("actual model creates socket") { self.transport.sockets.count == 1 }
        guard let socket = transport.sockets.first else { throw AsyncHarnessError.missingHandle }
        try await asyncEventually("actual model waits for initial proof") {
            socket.challenges.count == 1 && socket.pending.count == 1
        }
        guard let nonce = socket.challenges.first?.nonce else { throw AsyncHarnessError.missingHandle }
        try socket.deliver(.proof(nonce, sequence: 40))
        try await create.value("public model create finishes")
        try await asyncEventually("actual model host connected") {
            self.model.status == "Connected · host" && !self.model.isBusy && !socket.pending.isEmpty
        }
        guard let url = model.inviteURL, let invite = WatchPartyInviteLink.parse(url) else {
            throw AsyncHarnessError.assertion("actual model invite yields real room key")
        }
        roomKey = invite.roomKey
        try asyncRequire(invite.roomID == SyntheticParty.room && invite.roomKey.count == 32 &&
                         ownerRotations == 1 && transport.http.boundaryValid && transport.socketBoundaryValid,
                         "actual model create preserves owner and hardened Session boundaries")
        try asyncRequire(snapshotPositions.isEmpty && socket.publishes.isEmpty,
                         "host startup alone creates no readiness replay")
    
        return socket
    }

    func localSeek(_ position: Int64, share: Bool) {
        localPosition = position // synthetic player's synchronous local seek
        if share { model.send("seek", positionMs: position) }
    }

    func emit(_ frame: SyntheticServerFrame, on socket: ControlledSocket) async throws {
        try await asyncEventually("model socket receive ready") { !socket.pending.isEmpty }
        let calls = socket.receiveCalls
        try socket.deliver(frame)
        try await asyncEventually("model frame processed") { socket.receiveCalls > calls || socket.closeCount > 0 }
    }

    func grant(_ sequence: Int64, reserveCount: Int, on socket: ControlledSocket) async throws {
        try await asyncEventually("actual model reserve queued") {
            socket.sent.filter { $0.kind == "reserve" }.count == reserveCount && self.client.testingState.hasReservation
        }
        try await emit(.reservation(sequence: sequence), on: socket)
    }

    func publication(_ index: Int, on socket: ControlledSocket) async throws -> WatchPartyWire.Control {
        try await asyncEventually("actual model encrypted publication") { socket.publishes.count > index }
        let publish = socket.publishes[index]
        guard let sequence = publish.serverSequence, let ciphertext = publish.ciphertext,
              let roomKey,
              let control = WatchPartyWire.open(ciphertext, roomKey: roomKey,
                roomGeneration: SyntheticParty.generation, leaderTerm: 1, serverSequence: sequence) else {
            throw AsyncHarnessError.assertion("real model publication decrypts with actual invite key")
        }
        return control
    }

    func echo(_ index: Int, on socket: ControlledSocket) async throws {
        _ = try await publication(index, on: socket)
        let publish = socket.publishes[index]
        guard let sequence = publish.serverSequence, let ciphertext = publish.ciphertext else {
            throw AsyncHarnessError.missingHandle
        }
        var frame = SyntheticServerFrame.event("sealed", sequence: sequence)
        frame.ciphertext = ciphertext
        try await emit(frame, on: socket)
    }

    func stalePublicationOutcome(on socket: ControlledSocket) async throws {
        try await asyncEventually("model socket receive ready") { !socket.pending.isEmpty }
        let calls = socket.receiveCalls
        try socket.deliverRawJSON(#"{"kind":"error","code":"stale-reservation"}"#)
        try await asyncEventually("model frame processed") {
            socket.receiveCalls > calls || socket.closeCount > 0
        }
    }

    func cleanup() {
        model.cancelAndDisconnect()
        for cancel in cancellations { cancel() }
        cancellations.removeAll()
        client.onControl = nil
        client.onMemberReady = nil
        client.onMemberJoined = nil
        client.onDisconnected = nil
        client.cancel()
        transport.cleanup()
    }
}

@main
struct WatchPartyPanelModelAsyncTestRunner {
    @MainActor
    static func slowOutboundCoalescesReadiness() async throws {
        let fixture = try PanelModelFixture()
        defer { fixture.cleanup() }
        let socket = try await fixture.createHost()
        fixture.model.send("pause", positionMs: 100)
        try await fixture.grant(41, reserveCount: 1, on: socket)
        let original = try await fixture.publication(0, on: socket)
        try asyncRequire(original.action == "pause" && original.positionMs == 100,
                         "actual model first outbound is the original viewer action")
        let publicationStarted = fixture.transport.scheduler.now
        fixture.transport.scheduler.now += 1_500 // controlled time; no sleep, timeout remains pending
        fixture.localSeek(999, share: false)
        try await fixture.emit(.event("member-ready", sequence: 41), on: socket)
        try await fixture.emit(.event("member-ready", sequence: 42), on: socket)
        await asyncDrain(128)
        try asyncRequire(fixture.transport.scheduler.now - publicationStarted > 1_000 &&
                         socket.sent.filter { $0.kind == "reserve" }.count == 1 &&
                         socket.publishes.count == 1 && fixture.snapshotPositions.isEmpty && socket.closeCount == 0,
                         "busy longer than one second preserves coalesced readiness without retry or stale snapshot")
        try await fixture.stalePublicationOutcome(on: socket)
        try await fixture.grant(43, reserveCount: 2, on: socket)
        let replay = try await fixture.publication(1, on: socket)
        try asyncRequire(replay.action == "pause" && replay.positionMs == 999 &&
                         fixture.snapshotPositions == [999],
                         "old correlated outcome drains exactly one fresh latest-state replay")
        try await fixture.echo(1, on: socket)
        await asyncDrain(256)
        try asyncRequire(socket.sent.filter { $0.kind == "reserve" }.count == 2 && socket.publishes.count == 2 &&
                         fixture.client.testingState.serverSequence == 43 && fixture.localPosition == 999 &&
                         fixture.performedControls.isEmpty && fixture.model.status == "Connected · host" && socket.closeCount == 0,
                         "coalesced replay settles once through actual model own-echo admission")
    }

    @MainActor
    static func snapshotSampledAtGuardedTaskEntry() async throws {
        let fixture = try PanelModelFixture()
        defer { fixture.cleanup() }
        let socket = try await fixture.createHost()
        let actualReady = fixture.client.onMemberReady
        var hookObservedNoSample = false
        fixture.client.onMemberReady = {
            actualReady?() // schedules the ACTUAL model's replay task
            hookObservedNoSample = fixture.snapshotPositions.isEmpty
            fixture.localSeek(2_345, share: false) // same actor turn, before that task can start
        }
        try await fixture.emit(.event("member-ready", sequence: 41), on: socket)
        try await fixture.grant(42, reserveCount: 1, on: socket)
        let replay = try await fixture.publication(0, on: socket)
        try asyncRequire(hookObservedNoSample && fixture.snapshotPositions == [2_345] &&
                         replay.action == "pause" && replay.positionMs == 2_345,
                         "actual guarded task samples after newer synchronous local seek, not in ready callback")
        try await fixture.echo(0, on: socket)
        await asyncDrain(128)
        try asyncRequire(socket.publishes.count == 1 && fixture.localPosition == 2_345 &&
                         fixture.performedControls.isEmpty && fixture.client.testingState.serverSequence == 42 && socket.closeCount == 0,
                         "fresh snapshot is admitted without replaying a local player mutation")
    }

    @MainActor
    static func cancelBeforeReplayTaskEntry() async throws {
        let fixture = try PanelModelFixture()
        defer { fixture.cleanup() }
        let socket = try await fixture.createHost()
        let actualReady = fixture.client.onMemberReady
        var hookCalled = false
        fixture.client.onMemberReady = {
            actualReady?() // creates replay task while still in this MainActor turn
            hookCalled = true
            fixture.model.cancelAndDisconnect() // revokes/cancels it before actor task entry
        }
        try await fixture.emit(.event("member-ready", sequence: 41), on: socket)
        await asyncDrain(256)
        try asyncRequire(hookCalled && fixture.snapshotPositions.isEmpty && socket.publishes.isEmpty &&
                         socket.sent.filter { $0.kind == "reserve" }.isEmpty &&
                         fixture.model.status == "Disconnected" && fixture.client.testingState.socketID == nil,
                         "actual queued model replay cannot sample, reserve or publish after same-turn cancellation")
    }

    @MainActor
    static func queuedLatestSeekSurvivesOldOwnEcho() async throws {
        let fixture = try PanelModelFixture()
        defer { fixture.cleanup() }
        let socket = try await fixture.createHost()
        fixture.localSeek(456, share: true)
        try await fixture.grant(41, reserveCount: 1, on: socket)
        let first = try await fixture.publication(0, on: socket)
        try asyncRequire(first.action == "seek" && first.positionMs == 456,
                         "actual model publishes host seek one")
        fixture.localSeek(654, share: true) // public model.send queues latest while outbound is held
        await asyncDrain(128)
        try asyncRequire(socket.sent.filter { $0.kind == "reserve" }.count == 1 && socket.publishes.count == 1 &&
                         fixture.localPosition == 654,
                         "actual model coalesces seek two behind unsettled seek one")
        try await fixture.echo(0, on: socket)
        try asyncRequire(fixture.client.testingState.serverSequence == 41 &&
                         fixture.localPosition == 654 && fixture.performedControls.isEmpty,
                         "actual model admits old exact own echo with no-op performer, preserving local seek two")
        try await fixture.grant(42, reserveCount: 2, on: socket)
        let latest = try await fixture.publication(1, on: socket)
        try asyncRequire(latest.action == "seek" && latest.positionMs == 654,
                         "old settlement drains actual queued latest local seek")
        try await fixture.echo(1, on: socket)
        await asyncDrain(256)
        try asyncRequire(socket.sent.filter { $0.kind == "reserve" }.count == 2 && socket.publishes.count == 2 &&
                         fixture.client.testingState.serverSequence == 42 && fixture.localPosition == 654 &&
                         fixture.performedControls.isEmpty && fixture.snapshotPositions.isEmpty && socket.closeCount == 0,
                         "actual model completes ordered latest seek without extra replay or local rewind")
    }

    @MainActor
    static func main() async {
        let groups: [(String, @MainActor () async throws -> Void)] = [
            ("slow outbound retains and coalesces ready replay", slowOutboundCoalescesReadiness),
            ("actual replay samples snapshot after same-turn local seek", snapshotSampledAtGuardedTaskEntry),
            ("actual replay task canceled before actor entry emits no reserve", cancelBeforeReplayTaskEntry),
            ("actual model queues latest seek and suppresses old own-echo mutation", queuedLatestSeekSurvivesOldOwnEcho),
        ]
        var failures = 0
        for (label, group) in groups {
            do {
                try await group()
                await asyncDrain()
                print("PASS actual PanelModel async regression: " + label)
            } catch AsyncHarnessError.assertion(let assertion) {
                failures += 1
                print("FAIL actual PanelModel async regression: " + label + " [" + assertion + "]")
            } catch {
                failures += 1
                print("FAIL actual PanelModel async regression: " + label + " [unexpected failure category]")
            }
        }
        print("Actual PanelModel async regressions: \(groups.count - failures)/\(groups.count) passed")
        if failures != 0 { Foundation.exit(1) }
    }
}
