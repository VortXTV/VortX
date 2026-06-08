import SwiftUI

/// Library, driven by the **stremio-core** engine (`LibraryWithFilters`): the user's saved titles with
/// type + sort filters. Auto-refreshes as the library changes (add/remove/mark watched), no reload.
struct LibraryView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    private let columns = Array(repeating: GridItem(.fixed(kPosterWidth), spacing: Theme.Space.lg), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text("Library").screenTitleStyle().padding(.horizontal, Theme.Space.screenEdge)
                    if let library = core.library {
                        filters(library.selectable)
                        if library.catalog.isEmpty {
                            hint("Your library is empty. Add titles to your library in Stremio and they will show up here.")
                        } else {
                            grid(library.catalog)
                        }
                    } else if account.isSignedIn {
                        ProgressView().controlSize(.large).tint(Theme.Palette.accent)
                            .padding(Theme.Space.xxl).frame(maxWidth: .infinity)
                    } else {
                        CoreEmptyState.signedOut
                    }
                }
                .padding(.vertical, Theme.Space.xl)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        // Reload while empty: the library syncs from the API asynchronously after sign-in, so the
        // first load can land before ctx.library is populated. Revisiting the tab refills it.
        .onAppear { if core.library?.catalog.isEmpty != false { core.loadLibrary() } }
    }

    private func filters(_ selectable: CoreLibrarySelectable) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(selectable.types) { type in
                        Button { core.selectLibrary(type.request) } label: { Text(type.label) }
                            .buttonStyle(ChipButtonStyle(selected: type.selected))
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs / 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(selectable.sorts) { sort in
                        Button { core.selectLibrary(sort.request) } label: { Text(sort.label) }
                            .buttonStyle(ChipButtonStyle(selected: sort.selected))
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs / 2)
            }
        }
    }

    private func grid(_ items: [CoreCWItem]) -> some View {
        LazyVGrid(columns: columns, spacing: Theme.Space.xl) {
            ForEach(items) { item in
                PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                           progress: item.progress > 0 ? item.progress : nil)
            }
        }
        .padding(.horizontal, Theme.Space.screenEdge).padding(.top, Theme.Space.sm)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.top, Theme.Space.lg)
    }
}
