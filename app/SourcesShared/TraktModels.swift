import Foundation

/// Codable models for the Trakt.tv API (https://trakt.docs.apiary.io).
///
/// This layer is self-contained (Foundation + Keychain only). `TraktAuth` runs the OAuth device-code
/// flow; `TraktService` exposes the typed calls. These models cover exactly what those two need: the
/// device-code/token envelopes, the small `ids`/`item` shapes that scrobble and sync take, and the
/// scrobble/sync response envelopes.
///
/// Every type is `Sendable` so it can cross the actor boundary in `TraktService`. Field names follow
/// the wire format (snake_case) via explicit `CodingKeys`, keeping Swift call sites camelCase.

// MARK: - OAuth device-code flow

/// Result of `POST /oauth/device/code`: the codes plus the polling schedule the client must obey.
struct TraktDeviceCode: Codable, Sendable, Equatable {
    /// Opaque code the app polls with (never shown to the user).
    let deviceCode: String
    /// Short human code the user types at `verificationURL` (e.g. "ABCD-EFGH").
    let userCode: String
    /// Where the user goes to enter `userCode` (e.g. "https://trakt.tv/activate").
    let verificationURL: String
    /// Seconds until both codes expire; stop polling after this and restart the flow.
    let expiresIn: Int
    /// Minimum seconds between polls. Trakt answers HTTP 429 ("slow down") if the app polls faster.
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

/// An OAuth token set from `POST /oauth/device/token` or `POST /oauth/token`.
///
/// Trakt access tokens are valid for 7 days; `refreshToken` mints a new set without re-prompting the
/// user. `createdAt` is when the token was issued so the app can compute expiry locally
/// (Trakt sends `created_at` on `/oauth/token` but not always on the device path, so it defaults to
/// "now" when absent).
struct TraktToken: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    /// Seconds the access token is valid for from issue time.
    let expiresIn: Int
    /// Usually "bearer".
    let tokenType: String
    /// Space-separated scopes granted (may be absent on the device path).
    let scope: String?
    /// Unix epoch seconds when the token was issued.
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        expiresIn = try c.decode(Int.self, forKey: .expiresIn)
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType) ?? "bearer"
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        createdAt = try c.decodeIfPresent(Int.self, forKey: .createdAt)
            ?? Int(Date().timeIntervalSince1970)
    }

    /// Memberwise init for tests and local construction (the decoder above handles the wire path).
    init(accessToken: String, refreshToken: String, expiresIn: Int,
         tokenType: String = "bearer", scope: String? = nil,
         createdAt: Int = Int(Date().timeIntervalSince1970)) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.scope = scope
        self.createdAt = createdAt
    }

    /// Absolute expiry instant (issue time + lifetime).
    var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(createdAt + expiresIn)) }

    /// Conservative refresh margin: half the token's lifetime, capped at 30 minutes. Trakt cut the
    /// access-token lifetime to 24h in 2025, so a leeway equal to (or near) the lifetime would make
    /// EVERY `isExpired()` read true and fire a refresh POST on every `validToken()` call, storming
    /// Trakt's 1-POST/sec limit and, because Trakt ROTATES the refresh token, racing concurrent
    /// refreshes into a self-signout. Half-life capped at 30 min refreshes early without that storm.
    ///
    /// CONTRACT: this math only works when `expiresIn` is the token's ORIGINAL lifetime. A token
    /// rebuilt with its REMAINING lifetime makes "remaining <= min(1_800, remaining / 2)"
    /// unsatisfiable, so the early refresh silently never fires and the token only reads expired at
    /// hard expiry. `TraktAuth` therefore persists `createdAt` alongside the absolute expiry and
    /// rebuilds stored tokens with their original issue time.
    var defaultLeeway: TimeInterval { min(1_800, Double(max(expiresIn, 0)) / 2) }

    /// True when the access token is within `leeway` seconds of expiring (or already expired). `leeway`
    /// defaults to `defaultLeeway` (<= 30 min) so a fresh 24h token is NOT treated as already expired.
    func isExpired(leeway: TimeInterval? = nil) -> Bool {
        Date().addingTimeInterval(leeway ?? defaultLeeway) >= expiresAt
    }
}

// MARK: - Media identity

/// The id bag Trakt accepts on every item reference. Send whatever the app already has; Trakt resolves
/// the canonical item from any one of them. `imdb`/`tmdb` are what VortX usually holds (stremio uses
/// imdb ids), so those are the common path.
struct TraktIDs: Codable, Sendable, Equatable {
    var trakt: Int?
    var slug: String?
    var imdb: String?
    var tmdb: Int?
    var tvdb: Int?

    init(trakt: Int? = nil, slug: String? = nil, imdb: String? = nil,
         tmdb: Int? = nil, tvdb: Int? = nil) {
        self.trakt = trakt
        self.slug = slug
        self.imdb = imdb
        self.tmdb = tmdb
        self.tvdb = tvdb
    }

