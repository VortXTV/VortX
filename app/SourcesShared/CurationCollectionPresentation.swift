import SwiftUI

/// Stable partition only: a new render never randomly reorders folders or moves focus between IDs.
enum CurationPresentationPolicy {
    static func ordered(_ collections: [CurationCollection]) -> [CurationCollection] {
        collections.filter(\.pinned) + collections.filter { !$0.pinned }
    }

    static func resolvedLayout(_ layout: CurationPresentation.Layout,
                               following preference: CurationPresentation.Layout) -> CurationPresentation.Layout {
        guard layout == .followLayout else { return layout }
        return preference == .followLayout ? .grid : preference
    }

    static func aspectRatio(_ shape: CurationPresentation.TileShape) -> CGFloat {
        switch shape {
        case .poster: return 2.0 / 3.0
        case .square: return 1
        case .landscape: return 16.0 / 9.0
        }
    }

    /// All is a view over the ordered folders. It does not copy sources or issue catalog requests.
    static func visibleFolders(_ collection: CurationCollection, selectedID: String?) -> [CurationFolder] {
        if selectedID == nil, collection.presentation.showAll { return collection.folders }
        let selected = selectedID.flatMap { id in collection.folders.first { $0.id == id } }
        return (selected ?? collection.folders.first).map { [$0] } ?? []
    }
}

/// Used by the existing Collections screen and by the existing .smartCollections Home section.
/// Navigation content is supplied by the caller so title taps retain the platform's real detail route.
struct CurationCollectionShelf<Destination: View>: View {
    let collections: [CurationCollection]
    let lifetime: CurationArtworkLifetime
    let destination: (CurationCollection) -> Destination

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Theme.Space.md) {
                ForEach(CurationPresentationPolicy.ordered(collections)) { collection in
                    NavigationLink {
                        destination(collection)
                    } label: {
                        CurationCollectionTile(collection: collection, lifetime: lifetime)
                            .frame(width: 240)
                    }
                    .buttonStyle(RowFocusStyle())
                    .accessibilityLabel(collection.name)
                    .accessibilityHint("Open collection folders")
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.sm)
        }
        .curationFocusSection()
    }
}

/// A common collection view, whether authored in VortX, shipped as a starter, or imported by the user.
/// Only a visible folder's supplied content can load titles. Grid navigation creates no catalog jobs.
@MainActor struct CurationCollectionPage<FolderContent: View>: View {
    let collection: CurationCollection
    let lifetime: CurationArtworkLifetime
    let readTicket: CurationReadTicket
    let followLayout: CurationPresentation.Layout
    let folderContent: (CurationFolder) -> FolderContent
    @State private var selectedFolderID: String?

    init(collection: CurationCollection, lifetime: CurationArtworkLifetime,
         readTicket: CurationReadTicket, followLayout: CurationPresentation.Layout,
         @ViewBuilder folderContent: @escaping (CurationFolder) -> FolderContent) {
        self.collection = collection
        self.lifetime = lifetime
        self.readTicket = readTicket
        self.followLayout = followLayout
        self.folderContent = folderContent
        _selectedFolderID = State(initialValue: collection.presentation.showAll ? nil : collection.folders.first?.id)
    }

    private var layout: CurationPresentation.Layout {
        CurationPresentationPolicy.resolvedLayout(collection.presentation.layout, following: followLayout)
    }

    var body: some View {
        CurationReadScope(ticket: readTicket) {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                CurationCollectionHeader(collection: collection, lifetime: lifetime)
                if collection.folders.isEmpty {
                    Text("No folders in this collection.")
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    switch layout {
                    case .grid:
                        folderGrid
                    case .tabs:
                        tabs
                        folderRows(CurationPresentationPolicy.visibleFolders(collection, selectedID: selectedFolderID))
                    case .rows, .followLayout:
                        folderRows(collection.folders)
                    }
                }
            }
            .padding(Theme.Space.screenInset)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        .onValueChange(of: collection.id) { _ in resetSelection() }
        .onValueChange(of: collection.folders.map(\.id)) { ids in
            if let selectedFolderID, !ids.contains(selectedFolderID) { resetSelection() }
        }
        .onValueChange(of: collection.presentation.showAll) { showAll in
            if !showAll, selectedFolderID == nil { selectedFolderID = collection.folders.first?.id }
        }
    }

