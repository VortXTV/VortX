import Foundation

/// An additive per-collection companion. Never write rich fields inside forYou.collection.*:
/// shipped old clients serialize that typed DTO and would remove them on an ordinary edit.
///
/// Wire:
/// {schemaVersion:1,id:<existing UUID>,legacyCreatedAt:<exact JSON number>,
///  base:{folders:[{id,name,sources:[{id,type,...}],presentation:{...},artwork:{...}}],
///        pinned:false,presentation:{...},artwork:{...}},
///  origin?:{provider:<public name>,sourceID:<opaque ID>,revision:<opaque revision>},
///  overrides:{presentation:{...},artwork:{...},pinned:true,
///     folderOrder:[ids],removedFolderIDs:[ids],
///     folders:{<id>:{name:...,presentation:{...},artwork:{...},
///                    sourceOrder:[ids],removedSourceIDs:[ids]}}}}
///
/// Raw JSON is the durable model. Projections are never encoded back over the saved document.
/// Unknown fields/types stay raw. A source removal is a local tombstone and survives refresh.
struct CurationDocument: Equatable, Sendable {
    static let prefix = "curation.collection."
    static let maximumBytes = 16_384
    static let maximumFolders = 16
    static let maximumSources = 64
    private(set) var raw: VortxJSON
    let id: String
    var field: String { Self.prefix + id }

    init(raw: VortxJSON) throws {
        try Self.bound(raw)
        guard raw["schemaVersion"] == .integer(1) else { throw CurationFailure.unsupportedVersion }
        guard case .string(let id) = raw["id"], UUID(uuidString: id)?.uuidString.lowercased() == id,
              let createdAt = raw["legacyCreatedAt"], Self.finiteNumber(createdAt) != nil,
              case .object = raw["base"], case .object = raw["overrides"] else {
            throw CurationFailure.invalidDocument
        }
        self.raw = raw; self.id = id
        try validateBase()
        try validateOverrides()
        if let origin = raw["origin"] {
            guard case .object = origin else { throw CurationFailure.invalidDocument }
            for key in ["provider", "sourceID", "revision"] { _ = try Self.text(origin[key], maximum: 256) }
        }
    }

    static func make(for legacy: SmartCollection, legacyValue: VortxJSON) throws -> Self {
        guard case .string(let id) = legacyValue["id"], id == legacy.id,
              let createdAt = legacyValue["createdAt"],
              Self.finiteNumber(createdAt) == legacy.createdAt else { throw CurationFailure.staleCollection }
        return try .init(raw: .object([
            "schemaVersion": .integer(1), "id": .string(id), "legacyCreatedAt": createdAt,
            "base": .object(["folders": .array([.object([
                "id": .string("rules"), "name": .string(legacy.name),
                "sources": .array([.object(["id": .string("rules"), "type": .string("legacyRules"),
                                          "collectionID": .string(id)])])
            ])])]), "overrides": .object([:])
        ]))
    }

    func matches(_ legacy: SmartCollection) -> Bool {
        id == legacy.id && Self.finiteNumber(raw["legacyCreatedAt"]) == legacy.createdAt
    }

    /// A missing/tombstoned legacy register always hides its companion, including on old-app delete.
    static func read(registers: [String: VortxJSON], legacy: SmartCollection) -> Self? {
        guard let live = registers[legacy.field]?["value"], live != .null,
              live["id"] == .string(legacy.id),
              let value = registers[prefix + legacy.id]?["value"],
              let document = try? Self(raw: value), document.matches(legacy),
              VortxNativeHostFieldEvidence.json(live["createdAt"], value["legacyCreatedAt"]) else { return nil }
        return document
    }

