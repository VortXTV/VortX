import SwiftUI

/// "Install by QR - pair once, add many." The TV/phone/Mac shows a QR that opens a phone page; the user
/// pastes add-on manifest URLs there, and this view polls the relay session and AUTO-INSTALLS each accepted
/// submission THROUGH THE APP'S OWN hardened path (`CoreBridge.installAddon`), then publishes an explicit
/// on-device success / failure.
///
/// ARCHITECTURE: every DECISION lives in `AddonPairingReducer` (a pure, Foundation-only state machine that is
/// compiled directly into `AddonPairingReducerTests`); this view owns only I/O - creating / polling / rotating
/// the relay session, rendering the QR, and executing the reducer's effects (`resolve` / `install`) against
/// `CoreBridge`, reporting each result back as an event. So the "auto-install on ready, install exactly once,
/// fail honestly" contract is verified against the SHIPPED reducer, not a copy.
///
/// SAFETY MODEL (why auto-install is safe): the relay (`add.vortx.tv`) is a dumb pipe that only carries URL
/// strings, scoped to ONE one-time TV pairing session. A submission is acted on only when its token is THIS
/// device's CURRENT live session (`Event.delivered(liveToken:)`), so only a phone that scanned the QR now on
/// screen can push a URL here. Every accepted URL is still fetched + validated by `CoreBridge`
/// (`previewAddonManifest` then `installAddon`, the SAME validation + SSRF guard the paste-a-URL flow uses); a
/// malformed URL or a manifest that fails validation lands `.invalid` and is NEVER installed or counted as
/// success. Auto-install replaces the old "walk back to the TV and tap Install per row" step; a focusable
/// manual Install / Retry stays as recovery for a skipped or failed auto-install.
struct AddonPairingView: View {
    // The engine bridge is a singleton (`CoreBridge.shared`) referenced directly across the app; use it here
    // too so the install + validation path works regardless of how this view is presented (a sheet on tvOS /
    // macOS does not always carry the presenter's `@EnvironmentObject`s).
    private let core = CoreBridge.shared
    @Environment(\.dismiss) private var dismiss

    // Session + QR.
    @State private var session: AddonPairingClient.Session?
    @State private var qrImage: CGImage?
    @State private var creating = false
    @State private var createFailed = false

    // The whole pairing decision state lives in the reducer; the view never mutates rows directly.
    @State private var pairing = AddonPairingReducer.State()

    // Long-lived task: creates + rotates the session and polls it.
    @State private var pollTask: Task<Void, Never>?

    // Side-effect fencing: a reset or dismissal invalidates every resolve/install/ack task from the old
    // generation, so a late network result cannot resurrect stale reducer state.
    @State private var generation = 0
    @State private var sideEffectTasks: [Task<Void, Never>] = []
    @State private var latestRevision = 0
    /// Server claim/ack authority. A new view instance starts with a fresh tuple; a persisted session restores its
    /// durable tuple so an interrupted install resumes without stealing a live claim.
    @State private var authority = AddonPairingClient.newAuthority()

    private var batch: AddonPairingReducer.BatchStatus {
        AddonPairingReducer.batchStatus(pairing.rows.map(\.state))
    }

    private static let pollInterval: Duration = .seconds(2)

    // Ten-foot tvOS gets a large QR + panel; phone / Mac are arm's-length, so size down (mirrors
    // LinkLoginView's platform split).
    #if os(tvOS)
    private static let cardSize: CGFloat = 360
    private static let qrSize: CGFloat = 312
    #else
    private static let cardSize: CGFloat = 260
    private static let qrSize: CGFloat = 228
    #endif

    var body: some View {
        content
            .onAppear { startSession() }
            .onDisappear { stop() }
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                header
                qrCard
                instructions
                incomingSection
                doneButton
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        .background(Theme.Palette.canvas)
        #else
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #endif
    }

