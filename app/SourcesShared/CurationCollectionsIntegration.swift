import SwiftUI

/// The first common VortX starter adapts the existing Discover definitions. Its source IDs map to
/// real SubCatalog loaders; constructing this definition starts neither metadata nor artwork work.
enum CurationStarterCollections {
    static var collections: [CurationCollection] {
        let folders = DiscoverList.allCases.map { list in
            CurationFolder(id: "discover.\(list.rawValue)", name: list.title,
                sources: ["movies", "shows"].map { sub in
                    let id = "discover.\(list.rawValue).\(sub)"
                    return CurationSource(id: id, kind: .curated(collectionID: id))
                }, presentation: .init(layout: .followLayout, tileShape: .landscape))
        }
        return [.init(id: "vortx.discover", name: String(localized: "Discover"), home: false,
                      pinned: false, folders: folders, presentation: .init(layout: .tabs, tileShape: .landscape),
                      artwork: .init())]
    }

    static func catalogSource(_ id: String) -> SubCatalog? {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "discover", let list = DiscoverList(rawValue: String(parts[1])) else { return nil }
        return CollectionsCatalog.subCatalogs(for: .discover(list), region: TMDBClient.deviceRegion)
            .first { $0.id == String(parts[2]) }
    }
}

/// Optional import adapter only. Raw/unknown import fields and source bindings stay in their existing
/// namespace. A linked source can be added deliberately to a user collection through its editor.
enum CurationImportProjection {
    static func collections(_ namespace: XperienceSavedNamespace) -> [CurationCollection] {
        let importID = namespace.namespace.uuidString.lowercased()
        return namespace.document.collections.map { original in
            let layout: CurationPresentation.Layout
            switch original.viewMode.uppercased() {
            case "ROWS": layout = .rows
            case "TABBED_GRID": layout = .tabs
            case "FOLLOW_LAYOUT": layout = .followLayout
            default: layout = .grid
            }
            let folders = original.folders.map { folder in
                CurationFolder(id: folder.id, name: folder.title,
                    sources: folder.sources.map { source in
                        let id = XperienceAddonBinding.key(for: source)
                        return CurationSource(id: id, kind: source.isAddon
                            ? .xperience(importID: importID, collectionID: original.id, folderID: folder.id, sourceID: id)
                            : .unsupported(type: source.provider))
                    },
                    presentation: .init(layout: .followLayout, tileShape: shape(folder.tileShape),
                                        showAll: true, hideTitle: folder.hideTitle),
                    artwork: .init(cover: folder.coverImageURL, backdrop: folder.heroBackdropURL,
                                   logo: folder.titleLogoURL))
            }
            return CurationCollection(id: "xperience.\(importID).\(original.id)", name: original.title,
                home: false, pinned: original.pinToTop, folders: folders,
                presentation: .init(layout: layout, tileShape: .landscape,
                                    showAll: original.showAllTab, hideTitle: false),
                artwork: .init(backdrop: original.backdropImageURL))
        }
    }

    static func hasUnsupportedPresentation(_ namespace: XperienceSavedNamespace, collectionID: String) -> Bool {
        guard let index = namespace.document.collections.firstIndex(where: { $0.id == collectionID }) else { return false }
        return namespace.document.notices.contains {
            $0.collectionIndex == index && [.unsupportedViewMode, .unsupportedTileShape].contains($0.kind)
        }
    }

    private static func shape(_ value: String) -> CurationPresentation.TileShape {
        switch value.uppercased() {
        case "POSTER": return .poster
        case "LANDSCAPE", "WIDE": return .landscape
        default: return .square
        }
    }
}

/// Shared destination reached from the current Library collection screen or its existing Home
/// section. The source controller captures no replacement account/profile after a stale selection.
@MainActor struct CurationCollectionDestination: View {
    let collection: CurationCollection
    let ticket: CurationReadTicket
    var followLayout: CurationPresentation.Layout = .rows
    var unsupportedPresentation = false
    var onOpen: (MetaPreview) -> Void = { _ in }
    @ObservedObject private var lifetime: CurationReadLifetime
    @StateObject private var controller: CurationSourceController
    #if os(tvOS)
    @StateObject private var focusOwner = FocusedItemOwner()
    #endif

    init(collection: CurationCollection, ticket: CurationReadTicket,
         followLayout: CurationPresentation.Layout = .rows, unsupportedPresentation: Bool = false,
         resolved: CurationResolvedRows = .init(), onOpen: @escaping (MetaPreview) -> Void = { _ in }) {
        self.collection = collection; self.ticket = ticket; self.followLayout = followLayout
        self.unsupportedPresentation = unsupportedPresentation; self.onOpen = onOpen
        _lifetime = ObservedObject(wrappedValue: ticket.lifetime)
        _controller = StateObject(wrappedValue: CurationSourceController(ticket: ticket, resolved: resolved))
    }

