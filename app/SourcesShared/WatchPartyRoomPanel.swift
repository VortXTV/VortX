import SwiftUI

/// Main-actor UI adapter around the reviewed transport. Callers own playback identity and pass
/// fresh contexts; this view never reads engine/account internals or auto-joins a deep link.
@MainActor
final class WatchPartyPanelModel: ObservableObject {
    typealias Auth = VortXWatchPartyAuthSnapshot
    typealias Context = WatchPartyClientSession.ApplyContext

    @Published private(set) var status = "Disconnected"
    @Published private(set) var inviteURL: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var errorText: String?

    private let client: WatchPartyClientSession
    private let currentAuth: @MainActor () -> Auth?
    private let currentContext: @MainActor () -> Context?
    private let currentPlaybackSnapshot: @MainActor () -> WatchPartyWire.Control?
    private let ownerGeneration: @MainActor () -> UUID
    private let ownerWillReconnect: @MainActor () -> Void
    private var operationID = UUID()
    private var connected = false
    private var isHost = false
    private var sessionAuth: Auth?
    private var initialReplayTask: Task<Void, Never>?
    private var initialReplayObligation = WatchPartyReplayObligation()
    private var outboundControlInFlight = false
    private var pendingLocalEcho: WatchPartyWire.Control?
    private var queuedLocalControl: (control: WatchPartyWire.Control, auth: Auth, context: Context)?

    init(client: WatchPartyClientSession = WatchPartyClientSession(),
         performControl: @escaping @MainActor (WatchPartyWire.Control) -> Bool,
         currentAuth: @escaping @MainActor () -> Auth?,
         currentContext: @escaping @MainActor () -> Context?,
         currentPlaybackSnapshot: @escaping @MainActor () -> WatchPartyWire.Control? = { nil },
         ownerGeneration: @escaping @MainActor () -> UUID,
         ownerWillReconnect: @escaping @MainActor () -> Void = {}) {
        self.client = client
        self.performControl = performControl
        self.currentAuth = currentAuth
        self.currentContext = currentContext
        self.currentPlaybackSnapshot = currentPlaybackSnapshot
        self.ownerGeneration = ownerGeneration
        self.ownerWillReconnect = ownerWillReconnect
        client.onDisconnected = { [weak self] in
            guard let self, self.connected else { return }
            self.connected = false
            self.isHost = false
            self.sessionAuth = nil
            self.initialReplayTask?.cancel(); self.initialReplayTask = nil
            self.initialReplayObligation.cancel()
            self.queuedLocalControl = nil
            // create/join/leave already rotate before their own local teardown. Only an
            // unsolicited live-session loss needs a fresh caller generation here.
            if !self.isBusy { self.ownerWillReconnect() }
            self.status = "Disconnected"
            self.inviteURL = nil
            if !self.isBusy { self.errorText = "The room connection ended. Reconnect to continue." }
        }
        client.onControl = { [weak self] control, sequence in
            guard let self, let before = self.currentContext(),
                  let admitted = self.client.admit(control, sequence: sequence, current: before,
                                                   currentAuth: self.currentAuth),
                  let now = self.currentContext() else { return false }
            // Admission, guard recheck, one-use consume, and the synchronous player action occur
            // in this same MainActor turn. No Task/await is allowed in `perform`.
            return self.client.apply(admitted, current: now, currentAuth: self.currentAuth,
                                     perform: self.performAdmittedControl)
        }
        client.onMemberReady = { [weak self] in self?.scheduleInitialStateReplay() }
    }

    private let performControl: @MainActor (WatchPartyWire.Control) -> Bool

