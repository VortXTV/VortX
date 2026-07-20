import Foundation

/// Codable models for the SIMKL API (https://simkl.docs.apiary.io).
///
/// SCAFFOLD-DORMANT: like the Trakt layer, this is self-contained (Foundation + Keychain) and inert
/// until build credentials are present. SIMKL differs from Trakt in two ways the coordinator already
/// encodes as capability flags: (1) it has NO live start/pause/stop scrobble, only watched-on-finish via
/// `/sync/history`; (2) its access token is long-lived with no refresh rotation, so there is no 24h
/// leeway refresh to copy from `TraktToken`.
///
/// Every type is `Sendable`. Wire field names (snake_case) map to camelCase via explicit `CodingKeys`.

// MARK: - PIN / device flow

/// Result of `GET /oauth/pin?client_id=…`: the code the user enters at `verificationUrl`, plus the
/// polling schedule for `GET /oauth/pin/{user_code}`.
struct SIMKLPin: Codable, Sendable, Equatable {
    /// Short human code the user types at `verificationUrl` (also embedded in the QR).
    let userCode: String
    /// Where the user goes to enter `userCode` (e.g. "https://simkl.com/pin").
    let verificationUrl: String
    /// Seconds until the code expires; stop polling after this and restart.
    let expiresIn: Int
    /// Minimum seconds between polls.
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case userCode = "user_code"
        case verificationUrl = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

/// One poll of `GET /oauth/pin/{user_code}`: `result` is "OK" with an `accessToken` once authorized,
/// otherwise a keep-polling status ("KO").
struct SIMKLPinPoll: Codable, Sendable, Equatable {
    let result: String
    let accessToken: String?

    enum CodingKeys: String, CodingKey {
        case result
        case accessToken = "access_token"
    }
}

// MARK: - Media identity + sync payloads

/// The id bag SIMKL accepts on an item. `imdb`/`tmdb` are what VortX holds; SIMKL resolves from any.
///
/// ASYMMETRIC WIRE TYPES (read vs write): SIMKL ACCEPTS a numeric `tmdb` on the write paths, but its READ
/// responses (`/sync/all-items/…`) hand the numeric ids back as JSON STRINGS ("550"), and the same field
/// is an Int on some payloads. Synthesized decoding would throw `typeMismatch` on whichever form it did
/// not expect and take the WHOLE list response down with it, so the decode below accepts either form and
/// the encode stays synthesized (Int out, exactly as the shipping write paths already send). That keeps
/// this one type honest in both directions instead of forking a parallel read-only id bag that would
/// drift from this one.
struct SIMKLIDs: Codable, Sendable, Equatable {
    var simkl: Int?
    var imdb: String?
    var tmdb: Int?

    init(simkl: Int? = nil, imdb: String? = nil, tmdb: Int? = nil) {
        self.simkl = simkl
        self.imdb = imdb
        self.tmdb = tmdb
    }

    // Declared explicitly (not synthesized) because the custom decoder below refers to it. Encoding still
    // uses these keys via the synthesized `encode(to:)`, so the write wire format is unchanged.
    enum CodingKeys: String, CodingKey {
        case simkl, imdb, tmdb
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imdb = try c.decodeIfPresent(String.self, forKey: .imdb)
        simkl = Self.flexibleInt(c, .simkl)
        tmdb = Self.flexibleInt(c, .tmdb)
    }

    /// An Int that may arrive as a JSON number OR a JSON string. Absent / null / unparseable all read as
    /// nil rather than throwing: a single odd id must never fail the whole list, and a nil id here just
    /// means the caller falls back to another id in the bag.
    private static func flexibleInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let number = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil { return number }
        if let text = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil { return Int(text) }
        return nil
    }
}

/// A movie reference (ids plus soft title/year hints).
struct SIMKLMovie: Codable, Sendable, Equatable {
    var ids: SIMKLIDs
    var title: String?
    var year: Int?
    /// Target list for `/sync/add-to-list` ("plantowatch"); omitted on the `/sync/history` path.
    var to: String?

    init(ids: SIMKLIDs, title: String? = nil, year: Int? = nil, to: String? = nil) {
        self.ids = ids
        self.title = title
        self.year = year
        self.to = to
    }
}

/// One episode number inside a season (SIMKL nests episodes under seasons under the show).
struct SIMKLEpisodeNumber: Codable, Sendable, Equatable {
    var number: Int
}

/// One season with its episodes, used to mark a specific episode watched under its show.
struct SIMKLSeason: Codable, Sendable, Equatable {
    var number: Int
    var episodes: [SIMKLEpisodeNumber]?
}

