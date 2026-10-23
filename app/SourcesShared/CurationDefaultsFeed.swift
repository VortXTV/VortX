import Foundation

/// A bounded public definition feed, not a saved profile companion or an import transport.
struct CurationDefaultsFeed: Sendable {
    static let maximumBytes = 16_384
    static let maximumCollections = 8
    let raw: VortxJSON
    let revision: String
    let collections: [CurationCollection]

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw CurationDefaultsFailure.invalidDocument }
        do {
            try VortxNativeBootstrapArchive.requireUnambiguousJSON(data)
            let raw = try JSONDecoder().decode(VortxJSON.self, from: data)
            guard raw["schemaVersion"] == .integer(1),
                  case .array(let entries) = raw["collections"],
                  !entries.isEmpty, entries.count <= Self.maximumCollections else {
                throw CurationDefaultsFailure.invalidDocument
            }
            let revision = try Self.text(raw["revision"], limit: 256)
            var seen = Set<String>()
            let collections = try entries.map { entry -> CurationCollection in
                let id = try Self.text(entry["id"], limit: 128)
                guard id.hasPrefix("vortx."), id.utf8.count > 6,
                      id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }),
                      seen.insert(id).inserted else {
                    throw CurationDefaultsFailure.invalidDocument
                }
                let name = try Self.text(entry["name"], limit: 256)
                _ = try Self.text(entry["revision"], limit: 256)
                guard let base = entry["base"] else { throw CurationDefaultsFailure.invalidDocument }
                let projection = try CurationDocument.projectPublicBase(base)
                return CurationCollection(id: id, name: name, home: false, pinned: projection.pinned,
                    folders: projection.folders, presentation: projection.presentation, artwork: projection.artwork)
            }
            self.raw = raw; self.revision = revision; self.collections = collections
        } catch {
            throw CurationDefaultsFailure.invalidDocument
        }
    }

    private static func text(_ value: VortxJSON?, limit: Int) throws -> String {
        guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= limit else {
            throw CurationDefaultsFailure.invalidDocument
        }
        return text
    }
}

enum CurationDefaultsFailure: Error, Equatable, Sendable {
    case invalidDocument, transport
    case http(Int)
}

struct CurationDefaultsRequestScope: Equatable, Sendable {
    let endpoint: URL
    let lifecycle: SourceIndexLifecycleSnapshot
    let isSignedIn: Bool

    /// Uses the existing account/consent lifecycle, not a new account or native mutation epoch.
    var isCurrent: Bool {
        lifecycle == SourceIndexLifecycleClock.snapshot()
            && endpoint == CurationDefaultsClient.endpoint(catalogs: RemoteConfig.snapshot.catalogsEndpoint)
    }
}

enum CurationDefaultsClient {
    /// Deliberately independent of ApiKeys and TMDBClient's direct-key/fallback route.
    /// A remote config value is not authority to send a MOAT token to an arbitrary origin.
    static func endpoint(catalogs: URL) -> URL? {
        guard var parts = URLComponents(url: catalogs, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "catalogs.vortx.tv",
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        // Canonicalize the admitted origin for the existing case-sensitive signer host lookup.
        parts.scheme = "https"; parts.host = "catalogs.vortx.tv"; parts.port = nil
        parts.path = "/curation/v1/defaults"
        parts.query = nil; parts.fragment = nil
        return parts.url
    }

    /// A nonisolated async service. The bounded lexical and value decodes do not run on MainActor.
    static func load(_ scope: CurationDefaultsRequestScope) async throws -> CurationDefaultsFeed {
        try Task.checkCancellation()
        guard scope.isCurrent else { throw CancellationError() }
        var request = URLRequest(url: scope.endpoint, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        VortXEdgeAuth.sign(&request)
        await MoatToken.shared.stamp(&request, isSignedIn: scope.isSignedIn)
        try Task.checkCancellation()
        guard scope.isCurrent else { throw CancellationError() }
        do {
            let response = try await AuthenticatedHTTPTransport.shared.send(request,
                allowedHosts: ["catalogs.vortx.tv"], maxResponseBytes: CurationDefaultsFeed.maximumBytes)
            try Task.checkCancellation()
            guard scope.isCurrent else { throw CancellationError() }
            guard response.statusCode == 200 else { throw CurationDefaultsFailure.http(response.statusCode) }
            let feed = try CurationDefaultsFeed(data: response.data)
            try Task.checkCancellation()
            guard scope.isCurrent else { throw CancellationError() }
            return feed
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as CurationDefaultsFailure {
            throw failure
        } catch {
            try Task.checkCancellation()
            guard scope.isCurrent else { throw CancellationError() }
            throw CurationDefaultsFailure.transport
        }
    }
}
