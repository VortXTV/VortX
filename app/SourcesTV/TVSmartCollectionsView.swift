import SwiftUI

/// Existing Library route retained. Real source cards remain ExternalWatchlistRow cards, with the
/// same DetailView and playback path as Home. The collection shell does not preload every rule.
@MainActor struct TVSmartCollectionsView: View {
    var body: some View { CurationCollectionsLibrary() }
}

/// Existing inert builder preview retained; collection browsing itself uses the common source rows.
struct TVSmartCollectionPreview: View {
    let items: [MetaPreview]
    let loading: Bool

    var body: some View {
        if items.isEmpty {
            if loading { ProgressView() }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id, onDetails: {})
                    }
                }
                .padding(.vertical, Theme.Space.lg)
            }
        }
    }
}
