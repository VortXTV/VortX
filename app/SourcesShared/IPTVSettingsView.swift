import SwiftUI

/// Manage IPTV playlists: add an M3U URL or an Xtream Codes login (with an optional XMLTV EPG URL), list the
/// installed playlists, and remove them. Adding registers the source with the hosted converter worker, which
/// returns a slug; the app then installs `https://iptv.vortx.tv/c/<slug>/manifest.json` as a normal Stremio
/// add-on, so its channels appear in the existing Live tab with NO new playback code. Removing uninstalls the
/// add-on and revokes the slug server-side. Credentials stay in the Keychain (via `IPTVPlaylistStore`); only
/// the non-secret metadata is kept locally. Cross-platform (iOS / iPadOS / macOS / tvOS).
struct IPTVSettingsView: View {
    @ObservedObject private var store = IPTVPlaylistStore.shared
    // The engine bridge is a singleton referenced directly across the app (matches AddonPairingView), so this
    // screen needs no @EnvironmentObject injection to install / uninstall.
    private let core = CoreBridge.shared

    private enum Kind: String, CaseIterable, Identifiable {
        case m3u
        case xtream
        var id: String { rawValue }
        var label: String {
            switch self {
            case .m3u: return String(localized: "M3U URL")
            case .xtream: return String(localized: "Xtream login")
            }
        }
    }

    @State private var kind: Kind = .m3u
    @State private var name = ""
    @State private var m3uURL = ""
    @State private var xtreamHost = ""
    @State private var xtreamUser = ""
    @State private var xtreamPass = ""
    @State private var xmltvURL = ""

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var removingSlug: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Live TV (IPTV)").screenTitleStyle()
                Text("Add an M3U playlist or an Xtream Codes login and its channels appear in your Live tab. Your details stay on this device and go only to VortX's converter over an encrypted connection. An optional XMLTV URL adds the now / next guide.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)

                if !store.playlists.isEmpty {
                    installedSection
                }
                addSection
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    // MARK: Installed playlists

    @ViewBuilder private var installedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Your playlists").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            ForEach(store.playlists) { playlist in
                HStack(spacing: Theme.Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name).foregroundStyle(Theme.Palette.textPrimary)
                        Text(playlist.kind.label).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Spacer()
                    if removingSlug == playlist.id {
                        ProgressView()
                    } else {
                        Button(role: .destructive) {
                            remove(playlist)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Theme.Palette.accent)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isWorking)
                    }
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
        }
    }

    // MARK: Add form

    @ViewBuilder private var addSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Add a playlist").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)

            Picker("Type", selection: $kind) {
                ForEach(Kind.allCases) { k in Text(k.label).tag(k) }
            }
            #if os(iOS)
            .pickerStyle(.segmented)
            #endif
            .tint(Theme.Palette.accent)

            field("Name (optional)", text: $name, placeholder: "My IPTV", secure: false, isURL: false)

            if kind == .m3u {
                field("M3U URL", text: $m3uURL, placeholder: "https://provider.example/playlist.m3u", secure: false, isURL: true)
            } else {
                field("Server URL", text: $xtreamHost, placeholder: "http://panel.example.com:8080", secure: false, isURL: true)
                field("Username", text: $xtreamUser, placeholder: "username", secure: false, isURL: false)
                field("Password", text: $xtreamPass, placeholder: "password", secure: true, isURL: false)
            }
            field("XMLTV EPG URL (optional)", text: $xmltvURL, placeholder: "https://provider.example/xmltv.php", secure: false, isURL: true)

            if let errorMessage {
                Text(errorMessage).font(Theme.Typography.label).foregroundStyle(.red)
            }

            Button {
                submit()
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    if isWorking { ProgressView() }
                    Text(isWorking ? "Adding…" : "Add playlist")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.sm)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.accent)
            .disabled(isWorking || !canSubmit)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var canSubmit: Bool {
        switch kind {
        case .m3u: return !m3uURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .xtream:
            return !xtreamHost.trimmingCharacters(in: .whitespaces).isEmpty
                && !xtreamUser.trimmingCharacters(in: .whitespaces).isEmpty
                && !xtreamPass.isEmpty
        }
    }

    @ViewBuilder private func field(_ title: String, text: Binding<String>, placeholder: String, secure: Bool, isURL: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.system(size: 15, design: .monospaced))
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(isURL ? .URL : .default)
            #endif
        }
    }

    // MARK: Actions

    private func submit() {
        errorMessage = nil
        isWorking = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedEPG = xmltvURL.trimmingCharacters(in: .whitespaces)
        let chosen = kind

        Task {
            let result: Result<IPTVConverterClient.Registration, IPTVConverterClient.ClientError>
            let credentials: IPTVCredentials
            switch chosen {
            case .m3u:
                let url = m3uURL.trimmingCharacters(in: .whitespaces)
                result = await IPTVConverterClient.registerM3U(url: url, xmltvURL: trimmedEPG.isEmpty ? nil : trimmedEPG, name: trimmedName.isEmpty ? nil : trimmedName)
                credentials = IPTVCredentials(m3uURL: url, xmltvURL: trimmedEPG.isEmpty ? nil : trimmedEPG)
            case .xtream:
                let host = xtreamHost.trimmingCharacters(in: .whitespaces)
                let user = xtreamUser.trimmingCharacters(in: .whitespaces)
                result = await IPTVConverterClient.registerXtream(host: host, user: user, pass: xtreamPass, xmltvURL: trimmedEPG.isEmpty ? nil : trimmedEPG, name: trimmedName.isEmpty ? nil : trimmedName)
                credentials = IPTVCredentials(xtreamHost: host, xtreamUser: user, xtreamPass: xtreamPass, xmltvURL: trimmedEPG.isEmpty ? nil : trimmedEPG)
            }

            switch result {
            case .failure(let err):
                errorMessage = err.errorDescription
                isWorking = false
            case .success(let reg):
                // Install the returned manifest as a normal add-on. installAddon runs the SSRF AddonURLGuard,
                // which passes since iptv.vortx.tv is a public origin. A failure here surfaces to the user and
                // the playlist is not recorded (so a failed install is not left dangling in the list).
                if let installError = await core.installAddon(urlString: reg.manifestURL) {
                    errorMessage = installError
                    isWorking = false
                    return
                }
                let displayName = trimmedName.isEmpty ? defaultName(for: chosen) : trimmedName
                store.add(
                    IPTVPlaylist(id: reg.slug, name: displayName, kind: chosen == .m3u ? .m3u : .xtream,
                                 transportUrl: reg.manifestURL, createdAt: Date()),
                    credentials: credentials
                )
                clearForm()
                isWorking = false
            }
        }
    }

    private func remove(_ playlist: IPTVPlaylist) {
        removingSlug = playlist.id
        Task {
            // Uninstall the engine add-on first (AddonTombstones records the removal so sync does not re-add it),
            // then revoke the slug server-side (fail-soft), then drop the local record + Keychain credentials.
            if let descriptor = core.addons.first(where: { $0.transportUrl == playlist.transportUrl }) {
                core.uninstallAddon(descriptor)
            }
            await IPTVConverterClient.revoke(slug: playlist.id)
            store.remove(slug: playlist.id)
            removingSlug = nil
        }
    }

    private func defaultName(for kind: Kind) -> String {
        kind == .m3u ? String(localized: "M3U playlist") : String(localized: "Xtream playlist")
    }

    private func clearForm() {
        name = ""; m3uURL = ""; xtreamHost = ""; xtreamUser = ""; xtreamPass = ""; xmltvURL = ""
        errorMessage = nil
    }
}
