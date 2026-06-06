import SwiftUI

/// Add-ons: the addons installed on the signed-in account (Cinemeta, Debridio, Trakt, …),
/// with what each provides (catalogs / streams / meta / subtitles).
struct AddonsView: View {
    @EnvironmentObject private var account: StremioAccount

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Add-ons").font(.system(size: 56, weight: .heavy))
                    if !account.isSignedIn {
                        hint("Sign in (Settings tab) to see your installed add-ons.")
                    } else if account.addons.isEmpty {
                        hint("No add-ons found on your account yet.")
                    } else {
                        ForEach(account.addons, id: \.transportUrl) { addon in
                            addonRow(addon)
                        }
                    }
                }
                .padding(60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.ignoresSafeArea())
        }
    }

    private func addonRow(_ addon: AddonDescriptor) -> some View {
        HStack(alignment: .top, spacing: 22) {
            Image(systemName: addon.providesStreams ? "play.rectangle.on.rectangle.fill" : "puzzlepiece.extension.fill")
                .font(.system(size: 40)).foregroundStyle(addon.providesStreams ? .cyan : .secondary)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 8) {
                Text(addon.manifest.name).font(.title3.weight(.semibold))
                Text(capabilities(addon)).font(.callout).foregroundStyle(.secondary)
                Text(host(addon.transportUrl)).font(.caption.monospaced()).foregroundStyle(.secondary.opacity(0.7))
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    /// "Catalogs · Streams · Subtitles", the resource kinds the addon exposes.
    private func capabilities(_ addon: AddonDescriptor) -> String {
        var caps: [String] = []
        let res = Set(addon.manifest.resources.map { $0.name.lowercased() })
        if addon.manifest.catalogs?.isEmpty == false { caps.append("Catalogs") }
        if res.contains("stream") { caps.append("Streams") }
        if res.contains("meta") { caps.append("Metadata") }
        if res.contains("subtitles") { caps.append("Subtitles") }
        return caps.isEmpty ? "Add-on" : caps.joined(separator: " · ")
    }

    /// Show only the host (the full transportUrl can embed a debrid config token).
    private func host(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.title3).foregroundStyle(.secondary)
    }
}
