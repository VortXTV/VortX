import SwiftUI

/// Add-ons installed on your account, read live from the engine. You can remove a non-default addon
/// here; install new ones from the Stremio web or mobile app (they sync down on next launch).
struct AddonsView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Add-ons").font(.system(size: 56, weight: .heavy))
                    if !account.isSignedIn {
                        hint("Sign in (Settings tab) to see your installed add-ons.")
                    } else if core.addons.isEmpty {
                        hint("No add-ons found on your account yet.")
                    } else {
                        ForEach(core.addons) { addon in addonRow(addon) }
                    }
                }
                .padding(60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.ignoresSafeArea())
        }
    }

    private func addonRow(_ addon: CoreDescriptor) -> some View {
        HStack(alignment: .top, spacing: 22) {
            Image(systemName: addon.providesStreams ? "play.rectangle.on.rectangle.fill" : "puzzlepiece.extension.fill")
                .font(.system(size: 40)).foregroundStyle(addon.providesStreams ? .cyan : .secondary)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 8) {
                Text(addon.manifest.name).font(.title3.weight(.semibold))
                Text(addon.capabilities).font(.callout).foregroundStyle(.secondary)
                Text(addon.host).font(.caption.monospaced()).foregroundStyle(.secondary.opacity(0.7))
            }
            Spacer()
            if !addon.isProtected {
                Button(role: .destructive) { core.uninstallAddon(addon) } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.title3).foregroundStyle(.secondary)
    }
}
