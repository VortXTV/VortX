import SwiftUI

/// Simple search (Cinemeta), reachable from the Search tab.
struct SearchView: View {
    let client: AddonClient
    @State private var query = ""
    @State private var results: [MetaPreview] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TextField("Search movies & series", text: $query)
                .textFieldStyle(.plain).font(.title2).padding(.horizontal, 60).padding(.top, 40)
                .onSubmit { Task { await run() } }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(220), spacing: 28), count: 5), spacing: 28) {
                    ForEach(results) { item in
                        VStack(spacing: 12) {
                            NavigationLink { DetailView(type: item.type, id: item.id, client: client) } label: {
                                PosterImage(item: item)
                            }
                            .buttonStyle(.card)
                            Text(item.name)
                                .font(.caption).lineLimit(1).truncationMode(.tail)
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

    private func run() async {
        guard query.count >= 2 else { return }
        async let movies = try? client.search(type: "movie", query: query)
        async let series = try? client.search(type: "series", query: query)
        results = ((await movies) ?? []) + ((await series) ?? [])
    }
}
