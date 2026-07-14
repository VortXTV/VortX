import Foundation

/// Typed async client for the authenticated Trakt.tv data endpoints used by VortX.
///
/// This is the service layer. It is wired into playback + library through `ExternalScrobbleProvider`
/// (the Trakt provider) and `ScrobbleCoordinator`, and into the rails via `TraktRailsModel`. It depends on
/// `TraktAuth` for a live bearer token and on the `TraktModels` types, nothing else (Foundation + Keychain).
///
/// Endpoints covered (https://trakt.docs.apiary.io):
///   - Scrobble:  POST /scrobble/start, /scrobble/pause, /scrobble/stop   (player progress -> Trakt)
///   - Watchlist: POST /sync/watchlist, POST /sync/watchlist/remove, GET /sync/watchlist
///   - History:   POST /sync/history (mark watched), POST /sync/history/remove
///   - Collection: GET /sync/collection
///
/// An actor so the shared instance is safe to call from anywhere (player thread, library actions)
/// without external locking. Every write goes out with a fresh, auto-refreshed access token.
actor TraktService {
    static let shared = TraktService(auth: .shared)

    private let auth: TraktAuth
    private let session: URLSession

    init(auth: TraktAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    // MARK: - Scrobble (player progress)

    /// Call when playback starts or resumes. `progress` is 0...100. Trakt marks the item as
    /// "watching" and auto-expires it after the remaining runtime, so there is no need to repeat
    /// this for the same item while it keeps playing.
    @discardableResult
    func scrobbleStart(item: TraktScrobbleItem, progress: Double) async throws -> TraktScrobbleResponse {
        try await scrobble(path: "/scrobble/start", item: item, progress: progress)
    }

    /// Call when playback pauses. Trakt saves the progress so the item can resume later.
    @discardableResult
    func scrobblePause(item: TraktScrobbleItem, progress: Double) async throws -> TraktScrobbleResponse {
        try await scrobble(path: "/scrobble/pause", item: item, progress: progress)
    }

    /// Call when playback stops or finishes. Above 80% progress Trakt records a watch (action
    /// `.scrobble`, with a history `id`); between 1% and 79% it records a pause. Below 1% Trakt
    /// answers HTTP 422 and the call throws `.ignored`.
    @discardableResult
    func scrobbleStop(item: TraktScrobbleItem, progress: Double) async throws -> TraktScrobbleResponse {
        try await scrobble(path: "/scrobble/stop", item: item, progress: progress)
    }

    private func scrobble(path: String, item: TraktScrobbleItem, progress: Double) async throws -> TraktScrobbleResponse {
        let body = ScrobbleBody(item: item, progress: clampProgress(progress))
        let (data, status) = try await send(path: path, method: "POST", body: body)
        if status == 422 { throw TraktServiceError.ignored }
        try expectSuccess(status)
        return try decode(TraktScrobbleResponse.self, from: data)
    }

    // MARK: - Watchlist (library "want to watch")

    /// Add movies/shows/episodes to the user's Trakt watchlist (`POST /sync/watchlist`).
    @discardableResult
    func addToWatchlist(_ items: TraktSyncItems) async throws -> TraktSyncResponse {
        try await syncWrite(path: "/sync/watchlist", items: items)
    }

    /// Remove items from the watchlist (`POST /sync/watchlist/remove`).
    @discardableResult
    func removeFromWatchlist(_ items: TraktSyncItems) async throws -> TraktSyncResponse {
        try await syncWrite(path: "/sync/watchlist/remove", items: items)
    }

    /// The user's full watchlist (`GET /sync/watchlist`).
    func watchlist() async throws -> [TraktWatchlistEntry] {
        let (data, status) = try await send(path: "/sync/watchlist", method: "GET")
        try expectSuccess(status)
        return try decode([TraktWatchlistEntry].self, from: data)
    }

    // MARK: - History (mark watched)

    /// Mark items watched by adding them to history (`POST /sync/history`). Pass `watchedAt` to
    /// backdate; the default lets Trakt stamp "now".
    @discardableResult
    func markWatched(_ items: TraktSyncItems) async throws -> TraktSyncResponse {
        try await syncWrite(path: "/sync/history", items: items)
    }

    /// Remove items from watch history (`POST /sync/history/remove`).
    @discardableResult
    func removeFromHistory(_ items: TraktSyncItems) async throws -> TraktSyncResponse {
        try await syncWrite(path: "/sync/history/remove", items: items)
    }

    // MARK: - Collection (library "owned")

    /// The user's collection (`GET /sync/collection`). `type` is "movies" or "shows".
    func collection(type: TraktCollectionType) async throws -> [TraktCollectionEntry] {
        let (data, status) = try await send(path: "/sync/collection/\(type.rawValue)", method: "GET")
        try expectSuccess(status)
        return try decode([TraktCollectionEntry].self, from: data)
    }

    private func syncWrite(path: String, items: TraktSyncItems) async throws -> TraktSyncResponse {
        let (data, status) = try await send(path: path, method: "POST", body: items)
        try expectSuccess(status)
        return try decode(TraktSyncResponse.self, from: data)
    }

    // MARK: - HTTP plumbing

    /// Authenticated request: pulls a live bearer from `TraktAuth` (refreshing if needed) and sets
    /// the three headers Trakt requires on every call.
    private func makeRequest(path: String, method: String) async throws -> URLRequest {
        guard let url = URL(string: TraktAuth.apiBase + path) else { throw TraktServiceError.badURL }
        let token = try await auth.validToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(TraktAuth.clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(path: String, method: String) async throws -> (Data, Int) {
        let request = try await makeRequest(path: path, method: method)
        return try await perform(request)
    }

    private func send<Body: Encodable>(path: String, method: String, body: Body) async throws -> (Data, Int) {
        var request = try await makeRequest(path: path, method: method)
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw TraktServiceError.transport(error.localizedDescription)
        }
    }

    private func expectSuccess(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw TraktServiceError.unauthorized
        case 420, 429: throw TraktServiceError.rateLimited
        default: throw TraktServiceError.server(status: status)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw TraktServiceError.decoding }
    }

    /// Trakt rejects progress outside 0...100; keep it in range.
    private func clampProgress(_ value: Double) -> Double { min(max(value, 0), 100) }
}

// MARK: - Scrobble item

/// A scrobble target: a movie, an episode by its own id, or an episode anchored to its show. Encodes
/// to the `{ movie: {...} }` / `{ episode: {...}, show: {...} }` shape Trakt's scrobble endpoints take.
enum TraktScrobbleItem: Sendable, Encodable {
    case movie(TraktMovie)
    case episode(TraktEpisode)
    case episodeInShow(show: TraktShow, episode: TraktEpisode)

    private enum CodingKeys: String, CodingKey { case movie, episode, show }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .movie(let movie):
            try c.encode(movie, forKey: .movie)
        case .episode(let episode):
            try c.encode(episode, forKey: .episode)
        case .episodeInShow(let show, let episode):
            try c.encode(show, forKey: .show)
            try c.encode(episode, forKey: .episode)
        }
    }
}

