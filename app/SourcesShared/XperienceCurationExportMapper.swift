import Foundation

/// Supported rich layout only. The rest of a profile export (keys, imported URL metadata,
/// prompts, account rules and row filters) never enters the shared common document.
enum XperienceCurationExportMapper {
    static let provider = "xperienceProfileExport"
    static func map(_ projection: XperienceProfileExportAdmission.Projection,
                    upstreamCollectionID: String, sourceID: String,
                    into current: CurationDocument,
                    installed: [XperienceAddonBinding.Candidate]) throws -> CurationDocument {
        guard let collection = projection.collections.collections.first(where: { $0.id == upstreamCollectionID }) else {
            throw XperienceExportFailure.missingCollection
        }
        guard let mode = layout(collection.viewMode) else { throw XperienceExportFailure.unsupportedLayout }
        guard case .object(var base) = current.raw["base"],
              let existing = base["folders"]?.array else { throw XperienceExportFailure.invalidResponse }
        // Preserve native rule/curated/user folders. Only this link's tagged upstream slice changes.
        let retained = existing.filter { $0["xperienceSourceID"] != .string(sourceID) }
        var seen = Set(retained.compactMap { value -> String? in
            if case .string(let id) = value["id"] { return id }; return nil
        })
        var mapped: [VortxJSON] = []
        for folder in collection.folders {
            guard seen.insert(folder.id).inserted,
                  let shape = tileShape(folder.tileShape), !folder.sources.isEmpty else {
                throw XperienceExportFailure.unsupportedLayout
            }
            let old = existing.first { $0["id"] == .string(folder.id) && $0["xperienceSourceID"] == .string(sourceID) }
            let sources = try folder.sources.map { source -> VortxJSON in
                guard source.isAddon, let addon = source.addonID,
                      let type = source.type, let catalogID = source.catalogID,
                      case .resolved = XperienceAddonBinding.resolve(source, installed: installed) else {
                    // Missing, unsupported, duplicate or ambiguous installed instances reject this refresh.
                    throw XperienceExportFailure.unsupportedSource
                }
                let id = XperienceAddonBinding.key(for: source)
                var value = object(old?["sources"]?.array?.first { $0["id"] == .string(id) })
                value["id"] = .string(id); value["type"] = .string("addonCatalog")
                value["manifestID"] = .string(addon); value["mediaType"] = .string(type)
                value["catalogID"] = .string(catalogID)
                value["genre"] = source.genre.map(VortxJSON.string)
                return .object(value)
            }
            var fields = object(old), presentation = object(old?["presentation"])
            fields["id"] = .string(folder.id); fields["name"] = .string(folder.title)
            fields["xperienceSourceID"] = .string(sourceID); fields["sources"] = .array(sources)
            presentation["layout"] = .string(mode); presentation["tileShape"] = .string(shape)
            presentation["showAll"] = .bool(collection.showAllTab); presentation["hideTitle"] = .bool(folder.hideTitle)
            fields["presentation"] = .object(presentation)
            fields["artwork"] = artwork(cover: folder.coverImageURL, backdrop: folder.heroBackdropURL,
                                        logo: folder.titleLogoURL, retaining: old?["artwork"])
            mapped.append(.object(fields))
        }
        guard !mapped.isEmpty else { throw XperienceExportFailure.missingCollection }
        base["folders"] = .array(retained + mapped)
        base["pinned"] = .bool(collection.pinToTop)
        var presentation = object(base["presentation"]), art = object(base["artwork"])
        presentation["layout"] = .string(mode); presentation["showAll"] = .bool(collection.showAllTab)
        base["presentation"] = .object(presentation)
        // An absent first-link backdrop does not erase a native/user base backdrop. Once this
        // connector supplies that leaf, later upstream removal clears only its managed leaf.
        if let backdrop = collection.backdropImageURL {
            art["backdrop"] = .string(backdrop); base["xperienceManagesBackdrop"] = .bool(true)
        } else if base["xperienceManagesBackdrop"] == .bool(true) { art["backdrop"] = nil }
        base["artwork"] = .object(art)
        let updated: CurationDocument
        if current.raw["origin"] == nil {
            updated = try current.attaching(base: .object(base), provider: provider, sourceID: sourceID,
                revision: projection.opaqueUpstreamRevision, upstreamCollectionID: upstreamCollectionID)
        } else {
            guard current.raw["origin"]?["upstreamCollectionID"] == .string(upstreamCollectionID),
                  case .string(let revision) = current.raw["origin"]?["revision"] else {
                throw XperienceExportFailure.staleRevision
            }
            updated = try current.refreshing(base: .object(base), provider: provider, sourceID: sourceID,
                expectedRevision: revision, revision: projection.opaqueUpstreamRevision)
        }
        // Existing raw-bound model enforces 16 KiB/folder/source limits and static-art URL shape.
        // Run native credential exclusion too before labels/art are offered for Apply.
        let fields = VortxJSON.object([updated.field: updated.raw])
        do {
            let bytes = try XperienceCollections.canonicalData(fields)
            let archive = try VortxNativeBootstrapArchive.encode(document: bytes)
            let inspected = try JSONDecoder().decode(VortxJSON.self, from: archive)
            // The archive crosses a JSON wire boundary: an integral Double may decode as Int64.
            // Compare the complete canonical wire value, not the in-memory enum representation.
            // Never return the inspected tree: the original raw document/unknown leaves stay exact.
            guard inspected["excludedCredentialPaths"] == .array([]),
                  let inspectedHost = inspected["hostDocument"],
                  try XperienceCollections.canonicalData(inspectedHost) == bytes else {
                throw XperienceExportFailure.unsafeContent
            }
        } catch { throw XperienceExportFailure.unsafeContent }
        return updated
    }
    private static func layout(_ name: String) -> String? {
        switch name.uppercased() {
        case "TABBED_GRID": return "tabs"
        case "ROWS": return "rows"
        case "FOLLOW_LAYOUT": return "followLayout"
        default: return nil
        }
    }
    private static func tileShape(_ name: String) -> String? {
        switch name.uppercased() {
        case "POSTER": return "poster"
        case "SQUARE": return "square"
        case "LANDSCAPE", "WIDE": return "landscape"
        default: return nil
        }
    }
    private static func object(_ raw: VortxJSON?) -> [String: VortxJSON] {
        if case .object(let fields) = raw { return fields }; return [:]
    }
    private static func artwork(cover: String?, backdrop: String?, logo: String?, retaining raw: VortxJSON?) -> VortxJSON {
        var value = object(raw)
        value["cover"] = cover.map(VortxJSON.string)
        value["backdrop"] = backdrop.map(VortxJSON.string)
        value["logo"] = logo.map(VortxJSON.string)
        return .object(value)
    }
}
