import Foundation

/// Codable models for the Trakt.tv API (https://trakt.docs.apiary.io).
///
/// SCAFFOLD: this layer is self-contained (Foundation + Keychain only) and is NOT wired into the UI
/// yet. `TraktAuth` runs the OAuth device-code flow; `TraktService` exposes the typed calls. These
/// models cover exactly what those two need: the device-code/token envelopes, the small `ids`/`item`
/// shapes that scrobble and sync take, and the scrobble/sync response envelopes.
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

    /// True when the access token is within `leeway` seconds of expiring (or already expired). The
    /// default 24h leeway means the app refreshes a day early rather than mid-playback.
    func isExpired(leeway: TimeInterval = 86_400) -> Bool {
        Date().addingTimeInterval(leeway) >= expiresAt
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
