import SwiftUI

/// "My Trakt lists": pick which of your own Trakt lists (and the ones you liked) show up as Home rows.
///
/// READ-ONLY by construction, and that is the whole design:
///   - Adding a row calls `TraktMyListsClient.importList` -> `ImportedCatalogs.register`, which writes only
///     this app's own preferences. It never writes an engine `libraryItem` or an account document.
///   - Removing a row calls `ImportedCatalogs.remove`, which removes the ROW, not the list. The list on
///     Trakt is untouched. The copy below says so plainly, because a "Remove" button that might delete the
///     user's actual Trakt list would be a genuinely frightening thing to click.
///   - There is no add-title, reorder, or rename-on-Trakt affordance here. List editing lives on Trakt;
///     library editing lives in VortX. Neither one learns about the other, so neither can overwrite it.
///
/// Cross-platform (iPhone / iPad / Mac / Apple TV): hosted in SourcesShared and reached from the
/// Integrations screen that BOTH the iOS and tvOS settings screens push, so both surfaces get this by
/// construction rather than by two copies kept in step by hand (settings parity).
struct TraktMyListsView: View {
    @ObservedObject private var imported = ImportedCatalogs.shared

    @State private var lists: [TraktMyListsClient.MyList] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var connected = false
    /// Row id currently being fetched/resolved, so only that row shows a spinner.
    @State private var busyID: String?
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("My Trakt lists").screenTitleStyle()
                Text("Show your own Trakt lists, and the ones you liked, as rows on Home. VortX reads them only. Your lists stay on Trakt and your VortX library stays yours; adding a row here changes neither.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)

                if let message {
                    Text(message)
                        .font(Theme.Typography.label)
                        .foregroundStyle(messageIsError ? Theme.Palette.warn : Theme.Palette.textSecondary)
                }

                content
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if !TraktAuth.isConfigured {
            notice("Trakt is not available in this build.")
        } else if !connected && loaded {
            notice("Connect Trakt from Integrations to see your lists here.")
        } else if loading && lists.isEmpty {
            notice("Loading your lists…")
        } else if loaded && lists.isEmpty {
            notice("No lists found on your Trakt account yet. Lists you make or like on Trakt show up here.")
        } else {
            ForEach(TraktMyListsClient.Kind.allCasesInOrder, id: \.self) { kind in
                let group = lists.filter { $0.kind == kind }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text(kind == .personal ? "Your lists" : "Lists you liked")
                            .font(Theme.Typography.cardTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        ForEach(group) { list in
                            row(for: list)
                        }
                    }
                }
            }
        }
    }

    /// One list: name, provenance chips, and a single add/remove toggle. Whether it is already a row is read
    /// live from `ImportedCatalogs`, so a row removed on the manager screen reflects here immediately.
    @ViewBuilder private func row(for list: TraktMyListsClient.MyList) -> some View {
        let isAdded = imported.catalog(withID: list.id) != nil
        let isBusy = busyID == list.id

        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(list.name)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)

            HStack(spacing: Theme.Space.xs) {
                chip(list.privacyLabel)
                chip("\(list.itemCount) title\(list.itemCount == 1 ? "" : "s")")
                if list.kind == .liked { chip("by \(list.owner)") }
            }

            Button {
                isAdded ? removeRow(list) : addRow(list)
            } label: {
                Label(buttonTitle(isAdded: isAdded, isBusy: isBusy),
                      systemImage: isAdded ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(isBusy)

            if isAdded {
                Text("Showing on Home. Removing takes the row out of VortX; your list on Trakt is not changed.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    private func buttonTitle(isAdded: Bool, isBusy: Bool) -> String {
        if isBusy { return isAdded ? "Removing…" : "Adding…" }
        return isAdded ? "Remove row" : "Show as a row"
    }

    @ViewBuilder private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, 4)
            .background(Theme.Palette.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }

    @ViewBuilder private func notice(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vortxSettingsCard()
    }

    // MARK: - Actions

    /// Load the picker. Never blanks a populated screen on a flaky refresh. MainActor-isolated because every
    /// line below writes view state; the awaits inside are the network legs, which hop off on their own.
    @MainActor
    private func load() async {
        guard TraktAuth.isConfigured else { loaded = true; return }
        loading = true
        let signedIn = await TraktAuth.shared.isSignedIn
        let fetched = signedIn ? await TraktMyListsClient.allLists() : []
        connected = signedIn
        if !fetched.isEmpty || !signedIn { lists = fetched }
        loading = false
        loaded = true
    }

    /// Fetch + resolve the list and register it as a Home row. Fail-soft: the typed error's copy is shown
    /// verbatim and nothing is registered, so a partial fetch never paints a half row.
    private func addRow(_ list: TraktMyListsClient.MyList) {
        busyID = list.id
        message = nil
        Task { @MainActor in
            let result = await TraktMyListsClient.importList(list)
            busyID = nil
            switch result {
            case .success(let catalog):
                ImportedCatalogs.shared.register(catalog)
                messageIsError = false
                message = "Added \"\(catalog.title)\" as a Home row with \(catalog.items.count) title\(catalog.items.count == 1 ? "" : "s")."
            case .failure(let error):
                messageIsError = true
                message = error.localizedDescription
            }
        }
    }

    /// Remove the ROW only. `ImportedCatalogs.remove` touches this app's preferences and nothing else, so the
    /// list on Trakt is untouched by construction, not just by intent.
    private func removeRow(_ list: TraktMyListsClient.MyList) {
        ImportedCatalogs.shared.remove(id: list.id)
        messageIsError = false
        message = "Removed \"\(list.name)\" from Home. Your list on Trakt is unchanged."
    }
}

extension TraktMyListsClient.Kind {
    /// Display order for the grouped picker: your own lists before lists you liked.
    static var allCasesInOrder: [TraktMyListsClient.Kind] { [.personal, .liked] }
}
