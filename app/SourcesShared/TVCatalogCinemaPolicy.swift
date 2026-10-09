import Foundation

/// Preview facts are authored data, not a reason to issue another metadata request. This is also the
/// common card footprint for catalog/search and directly resumable Continue Watching entries.
struct TVCinemaCardPresentation: Equatable {
    enum Fact: Hashable { case text(String), rating(String) }
    let id: String
    let type: String
    let title: String
    var poster: String? = nil
    var background: String? = nil
    var overview: String? = nil
    var runtime: String? = nil
    var releaseInfo: String? = nil
    var rating: String? = nil
    var seriesContext: String? = nil
    var genres: [String] = []

    static func meta(_ item: CoreMeta) -> Self {
        .init(id: item.id, type: item.type, title: item.name, poster: item.poster,
              background: item.background, overview: item.description, runtime: item.runtime,
              releaseInfo: item.releaseInfo, rating: item.imdbRating, genres: item.genres ?? [])
    }

    var facts: [Fact] {
        var result: [Fact] = []
        if let context = clean(seriesContext) { result.append(.text(context)) }
        if let runtime = clean(runtime) { result.append(.text(runtime)) }
        if let year = clean(releaseInfo) { result.append(.text(year)) }
        if let rating = clean(rating), let score = Double(rating), score.isFinite, score > 0, score <= 10 {
            result.append(.rating(rating))
        }
        if let type = clean(type) { result.append(.text(type.capitalized)) }
        return result
    }

    var bodyText: String {
        clean(overview) ?? genres.compactMap(clean).prefix(3).joined(separator: " · ")
    }

    private func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

enum TVCinemaArtworkPolicy {
    static func fillsFrame(pixelWidth: Double, pixelHeight: Double) -> Bool {
        pixelWidth.isFinite && pixelHeight.isFinite && pixelHeight > 0 && pixelWidth / pixelHeight >= 1.2
    }
}

/// Exact installed transport, content type, catalog and filters. The transport may contain private
/// add-on configuration: retain it in memory for matching only, never display or log this identity.
struct TVCatalogRequestIdentity: Hashable, Decodable, Sendable {
    let base: String
    let type: String
    let catalogID: String
    let filters: [[String]]
    var rowID: String { "\(base)|\(type)|\(catalogID)" }

    init(base: String, type: String, catalogID: String, filters: [[String]]) {
        self.base = base; self.type = type; self.catalogID = catalogID
        self.filters = filters.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private struct Path: Decodable {
        let resource: String
        let type: String
        let id: String
        let extra: [[String]]?
    }
    private enum CodingKeys: String, CodingKey { case base, path }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let base = try values.decode(String.self, forKey: .base)
        let path = try values.decode(Path.self, forKey: .path)
        let extras = path.extra ?? []
        guard path.resource == "catalog", !base.isEmpty, !path.type.isEmpty, !path.id.isEmpty,
              extras.allSatisfy({ $0.count == 2 && !$0[0].isEmpty }),
              Set(extras.map { $0[0] }).count == extras.count,
              extras.filter({ $0[0] == "skip" }).allSatisfy({ UInt64($0[1]) != nil }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid catalog identity"))
        }
        self.init(base: base, type: path.type, catalogID: path.id, filters: extras.filter { $0[0] != "skip" })
    }
}

struct TVCatalogBrowseCandidate: Equatable, Sendable {
    enum State: Sendable { case ready, loading, error }
    let request: TVCatalogRequestIdentity
    let engineIndex: Int
    let itemCount: Int
    let lastPageCount: Int
    let state: State
}

/// A read-only projection of the existing board wire. It does not start a catalog load or own a page.
struct TVCatalogBrowseBoard: Decodable, Sendable {
    private struct Item: Decodable, Sendable { init(from _: Decoder) {} }
    private struct Content: Decodable, Sendable {
        let type: String
        let count: Int
        private enum CodingKeys: String, CodingKey { case type, content }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            count = type == "Ready" ? try values.decode([Item].self, forKey: .content).count : 0
        }
    }
    private struct Page: Decodable, Sendable {
        let request: TVCatalogRequestIdentity
        let content: Content?
    }
    private let catalogs: [[Page]]

    var candidates: [TVCatalogBrowseCandidate] {
        catalogs.enumerated().compactMap { index, pages in
            guard let first = pages.first, let last = pages.last,
                  pages.allSatisfy({ $0.request == first.request }) else { return nil }
            let state: TVCatalogBrowseCandidate.State = pages.contains(where: { $0.content?.type == "Loading" })
                ? .loading : (last.content?.type == "Ready" ? .ready : .error)
            return .init(request: first.request, engineIndex: index,
                         itemCount: pages.reduce(0) { $0 + ($1.content?.count ?? 0) },
                         lastPageCount: last.content?.count ?? 0, state: state)
        }
    }
}

/// Read the installed declaration too: a ready page without a skip extra is a finite catalog.
struct TVCatalogBrowseRegistry: Decodable, Sendable {
    private struct Extra: Decodable, Sendable { let name: String }
    private struct Catalog: Decodable, Sendable {
        let id: String
        let type: String
        let extra: [Extra]?
        let extraSupported: [String]?
    }
    private struct Manifest: Decodable, Sendable { let catalogs: [Catalog] }
    private struct Addon: Decodable, Sendable { let transportUrl: String; let manifest: Manifest }
    private struct Profile: Decodable, Sendable { let addons: [Addon] }
    private let profile: Profile

    func supportsPaging(_ request: TVCatalogRequestIdentity) -> Bool {
        let matches = profile.addons.filter { $0.transportUrl == request.base }.flatMap(\.manifest.catalogs)
            .filter { $0.type == request.type && $0.id == request.catalogID }
        guard matches.count == 1, let catalog = matches.first else { return false }
        return (catalog.extra ?? []).contains { $0.name == "skip" } || (catalog.extraSupported ?? []).contains("skip")
    }
}

enum TVCatalogBrowsePolicy {
    static func resolve(target: TVCatalogRequestIdentity, candidates: [TVCatalogBrowseCandidate],
                        ownerCurrent: Bool, visibleRowIDs: Set<String>) -> TVCatalogBrowseCandidate? {
        guard ownerCurrent, visibleRowIDs.contains(target.rowID) else { return nil }
        let matches = candidates.filter { $0.request == target }
        return matches.count == 1 ? matches.first : nil
    }

    /// Re-resolve the current engine index at the callback boundary. Horizontal Home paging and See
    /// All grid paging both dispatch to the same native row owner, whose in-flight/exhaustion gates apply.
    @discardableResult
    static func page(target: TVCatalogRequestIdentity, candidates: [TVCatalogBrowseCandidate],
                     ownerCurrent: Bool, visibleRowIDs: Set<String>, supportsPaging: Bool,
                     load: (Int) -> Void) -> Bool {
        guard supportsPaging, let row = resolve(target: target, candidates: candidates,
                                               ownerCurrent: ownerCurrent, visibleRowIDs: visibleRowIDs),
              row.engineIndex >= 0, row.state == .ready, row.itemCount > 0, row.lastPageCount > 0 else { return false }
        load(row.engineIndex)
        return true
    }
}
