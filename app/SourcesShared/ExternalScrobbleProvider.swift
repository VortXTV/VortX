import Foundation

/// External progress-sync providers (Trakt Lane C, SIMKL Lane D) behind one neutral interface, so the
/// player call sites and the library actions fan out to every connected service through a single
/// `ScrobbleCoordinator` without knowing any provider's wire shape.
///
/// DORMANCY: a provider whose credentials are absent (`isConfigured == false`) reports `isConnected`
/// false and every op is a no-op, so with empty build creds the whole feature makes zero network calls.
///
/// INVARIANTS (see the lane brief): none of this ever touches the engine `libraryItem` (external state
/// lives only on the provider's HTTP endpoints), every op is `try?`-wrapped so an outage never blocks
/// playback, and the OVERLAY/GUEST gate + once-latches live in the coordinator, applied once before the
/// fan-out here.

// MARK: - Neutral media reference

/// A provider-agnostic description of the thing being scrobbled / listed. The coordinator resolves the
/// engine's `libraryId` identity ONCE (tmdb:/kitsu: -> tt where possible, else a numeric tmdb id) and
/// hands every provider the same ref; each provider maps it to its own id bag. `Sendable` so it can
/// cross into the detached network task.
struct ExternalMediaRef: Sendable {
    /// True for a series episode, false for a movie. Decides the movie-vs-episode payload shape.
    let isSeries: Bool
    /// The resolved IMDb `tt…` id of the MOVIE, or of the SHOW for a series episode. Preferred identity.
    let imdb: String?
    /// Numeric TMDB id fallback, used when no tt id could be resolved (a tmdb-only catalog play).
    let tmdb: Int?
    /// 1-based season number for a series episode (nil for movies).
    let season: Int?
    /// 1-based episode number for a series episode (nil for movies).
    let episode: Int?
    /// Human title, sent as a soft hint only (providers match on ids).
    let title: String?
    /// Release year hint (optional).
    let year: Int?
    /// Playback progress percentage 0...100 for scrobble ops; ignored by watchlist/history ops.
    var progress: Double

    /// True when this ref carries at least one usable id. A ref with neither a tt nor a tmdb id (e.g. a
    /// kitsu-only or pasted-magnet identity) can't be sent anywhere, so the coordinator drops it.
    var hasUsableID: Bool { (imdb?.isEmpty == false) || (tmdb != nil) }
}

// MARK: - Capabilities

/// What a provider can do, so the coordinator can skip unsupported ops instead of special-casing each
/// service. SIMKL, for instance, has no live start/pause/stop scrobble, only watched-on-finish.
struct ExternalScrobbleCapabilities: Sendable {
    /// Live `start` / `pause` / `stop` progress scrobbling (Trakt yes, SIMKL no).
    let liveScrobble: Bool
    /// Marking a title watched (history add). Both providers support this.
    let history: Bool
    /// Watchlist add/remove on a library add/remove. Both support this.
    let watchlist: Bool
}

// MARK: - Provider protocol

/// One external service. Implementations wrap their existing auth + service actors unchanged and never
/// throw: an op that fails or is unsupported returns quietly.
protocol ExternalScrobbleProvider: Sendable {
    /// Stable identifier ("trakt", "simkl") for logging and per-provider dedupe latches.
    var id: String { get }
    /// Static capability flags.
    var capabilities: ExternalScrobbleCapabilities { get }

    /// True when the provider is configured (build creds present) AND the user has connected it. Async
    /// because sign-in state lives behind an actor. When false the coordinator skips the provider.
    func isConnected() async -> Bool
    /// The user's per-provider scrobble toggle (configured AND toggle on). Synchronous UserDefaults read.
    var scrobbleEnabled: Bool { get }
    /// The user's per-provider watchlist toggle (configured AND toggle on). Synchronous UserDefaults read.
    var watchlistEnabled: Bool { get }

    /// Live scrobble transitions (no-ops when `capabilities.liveScrobble` is false).
    func scrobbleStart(_ ref: ExternalMediaRef) async
    func scrobblePause(_ ref: ExternalMediaRef) async
    func scrobbleStop(_ ref: ExternalMediaRef) async
    /// Record a definitive watch (history add). The coordinator calls this at most once per (item,session).
    func recordWatched(_ ref: ExternalMediaRef) async
    /// Watchlist writes, driven by the library add/remove actions.
    func addToWatchlist(_ ref: ExternalMediaRef) async
    func removeFromWatchlist(_ ref: ExternalMediaRef) async
}

// MARK: - Per-provider toggle keys (shared with the settings view)

