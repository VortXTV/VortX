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
    private let transport: AuthenticatedHTTPTransport

    /// S-3: the next instant a data POST is allowed to fire, on the MONOTONIC uptime clock. Each `write`
    /// RESERVES a slot before sleeping (advancing this by `minPostInterval`), so concurrent callers queue
    /// into distinct 1-second slots and a burst can never exceed SIMKL's 1-POST/sec limit even if a future
    /// caller batches writes. `DispatchTime` rather than wall-clock `Date`: a large BACKWARD system-clock
    /// jump would park a `Date` slot in the apparent far future and wedge every SIMKL write until relaunch,
    /// while the uptime clock never runs backward (forward jumps were always harmless).
    private var nextPostSlot: DispatchTime?
    private static let minPostInterval: TimeInterval = 1.0

    init(auth: SIMKLAuth, transport: AuthenticatedHTTPTransport = .shared) {
        self.auth = auth
        self.transport = transport
    }

    // MARK: - History (mark watched on finish)

    /// Mark items watched (`POST /sync/history`).
    @discardableResult
    func addToHistory(
        _ items: SIMKLSyncItems,
        expectedSession: SIMKLSessionID
    ) async throws -> Int {
        try await write(path: "/sync/history", items: items, expectedSession: expectedSession)
    }

    /// Remove items from history (`POST /sync/history/remove`).
    @discardableResult
    func removeFromHistory(
        _ items: SIMKLSyncItems,
        expectedSession: SIMKLSessionID
    ) async throws -> Int {
        try await write(path: "/sync/history/remove", items: items, expectedSession: expectedSession)
    }

    // MARK: - Ratings (`POST /sync/ratings`, `/sync/ratings/remove`, and the `/sync/ratings/{type}` read-back)

    /// Add (or change) the user's title ratings (`POST /sync/ratings`). Anime ride the `shows` array. Rate-gated
    /// like every other SIMKL POST write.
    @discardableResult
    func addRatings(
        _ items: SIMKLRatingItems,
        expectedSession: SIMKLSessionID
    ) async throws -> Int {
        try await writeEncodable(path: "/sync/ratings", body: items, expectedSession: expectedSession)
    }

    /// Un-rate titles (`POST /sync/ratings/remove`): the ids alone identify what to clear, no `rating` field.
    @discardableResult
    func removeRatings(
        _ items: SIMKLRatingItems,
        expectedSession: SIMKLSessionID
    ) async throws -> Int {
        try await writeEncodable(path: "/sync/ratings/remove", body: items, expectedSession: expectedSession)
    }

    /// The user's own ratings across movies, shows AND anime (`POST /sync/ratings/{type}`).
    ///
    /// Read PER TYPE, not via a bare `POST /sync/ratings`: that path with no body is the ADD endpoint (it would
    /// return an `{added,…}` envelope, not the ratings list), so the read MUST carry a `{type}` segment. Each
    /// leg is a read (no state change), so it is NOT rate-gated and carries no body; a leg that throws
    /// contributes nothing rather than failing the whole call (ratings convergence is additive - absence never
    /// deletes - so a missing anime leg only defers that type a cycle, unlike the watched REPLACE). Sequential
    /// for the same reason `planToWatch` is: three authenticated POSTs fired together is exactly the burst shape
    /// that gets rate-limited.
    func ratings(expectedSession: SIMKLSessionID) async throws -> SIMKLRatingsResponse {
        _ = try await auth.validToken(for: expectedSession)
        var movies: [SIMKLRatingEntry] = []
        var shows: [SIMKLRatingEntry] = []
        var anime: [SIMKLRatingEntry] = []
        for type in SIMKLListType.allCases {
            do {
                let leg = try await ratingsRead(type: type, expectedSession: expectedSession)
                movies += leg.movies ?? []
                shows += leg.shows ?? []
                anime += leg.anime ?? []
            } catch SIMKLError.sessionChanged {
                throw SIMKLError.sessionChanged
            } catch {
                continue
            }
        }
        return SIMKLRatingsResponse(movies: movies, shows: shows, anime: anime)
    }

    /// One ratings-read leg: `POST /sync/ratings/{type}` with no body, decoded to the ratings envelope.
    private func ratingsRead(
        type: SIMKLListType,
        expectedSession: SIMKLSessionID
    ) async throws -> SIMKLRatingsResponse {
        let data = try await readPost(
            path: "/sync/ratings/\(type.rawValue)",
            expectedSession: expectedSession
        )
        // SIMKL answers an EMPTY BODY for a type the user has rated nothing in; that is a success with zero rows.
        guard !data.isEmpty else { return SIMKLRatingsResponse(movies: nil, shows: nil, anime: nil) }
        return try decode(SIMKLRatingsResponse.self, from: data)
    }

    // MARK: - Watchlist (plan-to-watch)

    /// Add items to the plan-to-watch list (`POST /sync/add-to-list`). Each item carries `to:"plantowatch"`.
    @discardableResult
    func addToWatchlist(
        _ items: SIMKLSyncItems,
        expectedSession: SIMKLSessionID
    ) async throws -> Int {
        try await write(path: "/sync/add-to-list", items: items, expectedSession: expectedSession)
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
    func list(
        type: SIMKLListType,
        status: SIMKLListStatus,
        expectedSession: SIMKLSessionID
    ) async throws -> [SIMKLListEntry] {
        let data = try await read(
            path: "/sync/all-items/\(type.rawValue)/\(status.rawValue)",
            expectedSession: expectedSession
        )
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
    /// All three type reads form one snapshot. If any leg fails, the whole read fails so callers retain their
    /// prior complete snapshot instead of publishing a plausible-looking movies-only or shows-only result.
    ///
    /// Sequential on purpose. The three reads are one throttled rail refresh, not a user-blocking path, so
    /// there is nothing to win by firing them together, and three concurrent authenticated GETs is exactly
    /// the burst shape that gets an API key rate-limited (the lesson S-3 already encodes for writes).
    ///
    /// Signing-in state is checked ONCE up front so "not connected" surfaces as a thrown error rather than
    /// as an innocent-looking empty list, which the rail would otherwise render as "you have nothing saved".
    func planToWatch(expectedSession: SIMKLSessionID) async throws -> [SIMKLListEntry] {
        _ = try await auth.validToken(for: expectedSession)
        var out: [SIMKLListEntry] = []
        for type in SIMKLListType.allCases {
            out += try await list(
                type: type,
                status: .planToWatch,
                expectedSession: expectedSession
            )
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
    private func read(path: String, expectedSession: SIMKLSessionID) async throws -> Data {
        let token = try await auth.validToken(for: expectedSession)
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
        let (data, status) = try await perform(
            request,
            maxResponseBytes: AuthenticatedHTTPTransport.snapshotResponseLimit
        )
        guard await auth.sessionID == expectedSession else { throw SIMKLError.sessionChanged }
        try expectSuccess(status)
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try AuthenticatedHTTPTransport.decodeJSON(type, from: data) }
        catch { throw SIMKLError.decoding }
    }

    private func write(
        path: String,
        items: SIMKLSyncItems,
        expectedSession: SIMKLSessionID
    ) async throws -> Int {
        try await writeEncodable(path: path, body: items, expectedSession: expectedSession)
    }

    /// A rate-gated authenticated POST carrying any Encodable body (history / watchlist / ratings all share
    /// this). Generic so the ratings write paths reuse the exact same S-3 gate + S-4/S-5 headers as the history
    /// and watchlist writes rather than forking a second POST path that could drift.
    private func writeEncodable<T: Encodable & Sendable>(
        path: String,
        body: T,
        expectedSession: SIMKLSessionID
    ) async throws -> Int {
        try await rateGate()
        let bodyData = try JSONEncoder().encode(body)
        let transport = transport
        let status: Int = try await auth.performSessionBoundWrite(
            expectedSession: expectedSession
        ) { token in
            guard var components = URLComponents(string: SIMKLAuth.apiBase + path) else {
                throw SIMKLError.badURL
            }
            components.queryItems = SIMKLAuth.requiredQueryItems
            guard let url = components.url else { throw SIMKLError.badURL }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(SIMKLAuth.clientID, forHTTPHeaderField: "simkl-api-key")
            request.setValue(SIMKLAuth.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = bodyData
            do {
                let response = try await transport.send(
                    request,
                    allowedHosts: ["api.simkl.com"],
                    maxResponseBytes: AuthenticatedHTTPTransport.controlResponseLimit
                )
                return response.statusCode
            } catch {
                throw SIMKLError.transport("SIMKL request failed.")
            }
        }
        if status == 401 || status == 403 {
            await auth.signOut(ifCurrent: expectedSession)
        }
        try expectSuccess(status)
        return status
    }

    /// An authenticated POST with NO body, used for the ratings read-back (`POST /sync/ratings/{type}`), which
    /// SIMKL models as a POST even though it retrieves. NOT rate-gated: it is a read (the S-3 gate exists for the
    /// 1-POST/sec WRITE limit, and gating reads would serialize convergence behind a user's "mark watched").
    private func readPost(path: String, expectedSession: SIMKLSessionID) async throws -> Data {
        let token = try await auth.validToken(for: expectedSession)
        guard var components = URLComponents(string: SIMKLAuth.apiBase + path) else { throw SIMKLError.badURL }
        components.queryItems = SIMKLAuth.requiredQueryItems
        guard let url = components.url else { throw SIMKLError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SIMKLAuth.clientID, forHTTPHeaderField: "simkl-api-key")
        request.setValue(SIMKLAuth.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await perform(
            request,
            maxResponseBytes: AuthenticatedHTTPTransport.snapshotResponseLimit
        )
        guard await auth.sessionID == expectedSession else { throw SIMKLError.sessionChanged }
        try expectSuccess(status)
        return data
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

    private func perform(
        _ request: URLRequest,
        maxResponseBytes: Int
    ) async throws -> (Data, Int) {
        do {
            let response = try await transport.send(
                request,
                allowedHosts: ["api.simkl.com"],
                maxResponseBytes: maxResponseBytes
            )
            return (response.data, response.statusCode)
        } catch {
            throw SIMKLError.transport("SIMKL request failed.")
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
    func scrobbleStart(_ ref: ExternalMediaRef, session: ExternalProviderSession?) async {}
    func scrobblePause(_ ref: ExternalMediaRef, session: ExternalProviderSession?) async {}
    func scrobbleStop(_ ref: ExternalMediaRef, session: ExternalProviderSession?) async {}

    func recordWatched(_ ref: ExternalMediaRef, session: ExternalProviderSession?) async {
        guard case .simkl(let sessionID) = session,
              SIMKLAuth.storedSessionID == sessionID,
              let items = historyItems(ref) else { return }
        _ = try? await SIMKLService.shared.addToHistory(items, expectedSession: sessionID)
    }

    func addToWatchlist(_ ref: ExternalMediaRef, session: ExternalProviderSession?) async {
        guard case .simkl(let sessionID) = session,
              SIMKLAuth.storedSessionID == sessionID,
              let items = watchlistItems(ref) else { return }
        _ = try? await SIMKLService.shared.addToWatchlist(items, expectedSession: sessionID)
    }

    // A library-remove is a NO-OP on SIMKL. SIMKL exposes no plan-to-watch remove endpoint, and the only
    // "remove" it offers (`/sync/history/remove`) deletes the user's WATCH HISTORY for the title (a show
    // payload removes every episode + status, with no undo). Silently destroying watch history from a
    // watchlist-remove intent is never acceptable, so removing a title from the VortX library leaves the
    // SIMKL plan-to-watch entry in place rather than risk that.
    func removeFromWatchlist(_ ref: ExternalMediaRef, session: ExternalProviderSession?) async {}

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
