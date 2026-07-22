import SwiftUI

/// "Install by QR — pair once, add many." The TV/phone/Mac shows a QR that opens a phone page; the
/// user pastes add-on manifest URLs there, and this view polls the relay session and AUTO-INSTALLS each
/// accepted submission THROUGH THE APP'S OWN hardened path (`CoreBridge.installAddon`), then publishes an
/// explicit on-device success / failure.
///
/// SAFETY MODEL (why auto-install is safe): the relay (`add.vortx.tv`) is a dumb pipe that only carries
/// URL strings, scoped to ONE one-time TV pairing session. A submission is only acted on when it is bound
/// to THIS device's CURRENT live session (`Row.sessionToken == session.token`), so only a phone that
/// scanned the QR now on screen can push a URL here — an expired, replayed, or wrong-session submission is
/// refused with no state change. Every accepted URL is still fetched + validated by `CoreBridge`
/// (`previewAddonManifest` then `installAddon`, the SAME manifest validation + SSRF guard the paste-a-URL
/// flow uses); a malformed URL or a manifest that fails validation lands `.invalid` and is NEVER installed
/// and NEVER counted as success. Auto-install replaces the old "walk back to the TV and click Install per
/// row" step (the defect: the phone's Done did nothing and the TV's Install was not focus-reachable), but a
/// focusable manual Install / Retry stays as recovery. Idempotency: rows are keyed by SESSION + identity so
/// a duplicate delivery collapses to one row and installs exactly once, and `installAddon` itself no-ops an
/// already-present add-on. The session is left alive on the relay after the sheet closes so a late add is
/// picked up by the persisted-session resume on the next open.
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

    // Live incoming list, keyed by SESSION + identity, with per-row install state.
    @State private var rows: [Row] = []
    // Row ids we have already DISPATCHED an auto-install for, so an accepted submission installs EXACTLY
    // once no matter how many poll cycles re-deliver it. Manual Install / Retry is a deliberate user action
    // and is NOT gated by this set.
    @State private var autoInstalled: Set<String> = []

    // Long-lived tasks: one creates + rotates the session, one polls it.
    @State private var pollTask: Task<Void, Never>?

    /// One incoming manifest URL and where it is in the install lifecycle on THIS device. Keyed by
    /// `sessionToken` + `identity` (never the URL alone) so a resubmission under a NEW pairing session is a
    /// distinct row and a duplicate delivery inside the SAME session collapses to one — the URL-only keying
    /// the prior attempt used let a stale-session URL masquerade as the live one.
    struct Row: Identifiable, Equatable {
        let sessionToken: String        // the pairing session this submission is bound to
        let url: String                 // the raw URL the phone added (relay-provided)
        let identity: String            // normalized manifest URL: the dedup + install-once key
        var name: String?               // resolved add-on name once the manifest validates
        var state: State = .pending
        var id: String { sessionToken + "\u{1}" + identity }

        enum State: Equatable {
            case pending       // not yet resolved
            case resolving     // fetching + validating the manifest
            case ready         // valid manifest, awaiting (or mid-) auto-install; manual Install as recovery
            case invalid       // manifest failed validation (not installable) — NEVER a success
            case installing
            case installed
            case failed(String)

            /// Non-terminal: work is still outstanding for this row. Drives the "Installing…" batch state and
            /// keeps Done from silently exiting a pending submission.
            var isInFlight: Bool {
                switch self {
                case .pending, .resolving, .ready, .installing: return true
                case .invalid, .installed, .failed:             return false
                }
            }
            /// A row the user can act on by hand (auto-install skipped it, or it failed): the manual Install /
            /// Retry recovery path.
            var isManualActionable: Bool {
                switch self {
                case .ready:  return true
                case .failed: return true
                default:      return false
                }
            }
        }
    }

    /// The aggregate outcome of the current batch, published explicitly on the TV. `.invalid` and `.failed`
    /// are NON-success, so an invalid-only or partially-failed batch never reports `.allInstalled`.
    enum BatchStatus: Equatable {
        case empty
        case working
        case allInstalled(Int)
        case partial(installed: Int, failed: Int, invalid: Int)
    }

    /// Pure reduction of the row states to the batch outcome. Extracted (and mirrored by
    /// `AddonPairingBatchTests`) so the success/failure rule is verifiable without the SwiftUI stack:
    /// working while ANY row is in flight; `.allInstalled` only when every row installed; otherwise a
    /// partial breakdown that counts invalid / failed as non-success.
    static func batchStatus(_ states: [Row.State]) -> BatchStatus {
        guard !states.isEmpty else { return .empty }
        if states.contains(where: { $0.isInFlight }) { return .working }
        var installed = 0, failed = 0, invalid = 0
        for s in states {
            switch s {
            case .installed: installed += 1
            case .invalid:   invalid += 1
            case .failed:    failed += 1
            default:         break
            }
        }
        if installed == states.count { return .allInstalled(installed) }
        return .partial(installed: installed, failed: failed, invalid: invalid)
    }

    /// Done's label + enabled state, derived from the batch. While work is outstanding Done is disabled and
    /// reads "Installing…", so it can never SILENTLY drop a pending valid submission; once every row is
    /// terminal (installed / failed / invalid) it re-enables as "Done". Pure so the test can assert it.
    static func doneState(_ status: BatchStatus) -> (title: String, enabled: Bool) {
        switch status {
        case .working:
            return (String(localized: "Installing…"), false)
        case .empty, .allInstalled, .partial:
            return (String(localized: "Done"), true)
        }
    }

    private var batch: BatchStatus { Self.batchStatus(rows.map(\.state)) }

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
        let state = Self.doneState(batch)
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
                Text("Scan with your phone to add add-ons by URL. Paste each add-on's manifest link on the page — it installs here automatically.")
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
        if rows.isEmpty, session != nil {
            // Live-poll indicator: makes it visible that adds from the phone will land + install here.
            HStack(spacing: Theme.Space.sm) {
                ProgressView().tint(Theme.Palette.accent)
                Text("Waiting for add-ons added on your phone…")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        if !rows.isEmpty {
            let section = VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("From your phone")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    // Batch-level manual recovery: install every not-yet-installed / failed row in one hit.
                    // Focus-reachable on tvOS (ChipButtonStyle), so an auto-install that stalled or failed is
                    // always recoverable without the removed per-row walk-back.
                    if rows.contains(where: { $0.state.isManualActionable }) {
                        Button { installActionable() } label: {
                            Label("Install all", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(ChipButtonStyle(selected: true))
                        .fixedSize()
                    }
                }
                batchBanner
                ForEach(rows) { row in incomingRow(row) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // One focus section for the whole incoming region (NOT per-row: stacked sibling focus sections
            // make tvOS skip rows — the Collections-hub region-jump lesson). This makes the region reliably
            // enterable so the manual Install / Retry buttons are reachable.
            #if os(tvOS)
            section.focusSection()
            #else
            section
            #endif
        }
    }

    /// Explicit on-device success / failure line for the batch (the "publish TV success OR failure" the
    /// phone's Done never gave). Invalid + failed are surfaced as non-success.
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

    private func incomingRow(_ row: Row) -> some View {
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

    @ViewBuilder private func trailingControl(for row: Row) -> some View {
        switch row.state {
        case .ready:
            // Manual recovery: auto-install normally beats the user to this, but if it was skipped (offline,
            // race) the button stays here, focusable + actionable.
            Button { install(rowId: row.id) } label: { Label("Install", systemImage: "square.and.arrow.down") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .fixedSize()
        case .failed:
            Button { install(rowId: row.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .fixedSize()
        case .resolving, .installing:
            ProgressView().tint(Theme.Palette.accent)
        default:
            EmptyView()
        }
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

    /// Create a session, render its QR, then poll it. If the session expires (or the relay reports it
    /// gone / closed), rotate to a fresh one so the QR on screen is always live.
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
                pruneStaleRows(currentToken: saved.token)
                merge(incoming: poll.manifests, sessionToken: saved.token)
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
            // A fresh session token means any not-yet-terminal row from a PRIOR session can never complete
            // (its phone page is dead); drop those so a wrong-session submission leaves no stuck state and
            // Done is not pinned "Installing…" forever. Terminal rows stay as visible history.
            pruneStaleRows(currentToken: created.token)

            // Poll THIS session until it dies, then loop to mint a new one. NOTE the polarity:
            // pollSession returns true when the session ENDED (expired / gone / closed) and a fresh
            // one should be minted; false means the task was cancelled (view dismissed). The old
            // `if !stillAlive { continue }` read it backwards, so an expired/closed session stopped
            // polling entirely and left a dead QR on screen instead of rotating.
            let ended = await pollSession(token: created.token, expiresAt: created.expiresAt)
            if ended { continue }
            return   // cancelled
        }
    }

    /// Poll one session. Returns true if the session ended (expired / gone / closed) and the caller
    /// should rotate to a new one; returns false when the task was cancelled (view dismissed).
    private func pollSession(token: String, expiresAt: Date) async -> Bool {
        var deadline = expiresAt
        while !Task.isCancelled {
            if Date() >= deadline { return true }   // expired → rotate
            switch await AddonPairingClient.poll(token: token) {
            case .gone:
                return true                          // unknown / expired token → rotate
            case .ok(let poll):
                // Merge BEFORE the closed check: a URL the phone adds in the same poll window as its
                // "Done" tap arrives with closed == true and must not be dropped by the rotation.
                merge(incoming: poll.manifests, sessionToken: token)
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
        // The session is deliberately LEFT ALIVE on the relay (it self-expires): a manifest the phone
        // adds after this sheet closes is picked up by the persisted-session resume on the next open.
    }

    // MARK: - List merge + resolution

    /// Fold the relay's list for the CURRENT session into our rows: add any new (session, identity) — and
    /// kick off its manifest resolution — while keeping the install state of rows we already track. A
    /// duplicate delivery (same session + identity) is a no-op, so nothing installs twice. A malformed URL
    /// (no valid normalized identity) is rejected in place as `.invalid` and never resolves or installs.
    private func merge(incoming: [AddonPairingClient.IncomingManifest], sessionToken: String) {
        // Only the live session's submissions are acted on; a poll is always token-scoped by the relay, but
        // binding the row to `sessionToken` makes a wrong-session URL structurally unable to install.
        guard sessionToken == session?.token else { return }
        let known = Set(rows.map(\.id))
        var toResolve: [String] = []
        for item in incoming {
            let normalized = core.normalizedAddonURL(item.url)
            let identity = normalized ?? item.url
            let rowId = sessionToken + "\u{1}" + identity
            guard !known.contains(rowId) else { continue }   // duplicate delivery → no second row / install
            if normalized == nil {
                // Malformed: reject with NO partial state — it never resolves and never installs.
                rows.append(Row(sessionToken: sessionToken, url: item.url, identity: identity, state: .invalid))
            } else {
                rows.append(Row(sessionToken: sessionToken, url: item.url, identity: identity))
                toResolve.append(rowId)
            }
        }
        for rowId in toResolve { resolve(rowId: rowId) }
    }

    /// Drop any non-terminal row bound to a session other than `currentToken`. A rotated-away session's
    /// phone page is dead, so its pending / resolving rows can never complete; leaving them would pin the
    /// batch "working" and disable Done forever. Terminal rows (installed / failed / invalid) stay as history.
    private func pruneStaleRows(currentToken: String) {
        rows.removeAll { $0.sessionToken != currentToken && $0.state.isInFlight }
    }

    /// Validate a row's manifest through `CoreBridge.previewAddonManifest` (the same fetch + validation the
    /// install path uses) to get its name + installable / already-installed state, then AUTO-INSTALL it once
    /// if it is a valid, not-yet-installed submission bound to the live session.
    private func resolve(rowId: String) {
        guard let row = rows.first(where: { $0.id == rowId }) else { return }
        updateRow(rowId) { $0.state = .resolving }
        let url = row.url
        Task { @MainActor in
            guard let preview = await core.previewAddonManifest(urlString: url) else {
                updateRow(rowId) { $0.state = .invalid }   // invalid → NON-success, never installed
                return
            }
            updateRow(rowId) { r in
                r.name = preview.name
                // Idempotent: an add-on already present (a re-add, or added on another device) is a success,
                // not a row to install again.
                r.state = preview.alreadyInstalled ? .installed : .ready
            }
            autoInstallIfEligible(rowId: rowId)
        }
    }

    // MARK: - Install (through the app's own hardened path only)

    /// Auto-install a freshly-resolved row EXACTLY once: only when it is valid + not yet installed, bound to
    /// the CURRENT live session, and has not already been dispatched. A wrong-session or already-dispatched
    /// row is refused here, so a replay / rotation can never trigger a second install.
    private func autoInstallIfEligible(rowId: String) {
        guard let row = rows.first(where: { $0.id == rowId }) else { return }
        guard row.sessionToken == session?.token else { return }   // wrong-session → never installs
        guard row.state == .ready else { return }
        guard !autoInstalled.contains(rowId) else { return }       // exactly once
        install(rowId: rowId)
    }

    /// The ONE installer: `CoreBridge.installAddon` fetches + validates + dispatches into the engine's
    /// add-on collection (idempotent — an already-present add-on is a no-op). Marks the row installed on
    /// success, or when the add-on ends up present anyway (idempotent duplicate); otherwise failed, with a
    /// focusable Retry.
    private func install(rowId: String) {
        guard let row = rows.first(where: { $0.id == rowId }) else { return }
        autoInstalled.insert(rowId)   // mark BEFORE the await so a re-entrant poll cannot double-dispatch
        updateRow(rowId) { $0.state = .installing }
        let url = row.url
        let identity = row.identity
        Task { @MainActor in
            let error = await core.installAddon(urlString: url)
            if error == nil {
                updateRow(rowId) { $0.state = .installed }
            } else if core.addons.contains(where: { $0.transportUrl == identity }) {
                // Idempotent: the add-on is present (already-installed / concurrent duplicate) → success.
                updateRow(rowId) { $0.state = .installed }
            } else {
                updateRow(rowId) { $0.state = .failed(error ?? String(localized: "Could not install.")) }
            }
        }
    }

    /// Manual batch recovery: install every row the user can still act on (ready or failed). A deliberate
    /// user action, so it is NOT gated by the auto-install-once guard.
    private func installActionable() {
        for row in rows where row.state.isManualActionable { install(rowId: row.id) }
    }

    private func updateRow(_ rowId: String, _ mutate: (inout Row) -> Void) {
        guard let idx = rows.firstIndex(where: { $0.id == rowId }) else { return }
        var row = rows[idx]
        mutate(&row)
        rows[idx] = row
    }

    // MARK: - Row presentation

    private func iconName(for state: Row.State) -> String {
        switch state {
        case .installed:        return "checkmark.circle.fill"
        case .invalid, .failed: return "exclamationmark.triangle.fill"
        default:                return "puzzlepiece.extension.fill"
        }
    }

    private func iconColor(for state: Row.State) -> Color {
        switch state {
        case .installed:        return Theme.Palette.ok
        case .invalid, .failed: return Theme.Palette.danger
        default:                return Theme.Palette.accent
        }
    }

    private func statusText(for row: Row) -> String {
        switch row.state {
        case .pending, .resolving: return String(localized: "Checking add-on…")
        case .ready:               return String(localized: "Installing…")
        case .invalid:             return String(localized: "That URL did not return a valid add-on manifest.")
        case .installing:          return String(localized: "Installing…")
        case .installed:           return String(localized: "Installed")
        case .failed(let message): return message
        }
    }

    private func statusColor(for state: Row.State) -> Color {
        switch state {
        case .installed:        return Theme.Palette.ok
        case .invalid, .failed: return Theme.Palette.danger
        default:                return Theme.Palette.textSecondary
        }
    }
}