    func create() async {
        guard !isBusy else { return }
        guard let previousAuth = currentAuth(), let previousContext = currentContext(),
              previousContext.auth == previousAuth,
              previousContext.localOwnerGeneration == ownerGeneration() else {
            show("Sign in and start a title first."); return
        }
        ownerWillReconnect()
        guard let auth = currentAuth(), let context = currentContext(), context.auth == auth,
              context.localOwnerGeneration == ownerGeneration() else {
            show("Playback changed. Reopen Watch Party and retry."); return
        }
        let id = begin("Creating room…")
        sessionAuth = auth
        do {
            let (receipt, key) = try await client.create(auth: auth, currentAuth: currentAuth)
            guard isCurrent(id), currentAuth() == auth, let context = currentContext(),
                  context.localOwnerGeneration == ownerGeneration(),
                  let url = WatchPartyInviteLink.make(roomID: receipt.roomId,
                                                     inviteCode: receipt.inviteCode, roomKey: key) else { throw WatchPartyClientSession.Failure.ownerChanged }
            inviteURL = url
            isHost = true
            try await client.connect(snapshot: receipt.snapshot, localOwnerGeneration: context.localOwnerGeneration,
                                     auth: auth, currentAuth: currentAuth)
            guard isCurrent(id), currentAuth() == auth, currentContext()?.localOwnerGeneration == context.localOwnerGeneration else {
                throw WatchPartyClientSession.Failure.ownerChanged
            }
            isBusy = false; status = "Connected · host"; errorText = nil
            connected = true
            drainInitialStateReplay()
        } catch { failIfCurrent(id) }
    }

    func join(_ rawLink: String) async {
        guard !isBusy else { return }
        guard let url = URL(string: rawLink), let invite = WatchPartyInviteLink.parse(url),
              let previousAuth = currentAuth(), let previousContext = currentContext(),
              previousContext.auth == previousAuth,
              previousContext.localOwnerGeneration == ownerGeneration() else {
            show("Paste a complete VortX Watch Party invite and start a title first."); return
        }
        ownerWillReconnect()
        guard let auth = currentAuth(), let context = currentContext(), context.auth == auth,
              context.localOwnerGeneration == ownerGeneration() else {
            show("Playback changed. Reopen Watch Party and retry."); return
        }
        let id = begin("Joining room…")
        sessionAuth = auth
        do {
            let receipt = try await client.join(roomId: invite.roomID, inviteCode: invite.inviteCode,
                                                roomKey: invite.roomKey, auth: auth, currentAuth: currentAuth)
            guard isCurrent(id), currentAuth() == auth, currentContext()?.localOwnerGeneration == context.localOwnerGeneration else {
                throw WatchPartyClientSession.Failure.ownerChanged
            }
            try await client.connect(snapshot: receipt.snapshot, localOwnerGeneration: context.localOwnerGeneration,
                                     auth: auth, currentAuth: currentAuth)
            guard isCurrent(id), currentAuth() == auth, currentContext()?.localOwnerGeneration == context.localOwnerGeneration else {
                throw WatchPartyClientSession.Failure.ownerChanged
            }
            if WatchPartyPendingInvite.shared.invite == invite { _ = WatchPartyPendingInvite.shared.consume() }
            inviteURL = nil; isBusy = false; status = "Connected · guest"; errorText = nil
            connected = true
            isHost = false
        } catch { failIfCurrent(id) }
    }

    func send(_ action: String, positionMs: Int64) {
        guard connected, let context = currentContext(), let auth = currentAuth(),
              let mediaID = WatchPartyWire.canonicalTitleToken(context.titleToken) else { return }
        let control = WatchPartyWire.Control(action: action, mediaId: mediaID, positionMs: positionMs)
        if outboundControlInFlight {
            queuedLocalControl = (control, auth, context) // bounded latest viewer intent
            return
        }
        Task { @MainActor [weak self] in
            guard let self, self.currentAuth() == auth, self.currentContext()?.localOwnerGeneration == context.localOwnerGeneration else { return }
            do { try await self.sendOutbound(control, auth: auth, context: context) }
            catch OutboundFailure.busy { self.queuedLocalControl = (control, auth, context) }
            catch { self.errorText = "Playback control could not be shared." }
        }
    }