    struct Projection: Equatable, Sendable {
        let pinned: Bool
        let folders: [CurationFolder]
        let presentation: CurationPresentation
        let artwork: CurationArtwork
    }
    func project() throws -> Projection {
        try Self.project(base: raw["base"]!, overrides: raw["overrides"]!)
    }
    /// Public starter definitions share the exact base validator and renderer projection, without
    /// fabricating a profile UUID, creation timestamp, origin, override register or save authority.
    static func projectPublicBase(_ base: VortxJSON) throws -> Projection {
        try bound(base)
        let overrides = VortxJSON.object([:])
        try validateBase(base: base, overrides: overrides, legacyID: nil)
        return try project(base: base, overrides: overrides)
    }
    private static func project(base: VortxJSON, overrides: VortxJSON) throws -> Projection {
        let removed = Set(Self.strings(overrides["removedFolderIDs"]))
        let folderPatches = overrides["folders"]
        let folders = try allFolders(base: base, overrides: overrides).filter {
            !removed.contains(try Self.text($0["id"], maximum: 128))
        }.map { item -> CurationFolder in
            let id = try Self.text(item["id"], maximum: 128)
            let patch = folderPatches?[id] ?? .object([:])
            let merged = Self.merge(item, patch)
            let removedSources = Set(Self.strings(patch["removedSourceIDs"]))
            let rawSources = (item["sources"]?.array ?? []) + (patch["addedSources"]?.array ?? [])
            let sources = try rawSources.filter {
                !removedSources.contains(try Self.text($0["id"], maximum: 128))
            }.map { try Self.source($0) }
            return .init(id: id, name: try Self.text(merged["name"], maximum: 256),
                sources: Self.ordered(sources, order: Self.strings(patch["sourceOrder"]), id: \.id),
                presentation: try Self.presentation(merged["presentation"]),
                artwork: try Self.artwork(merged["artwork"]))
        }
        return .init(pinned: try Self.boolean(overrides["pinned"] ?? base["pinned"], default: false),
            folders: Self.ordered(folders, order: Self.strings(overrides["folderOrder"]), id: \.id),
            presentation: try Self.presentation(Self.merge(base["presentation"], overrides["presentation"])),
            artwork: try Self.artwork(Self.merge(base["artwork"], overrides["artwork"])))
    }

