import SwiftUI

/// Search across your installed addons, powered by the engine (CatalogsWithExtra with a search extra).
struct SearchView: View {
    @EnvironmentObject private var core: CoreBridge
    @State private var query = ""
    private let columns = Array(repeating: GridItem(.fixed(220), spacing: 28), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TextField("Search movies & series", text: $query)
                .textFieldStyle(.plain).font(.title2).padding(.horizontal, 60).padding(.top, 40)
                .onSubmit { core.search(query) }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(core.searchResults) { item in
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
                .padding(60)
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}