    private var folderGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300), alignment: .top)],
                  alignment: .leading, spacing: Theme.Space.lg) {
            if collection.presentation.showAll {
                NavigationLink {
                    CurationReadScope(ticket: readTicket) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                            Text("All").screenTitleStyle()
                            folderRows(collection.folders)
                        }
                        .padding(Theme.Space.screenInset)
                    }
                    .background(Theme.Palette.canvas.ignoresSafeArea())
                    #if os(macOS)
                    .macBackAffordance()
                    #endif
                    }
                } label: {
                    Label("All", systemImage: "square.grid.2x2")
                        .font(Theme.Typography.cardTitle)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .padding(Theme.Space.md)
                        .vortxSettingsCard()
                }
                .buttonStyle(RowFocusStyle())
                .accessibilityHint("Browse sources from all folders in order")
            }
            ForEach(collection.folders) { folder in
                NavigationLink {
                    CurationReadScope(ticket: readTicket) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                            CurationFolderHeader(folder: folder, collectionID: collection.id, lifetime: lifetime)
                            folderContent(folder)
                        }
                        .padding(Theme.Space.screenInset)
                    }
                    .background(Theme.Palette.canvas.ignoresSafeArea())
                    #if os(macOS)
                    .macBackAffordance()
                    #endif
                    }
                } label: {
                    CurationFolderTile(folder: folder, collectionID: collection.id, lifetime: lifetime)
                }
                .buttonStyle(RowFocusStyle())
                .accessibilityLabel(folder.name)
                .accessibilityHint("Open folder sources")
            }
        }
        .curationFocusSection()
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                if collection.presentation.showAll {
                    tab(String(localized: "All"), id: nil)
                }
                ForEach(collection.folders) { folder in tab(folder.name, id: folder.id) }
            }
            .padding(.vertical, Theme.Space.xs)
        }
        .curationFocusSection()
    }

    private func tab(_ name: String, id: String?) -> some View {
        Button(name) { selectedFolderID = id }
            .buttonStyle(ChipButtonStyle(selected: selectedFolderID == id))
            .accessibilityAddTraits(selectedFolderID == id ? .isSelected : [])
    }

    private func folderRows(_ folders: [CurationFolder]) -> some View {
        ForEach(folders) { folder in
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                if folder.artwork.backdrop != nil || folder.artwork.logo != nil {
                    CurationFolderHeader(folder: folder, collectionID: collection.id, lifetime: lifetime)
                } else if !folder.presentation.hideTitle { Text(folder.name).sectionTitleStyle() }
                folderContent(folder)
            }
            .id(folder.id)
            .curationFocusSection()
        }
    }

    private func resetSelection() {
        selectedFolderID = collection.presentation.showAll ? nil : collection.folders.first?.id
    }
}

private struct CurationFolderHeader: View {
    let folder: CurationFolder
    let collectionID: String
    let lifetime: CurationArtworkLifetime

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Theme.Palette.surface2)
            .frame(height: 160)
            .overlay {
                CurationStaticArtwork(url: folder.artwork.backdrop ?? folder.artwork.cover,
                    resourceID: collectionID + "." + folder.id + ".header", lifetime: lifetime,
                    thumbnailDimension: 768)
            }
            .overlay {
                LinearGradient(colors: [.clear, Theme.Palette.canvas.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    if folder.artwork.logo != nil {
                        CurationStaticArtwork(url: folder.artwork.logo,
                            resourceID: collectionID + "." + folder.id + ".logo", lifetime: lifetime,
                            thumbnailDimension: 256, contentMode: .fit)
                            .frame(width: 220, height: 44, alignment: .leading)
                    }
                    Text(folder.name).sectionTitleStyle()
                }
                .padding(Theme.Space.md)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
    }
}

private struct CurationCollectionHeader: View {
    let collection: CurationCollection
    let lifetime: CurationArtworkLifetime

    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Theme.Palette.surface2)
            .frame(height: 180)
            .overlay {
                CurationStaticArtwork(url: collection.artwork.backdrop ?? collection.artwork.cover,
                                      resourceID: collection.id + ".header", lifetime: lifetime,
                                      thumbnailDimension: 768)
            }
            .overlay {
                LinearGradient(colors: [.clear, Theme.Palette.canvas.opacity(0.92)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    if collection.artwork.logo != nil {
                        CurationStaticArtwork(url: collection.artwork.logo,
                                              resourceID: collection.id + ".logo", lifetime: lifetime,
                                              thumbnailDimension: 256, contentMode: .fit)
                            .frame(width: 220, height: 54, alignment: .leading)
                    }
                    Text(collection.name).screenTitleStyle()
                    if collection.pinned { Label("Pinned", systemImage: "pin.fill").eyebrowStyle() }
                }
                .padding(Theme.Space.lg)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }
}

private struct CurationCollectionTile: View {
    let collection: CurationCollection
    let lifetime: CurationArtworkLifetime

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Theme.Palette.surface2)
            .aspectRatio(CurationPresentationPolicy.aspectRatio(collection.presentation.tileShape), contentMode: .fit)
            .overlay {
                CurationStaticArtwork(url: collection.artwork.cover ?? collection.artwork.backdrop,
                                      resourceID: collection.id + ".cover", lifetime: lifetime)
            }
            .overlay {
                LinearGradient(colors: [.clear, Theme.Palette.canvas.opacity(0.94)],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if collection.pinned { Image(systemName: "pin.fill").foregroundStyle(Theme.Palette.accent) }
                    if !collection.presentation.hideTitle { Text(collection.name).font(Theme.Typography.cardTitle).lineLimit(2) }
                    Text("\(collection.folders.count) folders").font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(Theme.Space.md)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(collection.name)
    }
}

private struct CurationFolderTile: View {
    let folder: CurationFolder
    let collectionID: String
    let lifetime: CurationArtworkLifetime

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Theme.Palette.surface2)
            .aspectRatio(CurationPresentationPolicy.aspectRatio(folder.presentation.tileShape), contentMode: .fit)
            .overlay {
                CurationStaticArtwork(url: folder.artwork.cover ?? folder.artwork.backdrop,
                                      resourceID: collectionID + "." + folder.id + ".cover", lifetime: lifetime)
            }
            .overlay {
                LinearGradient(colors: [.clear, Theme.Palette.canvas.opacity(0.94)],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    if folder.artwork.logo != nil {
                        CurationStaticArtwork(url: folder.artwork.logo,
                                              resourceID: collectionID + "." + folder.id + ".logo", lifetime: lifetime,
                                              thumbnailDimension: 256, contentMode: .fit)
                            .frame(height: 44)
                    }
                    if !folder.presentation.hideTitle { Text(folder.name).font(Theme.Typography.cardTitle).lineLimit(2) }
                }
                .padding(Theme.Space.md)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(folder.name)
    }
}

private extension View {
    @ViewBuilder func curationFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }
}