    /// Done reflects the batch: disabled + "Installing…" while a valid submission is still resolving /
    /// installing (never silently exits it), enabled + "Done" once every row is terminal.
    private var doneButton: some View {
        let state = AddonPairingReducer.doneState(batch)
        return Button(state.title) { dismiss() }
            .buttonStyle(.bordered)
            .tint(Theme.Palette.textPrimary)
            .foregroundStyle(Theme.Palette.textPrimary)
            .disabled(!state.enabled)
    }

    private var header: some View {
        VStack(spacing: Theme.Space.xs) {
            Text("Install by QR").font(.title2).fontWeight(.bold)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Pair once, add as many add-ons as you like.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white)
                .frame(width: Self.cardSize, height: Self.cardSize)
            if let qrImage {
                Image(decorative: qrImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.qrSize, height: Self.qrSize)
            } else if creating {
                #if os(tvOS)
                BigSpinner()
                #else
                ProgressView().scaleEffect(1.5).tint(Theme.Palette.accent)
                #endif
            } else {
                Image(systemName: createFailed ? "wifi.exclamationmark" : "qrcode")
                    .font(.system(size: 96))
                    .foregroundStyle(.black.opacity(0.25))
            }
        }
    }

    @ViewBuilder private var instructions: some View {
        if createFailed {
            VStack(spacing: Theme.Space.sm) {
                Text("Could not start a pairing session. Check your connection and try again.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.danger)
                    .multilineTextAlignment(.center)
                Button("Retry") { startSession() }
                    .buttonStyle(PrimaryActionStyle())
            }
        } else {
            VStack(spacing: Theme.Space.sm) {
                Text("Scan with your phone to add add-ons by URL. Paste each add-on's manifest link on the page - it installs here automatically.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 640)
                // Text fallback for anyone who can't scan the (decorative) QR: VoiceOver reads it, and on
                // touch/desktop it can be copied or opened on the same device (tvOS has no text selection).
                if let pageUrl = session?.pageUrl {
                    let urlText = Text(pageUrl)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityLabel("Pairing page URL: \(pageUrl)")
                    #if os(tvOS)
                    urlText
                    #else
                    urlText.textSelection(.enabled)
                    #endif
                }
            }
        }
    }

    @ViewBuilder private var incomingSection: some View {
        if pairing.rows.isEmpty, session != nil {
            // Live-poll indicator: makes it visible that adds from the phone will land + install here.
            HStack(spacing: Theme.Space.sm) {
                ProgressView().tint(Theme.Palette.accent)
                Text("Waiting for add-ons added on your phone…")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        if !pairing.rows.isEmpty {
            let section = VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("From your phone")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    // Batch-level manual recovery: install every not-yet-installed / failed row in one hit.
                    // Focus-reachable on tvOS (ChipButtonStyle), so an auto-install that stalled or failed is
                    // always recoverable without the removed per-row walk-back.
                    if pairing.rows.contains(where: { $0.state.isManualActionable }) {
                        Button { installActionable() } label: {
                            Label("Install all", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(ChipButtonStyle(selected: true))
                        .fixedSize()
                    }
                }
                batchBanner
                ForEach(pairing.rows) { row in incomingRow(row) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // One focus section for the whole incoming region (NOT per-row: stacked sibling focus sections
            // make tvOS skip rows - the Collections-hub region-jump lesson). This makes the region reliably
            // enterable so the manual Install / Retry buttons are reachable.
            #if os(tvOS)
            section.focusSection()
            #else
            section
            #endif
        }
    }

    /// Explicit on-device success / failure line for the batch (the "publish TV success OR failure" the phone's
    /// Done never gave). Invalid + failed are surfaced as non-success.
    @ViewBuilder private var batchBanner: some View {
        switch batch {
        case .empty:
            EmptyView()
        case .working:
            Label("Installing add-ons from your phone…", systemImage: "arrow.triangle.2.circlepath")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
        case .allInstalled(let n):
            Label(n == 1 ? "1 add-on installed." : "\(n) add-ons installed.", systemImage: "checkmark.circle.fill")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.ok)
        case .partial(let installed, let failed, let invalid):
            Label(partialSummary(installed: installed, failed: failed, invalid: invalid),
                  systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.danger)
        }
    }

    private func partialSummary(installed: Int, failed: Int, invalid: Int) -> String {
        var parts: [String] = []
        if installed > 0 { parts.append("\(installed) installed") }
        if failed > 0 { parts.append("\(failed) failed") }
        if invalid > 0 { parts.append("\(invalid) invalid") }
        return parts.joined(separator: " · ")
    }

    private func incomingRow(_ row: AddonPairingReducer.Row) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: iconName(for: row.state))
                .font(.system(size: 28))
                .foregroundStyle(iconColor(for: row.state))
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(row.name ?? row.url)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                Text(statusText(for: row))
                    .font(Theme.Typography.label)
                    .foregroundStyle(statusColor(for: row.state))
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Space.sm)
            trailingControl(for: row)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Shared settings-card glass instead of a hand-rolled surface1 plate (opaque warm card on tvOS via
        // the preset's built-in path). The white QR plate above stays solid on purpose: scan contrast.
        .vortxSettingsCard()
    }

    @ViewBuilder private func trailingControl(for row: AddonPairingReducer.Row) -> some View {
        switch row.state {
        case .ready:
            // Manual recovery: auto-install normally beats the user to this, but if it was skipped (offline,
            // race) the button stays here, focusable + actionable.
            Button { dispatch(.manualInstall(rowId: row.id)) } label: { Label("Install", systemImage: "square.and.arrow.down") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .fixedSize()
        case .failed:
            Button { dispatch(.manualInstall(rowId: row.id)) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .fixedSize()
        case .resolving, .installing:
            ProgressView().tint(Theme.Palette.accent)
        default:
            EmptyView()
        }
    }

    // MARK: - Reducer plumbing

    /// Feed one event through the reducer and perform whatever effects it emits. The reducer is the ONLY thing
    /// that mutates `pairing`; the view just performs I/O and reports results back as more events.
    private func dispatch(_ event: AddonPairingReducer.Event) {
        var next = pairing
        let effects = AddonPairingReducer.reduce(&next, event, normalize: core.normalizedAddonURL)
        pairing = next   // one @State write per event; effect results feed back as later events
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: AddonPairingReducer.Effect) {
        switch effect {
        case let .resolve(rowId, url):
            let gen = generation
            let task = Task { @MainActor in
                let preview = await core.previewAddonManifestResult(urlString: url)
                guard gen == generation, !Task.isCancelled else { return }
                let outcome: AddonPairingReducer.ResolveOutcome
                switch preview {
                case let .ready(name):
                    outcome = .ready(name: name)
                case let .alreadyInstalled(name):
                    outcome = .alreadyInstalled(name: name)
                case let .rejected(retryable, message):
                    outcome = .rejected(retryable: retryable, message: message)
                }
                dispatch(.resolved(rowId: rowId, outcome: outcome))
            }
            track(task)
        case let .resolveDurable(ticket, url):
            let gen = generation
            let task = Task { @MainActor in
                let preview = await core.previewAddonManifestResult(urlString: url)
                guard gen == generation, !Task.isCancelled else { return }
                let outcome: AddonPairingReducer.ResolveOutcome
                switch preview {
                case let .ready(name):
                    outcome = .ready(name: name)
                case let .alreadyInstalled(name):
                    outcome = .alreadyInstalled(name: name)
                case let .rejected(retryable, message):
                    outcome = .rejected(retryable: retryable, message: message)
                }
                dispatch(.resolvedDurable(ticket: ticket, outcome: outcome))
            }
            track(task)
        case let .install(rowId, url):
            let gen = generation
            let task = Task { @MainActor in
                // The ONE installer: fetches + validates + dispatches into the engine's add-on collection
                // (idempotent - an already-present add-on is a no-op).
                let error = await core.installAddon(urlString: url)
                guard gen == generation, !Task.isCancelled else { return }
                if error == nil {
                    dispatch(.installFinished(rowId: rowId, outcome: .installed))
                } else if let identity = pairing.rows.first(where: { $0.id == rowId })?.identity,
                          core.addons.contains(where: { $0.transportUrl == identity }) {
                    // Idempotent: the add-on is present anyway (already-installed / concurrent duplicate) → success.
                    dispatch(.installFinished(rowId: rowId, outcome: .installed))
                } else {
                    dispatch(.installFinished(rowId: rowId, outcome: .failed(error ?? String(localized: "Could not install."))))
                }
            }
            track(task)
        case let .claim(deliveryID, token, deliveryRevision, authoritySession, authorityGeneration):
            let gen = generation
            let task = Task { @MainActor in
                var authority = AddonPairingClient.Authority(id: authoritySession, generation: authorityGeneration)
                guard gen == generation, !Task.isCancelled else { return }
                let success = await AddonPairingClient.claim(token: token, authority: authority,
                                                             deliveryIDs: [deliveryID],
                                                             deliveryRevision: deliveryRevision)
                guard gen == generation, !Task.isCancelled else { return }
                dispatch(.claimFinished(rowId: deliveryID,
                                        authoritySession: authoritySession,
                                        authorityGeneration: authorityGeneration,
                                        attempt: success?.attempt ?? 0,
                                        deliveryRevision: success?.deliveryRevision ?? deliveryRevision,
                                        success: success != nil))
            }
            track(task)
        case let .installAttempt(rowId, url, attempt):
            let gen = generation
            let task = Task { @MainActor in
                let result = await core.installAddonConfirmed(urlString: url)
                guard gen == generation, !Task.isCancelled else { return }
                let outcome: AddonPairingReducer.InstallOutcome
                switch result {
                case .installed, .alreadyInstalled:
                    outcome = .installed
                case let .failed(retryable, message):
                    outcome = .failedWithRetry(retryable: retryable, message: message)
                }
                dispatch(.installFinishedAttempt(rowId: rowId, attempt: attempt, outcome: outcome))
            }
            track(task)
        case let .ack(deliveryID, token, status, authoritySession, authorityGeneration,
                      attempt, deliveryRevision, revision, retryable, mutationID, requiresClaim):
            let gen = generation
            let task = Task { @MainActor in
                guard gen == generation, !Task.isCancelled else { return }
                let authority = AddonPairingClient.Authority(id: authoritySession, generation: authorityGeneration)
                var wireAttempt = max(1, attempt)
                var wireDeliveryRevision = deliveryRevision
                if requiresClaim {
                    let claimResult = await AddonPairingClient.claim(token: token, authority: authority,
                                                                       deliveryIDs: [deliveryID],
                                                                       deliveryRevision: deliveryRevision)
                    // Fence immediately after the await. Cancellation is cooperative and a relay claim may
                    // complete after stop(); neither a late success nor a late failure may mutate reducer state.
                    guard AddonPairingReducer.canDispatchAckClaimCompletion(
                        pairing,
                        deliveryID: deliveryID,
                        authoritySession: authoritySession,
                        authorityGeneration: authorityGeneration,
                        mutationID: mutationID,
                        expectedGeneration: gen,
                        currentGeneration: generation,
                        taskIsCancelled: Task.isCancelled
                    ) else { return }
                    guard let claimed = claimResult else {
                        dispatch(.ackClaimFinished(deliveryID: deliveryID,
                                                   token: token,
                                                   authoritySession: authoritySession,
                                                   authorityGeneration: authorityGeneration,
                                                   attempt: attempt,
                                                   deliveryRevision: deliveryRevision,
                                                   mutationID: mutationID,
                                                   success: false))
                        return
                    }
                    dispatch(.ackClaimFinished(deliveryID: deliveryID,
                                               token: token,
                                               authoritySession: authoritySession,
                                               authorityGeneration: authorityGeneration,
                                               attempt: claimed.attempt,
                                               deliveryRevision: claimed.deliveryRevision,
                                               mutationID: mutationID,
                                               success: true))
                    guard gen == generation, !Task.isCancelled,
                          pairing.pendingAcks[deliveryID]?.mutationID == mutationID,
                          pairing.pendingAcks[deliveryID]?.requiresClaim == false else { return }
                    wireAttempt = claimed.attempt
                    wireDeliveryRevision = claimed.deliveryRevision
                }
                guard gen == generation, !Task.isCancelled,
                      pairing.pendingAcks[deliveryID]?.mutationID == mutationID else { return }
                let wireAck = AddonPairingClient.DeliveryAck(
                    deliveryId: deliveryID,
                    status: status.rawValue,
                    attempt: wireAttempt,
                    rev: revision,
                    mutationId: mutationID,
                    deliveryRevision: wireDeliveryRevision,
                    retryable: retryable
                )
                let success = await AddonPairingClient.ack(token: token, authority: authority,
                                                           deliveries: [wireAck], mutationID: mutationID)
                guard gen == generation, !Task.isCancelled else { return }
                dispatch(.ackFinished(deliveryID: deliveryID,
                                      token: token,
                                      status: status,
                                      authoritySession: authoritySession,
                                      authorityGeneration: authorityGeneration,
                                      attempt: wireAttempt,
                                      deliveryRevision: wireDeliveryRevision,
                                      revision: revision,
                                      retryable: retryable,
                                      mutationID: mutationID,
                                      success: success))
            }
            track(task)
        case let .poll(token, authoritySession, authorityGeneration):
            let gen = generation
            let task = Task { @MainActor in
                guard gen == generation, !Task.isCancelled else { return }
                let authority = AddonPairingClient.Authority(id: authoritySession, generation: authorityGeneration)
                switch await AddonPairingClient.poll(token: token, authority: authority) {
                case let .ok(poll):
                    guard gen == generation, !Task.isCancelled else { return }
                    merge(poll, token: token)
                case let .staleGeneration(currentGeneration):
                    guard let recovered = AddonPairingClient.authorityForStaleGeneration(
                        authority,
                        currentGeneration: currentGeneration
                    ) else { return }
                    guard gen == generation, !Task.isCancelled else { return }
                    self.authority = recovered
                    dispatch(.authorityChanged(session: recovered.id, generation: recovered.generation))
                case .gone, .failed:
                    // The normal lifecycle poll remains authoritative for expiry/rotation; this one-shot poll only
                    // exists to resolve an ambiguous claim before allowing its ACK to retry.
                    return
                }
            }
            track(task)
        case let .releaseSession(token, authoritySession, authorityGeneration, mutationID):
            let gen = generation
            let task = Task { @MainActor in
                let authority = AddonPairingClient.Authority(id: authoritySession, generation: authorityGeneration)
                let success = await AddonPairingClient.release(token: token, authority: authority,
                                                               mutationID: mutationID)
                guard gen == generation, !Task.isCancelled else { return }
                dispatch(.releaseFinished(sessionToken: token, success: success))
                if success, session?.token == token { AddonPairingClient.clearPersistedSession() }
            }
            track(task)
        }
    }

    /// Manual batch recovery: install every row the user can still act on (ready or failed).
    private func installActionable() {
        for row in pairing.rows where row.state.isManualActionable { dispatch(.manualInstall(rowId: row.id)) }
    }

    // MARK: - Session lifecycle

    private func startSession() {
        stop()
        authority = AddonPairingClient.newAuthority()
        dispatch(.authorityChanged(session: authority.id, generation: authority.generation))
        creating = true
        createFailed = false

        pollTask = Task { @MainActor in
            await createAndPollLoop()
        }
    }

    /// Create a session, render its QR, then poll it. If the session expires (or the relay reports it gone /
    /// closed), rotate to a fresh one so the QR on screen is always live.
    private func createAndPollLoop() async {
        let lifecycleGeneration = generation
        guard AddonPairingClient.canApplyLifecycleResult(
            expectedGeneration: lifecycleGeneration,
            currentGeneration: generation,
            taskIsCancelled: Task.isCancelled
        ) else { return }
        var rollbackSession: AddonPairingClient.Session?
        // Resume the persisted session FIRST, if the relay still knows it: a manifest the phone added after
        // this sheet was last closed is sitting unread in that session, and minting a fresh QR here would
        // orphan it forever. One poll decides; a dead token falls through to a new session. A transient poll
        // failure keeps the old session as the rollback target instead of replacing it speculatively.
        if let saved = AddonPairingClient.persistedSession() {
            if AddonPairingProtocol.isMutationID(saved.authoritySession) {
                // A sheet reopen in the same process must retain the authority that owns any live server claim.
                authority = AddonPairingClient.Authority(id: saved.authoritySession, generation: 0)
            }
            let savedPollResult = await AddonPairingClient.poll(token: saved.token)
            guard AddonPairingClient.canApplyLifecycleResult(
                expectedGeneration: lifecycleGeneration,
                currentGeneration: generation,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            switch savedPollResult {
            case .ok(let initialPoll):
                guard !initialPoll.released else {
                    AddonPairingClient.clearPersistedSession()
                    session = nil
                    qrImage = nil
                    break
                }
                var poll = initialPoll
                authority = AddonPairingClient.Authority(id: authority.id, generation: initialPoll.generation)
                if !initialPoll.terminal {
                    // A closed session needs the relay's generation transition to clear the prior claim. An open
                    // session returns the same generation, and the persisted authority makes an existing claim
                    // resumable rather than competing with it under a new owner.
                    let reopenedResult = await AddonPairingClient.reopen(token: saved.token, authority: authority)
                    guard AddonPairingClient.canApplyLifecycleResult(
                        expectedGeneration: lifecycleGeneration,
                        currentGeneration: generation,
                        taskIsCancelled: Task.isCancelled
                    ) else { return }
                    guard let reopened = reopenedResult else {
                        session = saved
                        qrImage = QRCodeImage.make(saved.pageUrl)
                        creating = false
                        createFailed = true
                        return
                    }
                    authority = reopened
                    let refreshedResult = await AddonPairingClient.poll(token: saved.token, authority: authority)
                    guard AddonPairingClient.canApplyLifecycleResult(
                        expectedGeneration: lifecycleGeneration,
                        currentGeneration: generation,
                        taskIsCancelled: Task.isCancelled
                    ) else { return }
                    guard case .ok(let refreshed) = refreshedResult else {
                        session = saved
                        qrImage = QRCodeImage.make(saved.pageUrl)
                        creating = false
                        createFailed = true
                        return
                    }
                    guard !refreshed.released else {
                        AddonPairingClient.clearPersistedSession()
                        session = nil
                        qrImage = nil
                        break
                    }
                    poll = refreshed
                }
                let resumed = AddonPairingClient.Session(token: saved.token,
                                                         pageUrl: saved.pageUrl,
                                                         expiresAtMs: poll.expiresAtMs,
                                                         generation: authority.generation,
                                                         authoritySession: authority.id)
                session = resumed
                qrImage = QRCodeImage.make(saved.pageUrl)
                creating = false
                createFailed = false
                dispatch(.authorityChanged(session: authority.id, generation: authority.generation))
                dispatch(.sessionRotated(liveToken: saved.token))
                merge(poll, token: saved.token)
                if !poll.closed || pairing.isInFlight(sessionToken: saved.token) {
                    let ended = await pollSession(token: saved.token, expiresAt: poll.expiresAt)
                    guard AddonPairingClient.canApplyLifecycleResult(
                        expectedGeneration: lifecycleGeneration,
                        currentGeneration: generation,
                        taskIsCancelled: Task.isCancelled
                    ) else { return }
                    if !ended { return }   // cancelled (view dismissed)
                }
                if poll.closed { rollbackSession = resumed }
                AddonPairingClient.clearPersistedSession()
            case .gone:
                AddonPairingClient.clearPersistedSession()
            case .staleGeneration:
                // The initial resume poll carries no authority generation, so a stale response cannot be
                // recovered safely here; the regular lifecycle poll handles authenticated generation rebases.
                return
            case .failed:
                session = saved
                qrImage = QRCodeImage.make(saved.pageUrl)
                creating = false
                createFailed = true
                return
            }
        }
        while !Task.isCancelled {
            guard AddonPairingClient.canApplyLifecycleResult(
                expectedGeneration: lifecycleGeneration,
                currentGeneration: generation,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            creating = true
            let createdResult = await AddonPairingClient.createSession()
            guard AddonPairingClient.canApplyLifecycleResult(
                expectedGeneration: lifecycleGeneration,
                currentGeneration: generation,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            guard let created = createdResult else {
                if let rollbackSession {
                    session = rollbackSession
                    qrImage = QRCodeImage.make(rollbackSession.pageUrl)
                    AddonPairingClient.persist(rollbackSession)
                }
                creating = false
                createFailed = true
                return   // startSession()'s Retry button re-enters this loop
            }
            authority = AddonPairingClient.Authority(id: authority.id, generation: created.generation)
            let persisted = AddonPairingClient.Session(token: created.token,
                                                       pageUrl: created.pageUrl,
                                                       expiresAtMs: created.expiresAtMs,
                                                       generation: created.generation,
                                                       authoritySession: authority.id)
            session = persisted
            qrImage = QRCodeImage.make(created.pageUrl)
            creating = false
            createFailed = false
            latestRevision = 0
            dispatch(.authorityChanged(session: authority.id, generation: authority.generation))
            AddonPairingClient.persist(persisted)   // survives sheet close, so a late add still arrives
            // A fresh session token means any not-yet-terminal row from a PRIOR session can never complete (its
            // phone page is dead); drop those so a wrong-session submission leaves no stuck state and Done is
            // not pinned "Installing…" forever. Terminal rows stay as visible history.
            dispatch(.sessionRotated(liveToken: created.token))

            // Poll THIS session until it dies, then loop to mint a fresh one. NOTE the polarity: pollSession
            // returns true when the session ENDED (expired / gone / closed) and false when cancelled.
            let ended = await pollSession(token: created.token, expiresAt: created.expiresAt)
            guard AddonPairingClient.canApplyLifecycleResult(
                expectedGeneration: lifecycleGeneration,
                currentGeneration: generation,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            if ended { continue }
            return   // cancelled
        }
    }

    /// Poll one session. Returns true if the session ended (expired / gone / closed) and the caller should
    /// rotate to a new one; returns false when the task is cancelled (view dismissed).
    private func pollSession(token: String, expiresAt: Date) async -> Bool {
        var deadline = expiresAt
        var closed = false
        let pollGeneration = generation
        while !Task.isCancelled {
            // A closed relay session remains live until every ACK and the server release mutation are
            // confirmed. It must still poll first: a phone-side reopen increments generation and clears claims,
            // while an old-authority poll otherwise falls into a sleep-only loop and never reaches the structured
            // stale-generation recovery branch.
            if closed && pairing.isSessionReleased(token) { return true }
            if !closed && Date() >= deadline { return true }
            let pollAuthority: AddonPairingClient.Authority? = authority.generation >= 1 ? authority : nil
            let result = await AddonPairingClient.poll(token: token, authority: pollAuthority)
            guard pollGeneration == generation, !Task.isCancelled else { return false }
            switch result {
            case .gone:
                return true
            case .ok(let poll):
                guard let transition = AddonPairingClient.pollTransition(result: .ok(poll), authority: authority) else {
                    if poll.released { return true }
                    break
                }
                guard case .current = transition else { break }
                merge(poll, token: token)
                closed = poll.closed
                if closed {
                    if !pairing.isInFlight(sessionToken: token) { return true }
                    dispatch(.retryPendingWork(sessionToken: token))
                }
                if !closed { deadline = poll.expiresAt }
            case let .staleGeneration(currentGeneration):
                guard case let .stale(recovered) = AddonPairingClient.pollTransition(
                    result: .staleGeneration(currentGeneration), authority: authority
                ) else { return false }
                authority = recovered
                dispatch(.authorityChanged(session: recovered.id, generation: recovered.generation))
            case .failed:
                if closed { dispatch(.retryPendingWork(sessionToken: token)) }
            }
            do { try await Task.sleep(for: Self.pollInterval) } catch { return false }
        }
        return false
    }

    private func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        for task in sideEffectTasks { task.cancel() }
        sideEffectTasks = []
        // The session is deliberately LEFT ALIVE on the relay (it self-expires): a manifest the phone adds
        // after this sheet closes is picked up by the persisted-session resume on the next open.
    }

    /// Keep cancellation handles for resolve/install/ack work, pruning cancelled entries before appending.
    private func track(_ task: Task<Void, Never>) {
        sideEffectTasks.removeAll { $0.isCancelled }
        sideEffectTasks.append(task)
    }

    /// Convert one relay poll into durable reducer deliveries. Unknown relay statuses are rejected as a whole
    /// poll so no unclassified remote state can enter the install path.
    private func merge(_ poll: AddonPairingClient.Poll, token: String) {
        guard session?.token == token,
              poll.generation >= authority.generation else { return }
        guard poll.manifests.allSatisfy({ manifest in
            AddonPairingProtocol.isOpaqueIdentifier(manifest.deliveryId, maxLength: 128) &&
            AddonPairingReducer.DeliveryStatus(rawValue: manifest.status) != nil &&
            AddonPairingProtocol.isStrictManifestURL(manifest.url)
        }) else { return }
        if authority.generation != poll.generation {
            authority = AddonPairingClient.Authority(id: authority.id, generation: poll.generation)
            dispatch(.authorityChanged(session: authority.id, generation: authority.generation))
        }
        latestRevision = max(latestRevision, poll.rev)
        let deliveries = poll.manifests.compactMap { manifest -> AddonPairingReducer.Delivery? in
            guard let status = AddonPairingReducer.DeliveryStatus(rawValue: manifest.status),
                  !manifest.deliveryId.isEmpty else { return nil }
            return AddonPairingReducer.Delivery(
                id: manifest.deliveryId,
                url: manifest.url,
                identity: core.normalizedAddonURL(manifest.url) ?? manifest.url,
                sessionToken: token,
                revision: poll.rev,
                status: status,
                deliveryRevision: manifest.deliveryRevision,
                attempt: manifest.attempt,
                retryable: manifest.retryable,
                claimed: manifest.claimed
            )
        }
        dispatch(.deliveries(deliveries,
                             sessionToken: token,
                             liveToken: session?.token,
                             revision: poll.rev))
        if poll.closed { dispatch(.sessionClosed(sessionToken: token)) }
    }
    // MARK: - Row presentation

    private func iconName(for state: AddonPairingReducer.RowState) -> String {
        switch state {
        case .installed:        return "checkmark.circle.fill"
        case .invalid, .failed: return "exclamationmark.triangle.fill"
        default:                return "puzzlepiece.extension.fill"
        }
    }

    private func iconColor(for state: AddonPairingReducer.RowState) -> Color {
        switch state {
        case .installed:        return Theme.Palette.ok
        case .invalid, .failed: return Theme.Palette.danger
        default:                return Theme.Palette.accent
        }
    }

    private func statusText(for row: AddonPairingReducer.Row) -> String {
        switch row.state {
        case .resolving:           return String(localized: "Checking add-on…")
        case .ready:               return String(localized: "Installing…")
        case .invalid:             return String(localized: "That URL did not return a valid add-on manifest.")
        case .installing:          return String(localized: "Installing…")
        case .installed:           return String(localized: "Installed")
        case .failed(let message): return message
        }
    }

    private func statusColor(for state: AddonPairingReducer.RowState) -> Color {
        switch state {
        case .installed:        return Theme.Palette.ok
        case .invalid, .failed: return Theme.Palette.danger
        default:                return Theme.Palette.textSecondary
        }
    }
}
