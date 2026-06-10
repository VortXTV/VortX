import SwiftUI

/// Search across every installed addon, on the engine (CatalogsWithExtra with a search extra).
struct SearchView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @State private var query = ""
    private let columns = Array(repeating: GridItem(.fixed(kPosterWidth), spacing: Theme.Space.lg), count: 6)

    var body: some View {
        Group {
            if account.isSignedIn { results } else { CoreEmptyState.signedOut }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Search").screenTitleStyle()
                .padding(.horizontal, Theme.Space.screenEdge).padding(.top, Theme.Space.lg)
            searchField
            ScrollView {
                if core.searchResults.isEmpty {
                    Text(query.isEmpty ? "Search across everything your addons cover."
                                       : "No matches for \"\(query)\".")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity).padding(.top, Theme.Space.xxl)
                } else {
                    LazyVGrid(columns: columns, spacing: Theme.Space.xl) {
                        ForEach(core.searchResults) { item in
                            PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                                       menu: .catalog)
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenEdge).padding(.top, Theme.Space.sm)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.textTertiary)
            TextField("Movies, series, anything your addons cover", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.Palette.textPrimary)
                .onSubmit { core.search(query) }
        }
        .font(Theme.Typography.body)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .padding(.horizontal, Theme.Space.screenEdge)
    }
}
