import SwiftUI

/// "Import from Nuvio" - lets a Nuvio user bring the Stremio-compatible add-on(s) they already use in
/// Nuvio into VortX. Nuvio (the open-source streaming app) has no account, sync service, or hosted API of
/// its own: it plays through the same Stremio add-on protocol VortX speaks. So there is nothing to sign
/// into here; the only real import action is pasting the add-on manifest URL(s) already configured in
/// Nuvio. VortX keeps its own account and add-on list either way (see SyncSettingsView).
///
/// Mirrors StremioImportView's batch-install card: same copy shape, same CoreBridge.installAddon path
/// (manifest.json suffixing, already-installed dedupe, AddonURLGuard SSRF validation), same success/failure
/// summary. It has no sign-in card, unlike StremioImportView, because there is no account to sign into.
/// VortX keeps NO curated third-party add-on list: the user brings their own manifest URL, never a bundled
/// one.
///
/// Cross-platform (iPhone / iPad / Mac / Apple TV): reached from IntegrationsSettingsView's Nuvio card,
/// which both the iOS and tvOS settings screens push to, so both surfaces get it by construction.
struct NuvioImportView: View {
    @EnvironmentObject private var core: CoreBridge
    @State private var urlsText = ""
    @State private var installing = false
    @State private var summary: String?
    @State private var summaryIsError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Import from Nuvio").screenTitleStyle()

                card {
                    Text("No account to sign into").font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Nuvio plays through Stremio-compatible add-ons. Paste the add-on link you use in Nuvio to bring its catalogs and streams into VortX. VortX keeps its own account and add-on list.")
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                }

                card {
                    Text("Add your Nuvio add-ons").font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Paste add-on manifest URLs, one per line, then install them all in one step.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                    TextField("https://…/manifest.json", text: $urlsText, axis: .vertical)
                        .lineLimit(3...10)
                        .font(.system(size: 15, design: .monospaced))
                        .disableAutocorrection(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .padding(Theme.Space.sm)
                        .background(Theme.Palette.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    Button { installAll() } label: {
                        Label(installing ? "Installing…" : "Install add-on\(trimmedURLs.count == 1 ? "" : "s")",
                              systemImage: "square.and.arrow.down.on.square")
                    }
                    // PrimaryActionStyle paints the label in Theme.Palette.onAccent on the accent fill;
                    // see StremioImportView for why the plain button style is avoided here.
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(installing || trimmedURLs.isEmpty)
                    if let summary {
                        Text(summary).font(Theme.Typography.label)
                            .foregroundStyle(summaryIsError ? Theme.Palette.warn : Theme.Palette.textSecondary)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    @ViewBuilder private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) { content() }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var trimmedURLs: [String] {
        var seen = Set<String>()
        return urlsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }   // drop blanks + duplicate lines
    }

    /// Install every pasted URL through the same engine path every other add-on install uses (the Add-ons
    /// screen's single field, StremioImportView's batch field, Install-by-QR): same manifest.json
    /// normalization, same AddonURLGuard SSRF validation (fetch through AddonURLGuard.fetch, which checks
    /// the resolved host and every redirect hop against the private/loopback/link-local ranges), same
    /// manifest shape check. Reports how many landed and why any failed (deduped, so one bad URL repeated
    /// does not spam the summary).
    private func installAll() {
        let urls = trimmedURLs
        guard !urls.isEmpty else { return }
        installing = true
        summary = nil
        Task { @MainActor in
            var installed = 0
            var failures: [String] = []
            for url in urls {
                if let error = await core.installAddon(urlString: url) { failures.append(error) }
                else { installed += 1 }
            }
            installing = false
            summaryIsError = installed == 0 && !failures.isEmpty
            var message = "Installed \(installed) add-on\(installed == 1 ? "" : "s")."
            if !failures.isEmpty {
                let reasons = Array(Set(failures)).joined(separator: " ")
                message += " \(failures.count) could not be added: \(reasons)"
            }
            summary = message
            if failures.isEmpty { urlsText = "" }
        }
    }
}
