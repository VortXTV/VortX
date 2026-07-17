import SwiftUI

/// "Integrations" screen: OPTIONAL imports and services that enrich VortX. VortX owns its own account,
/// add-ons, and library (see SyncSettingsView); nothing here is required, and connecting any of these
/// never turns VortX into a client of that service. Order, top to bottom:
///   1. Stremio: bring your Stremio add-ons and library in (StremioConnectCard, reuses LinkLoginView).
///   2. Trakt: scrobble + watchlist (existing card, via ExternalServicesSettingsView).
///   3. SIMKL: mark-watched + plan-to-watch (existing card, via ExternalServicesSettingsView).
///   4. Nuvio: bring the Stremio-compatible add-on(s) you use in Nuvio in (NuvioConnectCard, opens
///      NuvioImportView). Nuvio has no account/sync service of its own, so unlike Stremio there is
///      nothing to sign into; the card just opens the paste-URL importer.
///   5. List import: paste a public Letterboxd / MDBList / Trakt list URL and browse it as a native Home
///      row (ListImportConnectCard, opens ListImportView). On-device only; never touches account/library.
///
/// Cross-platform (iPhone / iPad / Mac / Apple TV): hosted here in SourcesShared and pushed from both the
/// iOS and tvOS settings screens, so both surfaces get the same section by construction (settings parity).
struct IntegrationsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Integrations").screenTitleStyle()
                Text("Optional imports and services that enrich VortX. Connect what you already use; VortX keeps its own account, add-ons, and library either way.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)

                // 1. Stremio, up front as one optional source among the rest.
                StremioConnectCard()

                // 2 + 3. Trakt then SIMKL, reused as-is (each still dormant until its build creds exist).
                ExternalServicesSettingsView()

                // 4. Nuvio: opens the paste-URL importer (WS6).
                NuvioConnectCard()

                // 5. List import: paste a public Letterboxd / MDBList / Trakt list URL and browse it as a
                //    native Home row (ListImport). Optional, on-device only, never touches account/library.
                ListImportConnectCard()
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

/// "Nuvio" card for the Integrations screen: opens `NuvioImportView`, the paste-URL import for bringing a
/// Nuvio user's Stremio-compatible add-on(s) into VortX. Styled to match the Stremio/Trakt/SIMKL cards
/// (surface1, rounded, same title/body type). Unlike those three, Nuvio has no account or sign-in state to
/// reflect here (see NuvioImportView's header comment for why), so this is a plain NavigationLink card
/// rather than an inline connect/disconnect control, matching the AddonsView "Discover add-ons" link.
private struct NuvioConnectCard: View {
    var body: some View {
        NavigationLink { NuvioImportView() } label: {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    Text("Nuvio").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textTertiary)
                }
                Text("Bring the Stremio-compatible add-on you use in Nuvio into VortX. This is optional and separate from your VortX account.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vortxSettingsCard()
        }
        // tvOS: `.plain` kept the system focus platter, which drew a white slab over this card and its
        // neighbours. The card draws its own `.vortxSettingsCard()` surface, so it takes the card ring.
        .vortxCardButton()
    }
}

/// "Import a list" card for the Integrations screen: opens `ListImportView`, the paste-URL import that turns
/// a public Letterboxd / MDBList / Trakt list into a native Home row. Styled to match the other cards.
private struct ListImportConnectCard: View {
    var body: some View {
        NavigationLink { ListImportView() } label: {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    Text("Import a list").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textTertiary)
                }
                Text("Paste a public Letterboxd, MDBList, or Trakt list link and browse it as a Home row. On-device only and separate from your VortX account.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vortxSettingsCard()
        }
        // Same platter bug as the Nuvio card above; same `.vortxSettingsCard()` surface, same card ring.
        .vortxCardButton()
    }
}

/// Paste-URL importer for public lists. The user pastes a Letterboxd / MDBList / Trakt list link; on import
/// the coordinator (`ListImport.importList`) fetches and resolves it to engine-safe ids, this view previews
/// the resolved titles, and registers the catalog with `ImportedCatalogs.shared` so it paints as a Home row.
/// Fail-soft: a bad or private link shows the typed `ImportedListError` copy verbatim, never a crash. Nothing
/// here writes account or library state (invariant): the list lives only in this app's own preferences.
///
/// Cross-platform (iPhone / iPad / Mac / Apple TV): hosted in SourcesShared and reached from the Integrations
/// screen both surfaces push to, so both get it by construction (settings parity).
struct ListImportView: View {
    @State private var urlText = ""
    @State private var importing = false
    @State private var summary: String?
    @State private var summaryIsError = false
    @State private var preview: ImportedListCatalog?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Import a list").screenTitleStyle()

                card {
                    Text("Paste a public list link").font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Letterboxd, MDBList, or Trakt. The list must be public. It becomes a Home row you can browse; it never changes your account or library.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                    TextField("https://letterboxd.com/…/list/…", text: $urlText, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.system(size: 15, design: .monospaced))
                        .disableAutocorrection(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .padding(Theme.Space.sm)
                        .background(Theme.Palette.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    Button { importList() } label: {
                        Label(importing ? "Importing…" : "Import list", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(importing || trimmedURL.isEmpty)
                    if let summary {
                        Text(summary).font(Theme.Typography.label)
                            .foregroundStyle(summaryIsError ? Theme.Palette.warn : Theme.Palette.textSecondary)
                    }
                }

                // Preview of what resolved, so a successful import visibly landed before the user leaves.
                if let preview, !preview.isEmpty {
                    card {
                        Text(preview.title).font(Theme.Typography.cardTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text("\(preview.items.count) title\(preview.items.count == 1 ? "" : "s") added as a Home row.")
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                        ForEach(preview.items.prefix(12)) { item in
                            Text(item.name).font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                        }
                        if preview.items.count > 12 {
                            Text("and \(preview.items.count - 12) more")
                                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                        }
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

    private var trimmedURL: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Fetch + resolve the pasted list, then preview and register it. On failure the typed error's user-facing
    /// copy is shown verbatim. Registration is on the main actor (`ImportedCatalogs.shared` is @MainActor).
    private func importList() {
        let url = trimmedURL
        guard !url.isEmpty else { return }
        importing = true
        summary = nil
        Task { @MainActor in
            let result = await ListImport.importList(from: url)
            importing = false
            switch result {
            case .success(let catalog):
                preview = catalog
                summaryIsError = false
                summary = "Imported \"\(catalog.title)\"."
                ImportedCatalogs.shared.register(catalog)
                urlText = ""
            case .failure(let error):
                preview = nil
                summaryIsError = true
                summary = error.localizedDescription
            }
        }
    }
}