    /// Only the changed leaves are written. A future layout enum is preserved when a caller edits
    /// artwork or pin state. It is never coerced into a known layout then silently written back.
    func settingPresentation(_ new: CurationPresentation, comparedTo old: CurationPresentation,
                             folderID: String? = nil) throws -> Self {
        var changes: [String: VortxJSON] = [:]
        if new.layout != old.layout { changes["layout"] = .string(new.layout.rawValue) }
        if new.tileShape != old.tileShape { changes["tileShape"] = .string(new.tileShape.rawValue) }
        if new.showAll != old.showAll { changes["showAll"] = .bool(new.showAll) }
        if new.hideTitle != old.hideTitle { changes["hideTitle"] = .bool(new.hideTitle) }
        return try override(changes, group: "presentation", folderID: folderID)
    }
    func settingArtwork(_ new: CurationArtwork, comparedTo old: CurationArtwork,
                        folderID: String? = nil) throws -> Self {
        var changes: [String: VortxJSON] = [:]
        if new.cover != old.cover { changes["cover"] = new.cover.map(VortxJSON.string) ?? .null }
        if new.backdrop != old.backdrop { changes["backdrop"] = new.backdrop.map(VortxJSON.string) ?? .null }
        if new.logo != old.logo { changes["logo"] = new.logo.map(VortxJSON.string) ?? .null }
        for value in changes.values where value != .null { _ = try Self.artReference(value) }
        return try override(changes, group: "artwork", folderID: folderID)
    }
    func settingPinned(_ value: Bool) throws -> Self { try override(["pinned": .bool(value)]) }
    func renamingFolder(_ id: String, name: String) throws -> Self {
        _ = try Self.text(.string(name), maximum: 256)
        return try override(["name": .string(name)], folderID: id)
    }
    func orderingFolders(_ ids: [String]) throws -> Self {
        let existing = try project().folders.map(\.id)
        guard Set(ids) == Set(existing), ids.count == existing.count else { throw CurationFailure.invalidEdit }
        return try override(["folderOrder": .array(ids.map(VortxJSON.string))])
    }
    func removingFolder(_ id: String) throws -> Self {
        try requireFolder(id)
        var ids = Self.strings(raw["overrides"]?["removedFolderIDs"])
        if !ids.contains(id) { ids.append(id) }
        return try override(["removedFolderIDs": .array(ids.map(VortxJSON.string))])
    }
    func removingSource(_ sourceID: String, folderID: String) throws -> Self {
        let folder = try requireFolder(folderID)
        let sources = (folder["sources"]?.array ?? [])
            + (raw["overrides"]?["folders"]?[folderID]?["addedSources"]?.array ?? [])
        guard sources.contains(where: { $0["id"] == .string(sourceID) }) else {
            throw CurationFailure.invalidEdit
        }
        var ids = Self.strings(raw["overrides"]?["folders"]?[folderID]?["removedSourceIDs"])
        if !ids.contains(sourceID) { ids.append(sourceID) }
        return try override(["removedSourceIDs": .array(ids.map(VortxJSON.string))], folderID: folderID)
    }
    func addingFolder(name: String, id: String = UUID().uuidString.lowercased()) throws -> Self {
        _ = try Self.text(.string(id), maximum: 128)
        _ = try Self.text(.string(name), maximum: 256)
        guard !(try allFolders()).contains(where: { $0["id"] == .string(id) }) else { throw CurationFailure.invalidEdit }
        var folders = raw["overrides"]?["addedFolders"]?.array ?? []
        folders.append(.object(["id": .string(id), "name": .string(name), "sources": .array([])]))
        return try override(["addedFolders": .array(folders)])
    }
    func addingSource(_ source: CurationSource, folderID: String) throws -> Self {
        let folder = try requireFolder(folderID)
        var additions = raw["overrides"]?["folders"]?[folderID]?["addedSources"]?.array ?? []
        guard !((folder["sources"]?.array ?? []) + additions).contains(where: { $0["id"] == .string(source.id) }) else {
            throw CurationFailure.invalidEdit
        }
        var fields: [String: VortxJSON] = ["id": .string(source.id)]
        switch source.kind {
        case .legacyRules(let collectionID):
            guard collectionID == id else { throw CurationFailure.invalidEdit }
            fields["type"] = .string("legacyRules"); fields["collectionID"] = .string(collectionID)
        case .curated(let collectionID):
            fields["type"] = .string("curated"); fields["collectionID"] = .string(collectionID)
        case .interests: fields["type"] = .string("interests")
        case .history: fields["type"] = .string("history")
        case .addonCatalog(let manifestID, let type, let catalogID, let genre):
            fields["type"] = .string("addonCatalog"); fields["manifestID"] = .string(manifestID)
            fields["mediaType"] = .string(type); fields["catalogID"] = .string(catalogID)
            fields["genre"] = genre.map(VortxJSON.string)
        case .xperience(let importID, let collectionID, let folderID, let sourceID):
            fields["type"] = .string("xperience"); fields["importID"] = .string(importID)
            fields["collectionID"] = .string(collectionID); fields["folderID"] = .string(folderID)
            fields["sourceID"] = .string(sourceID)
        case .unsupported: throw CurationFailure.invalidEdit
        }
        additions.append(.object(fields))
        return try override(["addedSources": .array(additions)], folderID: folderID)
    }
    func orderingSources(_ ids: [String], folderID: String) throws -> Self {
        guard let folder = try project().folders.first(where: { $0.id == folderID }),
              ids.count == folder.sources.count, Set(ids) == Set(folder.sources.map(\.id)) else {
            throw CurationFailure.invalidEdit
        }
        return try override(["sourceOrder": .array(ids.map(VortxJSON.string))], folderID: folderID)
    }

