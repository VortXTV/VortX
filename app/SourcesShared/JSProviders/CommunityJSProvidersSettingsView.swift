import SwiftUI

/// Cross-platform management for user-installed community JavaScript add-ons. The view is deliberately
/// separate from the source runtime: installing a manifest never enables execution, and the remote gate stays
/// authoritative even when the user has explicitly enabled this device.
struct CommunityJSProvidersSettingsView: View {
    @ObservedObject private var store = JSProviderStore.shared
    @State private var manifestText = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var confirmRemoval = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Community JavaScript add-ons").screenTitleStyle()
                Text("Paste your own manifest URL to add compatible community JavaScript providers. Provider code runs on this device only, and it remains off until both this device and the service rollout are enabled.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)

                card {
                    Toggle("Enable community JavaScript add-ons on this device", isOn: $store.userEnabled)
                        .tint(Theme.Palette.accent)
                    Text(featureStatus)
                        .font(Theme.Typography.label)
                        .foregroundStyle(store.isFeatureEnabled ? Theme.Palette.textSecondary : Theme.Palette.warn)
                }

                card {
                    Text("Paste a manifest URL").font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("The manifest and provider files must use a public HTTP or HTTPS URL. Private-network addresses and oversized files are refused.")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    TextField("https://example.com/manifest.json", text: $manifestText, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.system(size: 15, design: .monospaced))
                        .disableAutocorrection(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .padding(Theme.Space.sm)
                        .vortxGlassField(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    Button { install() } label: {
                        Label(store.isInstalling ? "Adding…" : "Add manifest", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(store.isInstalling || trimmedManifest.isEmpty)
                    statusRow
                }

                if !store.providers.isEmpty {
                    card {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.repoName ?? "Installed manifest")
                                    .font(Theme.Typography.cardTitle)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Text("\(store.providers.count) installed provider\(store.providers.count == 1 ? "" : "s")")
                                    .font(Theme.Typography.label)
                                    .foregroundStyle(Theme.Palette.textTertiary)
                            }
                            Spacer()
                            Button { refresh() } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(ChipButtonStyle())
                            .disabled(store.isInstalling)
                        }

                        ForEach(store.providers) { provider in
                            HStack(spacing: Theme.Space.sm) {
                                Image(systemName: provider.supports(mediaType: "movie") && provider.supports(mediaType: "tv")
                                      ? "film.stack" : "film")
                                    .foregroundStyle(Theme.Palette.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.name).font(Theme.Typography.body)
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                    Text(provider.supportedTypes.joined(separator: " · "))
                                        .font(Theme.Typography.label)
                                        .foregroundStyle(Theme.Palette.textTertiary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, Theme.Space.xs)
                        }

                        Button(role: .destructive) { confirmRemoval = true } label: {
                            Label("Remove manifest and providers", systemImage: "trash")
                        }
                        .buttonStyle(ChipButtonStyle())
                    }
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { manifestText = store.manifestURLString }
        .confirmationDialog("Remove community JavaScript add-ons?", isPresented: $confirmRemoval,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.removeAll()
                manifestText = ""
                statusMessage = "Removed the manifest and its cached providers."
                statusIsError = false
            }
        } message: {
            Text("This removes the saved manifest URL and downloaded provider code from this device.")
        }
    }

    @ViewBuilder private var statusRow: some View {
        if let statusMessage {
            Text(statusMessage)
                .font(Theme.Typography.label)
                .foregroundStyle(statusIsError ? Theme.Palette.warn : Theme.Palette.textSecondary)
        }
    }

    private var trimmedManifest: String {
        manifestText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var featureStatus: String {
        if store.isFeatureEnabled { return "Enabled. Installed providers can contribute sources." }
        if store.userEnabled { return "Enabled locally. Waiting for the service rollout to enable execution." }
        return "Disabled. Installing a manifest does not run provider code."
    }

    @ViewBuilder private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) { content() }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vortxSettingsCard()
    }

    private func install() {
        let raw = trimmedManifest
        guard !raw.isEmpty else { return }
        Task { @MainActor in
            let result = await store.install(from: raw)
            statusMessage = result.message
            statusIsError = result.failed
            if !result.failed { manifestText = store.manifestURLString }
        }
    }

    private func refresh() {
        Task { @MainActor in
            guard let result = await store.refreshFromStoredManifest() else {
                statusMessage = "No manifest is installed."
                statusIsError = true
                return
            }
            statusMessage = result.message
            statusIsError = result.failed
        }
    }
}
