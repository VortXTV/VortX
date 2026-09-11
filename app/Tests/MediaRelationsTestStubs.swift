// Peripheral collaborators only; tests compile the real CoreModels and relation parser.
import Foundation
// MARK: - Minimal CoreModels dependencies

enum DebridService: String { case torBox }
struct DebridEpisode { let season: Int; let episode: Int }

enum LastStreamStore {
    struct Entry {
        let videoId: String
        let url: String
        let type: String
        let debridService: String?
        let infoHash: String?
        let linkSavedAt: Date?
        let debridTorrentId: Int?
        let debridFileId: Int?
        let fileIdx: Int?
        let season: Int?
        let episode: Int?
    }
}

actor DebridCoordinator {
    static let shared = DebridCoordinator()
    func reresolve(service: DebridService, infoHash: String, torrentId: Int?, fileId: Int?, fileIdx: Int?,
                   episode: DebridEpisode? = nil, requiresSemanticSelection: Bool) async throws -> URL {
        throw StubError.unavailable
    }
}

enum StubError: Error { case unavailable }

enum VortXSyncManager { static var appliedAddonOrder: [String] = [] }
enum AddonTombstones { static func normalize(_ value: String) -> String { value } }

final class DebridKeys {
    static let shared = DebridKeys()
    func isConfigured(_ service: DebridService) -> Bool { false }
}

enum UsenetProviderStore { static let isConfigured = false }

enum StremioServer {
    static let usenetNodeBase: String? = nil
    static let base = "http://127.0.0.1:11470"
    static let trailerResolverBase = "https://trailer.invalid"
}

enum PlaybackSettings { static let torrentsDisabled = false }

// CoreModels routes community JavaScript streams through this production collaborator. The identity suite
// does not exercise that transport, so keep the standalone compile focused on the model predicates.
final class CommunityStreamGateway {
    static let shared = CommunityStreamGateway()
    func localURLIfReady(for stream: CoreStream, upstream: URL) -> URL? { upstream }
}

// MARK: - Assertions

private var failures = 0
