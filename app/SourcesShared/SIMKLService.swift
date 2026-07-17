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

    /// S-3: the next instant a data POST is allowed to fire, on the MONOTONIC uptime clock. Each `write`
    /// RESERVES a slot before sleeping (advancing this by `minPostInterval`), so concurrent callers queue
    /// into distinct 1-second slots and a burst can never exceed SIMKL's 1-POST/sec limit even if a future
    /// caller batches writes. `DispatchTime` rather than wall-clock `Date`: a large BACKWARD system-clock
    /// jump would park a `Date` slot in the apparent far future and wedge every SIMKL write until relaunch,
    /// while the uptime clock never runs backward (forward jumps were always harmless).
    private var nextPostSlot: DispatchTime?
    private static let minPostInterval: TimeInterval = 1.0

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

    // NOTE: there is deliberately NO watchlist-remove call here. SIMKL has no plan-to-watch remove
    // endpoint, and `/sync/history/remove` deletes WATCH HISTORY (a show payload wipes every episode +
    // its status), so a library-remove must never route to it. The provider's `removeFromWatchlist`
    // is a no-op instead (see `SIMKLProvider`).

    // MARK: - List reads (the read-back side)

    /// One list of one type (`GET /sync/all-items/{type}/{status}`), flattened to neutral entries.
    ///
    /// READS ARE NOT RATE-GATED. The S-3 gate exists for SIMKL's 1-POST/sec write limit; putting GETs
    /// through it would serialize the three type reads a second apart for no reason and, worse, would let
    /// a rail refresh push the write slot into the future and delay a user's "mark watched" behind it.
    func list(type: SIMKLListType, status: SIMKLListStatus) async throws -> [SIMKLListEntry] {
        let data = try await read(path: "/sync/all-items/\(type.rawValue)/\(status.rawValue)")
        // SIMKL answers an EMPTY BODY (not `{}`) for a list with nothing in it. That is a success with zero
        // rows, so it must not surface as a decode error the caller might treat as an outage.
        guard !data.isEmpty else { return [] }
        let response = try decode(SIMKLAllItemsResponse.self, from: data)
        switch type {
        case .movies:
            return (response.movies ?? []).compactMap { entry in
                guard let movie = entry.movie else { return nil }
                return Self.entry(ids: movie.ids, title: movie.title, added: entry.addedToWatchlistAt, type: type)
            }
        case .shows, .anime:
            let rows = (type == .anime ? response.anime : response.shows) ?? []
            return rows.compactMap { entry in
                guard let show = entry.show else { return nil }
                return Self.entry(ids: show.ids, title: show.title, added: entry.addedToWatchlistAt, type: type)
            }
        }
    }

    /// The user's whole plan-to-watch list across movies, shows AND anime.
    ///
    /// Each type is fetched INDEPENDENTLY, and a type that throws contributes an empty list instead of
    /// failing the call. That matters most for the anime read: SIMKL's anime rows are shaped like shows,
    /// but anime is a separate catalogue, so if that one response ever shifts, the movies and shows the
    /// user actually has still reach the rail.
    ///
    /// Sequential on purpose. The three reads are one throttled rail refresh, not a user-blocking path, so
    /// there is nothing to win by firing them together, and three concurrent authenticated GETs is exactly
    /// the burst shape that gets an API key rate-limited (the lesson S-3 already encodes for writes).
    ///
    /// Signing-in state is checked ONCE up front so "not connected" surfaces as a thrown error rather than
    /// as an innocent-looking empty list, which the rail would otherwise render as "you have nothing saved".
    func planToWatch() async throws -> [SIMKLListEntry] {
        _ = try await auth.validToken()
        var out: [SIMKLListEntry] = []
        for type in SIMKLListType.allCases {
            out += (try? await list(type: type, status: .planToWatch)) ?? []
        }
        return out
    }

    /// Flatten one decoded row into a neutral entry, dropping rows with no id VortX can open a detail page
    /// with and no title to show.
    private static func entry(ids: SIMKLIDs, title: String?, added: String?, type: SIMKLListType) -> SIMKLListEntry? {
        let name = title ?? ""
        let imdb = (ids.imdb?.isEmpty == false) ? ids.imdb : nil
        guard imdb != nil || ids.tmdb != nil, !name.isEmpty else { return nil }
        return SIMKLListEntry(imdb: imdb, tmdb: ids.tmdb, title: name, type: type.appType, addedAt: added)
    }

    // MARK: - HTTP plumbing

    /// An authenticated GET against the data API, carrying the same required query items + headers every
    /// SIMKL request needs (S-4 / S-5).
    private func read(path: String) async throws -> Data {
        let token = try await auth.validToken()
        guard var components = URLComponents(string: SIMKLAuth.apiBase + path) else { throw SIMKLError.badURL }
        components.queryItems = SIMKLAuth.requiredQueryItems
        guard let url = components.url else { throw SIMKLError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SIMKLAuth.clientID, forHTTPHeaderField: "simkl-api-key")
        request.setValue(SIMKLAuth.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await perform(request)
        try expectSuccess(status)
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw SIMKLError.decoding }
    }

    private func write(path: String, items: SIMKLSyncItems) async throws -> Int {
        let token = try await auth.validToken()
        try await rateGate()
        guard var components = URLComponents(string: SIMKLAuth.apiBase + path) else { throw SIMKLError.badURL }
        // SIMKL requires client_id / app-name / app-version on EVERY request (S-4).
        components.queryItems = SIMKLAuth.requiredQueryItems
        guard let url = components.url else { throw SIMKLError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SIMKLAuth.clientID, forHTTPHeaderField: "simkl-api-key")
        request.setValue(SIMKLAuth.userAgent, forHTTPHeaderField: "User-Agent")   // S-5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(items)
        let (_, status) = try await perform(request)
        try expectSuccess(status)
        return status
    }

    /// S-3 serial 1-POST/sec gate. RESERVE-then-sleep: reading `nextPostSlot`, computing this call's slot,
    /// and advancing `nextPostSlot` all happen synchronously in one actor turn (no await between), so two
    /// concurrent writes reserve DISTINCT slots rather than both reading the same stale timestamp and
    /// firing together. The reserved wait is then slept off before the request goes out (the actor is
    /// released during the sleep). Slots live on the monotonic uptime clock, immune to wall-clock jumps.
    private func rateGate() async throws {
        let now = DispatchTime.now()
        let slot = (nextPostSlot.map { $0 > now ? $0 : now }) ?? now
        nextPostSlot = slot + Self.minPostInterval
        let waitNanos = slot.uptimeNanoseconds - now.uptimeNanoseconds   // slot >= now by construction
        if waitNanos > 0 {
            try await Task.sleep(nanoseconds: waitNanos)
        }
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

    // A library-remove is a NO-OP on SIMKL. SIMKL exposes no plan-to-watch remove endpoint, and the only
    // "remove" it offers (`/sync/history/remove`) deletes the user's WATCH HISTORY for the title (a show
    // payload removes every episode + status, with no undo). Silently destroying watch history from a
    // watchlist-remove intent is never acceptable, so removing a title from the VortX library leaves the
    // SIMKL plan-to-watch entry in place rather than risk that.
    func removeFromWatchlist(_ ref: ExternalMediaRef) async {}

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

    /// Watchlist add payload: the WHOLE title (movie or show) tagged `to:"plantowatch"`. Only the add
    /// path uses this; a library-remove is a no-op on SIMKL (see `removeFromWatchlist`).
    private func watchlistItems(_ ref: ExternalMediaRef) -> SIMKLSyncItems? {
        guard ref.hasUsableID else { return nil }
        if ref.isSeries {
            return SIMKLSyncItems(shows: [SIMKLShow(ids: ids(ref), title: ref.title, year: ref.year, to: "plantowatch")])
        }
        return SIMKLSyncItems(movies: [SIMKLMovie(ids: ids(ref), title: ref.title, year: ref.year, to: "plantowatch")])
    }
}