    /// Convenience for the common VortX case: a stremio imdb id ("tt1234567").
    static func imdb(_ id: String) -> TraktIDs { TraktIDs(imdb: id) }
}

/// A movie reference (just its ids for write paths; Trakt fills in the rest).
struct TraktMovie: Codable, Sendable, Equatable {
    var ids: TraktIDs
    var title: String?
    var year: Int?

    init(ids: TraktIDs, title: String? = nil, year: Int? = nil) {
        self.ids = ids
        self.title = title
        self.year = year
    }
}

/// A show reference, used to anchor an episode by season/number when only the show has an imdb id.
struct TraktShow: Codable, Sendable, Equatable {
    var ids: TraktIDs
    var title: String?
    var year: Int?

    init(ids: TraktIDs, title: String? = nil, year: Int? = nil) {
        self.ids = ids
        self.title = title
        self.year = year
    }
}

/// An episode reference. Either carry the episode's own `ids`, or identify it by `season`+`number`
/// alongside a `TraktShow` in the enclosing payload.
struct TraktEpisode: Codable, Sendable, Equatable {
    var ids: TraktIDs?
    var season: Int?
    var number: Int?
    var title: String?

    init(ids: TraktIDs? = nil, season: Int? = nil, number: Int? = nil, title: String? = nil) {
        self.ids = ids
        self.season = season
        self.number = number
        self.title = title
    }
}

// MARK: - Scrobble

/// The action Trakt recorded for a scrobble call.
enum TraktScrobbleAction: String, Codable, Sendable {
    case start
    case pause
    case scrobble
}

/// Response from `/scrobble/{start,pause,stop}`. On a stop above 80% progress, `action` is `.scrobble`
/// and `id` is the new history entry's id; on a pause it is `.pause` with no `id`.
struct TraktScrobbleResponse: Codable, Sendable {
    let id: Int64?
    let action: TraktScrobbleAction
    let progress: Double
    let movie: TraktMovie?
    let episode: TraktEpisode?
    let show: TraktShow?
}

// MARK: - Sync

/// Body for `POST /sync/watchlist`, `POST /sync/history`, and their `/remove` variants. Send the
/// movies and/or episodes (or whole shows) to act on; omit the arrays you are not using.
struct TraktSyncItems: Codable, Sendable, Equatable {
    var movies: [TraktMovie]?
    var shows: [TraktShow]?
    var episodes: [TraktEpisode]?

    init(movies: [TraktMovie]? = nil, shows: [TraktShow]? = nil, episodes: [TraktEpisode]? = nil) {
        self.movies = movies
        self.shows = shows
        self.episodes = episodes
    }
}

/// Per-type added/existing/not_found counts returned by sync writes. The app rarely needs the detail;
/// this lets a caller confirm something actually landed.
struct TraktSyncCounts: Codable, Sendable {
    let movies: Int?
    let shows: Int?
    let seasons: Int?
    let episodes: Int?
}

/// Response envelope from `POST /sync/watchlist` and `POST /sync/history`.
struct TraktSyncResponse: Codable, Sendable {
    let added: TraktSyncCounts?
    let existing: TraktSyncCounts?
    let deleted: TraktSyncCounts?
    let notFound: TraktNotFound?

    enum CodingKeys: String, CodingKey {
        case added, existing, deleted
        case notFound = "not_found"
    }
}

/// Items Trakt could not match (bad ids). Surfaced so the caller can log what was dropped.
struct TraktNotFound: Codable, Sendable {
    let movies: [TraktMovie]?
    let shows: [TraktShow]?
    let episodes: [TraktEpisode]?
}

/// One row from `GET /sync/watchlist` (a movie or show the user wants to watch).
struct TraktWatchlistEntry: Codable, Sendable {
    let rank: Int?
    let listedAt: String?
    let type: String
    let movie: TraktMovie?
    let show: TraktShow?

    enum CodingKeys: String, CodingKey {
        case rank, type, movie, show
        case listedAt = "listed_at"
    }
}

/// One row from `GET /sync/collection` (something the user owns/has in their library).
struct TraktCollectionEntry: Codable, Sendable {
    let collectedAt: String?
    let movie: TraktMovie?
    let show: TraktShow?

    enum CodingKeys: String, CodingKey {
        case movie, show
        case collectedAt = "collected_at"
    }
}

// MARK: - Check-in

/// Response from `POST /checkin` (HTTP 201). `expiresAt` is when Trakt auto-expires the check-in (the
/// item's runtime measured from `watchedAt`); the account's single "watching" slot frees up then, and
/// Trakt records the watch in the user's own history at that point.
///
/// That history write lands on TRAKT ONLY. It reaches VortX's read path solely through the existing
/// opt-in `traktImportWatched` shadow cache, which is additive-read and never writes an engine
/// `libraryItem`, so a check-in can never mutate VortX's own watched state.
struct TraktCheckinResponse: Codable, Sendable {
    let id: Int64?
    let watchedAt: String?
    let expiresAt: String?
    let movie: TraktMovie?
    let episode: TraktEpisode?
    let show: TraktShow?

