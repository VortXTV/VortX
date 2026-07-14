import SwiftUI

/// Shared Settings screen to connect and manage personal media servers (Plex, Jellyfin, Emby). ONE file
/// mounted by BOTH the tvOS and iOS/iPad/Mac settings screens, so the feature reaches every Apple surface by
/// construction (settings parity). Mirrors `DebridKeysView` (ScrollView + card list) and reuses the Trakt
/// card's code+QR pairing shape, kept LOCAL here (a small `MSPairingPanel`) rather than de-privatizing the
/// laneCD component, so this lane touches no merged file.
///
/// DORMANT: with no server connected the app makes zero media-server network calls anywhere; this screen is
/// the only surface that mentions the feature. The add flows are the only place a network call originates
/// until a server exists.
struct MediaServersSettingsView: View {
    @ObservedObject private var store = MediaServerStore.shared
    @State private var adding: MediaServerKind?
    @State private var syncLogins = MediaServerStore.shared.syncLogins

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Media servers").screenTitleStyle()
                Text("Connect your own Plex, Jellyfin, or Emby server to play what you already own straight from your box. Your logins stay on this device (in the keychain) and, if you leave the toggle on below, sync encrypted to your VortX account. Your servers rank against your other sources in Source Order.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)

                Toggle("Sync server logins to my VortX account", isOn: $syncLogins)
                    .tint(Theme.Palette.accent)
                    .onChange(of: syncLogins) { store.syncLogins = $0 }

                ForEach(store.servers) { record in
                    MSServerCard(record: record) { store.remove(id: record.id) }
                }

                if let kind = adding {
                    MSAddServerFlow(kind: kind, onDone: { adding = nil }, onCancel: { adding = nil })
                } else {
                    addSection
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(store.servers.isEmpty ? "Add a server" : "Add another server")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Space.sm) {
                kindButton(.plex, "Plex")
                kindButton(.jellyfin, "Jellyfin")
                kindButton(.emby, "Emby")
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func kindButton(_ kind: MediaServerKind, _ label: String) -> some View {
        Button(label) { adding = kind }
            .buttonStyle(ChipButtonStyle(selected: false))
    }
}

// MARK: - Server card

private struct MSServerCard: View {
    let record: MediaServerRecord
    let onRemove: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text(record.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(kindLabel).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                Circle()
                    .fill(record.needsReauth ? Theme.Palette.danger : Theme.Palette.accent)
                    .frame(width: 9, height: 9)
            }
            if let url = record.urls.first {
                Text(url).font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary).lineLimit(1).minimumScaleFactor(0.7)
            }
            if record.needsReauth {
                Text("Sign in again to use this server.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
            }
            if confirmRemove {
                HStack(spacing: Theme.Space.sm) {
                    Button("Remove server") { onRemove() }.buttonStyle(ChipButtonStyle(selected: false))
                    Button("Keep") { confirmRemove = false }.buttonStyle(ChipButtonStyle(selected: false))
                }
            } else {
                Button("Remove") { confirmRemove = true }.buttonStyle(ChipButtonStyle(selected: false))
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var kindLabel: String {
        switch record.kind {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        }
    }
}

// MARK: - Local pairing panel (code + QR), kept local so this lane touches no merged file

private struct MSPairingPanel: View {
    let code: String
    let url: String
    let instruction: String
    let qr: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let qr {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white).frame(width: 180, height: 180)
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable().scaledToFit().frame(width: 156, height: 156)
                }
            }
            Text(code)
                .font(.system(size: 34, weight: .heavy, design: .monospaced))
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(instruction).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            Text(url).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Add-server flow (per kind)

private struct MSAddServerFlow: View {
    let kind: MediaServerKind
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            switch kind {
            case .plex:     MSPlexAddFlow(onDone: onDone)
            case .jellyfin: MSJellyfinAddFlow(onDone: onDone)
            case .emby:     MSEmbyAddFlow(onDone: onDone)
            }
            Button("Cancel") { onCancel() }.buttonStyle(ChipButtonStyle(selected: false))
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

// MARK: Plex add flow

private struct MSPlexAddFlow: View {
    let onDone: () -> Void
    @State private var pin: MediaServerAuth.PlexPin?
    @State private var qr: CGImage?
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var candidates: [PlexServerCandidate] = []
    @State private var accountToken: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Plex").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            if !candidates.isEmpty {
                Text("Choose a server to connect.").font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                ForEach(candidates) { c in
                    Button(c.name) { pick(c) }.buttonStyle(ChipButtonStyle(selected: false))
                }
            } else if let pin {
                MSPairingPanel(code: pin.code, url: pin.linkURL,
                               instruction: "On plex.tv/link, enter this code to connect your Plex account.", qr: qr)
                if !status.isEmpty { Text(status).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary) }
            } else {
                Text("Link your Plex account, then pick a server. Your VortX device shows up as a signed-in device on plex.tv.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                Button("Connect Plex") { start() }.buttonStyle(PrimaryActionStyle())
            }
            if let errorMessage { Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger) }
        }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        task?.cancel(); errorMessage = nil; status = "Requesting a code…"
        task = Task {
            do {
                let p = try await MediaServerAuth.plexRequestPin()
                let image = QRCodeImage.make(p.linkURL)
                await MainActor.run { pin = p; qr = image; status = "Waiting for you to authorize…" }
                let token = try await MediaServerAuth.plexPollForToken(pin: p)
                await MainActor.run { accountToken = token; status = "Finding your servers…" }
                let found = try await MediaServerAuth.plexDiscoverServers(accountToken: token)
                if found.count == 1 { await MainActor.run { pick(found[0]) } }
                else { await MainActor.run { candidates = found; pin = nil; qr = nil; status = ""
                    if found.isEmpty { errorMessage = "No Plex Media Server was found on your account." } } }
            } catch is CancellationError { return }
            catch { await MainActor.run { errorMessage = (error as? MediaServerAuthError)?.errorDescription ?? error.localizedDescription; pin = nil; qr = nil; status = "" } }
        }
    }

    private func pick(_ c: PlexServerCandidate) {
        let record = MediaServerRecord(name: c.name, kind: .plex, urls: c.urls, userId: "", machineId: c.machineId)
        MediaServerStore.shared.add(record, token: c.accessToken, plexAccountToken: accountToken)
        onDone()
    }
}

