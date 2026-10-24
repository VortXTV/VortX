import SwiftUI

/// Metadata from the existing catalog worker appears INSIDE HomeRail.collectionsHub. The current
/// classic hub remains the fallback surface, so the Discover fallback is not duplicated on Home.
@MainActor struct CurationDefaultsHomeShelf: View {
    var onOpen: (MetaPreview) -> Void = { _ in }
    @ObservedObject private var defaults = CurationDefaultsModel.shared
    @ObservedObject private var store = ForYouStore.shared
    @StateObject private var lifetime = CurationReadLifetime()

    private var ticket: CurationReadTicket {
        .init(lifetime: lifetime, generation: lifetime.generation, legacy: store.collections, importFingerprints: [:])
    }
    private var collections: [CurationCollection] {
        guard ticket.isCurrent else { return [] }
        return defaults.currentCollections().filter { $0.id != "vortx.discover" }
    }
    var body: some View {
        Group {
            if !collections.isEmpty {
                CurationCollectionShelf(collections: collections, lifetime: lifetime.artworkLifetime) { collection in
                    CurationCollectionDestination(collection: collection, ticket: ticket, onOpen: onOpen)
                }
            }
        }
        .onAppear { lifetime.renew() }
        .onValueChange(of: store.profileID) { _ in lifetime.renew() }
        .task { await defaults.loadIfNeeded() }
    }
}
