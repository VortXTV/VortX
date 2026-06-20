import SwiftUI

/// "Import from Stremio" - a guided onboarding screen for people arriving from official Stremio (or any
/// Stremio-compatible client). It makes the one real import action obvious (sign in: the engine then pulls
/// that account's add-ons, library, and watch history, since it IS the same engine) and adds a batch add-on
/// installer for the no-account path, so a newcomer is not stuck pasting one manifest URL at a time on the
/// Add-ons screen. Reached from Settings on iOS / Mac / tvOS; mirrors XRDBSettingsView's layout so it reads
/// natively on every platform. Reuses CoreBridge.installAddon, so each URL gets the same validation, the
/// manifest.json suffixing, and the already-installed dedupe the single-add screen uses.
struct StremioImportView: View {
    @EnvironmentObject private var core: CoreBridge
    @State private var urlsText = ""
    @State private var installing = false
    @State private var summary: String?
    @State private var summaryIsError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Import from Stremio").screenTitleStyle()

                card {
                    Text("Already use Stremio?").font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Open Account & sync and sign in with your Stremio account. VortX runs on the same engine, so your add-ons, library, and Continue Watching come across automatically, and stay in sync across your devices. Nothing to export or copy by hand.")
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                }

                card {
                    Text("Add several add-ons at once").font(Theme.Typography.cardTitle)
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
                        Label(installing ? "Installing…" : "Install all add-ons",
                              systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(installing || trimmedURLs.isEmpty)
                    .tint(Theme.Palette.accent)
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

    /// Install every pasted URL through the same engine path the single-add screen uses, then report how
    /// many landed and why any failed (deduped, so one bad URL repeated does not spam the summary).
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
