import Foundation

/// Catalog transport for an explicitly selected saved source. The caller owns account/profile and
/// installed-instance generations, and must recheck them after awaiting this service.
/// The async entry is nonisolated so bounded parsing runs away from the UI actor.
enum XperienceCatalogClient {
    static let maximumItems = 2_000

    enum Failure: Error, Equatable, LocalizedError {
        case unavailableSource
        case unreachable
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unavailableSource: return "This saved catalog is unavailable. Review its add-on binding."
            case .unreachable: return "Could not load this catalog. Check your connection and try again."
            case .invalidResponse: return "This add-on did not return a supported catalog response."
            }
        }
    }

    /// Only the exact installed candidate selected by the owner may supply a transport. The binder
    /// preserves configured query, type, catalog ID and literal genre values, including "None".
    nonisolated static func load(source: XperienceCollections.Source,
                     candidate: XperienceAddonBinding.Candidate,
                     skip: Int? = nil) async throws -> [CoreMeta] {
        try Task.checkCancellation()
        let url: URL
        do { url = try XperienceAddonBinding.catalogURL(source: source, candidate: candidate, skip: skip) }
        catch { throw Failure.unavailableSource }
        do {
            let response = try await AddonURLGuard.fetch(url, context: .xperienceCatalog)
            try Task.checkCancellation()
            return try decode(response.data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch {
            try Task.checkCancellation()
            throw Failure.unreachable
        }
    }

    /// The wire is the Stremio `metas` envelope. CoreMeta is the existing presentation DTO; raw
    /// Stremio rating/genres become its actual links representation before it reaches a browser.
    nonisolated static func decode(_ data: Data) throws -> [CoreMeta] {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= AddonURLGuard.ResponseContext.xperienceCatalog.maximumBytes else {
            throw Failure.invalidResponse
        }
        do {
            // Inspect original member bytes before decoding can erase duplicate names. This is
            // lexical admission only; JSONDecoder still validates the complete catalog value.
            try VortxNativeBootstrapArchive.requireUnambiguousJSON(data)
            try Task.checkCancellation()
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.metas.count <= maximumItems else { throw Failure.invalidResponse }
            var identities = Set<Identity>()
            return try envelope.metas.map { item in
                try Task.checkCancellation()
                guard !item.preview.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !item.preview.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !item.preview.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      identities.insert(.init(type: item.preview.type, id: item.preview.id)).inserted else {
                    throw Failure.invalidResponse
                }
                return try item.project()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.invalidResponse
        }
    }

    private struct Identity: Hashable { let type: String; let id: String }
    private struct Envelope: Decodable { let metas: [Item] }
    private struct Link: Encodable { let name: String; let category: String; let url: String? }

    private struct Item: Decodable {
        let preview: CoreMeta
        let imdbRating: String?
        let genres: [String]?
        private enum CodingKeys: String, CodingKey { case imdbRating, genres }

        init(from decoder: Decoder) throws {
            preview = try CoreMeta(from: decoder)
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            imdbRating = try fields.decodeIfPresent(String.self, forKey: .imdbRating)
            genres = try fields.decodeIfPresent([String].self, forKey: .genres)
        }

        func project() throws -> CoreMeta {
            var links = preview.links ?? []
            var additions: [Link] = []
            if let imdbRating, !imdbRating.isEmpty,
               !links.contains(where: { $0.category.caseInsensitiveCompare("imdb") == .orderedSame }) {
                additions.append(.init(name: imdbRating, category: "imdb", url: nil))
            }
            let presentGenres = Set(links.filter { ["genre", "genres"].contains($0.category.lowercased()) }.map(\.name))
            var seenGenres = presentGenres
            for genre in genres ?? [] where !genre.isEmpty && seenGenres.insert(genre).inserted {
                additions.append(.init(name: genre, category: "Genres", url: nil))
            }
            if !additions.isEmpty {
                links += try JSONDecoder().decode([CoreLink].self, from: JSONEncoder().encode(additions))
            }
            return CoreMeta(id: preview.id, type: preview.type, name: preview.name,
                            poster: preview.poster, posterShape: preview.posterShape, logo: preview.logo,
                            background: preview.background, description: preview.description,
                            releaseInfo: preview.releaseInfo, links: links.isEmpty ? nil : links)
        }
    }
}
