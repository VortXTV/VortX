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
struct SIMKLIDs: Codable, Sendable, Equatable {
    var simkl: Int?
    var imdb: String?
    var tmdb: Int?

    init(simkl: Int? = nil, imdb: String? = nil, tmdb: Int? = nil) {
        self.simkl = simkl
        self.imdb = imdb
        self.tmdb = tmdb
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