/// Body for the scrobble endpoints: the item flattened in with a `progress` field.
private struct ScrobbleBody: Encodable {
    let item: TraktScrobbleItem
    let progress: Double

    enum CodingKeys: String, CodingKey { case movie, episode, show, progress }

    func encode(to encoder: Encoder) throws {
        // Flatten the item's keys (movie/episode/show) to the top level alongside progress.
        try item.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(progress, forKey: .progress)
    }
}

/// Collection type selector for `GET /sync/collection/{type}`.
enum TraktCollectionType: String, Sendable {
    case movies
    case shows
}

/// Typed errors for the Trakt data calls.
enum TraktServiceError: LocalizedError, Sendable, Equatable {
    case badURL
    case unauthorized
    case rateLimited
    case ignored          // scrobble below 1% progress (HTTP 422)
    case server(status: Int)
    case transport(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .badURL: return "The Trakt service URL is invalid."
        case .unauthorized: return "Your Trakt session has expired. Please reconnect."
        case .rateLimited: return "Trakt is rate limiting requests. Please try again shortly."
        case .ignored: return "Too little was watched to record on Trakt."
        case .server(let status): return "Trakt returned an error (HTTP \(status))."
        case .transport(let message): return message
        case .decoding: return "Could not read the response from Trakt."
        }
    }
}

// MARK: - Wiring notes (where this is integrated)
//
// 1. Player progress -> scrobble. In the libmpv player core (`Sources/Player/`), where playback
//    state transitions are already observed (the same place that feeds Continue Watching /
//    `reportProgress`), call:
//       - on play/resume:  `await TraktService.shared.scrobbleStart(item:progress:)`
//       - on pause:        `await TraktService.shared.scrobblePause(item:progress:)`
//       - on stop/finish:  `await TraktService.shared.scrobbleStop(item:progress:)`
//    Build the `TraktScrobbleItem` from the playing meta's imdb id:
//       movie:   `.movie(TraktMovie(ids: .imdb(imdbID)))`
//       episode: `.episodeInShow(show: TraktShow(ids: .imdb(showImdbID)),
//                                episode: TraktEpisode(season: s, number: e))`
//    `progress` is the 0...100 percentage the player already computes for resume points.
//    Gate every call on `await TraktAuth.shared.isSignedIn` so it no-ops when Trakt is not connected,
//    and only fire for the MAIN profile (mirror `ProfileStore.activeUsesEngineHistory`) so overlay
//    profiles never push to a shared Trakt account. Wrap in `try?` so a Trakt outage never blocks
//    playback.
//
// 2. Library add -> watchlist. Where the app adds a title to the library (the DetailView "add" action
//    that dispatches the engine `AddToLibrary`), also call, behind the sign-in gate:
//       `try? await TraktService.shared.addToWatchlist(
//            TraktSyncItems(movies: [TraktMovie(ids: .imdb(imdbID))]))`
//    For a series use `shows:` instead. Mirror the library "remove" action to `removeFromWatchlist`.
//    Marking an episode/movie watched in the app can additionally call `markWatched(_:)`.
//
// 3. "Connect Trakt" Settings entry. Add a row to the settings/account surface (alongside the
//    existing Stremio sign-in and sync rows in `SyncSettingsView` / the iOS settings screen):
//       - Show "Connect Trakt" when `await TraktAuth.shared.isSignedIn == false`.
//       - On tap: `let code = try await TraktAuth.shared.requestDeviceCode()`, present
//         `code.userCode` + `code.verificationURL` (a QR of the URL fits the existing link-login UI
//         in `LinkLoginView`), then `try await TraktAuth.shared.pollForToken(
//             deviceCode: code.deviceCode, interval: code.interval, expiresIn: code.expiresIn)`.
//       - When signed in, show "Disconnect Trakt" -> `await TraktAuth.shared.signOut()`.
//    Gate the whole row on `TraktAuth.isConfigured` so it stays hidden until the client id/secret
//    constants are filled in.
