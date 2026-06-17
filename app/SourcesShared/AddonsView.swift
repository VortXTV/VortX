import SwiftUI

/// Add-ons installed on your account, read live from the engine. Install one by its manifest URL,
/// or remove a non-default add-on here. Changes sync to your account and to the official apps.
struct AddonsView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @State private var newAddonURL = ""
    @State private var installing = false
    @State private var installMessage: String?
    @State private var installFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Add-ons").screenTitleStyle()
                    if !account.isSignedIn {
                        hint("Sign in to manage your add-ons. They sync across your devices and the official apps.")
                    } else {
                        installSection
                        if core.addons.isEmpty {
                            hint("No add-ons yet. Paste an add-on's manifest URL above to install one.")
                        } else {
                            NavigationLink { CatalogManagerView() } label: {
                                HStack(spacing: Theme.Space.md) {
                                    Label("Customize catalogs", systemImage: "slider.horizontal.3")
                                        .font(Theme.Typography.cardTitle)
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textTertiary)
                                }
                                .padding(Theme.Space.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            ForEach(core.addons) { addon in addonRow(addon) }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.screenInset)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Add an add-on")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Space.md) {
                TextField("https://…/manifest.json", text: $newAddonURL)
                    .font(.system(size: 16, design: .monospaced))
                    .disableAutocorrection(true)
                    .frame(maxWidth: 560)
                Button(installing ? "Installing…" : "Install") { install() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(installing || newAddonURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let installMessage {
                Text(installMessage)
                    .font(Theme.Typography.label)
                    .foregroundStyle(installFailed ? Theme.Palette.danger : Theme.Palette.textSecondary)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func install() {
        installing = true
        installMessage = nil
        let url = newAddonURL
        Task { @MainActor in
            let error = await core.installAddon(urlString: url)
            installing = false
            installFailed = error != nil
            if let error {
                installMessage = error
            } else {
                installMessage = "Installed."
                newAddonURL = ""
            }
        }
    }

    private func addonRow(_ addon: CoreDescriptor) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: addon.providesStreams ? "play.rectangle.on.rectangle.fill" : "puzzlepiece.extension.fill")
                .font(.system(size: 36))
                .foregroundStyle(addon.providesStreams ? Theme.Palette.accent : Theme.Palette.textTertiary)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 8) {
                Text(addon.manifest.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text(addon.capabilities).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                Text(addon.host).font(.system(size: 16, design: .monospaced)).foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.sm)
            if !addon.isProtected {
                Button { core.uninstallAddon(addon) } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(ChipButtonStyle(selected: true, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
                    .fixedSize()   // keep the Remove chip at its intrinsic width so a narrow phone row can't squeeze the label to one glyph per line
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.top, Theme.Space.sm)
    }
}
