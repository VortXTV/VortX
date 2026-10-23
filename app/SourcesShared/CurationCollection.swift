import Foundation

/// Presentation only. Ownership, pending intent and legacy rules remain in ForYouStore.
struct CurationCollection: Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var home: Bool
    var pinned: Bool
    var folders: [CurationFolder]
    var presentation: CurationPresentation
    var artwork: CurationArtwork

    static func legacy(_ collection: SmartCollection, companion: CurationDocument? = nil) -> Self {
        let fallback = CurationFolder(id: "rules", name: collection.name,
            sources: [.init(id: "rules", kind: .legacyRules(collectionID: collection.id))])
        guard let companion, companion.matches(collection),
              let rich = try? companion.project() else {
            return .init(id: collection.id, name: collection.name, home: collection.home,
                pinned: false, folders: [fallback], presentation: .init(), artwork: .init())
        }
        // The old register is authoritative. An old app's rename/home/rules edit remains visible.
        return .init(id: collection.id, name: collection.name, home: collection.home,
            pinned: rich.pinned, folders: rich.folders, presentation: rich.presentation, artwork: rich.artwork)
    }
}

struct CurationFolder: Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var sources: [CurationSource]
    var presentation = CurationPresentation()
    var artwork = CurationArtwork()
}

struct CurationSource: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case legacyRules(collectionID: String)
        /// Existing app-owned IDs, resolved by its existing loaded model; never a network URL.
        case curated(collectionID: String)
        case interests
        case history
        /// The Xperience namespace retains the authorized raw export and installed-addon binding.
        case xperience(importID: String, collectionID: String, folderID: String, sourceID: String)
        /// Resolution must use the current installed registry, never an import-nominated transport.
        case addonCatalog(manifestID: String, type: String, catalogID: String, genre: String?)
        case unsupported(type: String)
    }
    let id: String
    let kind: Kind
}

struct CurationPresentation: Equatable, Sendable {
    enum Layout: String, CaseIterable, Sendable { case rows, grid, tabs, followLayout }
    enum TileShape: String, CaseIterable, Sendable { case poster, square, landscape }
    var layout: Layout = .followLayout
    var tileShape: TileShape = .poster
    var showAll = true
    var hideTitle = false
}

struct CurationArtwork: Equatable, Sendable {
    /// Inert references. Render through the existing guarded static-art client, with its body,
    /// redirect, content-type and pixel limits. Parsing a reference never authorizes a request.
    var cover: String?
    var backdrop: String?
    var logo: String?
}

enum CurationFailure: Error, Equatable {
    case invalidDocument, unsupportedVersion, tooLarge, invalidNumber, staleCollection
    case staleRevision, staleContext, unsupportedPresentation, invalidEdit, unavailable
}