    func cancelAndDisconnect() {
        operationID = UUID() // invalidate UI continuations before closing the session
        initialReplayTask?.cancel(); initialReplayTask = nil; initialReplayObligation.cancel()
        queuedLocalControl = nil
        ownerWillReconnect()
        connected = false; isHost = false
        let id = operationID
        let auth = sessionAuth ?? currentAuth()
        inviteURL = nil; status = "Disconnected"; errorText = nil
        guard let auth else { client.cancel(); isBusy = false; connected = false; isHost = false; return }
        // Reserve the model until leave has synchronously revoked local authority and sent best-effort
        // cleanup; create/join are blocked while this task is queued or suspended.
        isBusy = true
        Task { @MainActor [client = self.client, currentAuth = self.currentAuth, weak self] in
            await client.leave(auth: auth, currentAuth: currentAuth)
            guard let self, self.operationID == id else { return }
            self.connected = false
            self.isHost = false
            self.sessionAuth = nil
            self.isBusy = false
        }
    }

    private func begin(_ text: String) -> UUID { operationID = UUID(); isBusy = true; status = text; errorText = nil; return operationID }
    private func isCurrent(_ id: UUID) -> Bool { operationID == id }
    private func show(_ text: String) { errorText = text }
    private func failIfCurrent(_ id: UUID) {
        guard isCurrent(id) else { return }
        isBusy = false; status = "Disconnected"; inviteURL = nil
        sessionAuth = nil
        isHost = false
        initialReplayTask?.cancel(); initialReplayTask = nil; initialReplayObligation.cancel()
        queuedLocalControl = nil
        errorText = "Could not connect. Check the invite, account session, and playback, then retry."
        client.cancel()
        ownerWillReconnect()
    }

    private enum OutboundFailure: Error { case busy }

