import SwiftUI

/// Settings: who you're signed in as, the embedded streaming-server status, and app info.
/// Mirrors the official tvOS app's Settings → Account / Streaming sections.
struct SettingsView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @State private var serverOnline: Bool?
    @AppStorage(SubtitleStyle.Key.size) private var subSize = SubtitleStyle.defaultSize
    @AppStorage(SubtitleStyle.Key.color) private var subColor = SubtitleStyle.defaultColor
    @AppStorage(SubtitleStyle.Key.background) private var subBackground = SubtitleStyle.defaultBackground

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 44) {
                    Text("Settings").font(.system(size: 56, weight: .heavy))
                    accountSection
                    serverSection
                    subtitleSection
                    aboutSection
                }
                .padding(60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.ignoresSafeArea())
        }
        .task { serverOnline = await StremioServer.isOnline() }
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        section("Account") {
            if account.isSignedIn {
                HStack(spacing: 22) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 56)).foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(account.email ?? "Signed in").font(.title3.weight(.semibold))
                        Text("\(account.addons.count) add-ons · \(account.streamAddonBases.count) stream sources")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { account.signOut(); core.logOut() } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(ChipButtonStyle(selected: true, accent: .red, accentText: .white))
                }
            } else {
                NavigationLink { LoginView(account: account) } label: {
                    Label("Sign in to your Stremio account", systemImage: "person.crop.circle")
                }
                .buttonStyle(.card)
            }
        }
    }

    // MARK: Streaming server

    private var serverSection: some View {
        section("Streaming Server") {
            HStack(spacing: 16) {
                Circle().fill(serverColor).frame(width: 18, height: 18)
                Text(serverText).font(.title3)
                Spacer()
                Text(StremioServer.isCustom ? "CUSTOM" : "EMBEDDED")
                    .font(.caption.weight(.bold)).tracking(1)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }
            Text(StremioServer.base).font(.callout.monospaced()).foregroundStyle(.secondary)
            NavigationLink {
                ServerConfigView { Task { serverOnline = await StremioServer.isOnline() } }
            } label: {
                Label("Configure server", systemImage: "server.rack")
            }
            .buttonStyle(.card)
        }
    }

    private var serverColor: Color {
        switch serverOnline { case .some(true): .green; case .some(false): .red; default: .yellow }
    }
    private var serverText: String {
        switch serverOnline { case .some(true): "Online"; case .some(false): "Offline"; default: "Checking…" }
    }

    // MARK: Subtitles

    private var subtitleSection: some View {
        section("Subtitles") {
            choiceRow("Size", SubtitleStyle.sizes.map { ($0.id, $0.label) }, selection: $subSize)
            choiceRow("Color", SubtitleStyle.colors.map { ($0.id, $0.label) }, selection: $subColor)
            choiceRow("Background", SubtitleStyle.backgrounds.map { ($0.id, $0.label) }, selection: $subBackground)
            Text("Styles the built-in player's subtitles. Choose which subtitle track to show from the player while watching.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// A labeled row of selectable chips bound to a stored choice (matches the Discover chip style).
    private func choiceRow(_ label: String, _ options: [(id: String, label: String)],
                           selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(options, id: \.id) { opt in
                        Button { selection.wrappedValue = opt.id } label: {
                            Text(opt.label)
                        }
                        .buttonStyle(ChipButtonStyle(selected: selection.wrappedValue == opt.id))
                    }
                }
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        section("About") {
            infoRow("Version", appVersion)
            infoRow("Player", "libmpv · MPVKit")
            infoRow("Server", "Stremio streaming server (nodejs-mobile)")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ", "
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    // MARK: Section chrome

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary).tracking(2)
            content()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        // tvOS focus is spatial: "Log Out" sits far right (after a Spacer) while the next
        // focusable views (Configure server, subtitle chips) are left-aligned, outside the
        // downward beam, so Down would otherwise stick on Log Out. Making each section a focus
        // section lets the engine redirect focus into it even when it's off the movement axis.
        .focusSection()
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }.font(.title3)
    }
}
