import Foundation

/// Typed async client for the authenticated SIMKL data endpoints VortX uses, plus the
/// `SIMKLProvider` that plugs SIMKL into `ExternalScrobbleRegistry`. Depends on `SIMKLAuth` for a
/// bearer token and on `SIMKLModels` only.
///
/// SIMKL has NO live scrobble, so this exposes only watched-on-finish history and watchlist
/// (plan-to-watch). An actor so the shared instance is callable from anywhere without external locking.
actor SIMKLService {
    static let shared = SIMKLService(auth: .shared)

    private let auth: SIMKLAuth
    private let session: URLSession

    init(auth: SIMKLAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    // MARK: - History (mark watched on finish)

    /// Mark items watched (`POST /sync/history`).
    @discardableResult
    func addToHistory(_ items: SIMKLSyncItems) async throws -> Int {
        try await write(path: "/sync/history", items: items)
    }

    /// Remove items from history (`POST /sync/history/remove`).
    @discardableResult
    func removeFromHistory(_ items: SIMKLSyncItems) async throws -> Int {
        try await write(path: "/sync/history/remove", items: items)
    }

    // MARK: - Watchlist (plan-to-watch)

    /// Add items to the plan-to-watch list (`POST /sync/add-to-list`). Each item carries `to:"plantowatch"`.
    @discardableResult
    func addToWatchlist(_ items: SIMKLSyncItems) async throws -> Int {
        try await write(path: "/sync/add-to-list", items: items)
    }

    /// Remove items from the tracked lists (`POST /sync/history/remove`, which SIMKL applies across the
    /// user's lists). Best-effort: SIMKL has no dedicated plan-to-watch remove endpoint.
    @discardableResult
    func removeFromWatchlist(_ items: SIMKLSyncItems) async throws -> Int {
        try await write(path: "/sync/history/remove", items: items)
    }

    // MARK: - HTTP plumbing

    private func write(path: String, items: SIMKLSyncItems) async throws -> Int {
        let token = try await auth.validToken()
        guard let url = URL(string: SIMKLAuth.apiBase + path) else { throw SIMKLError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SIMKLAuth.clientID, forHTTPHeaderField: "simkl-api-key")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(items)
        let (_, status) = try await perform(request)
        try expectSuccess(status)
        return status
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw SIMKLError.transport(error.localizedDescription)
        }
    }

    private func expectSuccess(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw SIMKLError.notSignedIn
        default: throw SIMKLError.server(status: status)
        }
    }
}

// MARK: - SIMKL provider

/// SIMKL implementation of `ExternalScrobbleProvider`. Capability flags: no live scrobble, but history
/// (watched-on-finish) and watchlist. The coordinator therefore only ever calls `recordWatched` and the
/// watchlist ops on SIMKL, so a pause never reaches `/sync/history`.
struct SIMKLProvider: ExternalScrobbleProvider {
    let id = "simkl"
    let capabilities = ExternalScrobbleCapabilities(liveScrobble: false, history: true, watchlist: true)

    func isConnected() async -> Bool {
        guard SIMKLAuth.isConfigured else { return false }
        return await SIMKLAuth.shared.isSignedIn
    }

    var scrobbleEnabled: Bool { SIMKLAuth.isConfigured && ExternalSyncToggle.isOn(ExternalSyncToggle.simklScrobble) }
    var watchlistEnabled: Bool { SIMKLAuth.isConfigured && ExternalSyncToggle.isOn(ExternalSyncToggle.simklWatchlist) }

    // No live scrobble: these are no-ops (the coordinator also skips them by capability).
    func scrobbleStart(_ ref: ExternalMediaRef) async {}
    func scrobblePause(_ ref: ExternalMediaRef) async {}
    func scrobbleStop(_ ref: ExternalMediaRef) async {}

    func recordWatched(_ ref: ExternalMediaRef) async {
        guard let items = historyItems(ref) else { return }
        _ = try? await SIMKLService.shared.addToHistory(items)
    }

    func addToWatchlist(_ ref: ExternalMediaRef) async {
        guard let items = watchlistItems(ref) else { return }
        _ = try? await SIMKLService.shared.addToWatchlist(items)
    }

    func removeFromWatchlist(_ ref: ExternalMediaRef) async {
        guard let items = watchlistItems(ref, includeStatus: false) else { return }
        _ = try? await SIMKLService.shared.removeFromWatchlist(items)
    }

    // MARK: Mapping neutral ref -> SIMKL wire types

    private func ids(_ ref: ExternalMediaRef) -> SIMKLIDs {
        SIMKLIDs(imdb: (ref.imdb?.isEmpty == false) ? ref.imdb : nil, tmdb: ref.tmdb)
    }

    /// Watched payload. A movie is a plain movie; a series episode is the SHOW carrying the one season +
    /// episode number (SIMKL's canonical nested episode shape).
    private func historyItems(_ ref: ExternalMediaRef) -> SIMKLSyncItems? {
        guard ref.hasUsableID else { return nil }
        if ref.isSeries {
            guard let season = ref.season, let number = ref.episode else {
                return SIMKLSyncItems(shows: [SIMKLShow(ids: ids(ref), title: ref.title, year: ref.year)])
            }
            let show = SIMKLShow(ids: ids(ref), title: ref.title, year: ref.year,
                                 seasons: [SIMKLSeason(number: season, episodes: [SIMKLEpisodeNumber(number: number)])])
            return SIMKLSyncItems(shows: [show])
        }
        return SIMKLSyncItems(movies: [SIMKLMovie(ids: ids(ref), title: ref.title, year: ref.year)])
    }

    /// Watchlist payload: the WHOLE title (movie or show). `includeStatus` sets `to:"plantowatch"` on the
    /// add path; the remove path omits it.
    private func watchlistItems(_ ref: ExternalMediaRef, includeStatus: Bool = true) -> SIMKLSyncItems? {
        guard ref.hasUsableID else { return nil }
        let status = includeStatus ? "plantowatch" : nil
        if ref.isSeries {
            return SIMKLSyncItems(shows: [SIMKLShow(ids: ids(ref), title: ref.title, year: ref.year, to: status)])
        }
        return SIMKLSyncItems(movies: [SIMKLMovie(ids: ids(ref), title: ref.title, year: ref.year, to: status)])
    }
}