    var body: some View {
        Group {
            if ticket.isCurrent {
                CurationCollectionPage(collection: collection, lifetime: ticket.artworkLifetime,
                                       readTicket: ticket, followLayout: followLayout) { folder in
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        if unsupportedPresentation {
                            Text("Some imported layout fields are unsupported. This view uses a basic layout; the original import is retained.")
                                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.warn)
                        }
                        CurationFolderSourceRows(folder: folder, controller: controller) { items, suppliedArtwork in
                            Group {
                                if suppliedArtwork {
                                    CurationGuardedTitleRail(items: items, lifetime: ticket.artworkLifetime, onOpen: onOpen)
                                } else {
                                #if os(tvOS)
                                    ExternalWatchlistRow(eyebrow: String(localized: "Collection source"), title: folder.name,
                                                         items: items, focusModel: focusOwner.model)
                                #else
                                    PosterRail(title: folder.name, items: items.map { item in
                                        RailItem(id: item.id, type: item.type, name: item.name, poster: item.poster, progress: 0)
                                    }, onTap: { tapped in
                                        if let item = items.first(where: { $0.id == tapped.id && $0.type == tapped.type }) { onOpen(item) }
                                    }, showWatchedBadges: true)
                                #endif
                                }
                            }
                        }
                    }
                }
            } else {
                Text("These collections changed or belong to another profile. Return to Collections and reload.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .padding(Theme.Space.screenInset)
            }
        }
        .task { controller.start() }
        #if os(macOS)
        .macBackAffordance()
        #endif
    }
}

