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
            Task { @MainActor in
                guard let preview = await core.previewAddonManifest(urlString: url) else {
                    dispatch(.resolved(rowId: rowId, outcome: .invalid))
                    return
                }
                let outcome: AddonPairingReducer.ResolveOutcome = preview.alreadyInstalled
                    ? .alreadyInstalled(name: preview.name)
                    : .ready(name: preview.name)
                dispatch(.resolved(rowId: rowId, outcome: outcome))
            }
        case let .install(rowId, url):
            Task { @MainActor in
                // The ONE installer: fetches + validates + dispatches into the engine's add-on collection
                // (idempotent - an already-present add-on is a no-op).
                let error = await core.installAddon(urlString: url)
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
        }
    }

    /// Manual batch recovery: install every row the user can still act on (ready or failed).
    private func installActionable() {
        for row in pairing.rows where row.state.isManualActionable { dispatch(.manualInstall(rowId: row.id)) }
    }

    // MARK: - Session lifecycle

    private func startSession() {
        stop()
        creating = true
        createFailed = false
        qrImage = nil
        session = nil

        pollTask = Task { @MainActor in
            await createAndPollLoop()
        }
    }

    /// Create a session, render its QR, then poll it. If the session expires (or the relay reports it gone /
    /// closed), rotate to a fresh one so the QR on screen is always live.
    private func createAndPollLoop() async {
        // Resume the persisted session FIRST, if the relay still knows it: a manifest the phone added after
        // this sheet was last closed is sitting unread in that session, and minting a fresh QR here would
        // orphan it forever. One poll decides; a dead token falls through to a new session.
        if let saved = AddonPairingClient.persistedSession() {
            if case .ok(let poll) = await AddonPairingClient.poll(token: saved.token) {
                session = saved
                qrImage = QRCodeImage.make(saved.pageUrl)
                creating = false
                createFailed = false
                dispatch(.sessionRotated(liveToken: saved.token))
                dispatch(.delivered(urls: poll.manifests.map(\.url), sessionToken: saved.token, liveToken: session?.token))
                if !poll.closed {
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
            // A fresh session token means any not-yet-terminal row from a PRIOR session can never complete (its
            // phone page is dead); drop those so a wrong-session submission leaves no stuck state and Done is
            // not pinned "Installing…" forever. Terminal rows stay as visible history.
            dispatch(.sessionRotated(liveToken: created.token))

            // Poll THIS session until it dies, then loop to mint a new one. NOTE the polarity: pollSession
            // returns true when the session ENDED (expired / gone / closed) and a fresh one should be minted;
            // false means the task was cancelled (view dismissed).
            let ended = await pollSession(token: created.token, expiresAt: created.expiresAt)
            if ended { continue }
            return   // cancelled
        }
    }

    /// Poll one session. Returns true if the session ended (expired / gone / closed) and the caller should
    /// rotate to a new one; returns false when the task was cancelled (view dismissed).
    private func pollSession(token: String, expiresAt: Date) async -> Bool {
        var deadline = expiresAt
        while !Task.isCancelled {
            if Date() >= deadline { return true }   // expired → rotate
            switch await AddonPairingClient.poll(token: token) {
            case .gone:
                return true                          // unknown / expired token → rotate
            case .ok(let poll):
                // Deliver BEFORE the closed check: a URL the phone adds in the same poll window as its "Done"
                // tap arrives with closed == true and must not be dropped by the rotation.
                dispatch(.delivered(urls: poll.manifests.map(\.url), sessionToken: token, liveToken: session?.token))
                if poll.closed { return true }       // phone closed it → rotate
                deadline = poll.expiresAt            // keep the deadline fresh from the relay
            case .failed:
                break                                // transient; keep polling
            }
            do { try await Task.sleep(for: Self.pollInterval) } catch { return false }
        }
        return false
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        // The session is deliberately LEFT ALIVE on the relay (it self-expires): a manifest the phone adds
        // after this sheet closes is picked up by the persisted-session resume on the next open.
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
