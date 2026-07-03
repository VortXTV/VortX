import SwiftUI

/// "Install by QR — pair once, add many." The TV/phone/Mac shows a QR that opens a phone page; the
/// user pastes add-on manifest URLs there, and this view polls the relay session, shows the live
/// incoming list, and installs each one THROUGH THE APP'S OWN hardened path (`CoreBridge.installAddon`)
/// after an on-device confirm.
///
/// SAFETY MODEL: the relay (`add.vortx.tv`) is a dumb pipe that only carries URL strings between the
/// phone and this device. Nothing installs silently: every incoming URL is fetched + validated by
/// `CoreBridge` (the same manifest validation the paste-a-URL flow uses) and shown as an explicit
/// "Install <name>?" row, so a QR scanned by the wrong person cannot push an add-on onto the TV. The
/// view stays open so the user can keep adding on the phone and installing here.
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

    // Live incoming list, keyed by normalized URL, with per-row install state.
    @State private var rows: [Row] = []

    // Long-lived tasks: one creates + rotates the session, one polls it.
    @State private var pollTask: Task<Void, Never>?

    /// One incoming manifest URL and where it is in the install lifecycle on THIS device.
    private struct Row: Identifiable, Equatable {
        let url: String                 // the raw URL the phone added (relay-provided)
        var name: String?               // resolved add-on name once the manifest validates
        var state: State = .pending
        var id: String { url }

        enum State: Equatable {
            case pending       // not yet resolved
            case resolving     // fetching + validating the manifest
            case ready         // valid manifest, awaiting the user's Install tap
            case invalid       // manifest failed validation (not installable)
            case installing
            case installed
            case failed(String)
        }
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
                        Button("Install all") { installAll() }
                            .buttonStyle(ChipButtonStyle(selected: true))
                            .fixedSize()
                    }
                }
                ForEach(rows) { row in incomingRow(row) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    @ViewBuilder private func trailingControl(for row: Row) -> some View {
        switch row.state {
        case .ready:
            Button { install(url: row.url) } label: { Label("Install", systemImage: "square.and.arrow.down") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .fixedSize()
        case .failed:
            Button { retry(url: row.url) } label: { Label("Retry", systemImage: "arrow.clockwise") }
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
                merge(incoming: poll.manifests)
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
                merge(incoming: poll.manifests)
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

    /// Fold the relay's list into our rows: add any new URL (and kick off its manifest resolution),
    /// keeping the install state of URLs we already track. Never removes a row the user has acted on.
    private func merge(incoming: [AddonPairingClient.IncomingManifest]) {
        let known = Set(rows.map(\.url))
        var appended: [String] = []
        for item in incoming where !known.contains(item.url) {
            rows.append(Row(url: item.url))
            appended.append(item.url)
        }
        for url in appended { resolve(url: url) }
    }

    /// Validate a URL's manifest through `CoreBridge.previewAddonManifest` (the same fetch + validation
    /// the install path uses) to get its name and installable/already-installed state.
    private func resolve(url: String) {
        updateRow(url) { $0.state = .resolving }
        Task { @MainActor in
            guard let preview = await core.previewAddonManifest(urlString: url) else {
                updateRow(url) { $0.state = .invalid }
                return
            }
            updateRow(url) { row in
                row.name = preview.name
                row.state = preview.alreadyInstalled ? .installed : .ready
            }
        }
    }

    // MARK: - Install (through the app's own hardened path only)

    private func install(url: String) {
        updateRow(url) { $0.state = .installing }
        Task { @MainActor in
            // The ONE installer: fetches + validates + dispatches into the engine's add-on collection.
            let error = await core.installAddon(urlString: url)
            if let error {
                updateRow(url) { $0.state = .failed(error) }
            } else {
                updateRow(url) { $0.state = .installed }
            }
        }
    }

    private func installAll() {
        for row in rows where row.state == .ready { install(url: row.url) }
    }

    private func retry(url: String) {
        // Re-validate from scratch, then it becomes installable again.
        resolve(url: url)
    }

    private func updateRow(_ url: String, _ mutate: (inout Row) -> Void) {
        guard let idx = rows.firstIndex(where: { $0.url == url }) else { return }
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
        case .ready:               return row.url
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
