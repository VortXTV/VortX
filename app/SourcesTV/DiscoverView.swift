import SwiftUI

/// Discover, driven by the **stremio-core** engine (`CatalogWithFilters`): pick a type, catalog, and
/// genre, see the full grid. Each chip carries the engine's own `request`, dispatched back on tap, so
/// type/catalog/genre selection is exactly the official app's behavior.
struct DiscoverView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    private let columns = Array(repeating: GridItem(.fixed(220), spacing: 28), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Discover").font(.system(size: 56, weight: .heavy)).padding(.horizontal, 60)
                    if let discover = core.discover {
                        typeChips(discover.selectable.types)
                        catalogChips(discover.selectable.catalogs)
                        genreChips(discover.selectable.extra)
                        grid(discover.items)
                    } else if account.isSignedIn {
                        ProgressView().controlSize(.large).padding(60).frame(maxWidth: .infinity)
                    } else {
                        CoreEmptyState.signedOut
                    }
                }
                .padding(.vertical, 40)
            }
            .background(Color.black.ignoresSafeArea())
        }
        .onAppear { if core.discover == nil { core.loadDiscover() } }
    }

    private func typeChips(_ types: [CoreSelectableType]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(types) { type in
                    Button { core.selectDiscover(type.request) } label: { Text(type.type.capitalized) }
                        .buttonStyle(ChipButtonStyle(selected: type.selected))
                }
            }
            .padding(.horizontal, 60).padding(.vertical, 4)
        }
    }

    private func catalogChips(_ catalogs: [CoreSelectableCatalog]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(catalogs) { catalog in
                    Button { core.selectDiscover(catalog.request) } label: { Text(catalog.catalog).lineLimit(1) }
                        .buttonStyle(ChipButtonStyle(selected: catalog.selected))
                }
            }
            .padding(.horizontal, 60).padding(.vertical, 4)
        }
    }

    /// Genre filter chips, only when the selected catalog declares a "genre" extra.
    @ViewBuilder private func genreChips(_ extra: [CoreSelectableExtra]) -> some View {
        if let genre = extra.first(where: { $0.name.caseInsensitiveCompare("genre") == .orderedSame }),
           !genre.options.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(genre.options) { option in
                        Button { core.selectDiscover(option.request) } label: { Text(option.label).lineLimit(1) }
                            .buttonStyle(ChipButtonStyle(selected: option.selected))
                    }
                }
                .padding(.horizontal, 60).padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private func grid(_ items: [CoreMeta]) -> some View {
        if items.isEmpty {
            ProgressView().controlSize(.large).padding(60).frame(maxWidth: .infinity)
        } else {
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(items) { item in
                    VStack(spacing: 12) {
                        NavigationLink {
                            DetailView(type: item.type, id: item.id)
                        } label: { CorePoster(item.poster) }
                        .buttonStyle(.card)
                        Text(item.name).font(.caption).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(.secondary).frame(width: 220)
                    }
                    .frame(width: 220)
                }
            }
            .padding(.horizontal, 60)
        }
    }
}