/// The @AppStorage / UserDefaults keys for the per-provider on/off toggles. Kept here so both the
/// providers and `ExternalServicesSettingsView` reference the exact same strings. Each key's default is
/// passed at the call site (see `isOn`): the scrobble/watchlist toggles default ON, but `traktImportWatched`
/// defaults OFF, matching each toggle's @AppStorage default in the settings view.
enum ExternalSyncToggle {
    static let traktScrobble = "vortx.trakt.scrobble"
    static let traktWatchlist = "vortx.trakt.watchlist"
    static let simklScrobble = "vortx.simkl.scrobble"
    static let simklWatchlist = "vortx.simkl.watchlist"
    /// Show titles watched on Trakt (pulled into the local shadow cache) as watched in VortX rails.
    /// Default OFF: importing another service's history into the read path is opt-in, and it NEVER
    /// writes any engine libraryItem (additive-read only). Callers MUST read it with `default: false`.
    static let traktImportWatched = "vortx.trakt.importWatched"
    /// Show titles COMPLETED on SIMKL (pulled into the local shadow cache by `SIMKLWatchedShadow`) as
    /// watched in VortX rails. The SIMKL peer of `traktImportWatched`: same default OFF, same opt-in reason,
    /// same additive-read-only invariant (never an engine libraryItem). Callers MUST read it with
    /// `default: false`.
    static let simklImportWatched = "vortx.simkl.importWatched"
    /// Rate titles from the detail page, and mirror those ratings to Trakt. Gates BOTH the rating control
    /// and its wire: with no native VortX rating store yet, a rating made with the mirror off would land
    /// only in a local file nothing else reads, so offering the control there would be a half-feature.
    /// Default ON, like scrobble/watchlist (the control only ever appears once Trakt is CONNECTED, and it
    /// only moves on a deliberate user action), rather than OFF like `traktImportWatched`, which
    /// reinterprets another service's history as VortX watched state.
    /// Turning this OFF never deletes anything: the ratings live in `TraktRatingsStore`'s local shadow,
    /// so switching it back on restores every rating the user already gave.
    static let traktRatings = "vortx.trakt.ratings"
    /// Offer a one-tap "Resume from <time>" chip before playback when Trakt holds a position from another
    /// device that is ahead of this device's own. Default OFF for the same reason as `traktImportWatched`:
    /// reading another service's state into a VortX surface is opt-in. It is a SUGGESTION only. VortX stays
    /// the sole resume authority: nothing behind this key ever writes an engine libraryItem, the account, or
    /// Trakt. Callers MUST read it with `default: false`.
    static let traktResumeSuggestion = "vortx.trakt.resumeSuggestion"
    /// Offer an "I'm watching this" action on detail pages, for viewing that happens where VortX cannot
    /// see it (a cinema, someone else's TV). Default OFF, and it gates only whether the ACTION IS OFFERED:
    /// nothing behind this key ever fires on its own, so the check-in itself always takes a deliberate tap.
    /// OFF by default because this puts a new control on a detail page and announces viewing on the user's
    /// public Trakt feed; both are things to be asked for, not defaulted into. Callers MUST read it with
    /// `default: false`.
    static let traktCheckin = "vortx.trakt.checkin"

    /// A toggle's value, returning `defaultOn` when the user has never set it. `defaultOn` MUST match the
    /// key's @AppStorage default in the settings view (ON for scrobble/watchlist, OFF for importWatched),
    /// so a never-touched switch and its runtime read agree. Thread-safe (UserDefaults is).
    static func isOn(_ key: String, default defaultOn: Bool = true) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultOn }
        return UserDefaults.standard.bool(forKey: key)
    }
}

// MARK: - Registry

/// The set of providers the coordinator fans out to. Static and immutable at runtime: every provider is
/// always present, and its own `isConfigured` gate makes it inert when creds are absent, so an
/// unconfigured provider costs nothing.
enum ExternalScrobbleRegistry {
    /// All providers. Order is not significant (each is gated independently).
    static let providers: [ExternalScrobbleProvider] = [TraktProvider(), SIMKLProvider()]
}

// MARK: - Trakt provider

/// Trakt implementation: wraps the existing `TraktAuth` + `TraktService` actors unchanged. Full live
/// scrobble plus history and watchlist.
struct TraktProvider: ExternalScrobbleProvider {
    let id = "trakt"
    let capabilities = ExternalScrobbleCapabilities(liveScrobble: true, history: true, watchlist: true)

    func isConnected() async -> Bool {
        guard TraktAuth.isConfigured else { return false }
        return await TraktAuth.shared.isSignedIn
    }

    var scrobbleEnabled: Bool { TraktAuth.isConfigured && ExternalSyncToggle.isOn(ExternalSyncToggle.traktScrobble) }
    var watchlistEnabled: Bool { TraktAuth.isConfigured && ExternalSyncToggle.isOn(ExternalSyncToggle.traktWatchlist) }

