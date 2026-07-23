import SwiftUI

/// "Install by QR - pair once, add many." The TV/phone/Mac shows a QR that opens a phone page; the
/// user pastes add-on manifest URLs there, and this view polls the relay session, shows the live
/// incoming list, and installs each one THROUGH THE APP'S OWN hardened path (`CoreBridge.installAddonConfirmed`)
/// after an on-device confirm.
///
/// SAFETY MODEL: the relay (`add.vortx.tv`) is a dumb pipe that only carries URL strings between the
/// phone and this device. Nothing installs silently: every incoming URL is fetched + validated by
/// `CoreBridge` (the same manifest validation the paste-a-URL flow uses) and shown as an explicit
/// "Install <name>?" row, so a QR scanned by the wrong person cannot push an add-on onto the TV. The
/// view stays open so the user can keep adding on the phone and installing here.
///
/// STATE LIVES IN `AddonPairingReducer` (a pure value type, unit-tested standalone): this view is the shell that
/// renders `reducer.rows`, feeds the reducer events (poll results, user taps), and performs the side effects it
/// returns (resolve / install / ack). The reducer holds the correctness-critical invariants:
///  - a delivery is keyed by a DURABLE delivery id + canonical URL, not the raw string or the rotating token;
///  - a row is `.installed` only on a CONFIRMED install (the engine holds it), never on dispatch;
///  - closing the session (phone Done) NEVER discards an in-flight install: the poll loop DRAINS before rotating;
///  - the TV acks each confirmed install back to the relay so the phone's Done shows the truth.
struct AddonPairingView: View {
    // The engine bridge is a singleton (`CoreBridge.shared`) referenced directly across the app; use it
    // here too so the install + validation path works regardless of how this view is presented (a sheet
    // on tvOS / macOS does not always carry the presenter's `@EnvironmentObject`s).
    private let core = CoreBridge.shared
    @Environment(\.dismiss) private var dismiss

    // Session + QR.
    @State private var session: AddonPairingClient.Session?
    @State private var qrImage: CGImage?
    @State private var creating = false
    @State private var createFailed = false

    // The pure lifecycle core. Rows + install/close/drain/ack decisions live here; this view only renders it and
    // runs the effects it returns.
    @State private var reducer = AddonPairingReducer()

    // Long-lived tasks: one creates + rotates the session, one polls it.
    @State private var pollTask: Task<Void, Never>?

    // H4 fence: a monotonic generation bumped on a full session RESET (onAppear / Retry) and on teardown
    // (onDisappear). Every resolve / install / ack side-effect Task captures the generation it started under and
    // refuses to mutate the reducer or keep retrying once the view has been reset or dismissed, so an untracked
    // task can never resurrect a torn-down view or hammer the relay forever. NOTE: minting a fresh QR while the
    // view stays open (rotation inside the poll loop) does NOT bump the generation, so an install dispatched on
    // the old token still completes and lands — the outliving-coordinator guarantee (a dispatched-unconfirmed
    // install survives session close / rotation) is preserved.
    @State private var generation = 0
    // All in-flight side-effect Tasks, tracked so teardown cancels them (bounded: finished tasks are pruned on
    // each spawn, so this never grows without limit — M3 collection bound).
    @State private var sideEffectTasks: [Task<Void, Never>] = []
    // The latest session revision seen from the relay, attached to every ack so a stale ack cannot overwrite a
    // newer worker attempt (H3 revision authority).
    @State private var latestRev = 0