    /// Caller must have independently authorized this provider/source. This pure operation does no
    /// fetching, subscription or account work. A revision is an opaque string, never a timestamp.
    func refreshing(base: VortxJSON, provider: String, sourceID: String,
                    expectedRevision: String, revision: String) throws -> Self {
        guard raw["origin"]?["provider"] == .string(provider),
              raw["origin"]?["sourceID"] == .string(sourceID),
              raw["origin"]?["revision"] == .string(expectedRevision) else { throw CurationFailure.staleRevision }
        guard case .object(var value) = raw, case .object(var origin) = raw["origin"] else {
            throw CurationFailure.invalidDocument
        }
        origin["revision"] = .string(revision)
        value["origin"] = .object(origin); value["base"] = base
        // `overrides` and all unknown envelope/origin fields remain byte-value equivalent.
        return try .init(raw: .object(value))
    }
    /// Initial authorized link to one upstream definition. The URL/key stays device-local.
    /// Existing origins require refresh or an explicit unlink flow, never silent reassignment.
    func attaching(base: VortxJSON, provider: String, sourceID: String, revision: String,
                   upstreamCollectionID: String) throws -> Self {
        guard raw["origin"] == nil, case .object(var value) = raw else { throw CurationFailure.invalidEdit }
        _ = try Self.text(.string(upstreamCollectionID), maximum: 128)
        value["base"] = base
        value["origin"] = .object(["provider": .string(provider), "sourceID": .string(sourceID),
            "revision": .string(revision), "upstreamCollectionID": .string(upstreamCollectionID)])
        return try .init(raw: .object(value))
    }

    private func override(_ changes: [String: VortxJSON], group: String? = nil,
                          folderID: String? = nil) throws -> Self {
        guard case .object(var value) = raw, case .object(var overrides) = value["overrides"] else {
            throw CurationFailure.invalidDocument
        }
        var patch = overrides
        if let folderID {
            _ = try requireFolder(folderID)
            if case .object(let old) = overrides["folders"]?[folderID] { patch = old } else { patch = [:] }
        }
        if let group {
            var leaves: [String: VortxJSON] = [:]
            if case .object(let old) = patch[group] { leaves = old }
            for (key, leaf) in changes { leaves[key] = leaf }
            patch[group] = .object(leaves)
        } else { for (key, leaf) in changes { patch[key] = leaf } }
        if let folderID {
            var folders: [String: VortxJSON] = [:]
            if case .object(let old) = overrides["folders"] { folders = old }
            folders[folderID] = .object(patch); overrides["folders"] = .object(folders)
        } else { overrides = patch }
        value["overrides"] = .object(overrides)
        return try .init(raw: .object(value))
    }