    func scrobbleStart(_ ref: ExternalMediaRef) async {
        guard let item = Self.scrobbleItem(ref) else { return }
        _ = try? await TraktService.shared.scrobbleStart(item: item, progress: ref.progress)
    }

    func scrobblePause(_ ref: ExternalMediaRef) async {
        guard let item = Self.scrobbleItem(ref) else { return }
        _ = try? await TraktService.shared.scrobblePause(item: item, progress: ref.progress)
    }

    func scrobbleStop(_ ref: ExternalMediaRef) async {
        guard let item = Self.scrobbleItem(ref) else { return }
        _ = try? await TraktService.shared.scrobbleStop(item: item, progress: ref.progress)
    }

    func recordWatched(_ ref: ExternalMediaRef) async {
        // Record via the scrobble STOP endpoint rather than /sync/history: `scrobbleItem` models an
        // episode-of-show by season/number (show imdb + S/E), which the flat `TraktSyncItems.episodes`
        // array can't express from just the show's id. A stop at >=80% progress makes Trakt record the
        // watch in history, so the coordinator passes progress 100 on the definitive-watch path.
        guard let item = Self.scrobbleItem(ref) else { return }
        do { _ = try await TraktService.shared.scrobbleStop(item: item, progress: 100) }
        catch { enqueueIfTransient(ref, .watched, error) }
    }

    func addToWatchlist(_ ref: ExternalMediaRef) async {
        guard let items = titleItems(ref) else { return }
        do { _ = try await TraktService.shared.addToWatchlist(items) }
        catch { enqueueIfTransient(ref, .watchlistAdd, error) }
    }

    func removeFromWatchlist(_ ref: ExternalMediaRef) async {
        guard let items = titleItems(ref) else { return }
        do { _ = try await TraktService.shared.removeFromWatchlist(items) }
        catch { enqueueIfTransient(ref, .watchlistRemove, error) }
    }

    /// Queue a failed push for offline retry, but ONLY for TRANSIENT failures (offline / rate-limit /
    /// server / transport). A terminal outcome is dropped so the queue never carries a push that can never
    /// succeed: `.ignored` (too little watched, HTTP 422) is a legitimate skip, and `.unauthorized` (HTTP
    /// 401) needs a reconnect, not a blind replay that would 401 forever (and could drain into the next
    /// account). The live scrobble start/pause/stop are ephemeral and never reach here.
    private func enqueueIfTransient(_ ref: ExternalMediaRef, _ kind: TraktSyncEngine.PendingPush.Kind, _ error: Error) {
        if let e = error as? TraktServiceError, e == .ignored || e == .unauthorized { return }
        TraktSyncEngine.shared.enqueue(TraktSyncEngine.PendingPush(
            kind: kind, isSeries: ref.isSeries, imdb: ref.imdb, tmdb: ref.tmdb,
            season: ref.season, episode: ref.episode))
    }

    // MARK: Mapping neutral ref -> Trakt wire types

    /// The `ids` bag Trakt accepts, from whichever identity the ref carries.
    private static func ids(_ ref: ExternalMediaRef) -> TraktIDs {
        TraktIDs(imdb: (ref.imdb?.isEmpty == false) ? ref.imdb : nil, tmdb: ref.tmdb)
    }

    /// A scrobble target (movie, or episode anchored to its show by season/number).
    ///
    /// STATIC and non-private so the user-initiated check-in path (`TraktCheckinModel`) maps a ref the
    /// SAME way instead of keeping a second copy of this that could drift: `POST /checkin` takes exactly
    /// the scrobble item shape. Stateless, so this needs no provider instance.
    static func scrobbleItem(_ ref: ExternalMediaRef) -> TraktScrobbleItem? {
        guard ref.hasUsableID else { return nil }
        if ref.isSeries {
            guard let season = ref.season, let number = ref.episode else { return nil }
            return .episodeInShow(show: TraktShow(ids: ids(ref), title: ref.title, year: ref.year),
                                  episode: TraktEpisode(season: season, number: number))
        }
        return .movie(TraktMovie(ids: ids(ref), title: ref.title, year: ref.year))
    }

    /// Watchlist payload: always the WHOLE title (a movie, or a show for any series), since a library
    /// add/remove is a title-level intent (Stremio series ids are show-level). Episode-level watchlist
    /// isn't expressible from these flat models and isn't wanted here.
    private func titleItems(_ ref: ExternalMediaRef) -> TraktSyncItems? {
        guard ref.hasUsableID else { return nil }
        if ref.isSeries {
            return TraktSyncItems(shows: [TraktShow(ids: Self.ids(ref), title: ref.title, year: ref.year)])
        }
        return TraktSyncItems(movies: [TraktMovie(ids: Self.ids(ref), title: ref.title, year: ref.year)])
    }
}
