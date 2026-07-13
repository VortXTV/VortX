import SwiftUI

/// "External services" section for the shared VortX account/sync screen: connect Trakt (device-code
/// OAuth) and SIMKL (PIN flow), each with per-service scrobble + watchlist toggles. Cross-platform
/// (iPhone / iPad / Mac / Apple TV) because it is mounted inside `SyncSettingsView`, which both the iOS
/// and tvOS settings screens host, so both surfaces get the feature by construction (settings parity).
///
/// DORMANCY: each provider block renders ONLY when that provider's build credentials are present
/// (`TraktAuth.isConfigured` / `SIMKLAuth.isConfigured`). With empty creds the whole section is invisible
/// and nothing here ever hits the network, so the shipped beta shows no trace of the feature.
struct ExternalServicesSettingsView: View {
    var body: some View {
        // The entire section is hidden until at least one provider is configured.
        if TraktAuth.isConfigured || SIMKLAuth.isConfigured {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("External services")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Sync what you watch and want to watch to your other accounts. This is separate from your VortX account and uses each service's own connection.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if TraktAuth.isConfigured { TraktConnectCard() }
                if SIMKLAuth.isConfigured { SIMKLConnectCard() }
            }
            .padding(.top, Theme.Space.lg)
        }
    }
}

// MARK: - Shared building blocks

/// A card surface shared by both provider blocks, matching the account card styling in SyncSettingsView.
private struct ProviderCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) { content }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// The code + QR panel shown while a device/PIN flow is pending.
private struct PairingPanel: View {
    let code: String
    let url: String
    let instruction: String
    let qr: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let qr {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white)
                        .frame(width: 180, height: 180)
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none).resizable().scaledToFit()
                        .frame(width: 156, height: 156)
                }
            }
            Text(code)
                .font(.system(size: 34, weight: .heavy, design: .monospaced))
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(instruction)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(url)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Trakt

private struct TraktConnectCard: View {
    @State private var connected = false
    @State private var working = false
    @State private var code: TraktDeviceCode?
    @State private var qr: CGImage?
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?

    @AppStorage(ExternalSyncToggle.traktScrobble) private var scrobble = true
    @AppStorage(ExternalSyncToggle.traktWatchlist) private var watchlist = true
    @AppStorage(ExternalSyncToggle.traktImportWatched) private var importWatched = false

    var body: some View {
        ProviderCard {
            Text("Trakt").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            if connected {
                Text("Connected").font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                Toggle("Scrobble what you watch", isOn: $scrobble).tint(Theme.Palette.accent)
                Toggle("Add to watchlist when you add to Library", isOn: $watchlist).tint(Theme.Palette.accent)
                Toggle("Show titles watched on Trakt as watched here", isOn: $importWatched)
                    .tint(Theme.Palette.accent)
                    .onChange(of: importWatched) { _ in WatchedIndex.shared.externalShadowChanged() }
                Button("Disconnect") { disconnect() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            } else if let code {
                PairingPanel(code: code.userCode, url: code.verificationURL,
                             instruction: "Go to the address below and enter this code to connect Trakt.", qr: qr)
                if !status.isEmpty {
                    Text(status).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                }
                if let errorMessage {
                    Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                }
                Button("Cancel") { cancel() }.buttonStyle(ChipButtonStyle(selected: false))
            } else {
                Text("Connect Trakt to scrobble your progress and sync your watchlist.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                if let errorMessage {
                    Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                }
                Button(working ? "Connecting…" : "Connect Trakt") { connect() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(working)
            }
        }
        .task { connected = await TraktAuth.shared.isSignedIn }
        .onDisappear { pollTask?.cancel() }
    }

    private func connect() {
        pollTask?.cancel()
        working = true; errorMessage = nil; status = ""
        pollTask = Task {
            do {
                let dc = try await TraktAuth.shared.requestDeviceCode()
                let image = QRCodeImage.make(dc.verificationURL)
                await MainActor.run { code = dc; qr = image; working = false; status = "Waiting for you to authorize…" }
                _ = try await TraktAuth.shared.pollForToken(deviceCode: dc.deviceCode, interval: dc.interval, expiresIn: dc.expiresIn)
                await MainActor.run { connected = true; code = nil; qr = nil; status = "" }
            } catch is CancellationError {
                return
            } catch {
                let message = error.localizedDescription
                await MainActor.run { working = false; code = nil; qr = nil; status = ""; errorMessage = message }
            }
        }
    }

    private func cancel() {
        pollTask?.cancel(); pollTask = nil
        code = nil; qr = nil; status = ""; working = false; errorMessage = nil
    }

    private func disconnect() {
        Task {
            await TraktAuth.shared.signOut()
            await MainActor.run { connected = false; code = nil; qr = nil }
        }
    }
}

// MARK: - SIMKL

private struct SIMKLConnectCard: View {
    @State private var connected = false
    @State private var working = false
    @State private var pin: SIMKLPin?
    @State private var qr: CGImage?
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?

    @AppStorage(ExternalSyncToggle.simklScrobble) private var scrobble = true
    @AppStorage(ExternalSyncToggle.simklWatchlist) private var watchlist = true

    var body: some View {
        ProviderCard {
            Text("SIMKL").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            if connected {
                Text("Connected").font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                Toggle("Mark watched when you finish", isOn: $scrobble).tint(Theme.Palette.accent)
                Toggle("Add to watchlist when you add to Library", isOn: $watchlist).tint(Theme.Palette.accent)
                Button("Disconnect") { disconnect() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            } else if let pin {
                PairingPanel(code: pin.userCode, url: pin.verificationUrl,
                             instruction: "Go to the address below and enter this code to connect SIMKL.", qr: qr)
                if !status.isEmpty {
                    Text(status).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                }
                if let errorMessage {
                    Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                }
                Button("Cancel") { cancel() }.buttonStyle(ChipButtonStyle(selected: false))
            } else {
                Text("Connect SIMKL to mark titles watched and sync your plan-to-watch list.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                if let errorMessage {
                    Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                }
                Button(working ? "Connecting…" : "Connect SIMKL") { connect() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(working)
            }
        }
        .task { connected = await SIMKLAuth.shared.isSignedIn }
        .onDisappear { pollTask?.cancel() }
    }

    private func connect() {
        pollTask?.cancel()
        working = true; errorMessage = nil; status = ""
        pollTask = Task {
            do {
                let p = try await SIMKLAuth.shared.requestPin()
                let image = QRCodeImage.make(p.verificationUrl)
                await MainActor.run { pin = p; qr = image; working = false; status = "Waiting for you to authorize…" }
                _ = try await SIMKLAuth.shared.pollForToken(userCode: p.userCode, interval: p.interval, expiresIn: p.expiresIn)
                await MainActor.run { connected = true; pin = nil; qr = nil; status = "" }
            } catch is CancellationError {
                return
            } catch {
                let message = error.localizedDescription
                await MainActor.run { working = false; pin = nil; qr = nil; status = ""; errorMessage = message }
            }
        }
    }

    private func cancel() {
        pollTask?.cancel(); pollTask = nil
        pin = nil; qr = nil; status = ""; working = false; errorMessage = nil
    }

    private func disconnect() {
        Task {
            await SIMKLAuth.shared.signOut()
            await MainActor.run { connected = false; pin = nil; qr = nil }
        }
    }
}