    private static let pollInterval: Duration = .seconds(2)
    // H2: bounded ack retry. A confirmed install must be reported to the relay so the phone's Done shows truth;
    // a transient failure is retried a few times with backoff before giving up (the add-on is already installed
    // locally either way, so this is best-effort — but it no longer drops the ack after a single failed POST).
    private static let ackMaxAttempts = 4

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
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(Theme.Palette.textPrimary)
                    .foregroundStyle(Theme.Palette.textPrimary)
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
                Text("Scan with your phone to add add-ons by URL. Paste each add-on's manifest link on the page, then install it here.")
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
        let rows = reducer.rows
        if rows.isEmpty, session != nil {
            // Live-poll indicator: makes it visible that adds from the phone will land here.
            HStack(spacing: Theme.Space.sm) {
                ProgressView().tint(Theme.Palette.accent)
                Text("Waiting for add-ons added on your phone…")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    Text("From your phone")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    if rows.contains(where: { $0.state == .ready }) {
                        Button("Install all") { apply(reducer.installAllReady()) }
                            .buttonStyle(ChipButtonStyle(selected: true))
                            .fixedSize()
                    }
                }
                ForEach(rows) { row in incomingRow(row) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func incomingRow(_ row: AddonRow) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            // M6: the status icon is DECORATIVE — the status text below states the same thing — so hide it from
            // VoiceOver to remove the redundant accessibility element. The focusable Install/Retry button stays.
            Image(systemName: iconName(for: row.state))
                .font(.system(size: 28))
                .foregroundStyle(iconColor(for: row.state))
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                // M2: before the name resolves, fall back to the HOST ONLY — never the raw manifest URL, whose
                // query/path can embed a debrid/config credential that would then sit on a shared TV screen.
                Text(row.name ?? Self.credentialSafeHost(row.delivery.rawURL))
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

    @ViewBuilder private func trailingControl(for row: AddonRow) -> some View {
        switch row.state {
        case .ready:
            // Manual install / recovery: stays focusable so the user can always drive the install here.
            Button { apply(reducer.install(id: row.id)) } label: { Label("Install", systemImage: "square.and.arrow.down") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .fixedSize()
        case .failed(let retryable, _):
            // A retryable failure keeps a Retry button (manual recovery); a terminal failure shows none.
            if retryable {
                Button { apply(reducer.retry(id: row.id)) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .fixedSize()
            } else {
                EmptyView()
            }
        case .resolving, .installing:
            ProgressView().tint(Theme.Palette.accent)
        case .installed:
            EmptyView()
        }
    }

    // MARK: - Session lifecycle

    private func startSession() {
        stop()
        generation += 1   // H4: a fresh session lifecycle; results from the prior generation are now stale.
        creating = true
        createFailed = false
        qrImage = nil
        session = nil
        latestRev = 0

        pollTask = Task { @MainActor in
            await createAndPollLoop()
        }
    }

    /// Create a session, render its QR, then poll it. If the session expires (or the relay reports it
    /// gone / closed AND its in-flight installs have drained), rotate to a fresh one so the QR on screen is
    /// always live.
    private func createAndPollLoop() async {
        // Resume the persisted session FIRST, if the relay still knows it: a manifest the phone added
        // after this sheet was last closed is sitting unread in that session, and minting a fresh QR
        // here would orphan it forever. One poll decides; a dead token falls through to a new session.
        if let saved = AddonPairingClient.persistedSession() {
            if case .ok(let poll) = await AddonPairingClient.poll(token: saved.token) {
                session = saved
                qrImage = QRCodeImage.make(saved.pageUrl)
                creating = false
                createFailed = false
                merge(poll, token: saved.token)
                // Keep polling if the session is open, OR it is closed but still has an install to drain.
                if !poll.closed || reducer.isInFlight(token: saved.token) {
                    let ended = await pollSession(token: saved.token, expiresAt: poll.expiresAt)
                    if !ended { return }   // cancelled (view dismissed)
                }
            }
            AddonPairingClient.clearPersistedSession()
        }
        while !Task.isCancelled {
            creating = true
            guard let created = await AddonPairingClient.createSession() else {
                creating = false
                createFailed = true
                return   // startSession()'s Retry button re-enters this loop
            }
            session = created
            qrImage = QRCodeImage.make(created.pageUrl)
            creating = false
            createFailed = false
            AddonPairingClient.persist(created)   // survives sheet close, so a late add still arrives

            // Poll THIS session until it dies, then loop to mint a new one. NOTE the polarity:
            // pollSession returns true when the session ENDED (expired / gone / closed-and-drained) and a fresh
            // one should be minted; false means the task was cancelled (view dismissed).
            let ended = await pollSession(token: created.token, expiresAt: created.expiresAt)
            if ended { continue }
            return   // cancelled
        }
    }

    /// Poll one session. Returns true if the session ended (expired / gone / closed AND drained) and the caller
    /// should rotate to a new one; returns false when the task was cancelled (view dismissed).
    private func pollSession(token: String, expiresAt: Date) async -> Bool {
        var deadline = expiresAt
        while !Task.isCancelled {
            if Date() >= deadline { return true }   // expired → rotate
            switch await AddonPairingClient.poll(token: token) {
            case .gone:
                return true                          // unknown / expired token → rotate
            case .ok(let poll):
                // Merge BEFORE deciding to rotate: a URL the phone adds in the same poll window as its "Done"
                // tap arrives with closed == true and must not be dropped by the rotation.
                merge(poll, token: token)
                if poll.closed {
                    // DRAIN-BEFORE-ROTATE: only rotate once no delivery for this token is still resolving or
                    // installing, so an install dispatched just before Done finishes (and its ack lands) before
                    // the session is abandoned. This is the fix for the add-then-Done install-loss race.
                    if !reducer.isInFlight(token: token) { return true }
                }
                deadline = poll.expiresAt            // keep the deadline fresh from the relay
            case .failed:
                break                                // transient; keep polling
            }
            do { try await Task.sleep(for: Self.pollInterval) } catch { return false }
        }
        return false
    }

    private func stop() {
        generation += 1   // H4: invalidate every side-effect task started under the current generation.
        pollTask?.cancel()
        pollTask = nil
        // Cancel every tracked resolve / install / ack task so none outlives the dismissed view (H4).
        for task in sideEffectTasks { task.cancel() }
        sideEffectTasks = []
        // The session is deliberately LEFT ALIVE on the relay (it self-expires): a manifest the phone
        // adds after this sheet closes is picked up by the persisted-session resume on the next open.
    }

    /// Track a spawned side-effect task so teardown can cancel it, pruning already-finished entries so the list
    /// stays bounded (M3).
    private func track(_ task: Task<Void, Never>) {
        sideEffectTasks.removeAll { $0.isCancelled }
        sideEffectTasks.append(task)
    }

    // MARK: - Reducer wiring

    /// Fold the relay's live delivery list into the reducer, then run whatever effects it returns.
    private func merge(_ poll: AddonPairingClient.Poll, token: String) {
        // H3: track the newest session revision so every ack we send carries it (a stale ack cannot overwrite a
        // newer worker attempt). Never move it backwards.
        latestRev = max(latestRev, poll.rev)
        let deliveries = poll.manifests.map { m in
            AddonDelivery(
                id: m.deliveryId,
                canonicalURL: core.normalizedAddonURL(m.url) ?? m.url,
                rawURL: m.url,
                token: token
            )
        }
        apply(reducer.ingest(deliveries))
        if poll.closed { apply(reducer.closeSeen(token: token)) }
    }

    /// Run the side effects the reducer asked for. All mutations of `reducer` happen back on the main actor.
    private func apply(_ effects: [AddonPairingEffect]) {
        for effect in effects {
            switch effect {
            case .resolve(let delivery):
                resolve(delivery)
            case .install(let delivery, let attempt):
                performInstall(delivery, attempt: attempt)
            case .ack(let delivery, let status, let attempt):
                sendAck(delivery, status: status, attempt: attempt)
            case .releaseToken:
                // The poll loop rotates via `reducer.isInFlight`; nothing extra to do on release.
                break
            }
        }
    }

    /// Validate a URL's manifest through `CoreBridge.previewAddonManifest` (the same fetch + validation the
    /// install path uses; it also caches the manifest so the following install reuses that fetch) to get its name
    /// and installable / already-installed / rejected state.
    private func resolve(_ delivery: AddonDelivery) {
        let gen = generation
        let task = Task { @MainActor in
            let outcome = await core.previewAddonManifest(urlString: delivery.rawURL)
            // H4 fence: drop the result if the view was reset / dismissed while the preview was in flight.
            guard gen == generation, !Task.isCancelled else { return }
            apply(reducer.resolved(id: delivery.id, outcome: outcome))
        }
        track(task)
    }

    /// Install through the app's ONE hardened, CONFIRMED installer, then feed the typed outcome back to the
    /// reducer (which marks `.installed` only on confirmation and acks the relay).
    private func performInstall(_ delivery: AddonDelivery, attempt: Int) {
        let gen = generation
        let task = Task { @MainActor in
            let outcome = await core.installAddonConfirmed(urlString: delivery.rawURL)
            // H4 fence: a reset / dismissed view drops the reducer re-entry. The reducer's attempt authority
            // additionally ignores a stale attempt, so a late confirm can never double-apply.
            guard gen == generation, !Task.isCancelled else { return }
            apply(reducer.installed(id: delivery.id, attempt: attempt, outcome: outcome))
        }
        track(task)
    }

    /// Report a confirmed terminal status back to the relay so the phone's Done can show the truth (H2). Unlike
    /// the old fire-and-forget POST, this HONORS the returned Bool and RETRIES with backoff until the relay
    /// durably accepts it or the attempts are exhausted, so a single dropped POST no longer leaves the engine
    /// installed while the phone never learns it. Each ack carries the install `attempt`, the latest session
    /// `rev`, and a fresh mutation-id NONCE (H3 authority + replay enforcement); the client binds all of that
    /// into the HMAC body signature. The retry loop is fenced by generation so a dismissed view stops retrying.
    private func sendAck(_ delivery: AddonDelivery, status: AddonAckStatus, attempt: Int) {
        let gen = generation
        let rev = latestRev
        let task = Task { @MainActor in
            var backoff: Duration = .milliseconds(400)
            for tryIndex in 0..<Self.ackMaxAttempts {
                if gen != generation || Task.isCancelled { return }
                let ack = AddonPairingClient.DeliveryAck(
                    deliveryId: delivery.id,
                    status: status.rawValue,
                    attempt: attempt,
                    rev: rev,
                    mutationId: AddonPairingClient.newMutationId()
                )
                let ok = await AddonPairingClient.ack(token: delivery.token, deliveries: [ack])
                if ok { return }                       // durably accepted
                if tryIndex < Self.ackMaxAttempts - 1 {
                    try? await Task.sleep(for: backoff)
                    backoff *= 2
                }
            }
        }
        track(task)
    }

    // MARK: - Row presentation

    private func iconName(for state: AddonRowState) -> String {
        switch state {
        case .installed:  return "checkmark.circle.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        default:          return "puzzlepiece.extension.fill"
        }
    }

    private func iconColor(for state: AddonRowState) -> Color {
        switch state {
        case .installed:  return Theme.Palette.ok
        case .failed:     return Theme.Palette.danger
        default:          return Theme.Palette.accent
        }
    }

    private func statusText(for row: AddonRow) -> String {
        switch row.state {
        case .resolving:                    return String(localized: "Checking add-on…")
        // M2: never render the raw manifest URL (credential-bearing). A `.ready` row is transient under
        // auto-install anyway; show the credential-safe host.
        case .ready:                        return Self.credentialSafeHost(row.delivery.rawURL)
        case .installing:                   return String(localized: "Installing…")
        case .installed:                    return String(localized: "Installed")
        case .failed(_, let message):       return message
        }
    }

    /// The credential-SAFE display for an add-on URL: its host only, never the query or path, either of which can
    /// carry a debrid/config token that must not be shown on a shared TV (M2). Falls back to a generic label if
    /// the string has no parseable host.
    private static func credentialSafeHost(_ raw: String) -> String {
        URLComponents(string: raw)?.host ?? String(localized: "Add-on")
    }

    private func statusColor(for state: AddonRowState) -> Color {
        switch state {
        case .installed:  return Theme.Palette.ok
        case .failed:     return Theme.Palette.danger
        default:          return Theme.Palette.textSecondary
        }
    }
}