    enum CodingKeys: String, CodingKey {
        case id, movie, episode, show
        case watchedAt = "watched_at"
        case expiresAt = "expires_at"
    }
}

/// Body of the HTTP 409 that `POST /checkin` answers with when the account is ALREADY watching
/// something. Trakt keeps ONE watching slot per account, shared by check-ins and by live scrobbles, and
/// refuses to overwrite it silently. `expiresAt` says when that prior watch frees the slot, so the app
/// can tell the user exactly what is in the way rather than reporting a bare failure.
struct TraktCheckinConflict: Codable, Sendable {
    let expiresAt: String?

    enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
}

/// Timestamp parsing for the Trakt wire format ("2026-07-16T12:00:00.000Z"). Trakt sends fractional
/// seconds; the plain form is accepted as a fallback so a format change degrades to "no expiry shown"
/// instead of silently dropping the value. Reuses the shared `ISO8601DateFormatter` instances
/// (formatters are costly to build and are not thread-safe to mutate, so these are never reconfigured).
enum TraktDate {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = ISO8601DateFormatter.epgFractional.date(from: raw) { return date }
        return ISO8601DateFormatter.epg.date(from: raw)
    }
}

// MARK: - Ratings

/// The `rated_at` timestamp shape Trakt uses: ISO8601 UTC with fractional seconds
/// ("2014-09-01T09:10:11.000Z"). Carried as a `String` on the wire types so `TraktService`'s plain
/// `JSONEncoder`/`JSONDecoder` keep their defaults for every other call (a date strategy set for
/// ratings would otherwise silently reinterpret the `created_at` Int in `TraktToken`).
///
/// Parsing accepts BOTH the fractional and whole-second forms: Trakt documents the fractional shape
/// but does not always send the `.000`, and an `ISO8601DateFormatter` configured `.withFractionalSeconds`
/// returns nil on a whole-second string rather than tolerating it. A rating whose date failed to parse
/// would fall back to `.distantPast` at the merge and could never win a newer-wins comparison, so both
/// forms are tried before giving up.
enum TraktRatedAt {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Format a date the way Trakt expects on a ratings write.
    static func string(from date: Date) -> String { fractional.string(from: date) }

    /// Parse a Trakt `rated_at`, tolerating the whole-second form. nil when neither form matches.
    static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? whole.date(from: string)
    }
}

/// A movie carrying a rating, for `POST /sync/ratings`. `rating` is 1...10; it is optional because
/// `POST /sync/ratings/remove` takes the same shape with the value omitted (the ids alone identify what
/// to un-rate).
struct TraktRatedMovie: Codable, Sendable, Equatable {
    var ids: TraktIDs
    var rating: Int?
    var ratedAt: String?

    init(ids: TraktIDs, rating: Int? = nil, ratedAt: String? = nil) {
        self.ids = ids
        self.rating = rating
        self.ratedAt = ratedAt
    }

    enum CodingKeys: String, CodingKey {
        case ids, rating
        case ratedAt = "rated_at"
    }
}

/// A show carrying a rating, for `POST /sync/ratings`. Show-level (not season/episode), matching the
/// title-level intent of the detail page's rating control and of `TraktProvider.titleItems`.
struct TraktRatedShow: Codable, Sendable, Equatable {
    var ids: TraktIDs
    var rating: Int?
    var ratedAt: String?

    init(ids: TraktIDs, rating: Int? = nil, ratedAt: String? = nil) {
        self.ids = ids
        self.rating = rating
        self.ratedAt = ratedAt
    }

    enum CodingKeys: String, CodingKey {
        case ids, rating
        case ratedAt = "rated_at"
    }
}

/// Body for `POST /sync/ratings` and `POST /sync/ratings/remove`. Omit the array you are not using.
struct TraktRatingItems: Codable, Sendable, Equatable {
    var movies: [TraktRatedMovie]?
    var shows: [TraktRatedShow]?

    init(movies: [TraktRatedMovie]? = nil, shows: [TraktRatedShow]? = nil) {
        self.movies = movies
        self.shows = shows
    }
}

/// One row from `GET /sync/ratings/{type}`: the rating the user gave, when, and which title it is on.
struct TraktRatingEntry: Codable, Sendable {
    let rating: Int
    let ratedAt: String?
    let type: String?
    let movie: TraktMovie?
    let show: TraktShow?

    enum CodingKeys: String, CodingKey {
        case rating, type, movie, show
        case ratedAt = "rated_at"
    }
}