    private func sendOutbound(_ control: WatchPartyWire.Control, auth: Auth, context: Context) async throws {
        guard !outboundControlInFlight else { throw OutboundFailure.busy }
        outboundControlInFlight = true
        pendingLocalEcho = control
        defer {
            if pendingLocalEcho == control { pendingLocalEcho = nil }
            outboundControlInFlight = false
            if let queued = queuedLocalControl {
                // Keep the queued slot occupied until this task is ready to enter sendOutbound. A
                // replay drain must not slip between publication completion and the queued action.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.currentAuth() == queued.auth,
                          self.currentContext()?.localOwnerGeneration == queued.context.localOwnerGeneration else {
                        if let pending = self.queuedLocalControl,
                           pending.control == queued.control,
                           pending.context.localOwnerGeneration == queued.context.localOwnerGeneration {
                            self.queuedLocalControl = nil
                        }
                        self.drainInitialStateReplay()
                        return
                    }
                    if let pending = self.queuedLocalControl,
                       pending.control == queued.control,
                       pending.context.localOwnerGeneration == queued.context.localOwnerGeneration {
                        self.queuedLocalControl = nil
                    }
                    do { try await self.sendOutbound(queued.control, auth: queued.auth, context: queued.context) }
                    catch { self.errorText = "Playback control could not be shared." }
                    self.drainInitialStateReplay()
                }
            } else {
                drainInitialStateReplay()
            }
        }
        try await client.sendControl(control, currentOwner: currentContext, auth: auth, currentAuth: currentAuth)
        guard currentAuth() == auth, let now = currentContext(), now.localOwnerGeneration == context.localOwnerGeneration else {
            throw WatchPartyClientSession.Failure.ownerChanged
        }
    }

    /// A host's own ordered echo must advance/consume admission like any other frame, but must not
    /// seek or toggle the local player a second time.
    private func performAdmittedControl(_ control: WatchPartyWire.Control) -> Bool {
        if pendingLocalEcho == control { pendingLocalEcho = nil; return true }
        return performControl(control)
    }

    /// Coalesced leader replay after a guest proves its socket and the relay emits ordered member-ready.
    /// Uses the existing encrypted play/pause control format and reservation sequence; no media identity
    /// or playhead is sent in relay-readable event metadata.
    private func scheduleInitialStateReplay() {
        guard isHost else { return }
        initialReplayObligation.markReady()
        drainInitialStateReplay()
    }

    /// One coalesced obligation waits behind the active outbound and any queued viewer action.
    /// The outbound completion path calls this again, so a slow publication cannot consume retries.
    private func drainInitialStateReplay() {
        guard initialReplayTask == nil, isCurrent(operationID), isHost, connected,
              initialReplayObligation.begin(outboundBusy: outboundControlInFlight || queuedLocalControl != nil) else { return }
        let id = operationID
        initialReplayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.isCurrent(id) {
                    self.initialReplayTask = nil
                    if self.initialReplayObligation.needsDrain {
                        self.drainInitialStateReplay()
                    }
                }
            }
            // Capture at task entry, after queued main-actor work has had a chance to run. This
            // prevents a stale pre-seek snapshot from overtaking a newer local viewer command.
            guard !Task.isCancelled, self.isCurrent(id), self.isHost, self.connected else {
                if self.isCurrent(id) { self.initialReplayObligation.cancel() }
                return
            }
            guard !self.outboundControlInFlight, self.queuedLocalControl == nil else {
                self.initialReplayObligation.retryAfterRetirement()
                return
            }
            guard let auth = self.currentAuth(), let context = self.currentContext(),
                  context.auth == auth, context.localOwnerGeneration == self.ownerGeneration(),
                  let control = self.currentPlaybackSnapshot(),
                  (control.action == "play" || control.action == "pause"),
                  control.mediaId == context.titleToken,
                  (0...86_400_000).contains(control.positionMs) else {
                self.initialReplayObligation.cancel()
                return
            }
            do {
                try await self.sendOutbound(control, auth: auth, context: context)
                guard !Task.isCancelled, self.isCurrent(id) else { return }
                self.initialReplayObligation.complete()
            } catch OutboundFailure.busy {
                guard self.isCurrent(id) else { return }
                self.initialReplayObligation.retryAfterRetirement()
            } catch WatchPartyClientSession.Failure.reservationRetired {
                guard self.isCurrent(id) else { return }
                self.initialReplayObligation.retryAfterRetirement()
            } catch {
                guard self.isCurrent(id) else { return }
                self.initialReplayObligation.cancel()
                self.errorText = "A new viewer joined, but playback sync could not be sent."
            }
        }
    }

}

struct WatchPartyRoomPanel: View {
    @ObservedObject var model: WatchPartyPanelModel
    @State private var inviteText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Watch Party").font(.title2.weight(.semibold))
            Text(model.status).foregroundStyle(.secondary)
            if let error = model.errorText { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Create room") { Task { await model.create() } }.disabled(model.isBusy)
                #if !os(tvOS)
                if let invite = model.inviteURL { ShareLink(item: invite) { Label("Share invite", systemImage: "square.and.arrow.up") } }
                #endif
                Button("Leave") { model.cancelAndDisconnect() }
            }
            #if os(macOS)
            TextField("Paste full invite link", text: $inviteText).autocorrectionDisabled()
            #else
            TextField("Paste full invite link", text: $inviteText, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            #endif
            Button("Join room") { let text = inviteText; Task { await model.join(text) } }
                .disabled(model.isBusy || inviteText.isEmpty)
            Text("The invite includes a private encryption key. Share it only with people you want in this room.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Recipients should paste the complete invite into VortX. Browser landing and automatic app opening are not enabled.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: 520)
        .vortxGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
                    fillAlpha: VortXGlass.pillFillAlpha, shadow: .pill)
        .onReceive(WatchPartyPendingInvite.shared.$invite) { invite in
            // Display only. The viewer must press Join; deep links never create membership implicitly.
            if let invite { inviteText = invite.url.absoluteString }
        }
    }
}
