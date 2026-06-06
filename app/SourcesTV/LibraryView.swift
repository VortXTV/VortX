import SwiftUI

/// Library, driven by the **stremio-core** engine (`LibraryWithFilters`): the user's saved titles with
/// type + sort filters. Auto-refreshes as the library changes (add/remove/mark watched), no reload.
struct LibraryView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    private let columns = Array(repeating: GridItem(.fixed(220), spacing: 28), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Library").font(.system(size: 56, weight: .heavy)).padding(.horizontal, 60)
                    if let library = core.library {
                        filters(library.selectable)
                        if library.catalog.isEmpty {
                            hint("No titles here. Add titles to your library in Stremio and they'll show up.")
                        } else {
                            grid(library.catalog)
                        }
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
        .onAppear { if core.library == nil { core.loadLibrary() } }
    }

    private func filters(_ selectable: CoreLibrarySelectable) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(selectable.types) { type in
                        Button { core.selectLibrary(type.request) } label: { Text(type.label) }
                            .buttonStyle(ChipButtonStyle(selected: type.selected))
                    }
                }
                .padding(.horizontal, 60).padding(.vertical, 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(selectable.sorts) { sort in
                        Button { core.selectLibrary(sort.request) } label: { Text(sort.label) }
                            .buttonStyle(ChipButtonStyle(selected: sort.selected))
                    }
                }
                .padding(.horizontal, 60).padding(.vertical, 2)
            }
        }
    }

    private func grid(_ items: [CoreCWItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 28) {
            ForEach(items) { item in
                VStack(spacing: 12) {
                    NavigationLink {
                        DetailView(type: item.type, id: item.id)
                    } label: {
                        VStack(spacing: 0) {
                            CorePoster(item.poster)
                            if item.progress > 0 {
                                ProgressView(value: item.progress).tint(.cyan).padding(.top, 6)
                            }
                        }
                    }
                    .buttonStyle(.card)
                    Text(item.name).font(.caption).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.secondary).frame(width: 220)
                }
                .frame(width: 220)
            }
        }
        .padding(.horizontal, 60)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.title3).foregroundStyle(.secondary).padding(.horizontal, 60)
    }
}