/// Add-on poster URLs are supplied artwork too. They never enter the general poster cache or an
/// AsyncImage path. Title selection still opens the existing native detail destination/callback.
@MainActor private struct CurationGuardedTitleRail: View {
    let items: [MetaPreview]
    let lifetime: CurationArtworkLifetime
    let onOpen: (MetaPreview) -> Void
    private struct Identity: Hashable { let type: String; let id: String }
    private struct Entry: Identifiable {
        let item: MetaPreview
        var id: Identity { .init(type: item.type, id: item.id) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Theme.Space.md) {
                ForEach(items.map { Entry(item: $0) }) { entry in
                    #if os(tvOS)
                    NavigationLink { DetailView(type: entry.item.type, id: entry.item.id) } label: {
                        tile(entry.item)
                    }
                    .buttonStyle(RowFocusStyle())
                    .accessibilityLabel(entry.item.name)
                    #else
                    Button { onOpen(entry.item) } label: { tile(entry.item) }
                        .buttonStyle(RowFocusStyle())
                        .accessibilityLabel(entry.item.name)
                    #endif
                }
            }
            .padding(.vertical, Theme.Space.sm)
        }
    }

    private func tile(_ item: MetaPreview) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Theme.Palette.surface2)
            .frame(width: 170, height: 255)
            .overlay {
                CurationStaticArtwork(url: item.poster, resourceID: "\(item.type).\(item.id).poster",
                                      lifetime: lifetime, thumbnailDimension: 384)
            }
            .overlay {
                LinearGradient(colors: [.clear, Theme.Palette.canvas.opacity(0.94)],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Text(item.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(3).multilineTextAlignment(.leading).padding(Theme.Space.sm)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Replaces the two current eager SmartCollections view bodies while retaining their public routes
/// and existing SmartCollectionEditor. Collections are tiles until the user opens a folder/source.
@MainActor struct CurationCollectionsLibrary: View {
    var onOpen: (MetaPreview) -> Void = { _ in }
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var store = ForYouStore.shared
    @ObservedObject private var watched = WatchedIndex.shared
    @ObservedObject private var defaults = CurationDefaultsModel.shared
    @StateObject private var imports = XperienceCollectionsViewModel()
    @StateObject private var lifetime = CurationReadLifetime()
    @State private var editing: Editing?
    @State private var editError: String?
    private struct Editing: Identifiable {
        let collection: SmartCollection?
        let ticket: CurationReadTicket
        let session: CurationLegacyEditSession
        var id: String { collection?.id ?? "new" }
    }

    private var definitions: [CurationCollection] {
        guard ticket.isCurrent else { return [] }
        return defaults.currentCollections() + store.richCollections + imports.namespaces.flatMap(CurationImportProjection.collections)
    }
    private var ticket: CurationReadTicket {
        .init(lifetime: lifetime, generation: lifetime.generation, legacy: store.collections,
              importFingerprints: Dictionary(uniqueKeysWithValues: imports.namespaces.map {
                  ($0.namespace.uuidString.lowercased(), $0.document.fingerprint)
              }))
    }

    private var editableCollections: [SmartCollection] { ticket.isCurrent ? store.collections : [] }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Collections").screenTitleStyle().padding(.horizontal, Theme.Space.screenInset)
                HStack(spacing: Theme.Space.sm) {
                    Button { beginEdit(nil) } label: { Label("New collection", systemImage: "plus") }
                        .buttonStyle(ChipButtonStyle()).disabled(!ticket.isCurrent)
                    NavigationLink { XperienceCollectionsBrowserView() } label: {
                        Label("Import or update", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(ChipButtonStyle()).disabled(!ticket.isCurrent)
                    Button("Reload") { reload() }.buttonStyle(ChipButtonStyle())
                }
                .padding(.horizontal, Theme.Space.screenInset)
                if let editError { Text(editError).font(Theme.Typography.label).foregroundStyle(Theme.Palette.warn) }
                if !store.ready {
                    Text("Your collections appear once your account has loaded.")
                        .font(Theme.Typography.label).padding(.horizontal, Theme.Space.screenInset)
                }
                CurationCollectionShelf(collections: definitions, lifetime: lifetime.artworkLifetime) { collection in
                    CurationCollectionDestination(collection: collection, ticket: ticket,
                                                  unsupportedPresentation: hasUnsupportedPresentation(collection), onOpen: onOpen)
                }
                if definitions.isEmpty && store.ready {
                    Text("Create a collection from rules, then choose its folders, artwork and layout.")
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Space.screenInset)
                }
                ForEach(editableCollections) { collection in
                    Button { beginEdit(collection) } label: {
                        HStack {
                            Text(collection.name).font(Theme.Typography.cardTitle)
                            Spacer()
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }
                        .padding(Theme.Space.md).vortxSettingsCard()
                    }
                    .vortxCardButton()
                    .padding(.horizontal, Theme.Space.screenInset)
                }
            }
            .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { reload() }
        .task { await defaults.loadIfNeeded() }
        .onValueChange(of: store.profileID) { _ in reload() }
        .onReceive(imports.store.revisionEvents) { _ in
            lifetime.revalidate()
            imports.retireIfStale()
        }
        #if os(tvOS)
        .fullScreenCover(item: editingBinding) { editor($0) }
        #else
        .sheet(item: editingBinding) { editor($0) }
        #endif
    }

    private func editor(_ editing: Editing) -> some View {
        SmartCollectionEditor(existing: editing.collection, legacySession: editing.session,
                              readTicket: editing.ticket, watched: watched.ids, onFinish: { dismissEditor() }) { items, loading in
            #if os(tvOS)
            TVSmartCollectionPreview(items: items, loading: loading)
            #else
            if loading { ProgressView() }
            if !items.isEmpty {
                PosterRail(title: String(localized: "Preview"), items: items.map {
                    RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0)
                }, onTap: { _ in })
            }
            #endif
        }
        .environmentObject(theme)
    }
    private func beginEdit(_ existing: SmartCollection?) {
        guard ticket.isCurrent else { return }
        let original = existing ?? SmartCollection.make(name: "", rules: .init(), home: true)
        do {
            let session = try store.captureLegacyEdit(original, isNew: existing == nil)
            editError = nil
            editing = .init(collection: existing, ticket: ticket, session: session)
        } catch {
            editError = String(localized: "This collection or profile changed. Reload Collections and try again.")
        }
    }
    private var editingBinding: Binding<Editing?> {
        Binding(get: { editing }, set: { value in
            if value == nil { dismissEditor() } else { editing = value }
        })
    }
    private func dismissEditor() {
        if let editing { store.retireLegacyEdit(editing.session) }
        editing = nil
    }
    private func reload() {
        lifetime.renew()
        imports.reload()
        lifetime.bindImports(ticket.importFingerprints)
    }
    private func hasUnsupportedPresentation(_ collection: CurationCollection) -> Bool {
        imports.namespaces.contains { namespace in
            namespace.document.collections.contains { original in
                collection.id == "xperience.\(namespace.namespace.uuidString.lowercased()).\(original.id)"
                    && CurationImportProjection.hasUnsupportedPresentation(namespace, collectionID: original.id)
            }
        }
    }
}

/// This view belongs INSIDE HomeRail.smartCollections. Keeping its raw key preserves hide/order
/// preferences; the import manager no longer sits above the user's arranged Home sections.
@MainActor struct CurationCollectionsHome: View {
    var onOpen: (MetaPreview) -> Void = { _ in }
    var resolved = CurationResolvedRows()
    @ObservedObject private var store = ForYouStore.shared
    @StateObject private var lifetime = CurationReadLifetime()
    @StateObject private var imports = XperienceCollectionsViewModel()
    private var ticket: CurationReadTicket {
        .init(lifetime: lifetime, generation: lifetime.generation, legacy: store.collections,
              importFingerprints: Dictionary(uniqueKeysWithValues: imports.namespaces.map {
                  ($0.namespace.uuidString.lowercased(), $0.document.fingerprint)
              }))
    }
    var body: some View {
        Group {
        let collections = store.richCollections.filter(\.home)
        if !collections.isEmpty, ticket.isCurrent {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Your collections").sectionTitleStyle().padding(.horizontal, Theme.Space.screenInset)
                CurationCollectionShelf(collections: collections, lifetime: lifetime.artworkLifetime) { collection in
                    CurationCollectionDestination(collection: collection, ticket: ticket, resolved: resolved, onOpen: onOpen)
                }
            }
        }
        }
        .onAppear { reloadReadContext() }
        .onValueChange(of: store.profileID) { _ in reloadReadContext() }
        .onReceive(imports.store.revisionEvents) { _ in
            lifetime.revalidate()
            imports.retireIfStale()
        }
    }
    private func reloadReadContext() {
        lifetime.renew()
        imports.reload()
        lifetime.bindImports(ticket.importFingerprints)
    }
}