/// A show reference. For a whole-series watchlist add just the ids; to mark an episode watched, carry
/// the nested `seasons` -> `episodes` (SIMKL's canonical episode shape, unlike Trakt's flat episodes).
struct SIMKLShow: Codable, Sendable, Equatable {
    var ids: SIMKLIDs
    var title: String?
    var year: Int?
    var to: String?
    var seasons: [SIMKLSeason]?

    init(ids: SIMKLIDs, title: String? = nil, year: Int? = nil, to: String? = nil, seasons: [SIMKLSeason]? = nil) {
        self.ids = ids
        self.title = title
        self.year = year
        self.to = to
        self.seasons = seasons
    }
}

/// Body for `/sync/history`, `/sync/history/remove`, and `/sync/add-to-list`. Send the arrays in use.
struct SIMKLSyncItems: Codable, Sendable, Equatable {
    var movies: [SIMKLMovie]?
    var shows: [SIMKLShow]?

    init(movies: [SIMKLMovie]? = nil, shows: [SIMKLShow]? = nil) {
        self.movies = movies
        self.shows = shows
    }
}

// MARK: - List reads (`GET /sync/all-items/{type}/{status}`)

/// Which of SIMKL's three top-level catalogues to read. SIMKL splits ANIME out of `shows` as its own
/// type (it is an anime-first tracker), so a read that asks only for `shows` silently misses a large part
/// of a typical SIMKL user's list. Each type is fetched independently so one failing type cannot blank
/// the others.
enum SIMKLListType: String, Sendable, CaseIterable {
    case movies
    case shows
    case anime

    /// The app-side media type these entries render as. Anime series and shows are both "series" to the
    /// detail page; only `movies` is a movie.
    var appType: String { self == .movies ? "movie" : "series" }
}

/// One row of `GET /sync/all-items/movies/{status}`: the list metadata plus the movie it points at.
struct SIMKLListedMovie: Decodable, Sendable {
    let movie: SIMKLMovie?
    let status: String?
    /// When the user put this on the list. Optional: used only to order the rail newest-first, and a
    /// missing value just sorts last.
    let addedToWatchlistAt: String?

    enum CodingKeys: String, CodingKey {
        case movie, status
        case addedToWatchlistAt = "added_to_watchlist_at"
    }
}

/// One row of `GET /sync/all-items/{shows,anime}/{status}`. SIMKL nests the title under `show` for both
/// the `shows` and `anime` types, so one entry type covers both.
struct SIMKLListedShow: Decodable, Sendable {
    let show: SIMKLShow?
    let status: String?
    let addedToWatchlistAt: String?

    enum CodingKeys: String, CodingKey {
        case show, status
        case addedToWatchlistAt = "added_to_watchlist_at"
    }
}

/// Envelope for `GET /sync/all-items/{type}/{status}`. SIMKL keys the array by the type asked for, so a
/// `movies` read populates `movies` and leaves the rest nil. Every field is optional because SIMKL omits
/// the key entirely (rather than sending `[]`) when a list is empty.
struct SIMKLAllItemsResponse: Decodable, Sendable {
    let movies: [SIMKLListedMovie]?
    let shows: [SIMKLListedShow]?
    let anime: [SIMKLListedShow]?
}

/// A list status on SIMKL. Only `plantowatch` is read today (the watchlist rail); the rest are named so a
/// caller does not have to hand-write the wire string.
enum SIMKLListStatus: String, Sendable {
    case watching
    case planToWatch = "plantowatch"
    case completed
    case hold
    case dropped
}

/// A resolved list entry, flattened out of whichever typed array it arrived in, so callers do not have to
/// branch on movie-vs-show to build a rail.
struct SIMKLListEntry: Sendable, Equatable {
    let imdb: String?
    let tmdb: Int?
    let title: String
    /// App media type ("movie" / "series").
    let type: String
    /// ISO-8601 timestamp of when it was listed, when SIMKL sent one.
    let addedAt: String?
}

/// Typed errors for the SIMKL calls.
enum SIMKLError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case notSignedIn
    case badURL
    case expired
    case server(status: Int)
    case transport(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "SIMKL is not configured in this build."
        case .notSignedIn: return "You are not connected to SIMKL."
        case .badURL: return "The SIMKL service URL is invalid."
        case .expired: return "The SIMKL sign-in code expired. Please try again."
        case .server(let status): return "SIMKL returned an error (HTTP \(status))."
        case .transport(let message): return message
        case .decoding: return "Could not read the response from SIMKL."
        }
    }
}
