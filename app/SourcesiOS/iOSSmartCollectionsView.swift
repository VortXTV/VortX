import SwiftUI

/// Existing Library route and existing detail callback retained. Catalog content now loads only
/// inside a visible selected folder/source in the common collection destination.
@MainActor struct iOSSmartCollectionsView: View {
    let onOpen: (RailItem) -> Void

    var body: some View {
        CurationCollectionsLibrary { item in
            onOpen(RailItem(id: item.id, type: item.type, name: item.name, poster: item.poster, progress: 0))
        }
        .navigationTitle(Text("Collections"))
    }
}