// MARK: Jellyfin add flow

private struct MSJellyfinAddFlow: View {
    let onDone: () -> Void
    @State private var base = ""
    @State private var phase: Phase = .url
    @State private var qc: MediaServerAuth.QuickConnectInit?
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    private enum Phase { case url, quickConnect, password }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Jellyfin").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            switch phase {
            case .url:
                serverField
                Button("Continue") { beginQuickConnect() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(MediaServerResolve.normalizedBase(base) == nil)
            case .quickConnect:
                if let qc {
                    MSPairingPanel(code: qc.code, url: base,
                                   instruction: "In your Jellyfin app or web, open Quick Connect and enter this code.", qr: nil)
                }
                if !status.isEmpty { Text(status).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary) }
                Button("Use username & password instead") { phase = .password; task?.cancel() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            case .password:
                credentialFields
                Button("Sign in") { signInPassword() }.buttonStyle(PrimaryActionStyle())
                    .disabled(username.isEmpty || password.isEmpty)
            }
            if let errorMessage { Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger) }
        }
        .onDisappear { task?.cancel() }
    }

    private var serverField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            TextField("http://192.168.1.10:8096", text: $base)
                .font(.system(size: 15, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                #endif
            Text("Your Jellyfin server address.").font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            TextField("Username", text: $username)
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
            SecureField("Password", text: $password)
                #if os(iOS)
                .textContentType(.password)
                #endif
        }
    }

    private func beginQuickConnect() {
        task?.cancel(); errorMessage = nil; status = "Checking Quick Connect…"
        task = Task {
            let enabled = await MediaServerAuth.jellyfinQuickConnectEnabled(base: base)
            guard enabled else { await MainActor.run { phase = .password; status = "" }; return }
            do {
                let init0 = try await MediaServerAuth.jellyfinInitiateQuickConnect(base: base)
                await MainActor.run { qc = init0; phase = .quickConnect; status = "Waiting for you to authorize…" }
                let result = try await MediaServerAuth.jellyfinAwaitQuickConnect(base: base, secret: init0.secret)
                await MainActor.run { finish(result) }
            } catch is CancellationError { return }
            catch { await MainActor.run { phase = .password; status = ""; errorMessage = (error as? MediaServerAuthError)?.errorDescription } }
        }
    }

    private func signInPassword() {
        task?.cancel(); errorMessage = nil; status = "Signing in…"
        task = Task {
            do {
                let result = try await MediaServerAuth.jellyfinAuthByPassword(base: base, username: username, password: password)
                await MainActor.run { finish(result) }
            } catch is CancellationError { return }
            catch { await MainActor.run { status = ""; errorMessage = (error as? MediaServerAuthError)?.errorDescription ?? error.localizedDescription } }
        }
    }

    private func finish(_ result: MediaServerAuthResult) {
        guard let root = MediaServerResolve.normalizedBase(base) else { errorMessage = "That server address does not look valid."; return }
        let name = result.serverName ?? URL(string: root)?.host ?? "Jellyfin"
        let record = MediaServerRecord(name: name, kind: .jellyfin, urls: [root], userId: result.userId, machineId: result.serverId)
        MediaServerStore.shared.add(record, token: result.accessToken)
        onDone()
    }
}

// MARK: Emby add flow

private struct MSEmbyAddFlow: View {
    let onDone: () -> Void
    @State private var base = ""
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Emby").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                TextField("http://192.168.1.10:8096", text: $base)
                    .font(.system(size: 15, design: .monospaced))
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    #endif
                TextField("Username", text: $username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                SecureField("Password", text: $password)
                    #if os(iOS)
                    .textContentType(.password)
                    #endif
            }
            Button("Sign in") { signIn() }.buttonStyle(PrimaryActionStyle())
                .disabled(MediaServerResolve.normalizedBase(base) == nil || username.isEmpty)
            if !status.isEmpty { Text(status).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary) }
            if let errorMessage { Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger) }
        }
        .onDisappear { task?.cancel() }
    }

    private func signIn() {
        task?.cancel(); errorMessage = nil; status = "Signing in…"
        task = Task {
            do {
                let result = try await MediaServerAuth.embyAuthByPassword(base: base, username: username, password: password)
                await MainActor.run { finish(result) }
            } catch is CancellationError { return }
            catch { await MainActor.run { status = ""; errorMessage = (error as? MediaServerAuthError)?.errorDescription ?? error.localizedDescription } }
        }
    }

    private func finish(_ result: MediaServerAuthResult) {
        guard let root = MediaServerResolve.normalizedBase(base) else { errorMessage = "That server address does not look valid."; return }
        let name = result.serverName ?? URL(string: root)?.host ?? "Emby"
        let record = MediaServerRecord(name: name, kind: .emby, urls: [root], userId: result.userId, machineId: result.serverId)
        MediaServerStore.shared.add(record, token: result.accessToken)
        onDone()
    }
}