    @discardableResult private func requireFolder(_ id: String) throws -> VortxJSON {
        guard let folder = try allFolders().first(where: { $0["id"] == .string(id) }) else {
            throw CurationFailure.invalidEdit
        }
        return folder
    }
    private func allFolders() throws -> [VortxJSON] {
        try Self.allFolders(base: raw["base"]!, overrides: raw["overrides"]!)
    }
    private static func allFolders(base: VortxJSON, overrides: VortxJSON) throws -> [VortxJSON] {
        guard let folders = base["folders"]?.array else { throw CurationFailure.invalidDocument }
        var added: [VortxJSON] = []
        if let value = overrides["addedFolders"] {
            guard let array = value.array else { throw CurationFailure.invalidDocument }
            added = array
        }
        return folders + added
    }
    private func validateBase() throws {
        try Self.validateBase(base: raw["base"]!, overrides: raw["overrides"]!, legacyID: id)
    }
    private static func validateBase(base: VortxJSON, overrides: VortxJSON, legacyID: String?) throws {
        let folders = try allFolders(base: base, overrides: overrides)
        guard folders.count <= Self.maximumFolders else {
            throw CurationFailure.invalidDocument
        }
        var folderIDs = Set<String>(), sourceCount = 0
        // Retained overrides outlive a removed upstream folder. Count every retained addition,
        // including orphan/removed-folder patches, exactly once; never truncate opaque intent.
        if case .object(let patches) = overrides["folders"] {
            for patch in patches.values {
                if let value = patch["addedSources"] {
                    guard let additions = value.array else { throw CurationFailure.invalidDocument }
                    sourceCount += additions.count
                }
            }
        }
        for folder in folders {
            let id = try Self.text(folder["id"], maximum: 128)
            guard folderIDs.insert(id).inserted else { throw CurationFailure.invalidDocument }
            _ = try Self.text(folder["name"], maximum: 256)
            guard let baseSources = folder["sources"]?.array else { throw CurationFailure.invalidDocument }
            let extra = overrides["folders"]?[id]?["addedSources"]
            if let extra, extra.array == nil { throw CurationFailure.invalidDocument }
            let sources = baseSources + (extra?.array ?? [])
            guard sources.count <= 8 else { throw CurationFailure.invalidDocument }
            sourceCount += baseSources.count
            var ids = Set<String>()
            for source in sources {
                let projected = try Self.source(source)
                guard ids.insert(projected.id).inserted else { throw CurationFailure.invalidDocument }
                if case .legacyRules(let collectionID) = projected.kind {
                    guard let legacyID, collectionID == legacyID else { throw CurationFailure.invalidDocument }
                }
            }
            try Self.validatePresentationShape(folder["presentation"])
            _ = try Self.artwork(folder["artwork"])
        }
        guard sourceCount <= Self.maximumSources else { throw CurationFailure.invalidDocument }
        try Self.validatePresentationShape(base["presentation"])
        _ = try Self.artwork(base["artwork"])
        _ = try Self.boolean(base["pinned"], default: false)
    }
    private func validateOverrides() throws {
        let overrides = raw["overrides"]!
        for key in ["folderOrder", "removedFolderIDs"] { try Self.validateIDs(overrides[key]) }
        try Self.validatePresentationShape(overrides["presentation"])
        _ = try Self.artwork(overrides["artwork"])
        _ = try Self.boolean(overrides["pinned"], default: false)
        if let folders = overrides["folders"] {
            guard case .object(let patches) = folders, patches.count <= Self.maximumFolders else {
                throw CurationFailure.invalidDocument
            }
            for (id, patch) in patches {
                _ = try Self.text(.string(id), maximum: 128)
                guard case .object = patch else { throw CurationFailure.invalidDocument }
                if let name = patch["name"] { _ = try Self.text(name, maximum: 256) }
                for key in ["sourceOrder", "removedSourceIDs"] { try Self.validateIDs(patch[key]) }
                if let sources = patch["addedSources"] {
                    guard let array = sources.array, array.count <= 8 else { throw CurationFailure.invalidDocument }
                    for source in array { _ = try Self.source(source) }
                }
                try Self.validatePresentationShape(patch["presentation"])
                _ = try Self.artwork(patch["artwork"])
            }
        }
    }
    private static func source(_ raw: VortxJSON) throws -> CurationSource {
        let id = try text(raw["id"], maximum: 128), type = try text(raw["type"], maximum: 128)
        let kind: CurationSource.Kind
        switch type {
        case "legacyRules": kind = .legacyRules(collectionID: try text(raw["collectionID"], maximum: 128))
        case "curated": kind = .curated(collectionID: try text(raw["collectionID"], maximum: 128))
        case "interests": kind = .interests
        case "history": kind = .history
        case "xperience":
            kind = .xperience(importID: try text(raw["importID"], maximum: 128),
                collectionID: try text(raw["collectionID"], maximum: 128),
                folderID: try text(raw["folderID"], maximum: 128), sourceID: try text(raw["sourceID"], maximum: 128))
        case "addonCatalog":
            let genre = try raw["genre"].map { try text($0, maximum: 128) }
            kind = .addonCatalog(manifestID: try text(raw["manifestID"], maximum: 256),
                type: try text(raw["mediaType"], maximum: 64), catalogID: try text(raw["catalogID"], maximum: 128), genre: genre)
        default: kind = .unsupported(type: type)
        }
        return .init(id: id, kind: kind)
    }
    private static func presentation(_ raw: VortxJSON?) throws -> CurationPresentation {
        guard let raw else { return .init() }
        try validatePresentationShape(raw)
        let layoutName = try raw["layout"].map { try text($0, maximum: 64) } ?? "followLayout"
        let shapeName = try raw["tileShape"].map { try text($0, maximum: 64) } ?? "poster"
        guard let layout = CurationPresentation.Layout(rawValue: layoutName),
              let tileShape = CurationPresentation.TileShape(rawValue: shapeName) else {
            throw CurationFailure.unsupportedPresentation
        }
        return .init(layout: layout, tileShape: tileShape,
            showAll: try boolean(raw["showAll"], default: true), hideTitle: try boolean(raw["hideTitle"], default: false))
    }
    private static func validatePresentationShape(_ raw: VortxJSON?) throws {
        guard let raw else { return }
        guard case .object = raw else { throw CurationFailure.invalidDocument }
        for key in ["layout", "tileShape"] { if let value = raw[key] { _ = try text(value, maximum: 64) } }
        _ = try boolean(raw["showAll"], default: true); _ = try boolean(raw["hideTitle"], default: false)
    }
    private static func artwork(_ raw: VortxJSON?) throws -> CurationArtwork {
        guard let raw else { return .init() }
        guard case .object = raw else { throw CurationFailure.invalidDocument }
        return try .init(cover: artReference(raw["cover"]), backdrop: artReference(raw["backdrop"]), logo: artReference(raw["logo"]))
    }
    private static func artReference(_ value: VortxJSON?) throws -> String? {
        guard let value, value != .null else { return nil }
        let text = try text(value, maximum: 2048)
        guard let url = URLComponents(string: text), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              !["localhost", "local"].contains(host.lowercased()),
              !host.contains(":"), host.range(of: #"^\d+(?:\.\d+){3}$"#, options: .regularExpression) == nil else {
            throw CurationFailure.invalidEdit
        }
        return text
    }
    private static func boolean(_ value: VortxJSON?, default fallback: Bool) throws -> Bool {
        guard let value else { return fallback }
        guard case .bool(let result) = value else { throw CurationFailure.invalidDocument }
        return result
    }
    private static func text(_ value: VortxJSON?, maximum: Int) throws -> String {
        guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= maximum else {
            throw CurationFailure.invalidDocument
        }
        return text
    }
    private static func strings(_ value: VortxJSON?) -> [String] {
        value?.array?.compactMap { if case .string(let text) = $0 { return text }; return nil } ?? []
    }
    private static func validateIDs(_ raw: VortxJSON?) throws {
        guard let raw else { return }
        guard let array = raw.array, array.count <= maximumSources else { throw CurationFailure.invalidDocument }
        let values = try array.map { try text($0, maximum: 128) }
        guard Set(values).count == values.count else { throw CurationFailure.invalidDocument }
    }
    private static func merge(_ base: VortxJSON?, _ patch: VortxJSON?) -> VortxJSON {
        guard let patch else { return base ?? .object([:]) }
        guard case .object(let changes) = patch else { return patch }
        var result: [String: VortxJSON] = [:]
        if case .object(let original) = base { result = original }
        for (key, value) in changes { result[key] = merge(result[key], value) }
        return .object(result)
    }
    private static func ordered<T>(_ values: [T], order: [String], id: KeyPath<T, String>) -> [T] {
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return values.enumerated().sorted {
            let a = positions[$0.element[keyPath: id]] ?? Int.max, b = positions[$1.element[keyPath: id]] ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
    private static func finiteNumber(_ value: VortxJSON?) -> Double? {
        switch value {
        case .integer(let n): return abs(Double(n)) <= 9_007_199_254_740_991 ? Double(n) : nil
        case .unsigned(let n): return n <= 9_007_199_254_740_991 ? Double(n) : nil
        case .number(let n): return n.isFinite && abs(n) <= 9_007_199_254_740_991 ? n : nil
        default: return nil
        }
    }
    private static func bound(_ raw: VortxJSON) throws {
        var nodes = 0
        func walk(_ value: VortxJSON, depth: Int) throws {
            nodes += 1
            guard depth <= 12, nodes <= 2_048 else { throw CurationFailure.tooLarge }
            switch value {
            case .object(let fields):
                for (key, item) in fields {
                    guard !key.isEmpty, key.utf8.count <= 256 else { throw CurationFailure.tooLarge }
                    try walk(item, depth: depth + 1)
                }
            case .array(let items): for item in items { try walk(item, depth: depth + 1) }
            case .string(let string): guard string.utf8.count <= 4_096 else { throw CurationFailure.tooLarge }
            case .integer, .unsigned, .number:
                guard finiteNumber(value) != nil else { throw CurationFailure.invalidNumber }
            default: break
            }
        }
        try walk(raw, depth: 0)
        guard try JSONEncoder().encode(raw).count <= maximumBytes else { throw CurationFailure.tooLarge }
    }
}
