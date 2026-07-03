import Foundation

/// Minimal TMDB v3 client, used only when the user has set a TMDB key (see ApiKeys). It enriches the
/// engine's data; it is never required. Recommendations are returned as IMDb ids so they map straight
/// onto the engine's Cinemeta metas. Every call fails soft (returns nil / []), so a flaky or missing
/// key never breaks a screen.
enum TMDBClient {
    private static let host = "https://api.themoviedb.org/3"

    /// IMDb ids recommended for the given IMDb id. `type` is the stremio type ("movie" or "series").
    /// Recommendations whose ORIGIN/language matches the source are surfaced first, so a Korean drama
    /// suggests Korean, a Bollywood film suggests Bollywood, not just same-genre Hollywood.
    static func recommendations(imdbID: String, type: String) async -> [String] {
        guard imdbID.hasPrefix("tt") else { return [] }
        let key = ApiKeys.effectiveTMDBKey()
        let media = (type == "series") ? "tv" : "movie"
        guard let found = await get("/find/\(imdbID)?external_source=imdb_id&api_key=\(key)"),
              let first = (found[media == "tv" ? "tv_results" : "movie_results"] as? [[String: Any]])?.first,
              let tmdbID = first["id"] as? Int else { return [] }
        let srcLang = first["original_language"] as? String
        guard let recs = await get("/\(media)/\(tmdbID)/recommendations?api_key=\(key)"),
              let results = recs["results"] as? [[String: Any]] else { return [] }
        // Stable sort: same-original-language first, otherwise keep TMDB's popularity order.
        let ranked = results.enumerated().sorted { a, b in
            let am = ((a.element["original_language"] as? String) == srcLang) ? 0 : 1
            let bm = ((b.element["original_language"] as? String) == srcLang) ? 0 : 1
            return am != bm ? am < bm : a.offset < b.offset
        }.map { $0.element }
        let ids = ranked.compactMap { $0["id"] as? Int }.prefix(12)
        // Map each TMDB id back to an IMDb id (concurrently, capped) so results play through the engine.
        return await withTaskGroup(of: (Int, String)?.self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask {
                    guard let ext = await get("/\(media)/\(id)/external_ids?api_key=\(key)"),
                          let imdb = ext["imdb_id"] as? String, imdb.hasPrefix("tt") else { return nil }
                    return (i, imdb)
                }
            }
            var out: [(Int, String)] = []
            for await r in group { if let r { out.append(r) } }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }   // preserve the language-boosted order
        }
    }

    /// A streaming/rent/buy provider a title is available on, for the "Where to watch" row.
    struct WatchProvider: Identifiable, Hashable {
        let name: String
        let logoURL: String?
        var id: String { name }
    }

    /// Legal streaming availability for a title in the viewer's region, from TMDB's watch/providers
    /// (JustWatch data). `link` is the JustWatch page for the title. Nil when there's no TMDB key, the
    /// id is not an IMDb id, or nothing is listed for the region. Streaming (flatrate) is listed first.
    struct WatchAvailability {
        let link: String?
        let providers: [WatchProvider]
    }

    /// The region used for all TMDB region-scoped calls (watch providers, discover watch_region, release
    /// dates). Honors the user's Discover region OVERRIDE first (Settings), else the device region, else US.
    /// Reading the override here means every hub content path picks up the preference with no signature churn.
    static var deviceRegion: String {
        CatalogPrefsStore.regionOverride() ?? (Locale.current.region?.identifier ?? "US")
    }

    static func watchProviders(imdbID: String, type: String, region: String = TMDBClient.deviceRegion) async -> WatchAvailability? {
        guard imdbID.hasPrefix("tt") else { return nil }
        let key = ApiKeys.effectiveTMDBKey()
        let media = (type == "series") ? "tv" : "movie"
        guard let found = await get("/find/\(imdbID)?external_source=imdb_id&api_key=\(key)"),
              let first = (found[media == "tv" ? "tv_results" : "movie_results"] as? [[String: Any]])?.first,
              let tmdbID = first["id"] as? Int,
              let prov = await get("/\(media)/\(tmdbID)/watch/providers?api_key=\(key)"),
              let results = prov["results"] as? [String: Any],
              let here = results[region] as? [String: Any] else { return nil }
        let link = here["link"] as? String
        func read(_ bucket: String) -> [WatchProvider] {
            ((here[bucket] as? [[String: Any]]) ?? [])
                .sorted { ($0["display_priority"] as? Int ?? 99) < ($1["display_priority"] as? Int ?? 99) }
                .compactMap { p in
                    guard let name = p["provider_name"] as? String else { return nil }
                    let logo = (p["logo_path"] as? String).map { "https://image.tmdb.org/t/p/w92\($0)" }
                    return WatchProvider(name: name, logoURL: logo)
                }
        }
        // Streaming first, then rent, then buy; dedupe by provider name.
        var seen = Set<String>()
        let merged = (read("flatrate") + read("rent") + read("buy")).filter { seen.insert($0.name).inserted }
        guard !merged.isEmpty else { return nil }
        return WatchAvailability(link: link, providers: merged)
    }

    /// The official YouTube trailer id for a title from TMDB's /videos (the source Stremio trailer add-ons
    /// use). Accepts an IMDb id (tt...) via /find or a `tmdb:[type:]id`. Requires a TMDB key; nil on no key,
    /// no match, or no trailer.
    ///
    /// LANGUAGE PICK (`preferredLanguages`, ISO-639-1 codes in priority order, e.g. ["pt", "en"]): TMDB tags
    /// each video with an `iso_639_1` language. For the WITH-SOUND "watch trailer" action we prefer a trailer
    /// whose language matches the user's preferred language, then the title's ORIGINAL language, then English,
    /// then the first/most-popular official Trailer. Within each language band an official Trailer beats a
    /// non-official one, which beats a Teaser/Clip. Pass `[]` (the default) to keep the old
    /// language-agnostic pick — the AMBIENT muted hero clip does not use this, so its behavior is unchanged.
    static func trailerYouTubeID(metaID: String, type: String, preferredLanguages: [String] = []) async -> String? {
        let key = ApiKeys.effectiveTMDBKey()
        let media = (type == "series") ? "tv" : "movie"
        var tmdbID: Int?
        var originalLanguage: String?
        if metaID.hasPrefix("tt") {
            guard let found = await get("/find/\(metaID)?external_source=imdb_id&api_key=\(key)"),
                  let first = (found[media == "tv" ? "tv_results" : "movie_results"] as? [[String: Any]])?.first else { return nil }
            tmdbID = first["id"] as? Int
            originalLanguage = (first["original_language"] as? String)?.lowercased()
        } else if metaID.hasPrefix("tmdb:") {
            tmdbID = metaID.split(separator: ":").last.flatMap { Int($0) }
        }
        guard let id = tmdbID,
              let vids = await get("/\(media)/\(id)/videos?api_key=\(key)"),
              let results = vids["results"] as? [[String: Any]] else { return nil }
        let youtube = results.filter { ($0["site"] as? String)?.lowercased() == "youtube" && $0["key"] is String }
        return pickTrailerKey(from: youtube, preferredLanguages: preferredLanguages, originalLanguage: originalLanguage).key
    }

    /// A picked trailer id plus whether it matched one of the caller's PREFERRED languages (vs. falling back to
    /// original-language / English / first). Callers that only want to OVERRIDE a default trailer when the pick
    /// is a genuine localized hit key on `matchedPreferred`.
    struct TrailerPick { let key: String?; let matchedPreferred: Bool }

    /// Language-preferred trailer id from TMDB /videos, returning whether the match was a real preferred-language
    /// hit. Same resolution as `trailerYouTubeID` but surfaces `matchedPreferred` so the WITH-SOUND action can
    /// decide whether the localized pick is worth preferring over the default (/clip mp4) path.
    static func preferredTrailerPick(metaID: String, type: String, preferredLanguages: [String]) async -> TrailerPick {
        let key = ApiKeys.effectiveTMDBKey()
        let media = (type == "series") ? "tv" : "movie"
        var tmdbID: Int?
        var originalLanguage: String?
        if metaID.hasPrefix("tt") {
            guard let found = await get("/find/\(metaID)?external_source=imdb_id&api_key=\(key)"),
                  let first = (found[media == "tv" ? "tv_results" : "movie_results"] as? [[String: Any]])?.first else { return TrailerPick(key: nil, matchedPreferred: false) }
            tmdbID = first["id"] as? Int
            originalLanguage = (first["original_language"] as? String)?.lowercased()
        } else if metaID.hasPrefix("tmdb:") {
            tmdbID = metaID.split(separator: ":").last.flatMap { Int($0) }
        }
        guard let id = tmdbID,
              let vids = await get("/\(media)/\(id)/videos?api_key=\(key)"),
              let results = vids["results"] as? [[String: Any]] else { return TrailerPick(key: nil, matchedPreferred: false) }
        let youtube = results.filter { ($0["site"] as? String)?.lowercased() == "youtube" && $0["key"] is String }
        return pickTrailerKey(from: youtube, preferredLanguages: preferredLanguages, originalLanguage: originalLanguage)
    }

    /// Choose a YouTube video `key` from TMDB /videos results by LANGUAGE then KIND. Language bands, in order:
    /// each of `preferredLanguages` (ISO-639-1), the title's `originalLanguage`, English, then any language.
    /// Within a band: an official Trailer, then any Trailer, then a Teaser/Clip. This is the single place the
    /// "prefer the localized trailer" policy lives, so every caller (the language pick + the language-agnostic
    /// default when `preferredLanguages` is empty) gets a consistent, fail-soft result. `key` is nil when the
    /// list has no usable YouTube video; `matchedPreferred` is true only when the chosen video was in one of
    /// `preferredLanguages` (not an original-language / English / any fallback), so a caller can decide whether
    /// the pick is a genuine localized hit worth overriding a default trailer.
    static func pickTrailerKey(from youtube: [[String: Any]], preferredLanguages: [String], originalLanguage: String?) -> TrailerPick {
        func lang(_ v: [String: Any]) -> String { ((v["iso_639_1"] as? String) ?? "").lowercased() }
        func kindRank(_ v: [String: Any]) -> Int {
            let t = (v["type"] as? String) ?? ""
            let official = (v["official"] as? Bool) == true
            if t == "Trailer", official { return 0 }
            if t == "Trailer" { return 1 }
            if t == "Teaser" || t == "Clip" { return 2 }
            return 3
        }
        // Best (lowest-kind-rank) YouTube video whose language is in `codes`; nil if none match.
        func best(in codes: [String]) -> String? {
            let set = Set(codes.filter { !$0.isEmpty })
            guard !set.isEmpty else { return nil }
            return youtube.filter { set.contains(lang($0)) }
                .min { kindRank($0) < kindRank($1) }
                .flatMap { $0["key"] as? String }
        }
        // Preferred language(s) first (a genuine localized hit), then the title's original language, then English.
        for code in preferredLanguages where !code.isEmpty {
            if let k = best(in: [code]) { return TrailerPick(key: k, matchedPreferred: true) }
        }
        if let orig = originalLanguage, let k = best(in: [orig]) { return TrailerPick(key: k, matchedPreferred: false) }
        if let k = best(in: ["en"]) { return TrailerPick(key: k, matchedPreferred: false) }
        // No language matched: fall back to the best video regardless of language (old behavior).
        let k = youtube.min { kindRank($0) < kindRank($1) }.flatMap { $0["key"] as? String }
        return TrailerPick(key: k, matchedPreferred: false)
    }

    /// The `stremiox.trailerLanguage` explicit picker value (D11), if the user set one in Settings. Empty /
    /// absent means "follow the app UI language" (the default), which `preferredTrailerLanguages` already
    /// applies via `AppLanguage.current`. When set, it is the HIGHEST-priority trailer language so the pick
    /// honors the user's explicit choice over the UI language / audio / device order. Shared with the trailer
    /// URL builders so the `/yt?lang=` hint matches the id the app selected.
    static var trailerLanguageOverride: String? {
        let v = UserDefaults.standard.string(forKey: "stremiox.trailerLanguage")
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// The user's preferred trailer languages as ISO-639-1 codes, in priority order: the explicit
    /// `stremiox.trailerLanguage` picker first (D11) when set, then the pinned app UI language (reduced to its
    /// base language code, so "pt-BR" -> "pt", "zh-Hans" -> "zh"), then the preferred AUDIO languages, then the
    /// device languages. Deduped, lowercased. Empty only when nothing resolves (then the trailer pick falls
    /// back to original-language/English/first). Shared by the iOS/Mac "watch trailer" callers so the language
    /// pick is consistent, and by the D11 fallback chain user-lang -> English -> original/any.
    static var preferredTrailerLanguages: [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ raw: String?) {
            guard let raw, !raw.isEmpty else { return }
            let base = Locale(identifier: raw).language.languageCode?.identifier ?? String(raw.prefix(2))
            let code = base.lowercased()
            guard !code.isEmpty, seen.insert(code).inserted else { return }
            out.append(code)
        }
        add(trailerLanguageOverride)   // D11: explicit picker wins when set (else UI language, below, is the default)
        add(AppLanguage.current)
        for c in TrackPreferences.current.audioLanguages { add(c) }
        for c in TrackPreferences.deviceLanguages { add(c) }
        return out
    }

    /// The single base trailer-language code (ISO-639-1) to hint the `/yt` resolver with (`?lang=`), matching
    /// the language the app used to pick the YouTube id: the explicit `stremiox.trailerLanguage` picker when
    /// set (D11), else the resolved app UI language base code. Never empty. Shared by iOS/Mac + tvOS so the
    /// resolver hint is consistent with the client-side pick (fallback chain user-lang -> en -> original/any is
    /// enforced resolver-side).
    static var trailerLanguageBaseCode: String {
        if let override = trailerLanguageOverride {
            let base = Locale(identifier: override).language.languageCode?.identifier ?? String(override.prefix(2))
            if !base.isEmpty { return base.lowercased() }
        }
        return LocalizedMetadataLanguage.baseCode
    }

    /// CLEAN landscape artwork for the cinematic cards: a textless 16:9 backdrop + a PNG clearlogo from
    /// TMDB, with NO rating/quality overlay (distinct from the ERDB rating-bake path, which stays opt-in for
    /// posters). Requires a TMDB key; accepts an IMDb id (tt..., via /find) or a `tmdb:[type:]id`. Either URL
    /// is nil when absent. The card layer caches the result so each title resolves once.
    static func landscapeImages(metaID: String, type: String) async -> (backdrop: String?, logo: String?) {
        let key = ApiKeys.effectiveTMDBKey()
        let media = (type == "series") ? "tv" : "movie"
        var tmdbID: Int?
        if metaID.hasPrefix("tt") {
            guard let found = await get("/find/\(metaID)?external_source=imdb_id&api_key=\(key)"),
                  let first = (found[media == "tv" ? "tv_results" : "movie_results"] as? [[String: Any]])?.first else { return (nil, nil) }
            tmdbID = first["id"] as? Int
        } else if metaID.hasPrefix("tmdb:") {
            tmdbID = metaID.split(separator: ":").last.flatMap { Int($0) }
        }
        guard let id = tmdbID,
              let imgs = await get("/\(media)/\(id)/images?api_key=\(key)&include_image_language=en,null") else { return (nil, nil) }
        // Prefer a TEXTLESS backdrop (iso_639_1 == null) for a clean card, else the first available.
        let backdrops = (imgs["backdrops"] as? [[String: Any]]) ?? []
        let bd = ((backdrops.first { ($0["iso_639_1"] as? String) == nil }) ?? backdrops.first)?["file_path"] as? String
        // Prefer a PNG clearlogo (transparent), else the first.
        let logos = (imgs["logos"] as? [[String: Any]]) ?? []
        let lg = ((logos.first { ($0["file_path"] as? String)?.lowercased().hasSuffix(".png") == true }) ?? logos.first)?["file_path"] as? String
        return (bd.map { "https://image.tmdb.org/t/p/w780\($0)" }, lg.map { "https://image.tmdb.org/t/p/w500\($0)" })
    }

    /// A streaming service for a "what's on {service}" Home rail (TMDB watch-provider id + display label).
    struct StreamingService: Identifiable, Hashable {
        let providerID: Int
        let name: String
        var id: Int { providerID }
    }

    /// The major flatrate streaming services, by TMDB watch-provider id (JustWatch). A service with nothing
    /// available in the viewer's region resolves to an empty rail and is dropped, so users outside the US
    /// simply see fewer rails rather than blank rows. Order here is the on-screen order.
    static let majorStreamingServices: [StreamingService] = [
        .init(providerID: 8, name: "Netflix"),
        .init(providerID: 337, name: "Disney+"),
        .init(providerID: 9, name: "Prime Video"),
        .init(providerID: 1899, name: "Max"),
        .init(providerID: 350, name: "Apple TV+"),
        .init(providerID: 531, name: "Paramount+"),
        .init(providerID: 15, name: "Hulu"),
        .init(providerID: 386, name: "Peacock"),
        .init(providerID: 283, name: "Crunchyroll"),
    ]

    /// Titles available on a streaming service in the region (TMDB /discover with_watch_providers, flatrate,
    /// most-popular first), resolved to engine-playable Cinemeta (tt) previews so a tapped card plays through
    /// the engine like any other card. Movie + TV are merged. Returns [] when no TMDB key is set or nothing
    /// is available in-region; titles with no IMDb id are dropped (they would dead-tap without a TMDB meta
    /// add-on). Name + poster come from the discover row itself, so this is one discover call + one
    /// external_ids call per title (capped), not a full meta fetch per card.
    static func streamingProviderTitles(providerID: Int, region: String = deviceRegion, limit: Int = 18) async -> [MetaPreview] {
        let key = ApiKeys.effectiveTMDBKey()
        async let movieRows = discoverProviderPage(media: "movie", providerID: providerID, region: region, key: key)
        async let tvRows = discoverProviderPage(media: "tv", providerID: providerID, region: region, key: key)
        let movies = await movieRows, series = await tvRows
        // Interleave movie + tv (each already popularity-ordered) so a rail blends both.
        var rows: [(tmdbID: Int, media: String, name: String, poster: String?)] = []
        for i in 0..<max(movies.count, series.count) {
            if i < movies.count { rows.append(movies[i]) }
            if i < series.count { rows.append(series[i]) }
        }
        // Over-fetch (some drop for a missing IMDb id), resolve each TMDB id -> tt concurrently, preserve order.
        let slice = Array(rows.prefix(limit * 2))
        // Resolve external_ids in CAPPED chunks (~6 in flight) instead of spawning all ~36 at once, so the
        // 9 rails together never burst hundreds of concurrent requests at TMDB (429s silently thin the rails)
        // and the in-flight count tracks URLSession's per-host socket budget. Order preserved by row index.
        var resolved: [(Int, MetaPreview)] = []
        for start in stride(from: 0, to: slice.count, by: 6) {
            if resolved.count >= limit { break }   // enough resolved; stop the over-fetch early
            let batch = Array(slice[start..<min(start + 6, slice.count)])
            let part: [(Int, MetaPreview)] = await withTaskGroup(of: (Int, MetaPreview)?.self) { group in
                for (offset, row) in batch.enumerated() {
                    let i = start + offset
                    group.addTask {
                        guard let ext = await get("/\(row.media)/\(row.tmdbID)/external_ids?api_key=\(key)"),
                              let imdb = ext["imdb_id"] as? String, imdb.hasPrefix("tt"),
                              row.poster?.isEmpty == false else { return nil }
                        let type = row.media == "tv" ? "series" : "movie"
                        return (i, MetaPreview(id: imdb, type: type, name: row.name, poster: row.poster, posterShape: nil, popularity: nil))
                    }
                }
                var out: [(Int, MetaPreview)] = []
                for await r in group { if let r { out.append(r) } }
                return out
            }
            resolved.append(contentsOf: part)
        }
        var seen = Set<String>()
        let ordered = resolved.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0.id).inserted }
        return Array(ordered.prefix(limit))
    }

    // MARK: - Nested-collection Home rails (genres, Top New, Just New)

    /// A TMDB genre for a "Genres" Home rail: a stable movie-genre id, an optional matching TV-genre id
    /// (nil = movies-only for this rail), and a display label. A genre rail blends its movie + TV buckets.
    /// Order in `homeGenres` is the on-screen order.
    struct Genre: Identifiable, Hashable {
        let movieGenreID: Int
        let tvGenreID: Int?
        let name: String
        var id: Int { movieGenreID }
    }

    /// A handful of broad, populated genres for the "Genres" group, in display order. TMDB splits a few
    /// genres between movie and TV (Action vs Action & Adventure, Sci-Fi vs Sci-Fi & Fantasy), so each
    /// carries the matching TV id where it differs; a nil TV id means "movies only for this rail".
    static let homeGenres: [Genre] = [
        .init(movieGenreID: 28, tvGenreID: 10759, name: "Action"),       // TV: Action & Adventure
        .init(movieGenreID: 35, tvGenreID: 35, name: "Comedy"),
        .init(movieGenreID: 18, tvGenreID: 18, name: "Drama"),
        .init(movieGenreID: 53, tvGenreID: nil, name: "Thriller"),       // no direct TV genre
        .init(movieGenreID: 878, tvGenreID: 10765, name: "Sci-Fi"),      // TV: Sci-Fi & Fantasy
        .init(movieGenreID: 27, tvGenreID: nil, name: "Horror"),
        .init(movieGenreID: 16, tvGenreID: 16, name: "Animation"),
        .init(movieGenreID: 10749, tvGenreID: nil, name: "Romance"),
    ]

    /// "How recent counts as new" for the Top New / Just New groups: titles released within this many
    /// months back from today. Keeps both groups to genuinely-current releases, not the all-time catalog.
    static let newWindowMonths = 6

    /// Titles for one genre rail (TMDB /discover by genre, popularity-desc), movie + TV merged, resolved to
    /// engine-playable Cinemeta (tt) previews. [] with no TMDB key or nothing found; the caller then falls
    /// back to Cinemeta genre catalogs (which need no key) so the Genres group still fills.
    static func genreTitles(_ genre: Genre, region: String = deviceRegion, limit: Int = 18) async -> [MetaPreview] {
        let key = ApiKeys.effectiveTMDBKey()
        async let movieRows = discoverGenrePage(media: "movie", genreID: genre.movieGenreID, key: key)
        // Only fetch a TV bucket for genres that map to a TMDB TV genre (Thriller / Horror / Romance are
        // movie-only here); otherwise the rail is movies-only.
        async let tvRows = tvGenrePageIfAvailable(genre.tvGenreID, key: key)
        return await resolveRows(interleave(await movieRows, await tvRows), key: key, limit: limit)
    }

    /// The TV discover-by-genre page when a TV genre id exists, else []. Keeps `genreTitles`' `async let`
    /// clean (a `.map` closure over an async call won't type-check).
    private static func tvGenrePageIfAvailable(_ tvGenreID: Int?, key: String) async -> [DiscoverRow] {
        guard let tvGenreID else { return [] }
        return await discoverGenrePage(media: "tv", genreID: tvGenreID, key: key)
    }

    /// "Top New": the most popular movies + shows released in the last `newWindowMonths`, merged and
    /// resolved to tt previews. Sorted by popularity (what's hot right now among recent releases).
    static func topNewTitles(region: String = deviceRegion, limit: Int = 24) async -> [MetaPreview] {
        let key = ApiKeys.effectiveTMDBKey()
        let (from, to) = newWindow()
        async let movieRows = discoverRecentPage(media: "movie", sort: "popularity.desc", from: from, to: to, region: region, key: key)
        async let tvRows = discoverRecentPage(media: "tv", sort: "popularity.desc", from: from, to: to, region: region, key: key)
        return await resolveRows(interleave(await movieRows, await tvRows), key: key, limit: limit)
    }

    /// "New": the freshest movies + shows by release / air date (newest first) within the last
    /// `newWindowMonths`, merged and resolved to tt previews. This is the "just landed" rail.
    static func justNewTitles(region: String = deviceRegion, limit: Int = 24) async -> [MetaPreview] {
        let key = ApiKeys.effectiveTMDBKey()
        let (from, to) = newWindow()
        async let movieRows = discoverRecentPage(media: "movie", sort: "primary_release_date.desc", from: from, to: to, region: region, key: key)
        async let tvRows = discoverRecentPage(media: "tv", sort: "first_air_date.desc", from: from, to: to, region: region, key: key)
        return await resolveRows(interleave(await movieRows, await tvRows), key: key, limit: limit)
    }

    /// The (from, to) ISO date strings bounding the "new" window: `newWindowMonths` ago through today, so a
    /// "release date desc" sort can't surface far-future scheduled titles with no real release yet.
    private static func newWindow() -> (from: String, to: String) {
        let now = Date()
        let from = Calendar.current.date(byAdding: .month, value: -newWindowMonths, to: now) ?? now
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .iso8601)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return (fmt.string(from: from), fmt.string(from: now))
    }

    /// Interleave two already-ordered row lists (movie + tv) so a rail blends both, movie-first per pair.
    private static func interleave(_ a: [DiscoverRow], _ b: [DiscoverRow]) -> [DiscoverRow] {
        var rows: [DiscoverRow] = []
        for i in 0..<max(a.count, b.count) {
            if i < a.count { rows.append(a[i]) }
            if i < b.count { rows.append(b[i]) }
        }
        return rows
    }

    /// Resolve discover rows to engine-playable tt previews: over-fetch (some drop for a missing IMDb id),
    /// resolve each tmdb id -> tt in CAPPED chunks (~6 in flight) so several rails don't burst hundreds of
    /// concurrent requests at TMDB (429s silently thin rails), preserve order, de-dup, and cap at `limit`.
    /// This is the exact resolve path `streamingProviderTitles` uses, factored out for the new rails.
    private static func resolveRows(_ rows: [DiscoverRow], key: String, limit: Int) async -> [MetaPreview] {
        let slice = Array(rows.prefix(limit * 2))
        var resolved: [(Int, MetaPreview)] = []
        for start in stride(from: 0, to: slice.count, by: 6) {
            if resolved.count >= limit { break }
            let batch = Array(slice[start..<min(start + 6, slice.count)])
            let part: [(Int, MetaPreview)] = await withTaskGroup(of: (Int, MetaPreview)?.self) { group in
                for (offset, row) in batch.enumerated() {
                    let i = start + offset
                    group.addTask {
                        guard let ext = await get("/\(row.media)/\(row.tmdbID)/external_ids?api_key=\(key)"),
                              let imdb = ext["imdb_id"] as? String, imdb.hasPrefix("tt"),
                              row.poster?.isEmpty == false else { return nil }
                        let type = row.media == "tv" ? "series" : "movie"
                        return (i, MetaPreview(id: imdb, type: type, name: row.name, poster: row.poster, posterShape: nil, popularity: nil))
                    }
                }
                var out: [(Int, MetaPreview)] = []
                for await r in group { if let r { out.append(r) } }
                return out
            }
            resolved.append(contentsOf: part)
        }
        var seen = Set<String>()
        let ordered = resolved.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0.id).inserted }
        return Array(ordered.prefix(limit))
    }

    /// A discover-result row, shared by the genre / recent / provider pages: (tmdb id, media, title, poster).
    private typealias DiscoverRow = (tmdbID: Int, media: String, name: String, poster: String?)

    /// One TMDB discover-by-genre page, popularity-desc, US-English titles.
    private static func discoverGenrePage(media: String, genreID: Int, key: String) async -> [DiscoverRow] {
        let path = "/discover/\(media)?api_key=\(key)&with_genres=\(genreID)"
            + "&sort_by=popularity.desc&vote_count.gte=50&language=en-US&page=1"
        return parseDiscover(await get(path), media: media)
    }

    /// One TMDB discover page bounded by a release/air-date window, with the given sort (popularity for Top
    /// New, release-date for Just New). The date field differs by media (`primary_release_date` vs
    /// `first_air_date`), so bound on the matching `.gte`/`.lte` for each.
    private static func discoverRecentPage(media: String, sort: String, from: String, to: String, region: String, key: String) async -> [DiscoverRow] {
        let dateField = media == "tv" ? "first_air_date" : "primary_release_date"
        let path = "/discover/\(media)?api_key=\(key)&sort_by=\(sort)&\(dateField).gte=\(from)&\(dateField).lte=\(to)"
            + "&vote_count.gte=20&watch_region=\(region)&language=en-US&page=1"
        return parseDiscover(await get(path), media: media)
    }

    /// Decode a TMDB discover/results payload into `DiscoverRow`s (id + title/name + poster).
    private static func parseDiscover(_ obj: [String: Any]?, media: String) -> [DiscoverRow] {
        guard let obj, let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            let name = (r["title"] as? String) ?? (r["name"] as? String) ?? ""
            let poster = (r["poster_path"] as? String).map { "https://image.tmdb.org/t/p/w342\($0)" }
            return (id, media, name, poster)
        }
    }

    /// One TMDB discover-by-provider page: (tmdb id, media, title, poster URL) rows, flatrate + most popular.
    private static func discoverProviderPage(media: String, providerID: Int, region: String, key: String)
        async -> [(tmdbID: Int, media: String, name: String, poster: String?)] {
        let path = "/discover/\(media)?api_key=\(key)&watch_region=\(region)&with_watch_providers=\(providerID)"
            + "&with_watch_monetization_types=flatrate&sort_by=popularity.desc&language=en-US&page=1"
        guard let obj = await get(path), let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            let name = (r["title"] as? String) ?? (r["name"] as? String) ?? ""
            let poster = (r["poster_path"] as? String).map { "https://image.tmdb.org/t/p/w342\($0)" }
            return (id, media, name, poster)
        }
    }

    // MARK: - Collections hub (Discover cards, streaming-service tiles, sub-catalog grids)

    /// A streaming/SVOD provider available in the viewer's region, for the Streaming-Services tile row.
    /// `providerID` is the TMDB/JustWatch watch-provider id; `logoURL` is TMDB's OFFICIAL logo (so we ship
    /// no copyrighted brand art). Built from /watch/providers, region-filtered, majors boosted to the front.
    struct ProviderTile: Identifiable, Hashable {
        let providerID: Int
        let name: String
        let logoPath: String?
        var id: Int { providerID }
        var logoURL: String? { logoPath.map { "https://image.tmdb.org/t/p/w300\($0)" } }
    }

    /// Curated front-of-row ordering for well-known SVOD services (lower = earlier). Anything not listed
    /// keeps TMDB's region `display_priority` (appended after). Includes anime + K-drama services so they
    /// surface high where the region carries them (Crunchyroll, Rakuten Viki, HiDive, Disney+ Hotstar, ...).
    private static let featuredProviderRank: [Int: Int] = [
        8: 0,                 // Netflix
        9: 1, 119: 1,         // Amazon Prime Video
        337: 2,               // Disney+
        1899: 3, 384: 3,      // Max / HBO Max
        15: 4,                // Hulu
        350: 5, 2: 5,         // Apple TV+
        531: 6,               // Paramount+
        386: 7,               // Peacock
        283: 8,               // Crunchyroll (anime)
        344: 9,               // Rakuten Viki (K-drama / Asian)
        430: 10,              // HiDive (anime)
        122: 11,              // Disney+ Hotstar
        43: 12,               // Starz
        37: 13,               // Showtime
        526: 14,              // AMC+
        520: 15, 524: 15,     // Discovery+
        38: 16,               // BBC iPlayer
        73: 17,               // Tubi
        300: 18,              // Pluto TV
        11: 19,               // MUBI
    ]

    /// The streaming-service tiles for the region: every provider TMDB lists in-region, the majors boosted
    /// to the front by `featuredProviderRank`, the rest by TMDB's region display_priority, capped. Merges
    /// the movie + TV provider lists (some services are TV-only or movie-only). [] with no TMDB key.
    static func regionProviders(region: String = deviceRegion, limit: Int = 36) async -> [ProviderTile] {
        // No user-key guard: the keyless edge serves providers too, so the hub populates for everyone.
        async let movieList = providerPage(media: "movie", region: region)
        async let tvList = providerPage(media: "tv", region: region)
        var byID: [Int: (tile: ProviderTile, priority: Int)] = [:]
        for entry in (await movieList) + (await tvList) {
            // Keep the smaller (more prominent) display_priority when a provider is in both lists.
            if let existing = byID[entry.tile.providerID], existing.priority <= entry.priority { continue }
            byID[entry.tile.providerID] = entry
        }
        let ranked = byID.values.sorted { a, b in
            let ra = featuredProviderRank[a.tile.providerID] ?? (1000 + a.priority)
            let rb = featuredProviderRank[b.tile.providerID] ?? (1000 + b.priority)
            return ra != rb ? ra < rb : a.tile.name < b.tile.name
        }
        return Array(ranked.map(\.tile).prefix(limit))
    }

    private static func providerPage(media: String, region: String) async -> [(tile: ProviderTile, priority: Int)] {
        let key = ApiKeys.effectiveTMDBKey()
        guard let obj = await get("/watch/providers/\(media)?api_key=\(key)&watch_region=\(region)"),
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { p in
            guard let id = p["provider_id"] as? Int, let name = p["provider_name"] as? String else { return nil }
            let priority = (p["display_priority"] as? Int) ?? 999
            return (ProviderTile(providerID: id, name: name, logoPath: p["logo_path"] as? String), priority)
        }
    }

    /// One TMDB LIST endpoint (trending / popular / now_playing / upcoming) resolved to engine-playable tt
    /// previews. `path` is the endpoint without query, e.g. "/trending/movie/week", "/movie/popular",
    /// "/movie/now_playing", "/movie/upcoming". Paginated. Fails soft to [] with no key / nothing found.
    static func listTitles(path: String, region: String = deviceRegion, page: Int = 1, limit: Int = 40) async -> [MetaPreview] {
        let key = ApiKeys.effectiveTMDBKey()
        let media = path.contains("/tv") ? "tv" : "movie"
        let full = "\(path)?api_key=\(key)&language=en-US&page=\(page)&region=\(region)"
        return await resolveRows(parseDiscover(await get(full), media: media), key: key, limit: limit)
    }

    /// One TMDB /discover page with arbitrary extra params (with_watch_providers / with_genres / sort_by /
    /// date windows), resolved to tt previews. `extra` is a pre-built query fragment (no leading `&`). The
    /// sub-catalog grids (Movies / Shows / New / Top week-month-year / Trending) are built from this.
    static func discoverTitles(media: String, extra: String, region: String = deviceRegion, page: Int = 1, limit: Int = 40) async -> [MetaPreview] {
        let key = ApiKeys.effectiveTMDBKey()
        let full = "/discover/\(media)?api_key=\(key)&language=en-US&watch_region=\(region)&page=\(page)&\(extra)"
        return await resolveRows(parseDiscover(await get(full), media: media), key: key, limit: limit)
    }

    /// A representative 16:9 backdrop for a genre tile: the most popular in-region title in that genre's
    /// bucket (movie bucket preferred; TV when the genre is movies-only), as a w780 URL. One discover call,
    /// fail-soft to nil. Lets the Collections-hub genre tiles show real artwork instead of a flat gradient.
    static func genreBackdrop(movieGenre: Int?, tvGenre: Int?, keyword: Int?, lang: String?, region: String = deviceRegion) async -> String? {
        let key = ApiKeys.effectiveTMDBKey()
        let media = movieGenre != nil ? "movie" : "tv"
        let genreID = movieGenre ?? tvGenre
        var parts = ["api_key=\(key)", "sort_by=popularity.desc", "watch_region=\(region)",
                     "language=en-US", "page=1", "include_adult=false", "vote_count.gte=150"]
        if let genreID { parts.append("with_genres=\(genreID)") }
        if let keyword { parts.append("with_keywords=\(keyword)") }
        if let lang { parts.append("with_original_language=\(lang)") }
        guard let obj = await get("/discover/\(media)?" + parts.joined(separator: "&")),
              let results = obj["results"] as? [[String: Any]] else { return nil }
        // First result that actually carries a backdrop; the scrim in the tile keeps the label legible.
        let bd = results.compactMap { $0["backdrop_path"] as? String }.first
        return bd.map { "https://image.tmdb.org/t/p/w780\($0)" }
    }

    /// A representative 16:9 backdrop for a Discover card, from the most popular title in its primary movie
    /// list (a TMDB list path like `/trending/movie/week` or `/movie/popular`), as a w780 URL. One list call,
    /// fail-soft to nil. The direct mirror of `genreBackdrop` for the Discover tiles. The scrim in the tile
    /// keeps the label legible.
    static func listBackdrop(path: String, region: String = deviceRegion) async -> String? {
        let key = ApiKeys.effectiveTMDBKey()
        let full = "\(path)?api_key=\(key)&language=en-US&page=1&region=\(region)"
        guard let obj = await get(full), let results = obj["results"] as? [[String: Any]] else { return nil }
        let bd = results.compactMap { $0["backdrop_path"] as? String }.first
        return bd.map { "https://image.tmdb.org/t/p/w780\($0)" }
    }

    /// ISO `yyyy-MM-dd` for `daysAgo` days before now (0 = today). Bounds the Top-This-Week/Month/Year and
    /// "new"/"upcoming" date windows for the sub-catalog discover queries.
    static func isoDate(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .iso8601)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    // MARK: - Movie financials (budget + box office)

    struct Financials: Hashable { let budget: Int; let revenue: Int }

    /// Movie budget + box-office (revenue) from TMDB /movie/{id}, resolved from an IMDb id. Movies only
    /// (TMDB carries no TV financials). nil with no key / a series / nothing found / both values zero.
    static func details(imdbID: String, type: String) async -> Financials? {
        guard type != "series", imdbID.hasPrefix("tt") else { return nil }
        let key = ApiKeys.effectiveTMDBKey()
        guard let found = await get("/find/\(imdbID)?external_source=imdb_id&api_key=\(key)"),
              let first = (found["movie_results"] as? [[String: Any]])?.first,
              let tmdbID = first["id"] as? Int,
              let movie = await get("/movie/\(tmdbID)?api_key=\(key)") else { return nil }
        let budget = movie["budget"] as? Int ?? 0
        let revenue = movie["revenue"] as? Int ?? 0
        guard budget > 0 || revenue > 0 else { return nil }
        return Financials(budget: budget, revenue: revenue)
    }

    /// Compact USD for the detail facts row: "$1.5K" / "$200M" / "$2.4B". nil for a non-positive amount.
    static func shortMoney(_ value: Int) -> String? {
        guard value > 0 else { return nil }
        let v = Double(value)
        if v >= 1_000_000_000 { return String(format: "$%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "$%.0fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "$%.0fK", v / 1_000) }
        return "$\(value)"
    }

    // MARK: - Spoken languages (audio-claim verification)

    /// The ISO-639-1 language codes TMDB lists as SPOKEN in a title (movie or TV), lowercased. This is the
    /// authoritative "which languages does this film's audio actually contain" signal used to VERIFY a
    /// release-name audio claim before it is shown as a confident language chip: a K-drama whose release name
    /// says "English" but whose real audio is Korean-only has `spoken_languages` == [ko], so the false EN
    /// claim can be dropped.
    ///
    /// Resolved from an IMDb id through the SAME keyless, cached edge path every other TMDB call uses
    /// (`get` -> `catalogs.vortx.tv/3` when the user has no key, TMDB direct when they do), so it needs no user
    /// key. Fail-soft: returns nil (NOT an empty set) on no id / no match / no data / any error, so the caller
    /// can distinguish "TMDB says the spoken set is X" from "TMDB was unreachable" and only DROP a claim on the
    /// former. Codes only; no user data.
    static func spokenLanguages(imdbID: String, type: String) async -> Set<String>? {
        guard imdbID.hasPrefix("tt") else { return nil }
        let key = ApiKeys.effectiveTMDBKey()
        let media = (type == "series") ? "tv" : "movie"
        guard let found = await get("/find/\(imdbID)?external_source=imdb_id&api_key=\(key)"),
              let first = (found[media == "tv" ? "tv_results" : "movie_results"] as? [[String: Any]])?.first,
              let tmdbID = first["id"] as? Int,
              let details = await get("/\(media)/\(tmdbID)?api_key=\(key)") else { return nil }
        // `spoken_languages` is [{ iso_639_1, english_name, name }, ...]. Missing/empty -> nil (no signal, do
        // not treat as "contradicts everything"), never [] (which would falsely contradict every audio claim).
        guard let langs = details["spoken_languages"] as? [[String: Any]] else { return nil }
        let codes = langs.compactMap { ($0["iso_639_1"] as? String)?.lowercased() }
            .filter { !$0.isEmpty && $0 != "xx" }   // TMDB uses "xx" for "no linguistic content"
        // Fold in original_language too: some titles carry a bare original_language but an empty
        // spoken_languages, and the original language is genuinely spoken.
        var set = Set(codes)
        if let orig = (first["original_language"] as? String)?.lowercased(), !orig.isEmpty, orig != "xx" {
            set.insert(orig)
        }
        guard !set.isEmpty else { return nil }
        return set
    }

    /// Optional-id convenience so a caller can `async let` the spoken-languages fetch without wrapping the
    /// optional in a non-async `.map` (which won't type-check around an async call). nil id -> nil result.
    static func spokenLanguages(imdbID: String?, type: String) async -> Set<String>? {
        guard let imdbID else { return nil }
        return await spokenLanguages(imdbID: imdbID, type: type)
    }

    // MARK: - Movie release dates (theatrical + digital)

    struct ReleaseDates: Hashable { let theatrical: String?; let digital: String? }

    /// Theatrical (TMDB release type 3) + digital (type 4) dates from /movie/{id}/release_dates, resolved
    /// from an IMDb id. Movies only (TMDB carries no TV release dates). Region-aware: the device region
    /// first, then a US fallback per field. nil with no key / a series / neither date found. Dates come back
    /// pretty-printed ("Mar 1, 2024") so the views render them verbatim.
    static func releaseDates(imdbID: String, type: String) async -> ReleaseDates? {
        guard type != "series", imdbID.hasPrefix("tt") else { return nil }
        let key = ApiKeys.effectiveTMDBKey()
        guard let found = await get("/find/\(imdbID)?external_source=imdb_id&api_key=\(key)"),
              let first = (found["movie_results"] as? [[String: Any]])?.first,
              let tmdbID = first["id"] as? Int,
              let payload = await get("/movie/\(tmdbID)/release_dates?api_key=\(key)"),
              let results = payload["results"] as? [[String: Any]] else { return nil }

        func date(ofType t: Int, in entries: [[String: Any]]) -> String? {
            entries.first { ($0["type"] as? Int) == t }?["release_date"] as? String
        }
        func entries(forRegion code: String) -> [[String: Any]]? {
            results.first { ($0["iso_3166_1"] as? String) == code }?["release_dates"] as? [[String: Any]]
        }

        var theatrical: String?, digital: String?
        if let local = entries(forRegion: deviceRegion) {
            theatrical = date(ofType: 3, in: local); digital = date(ofType: 4, in: local)
        }
        if theatrical == nil || digital == nil, let us = entries(forRegion: "US") {
            theatrical = theatrical ?? date(ofType: 3, in: us)
            digital = digital ?? date(ofType: 4, in: us)
        }
        guard theatrical != nil || digital != nil else { return nil }
        return ReleaseDates(theatrical: prettyDate(theatrical), digital: prettyDate(digital))
    }

    /// TMDB sends "2024-03-01T00:00:00.000Z" (or "2024-03-01"); render the date part as "Mar 1, 2024".
    private static func prettyDate(_ iso: String?) -> String? {
        guard let iso, iso.count >= 10 else { return nil }
        let inFmt = DateFormatter()
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.dateFormat = "yyyy-MM-dd"
        guard let date = inFmt.date(from: String(iso.prefix(10))) else { return nil }
        let out = DateFormatter()
        out.dateStyle = .medium; out.timeStyle = .none
        return out.string(from: date)
    }

    // MARK: - Cast & crew credits (full cast, who-played-who)

    /// One cast entry for the detail page's full-cast rail: the person, the character they played, and a
    /// w185 headshot URL when TMDB has one. Identifiable by the TMDB person id.
    struct CastMember: Identifiable, Hashable {
        let id: Int
        let name: String
        let character: String?
        let profileURL: String?
    }

    struct CreditsResult: Hashable { let cast: [CastMember]; let overview: String? }

    /// Full cast with character names + headshots, resolved from an IMDb id through the SAME keyless
    /// edge path every other call uses (no user key required). Series use aggregate_credits so recurring
    /// roles across seasons resolve; movies use /credits. The /find result's overview rides along as a
    /// description fallback for titles Cinemeta doesn't know yet. Fail-soft: nil on no match / no data /
    /// any error; an overview with no cast still returns (the fallback synopsis is useful on its own).
    static func credits(imdbID: String, type: String) async -> CreditsResult? {
        guard imdbID.hasPrefix("tt") else { return nil }
        let key = ApiKeys.effectiveTMDBKey()
        let media = (type == "series") ? "tv" : "movie"
        guard let found = await get("/find/\(imdbID)?external_source=imdb_id&api_key=\(key)"),
              let first = (found[media == "tv" ? "tv_results" : "movie_results"] as? [[String: Any]])?.first,
              let tmdbID = first["id"] as? Int else { return nil }
        let overview = (first["overview"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let path = media == "tv" ? "/tv/\(tmdbID)/aggregate_credits?api_key=\(key)"
                                 : "/movie/\(tmdbID)/credits?api_key=\(key)"
        guard let payload = await get(path), let cast = payload["cast"] as? [[String: Any]] else {
            return overview == nil ? nil : CreditsResult(cast: [], overview: overview)
        }
        let members: [CastMember] = cast.compactMap { entry in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            // Movies carry `character`; TV aggregate credits carry `roles: [{ character }]`.
            let character = (entry["character"] as? String)
                ?? ((entry["roles"] as? [[String: Any]])?.first?["character"] as? String)
            let profile = (entry["profile_path"] as? String).map { "https://image.tmdb.org/t/p/w185\($0)" }
            return CastMember(id: entry["id"] as? Int ?? name.hashValue, name: name,
                              character: character.flatMap { $0.isEmpty ? nil : $0 },
                              profileURL: profile)
        }
        return CreditsResult(cast: members, overview: overview)
    }

    /// VortX's keyless catalog edge: a cached, app-gated TMDB proxy that injects OUR key server-side, so
    /// users with no TMDB key still get the hub. Path here mirrors TMDB's /3 namespace. Sourced from the
    /// RemoteConfig `endpoints.catalogs` dial (validated https + *.vortx.tv host, else baked default), so the
    /// owner can repoint the catalog edge with no app update. Baked default `https://catalogs.vortx.tv/3` ==
    /// the shipping value; a null/invalid remote endpoint keeps that default.
    private static var edgeBase: String { RemoteConfig.snapshot.catalogsEndpoint.absoluteString }

    /// Single fetch choke point. ROUTE by whether the user supplied their OWN TMDB key:
    ///   - user key present -> talk to TMDB directly (the path already carries their key);
    ///   - no user key      -> route through the keyless edge (it injects its own key + caches), signed so
    ///                          the gate attributes the call to VortX. The bundled key is stripped from the
    ///                          path on this route; if the edge is unreachable we fall back to TMDB direct
    ///                          with the bundled key (the path still carries it) so the hub degrades, never
    ///                          dies. `path` is "/...?api_key=<effective>&...".
    private static func get(_ path: String) async -> [String: Any]? {
        if ApiKeys.tmdbKey() != nil {
            return await fetchJSON(URL(string: host + path), sign: false)
        }
        if let edgeURL = edgeURL(forPath: path), let obj = await fetchJSON(edgeURL, sign: true) {
            return obj
        }
        return await fetchJSON(URL(string: host + path), sign: false)   // edge down -> bundled-key direct
    }

    /// Build the edge URL for a TMDB path: prefix /3 (already in `host` for direct calls) and DROP the
    /// `api_key` param, since the worker injects its own key server-side.
    private static func edgeURL(forPath path: String) -> URL? {
        guard var comps = URLComponents(string: edgeBase + path) else { return nil }
        comps.queryItems = (comps.queryItems ?? []).filter { $0.name != "api_key" }
        if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
        return comps.url
    }

    /// GET + decode JSON. Signs the request via `VortXEdgeAuth` when `sign` (only our edge host is gated;
    /// the helper no-ops for any other host), so the same call is safe whether it targets TMDB or the edge.
    private static func fetchJSON(_ url: URL?, sign: Bool) async -> [String: Any]? {
        guard let url else { return nil }
        var req = URLRequest(url: url)
        if sign { VortXEdgeAuth.sign(&req) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } catch { return nil }
    }

    /// Resolve a catalog id to an IMDb `tt` id. A `tt` id passes straight through; a `tmdb:<n>` (or bare
    /// numeric) id is resolved via /external_ids through the SAME keyless, edge-cached choke point as every
    /// other call here (catalogs.vortx.tv caches external_ids ~24h with SWR, so a warm title resolves in a few
    /// ms). Hub catalogs (Discover/Trending/genres/streaming tiles) deliver tmdb: ids, but Cinemeta meta,
    /// stream add-ons and the ratings service all key on the imdb `tt` id - so resolving BEFORE pushing detail
    /// is what makes hub items show art/ratings/sources on iOS+Mac the way tvOS already does. The hub type
    /// guess is sometimes wrong, so try the guessed media then the other; external_ids is authoritative.
    /// Fail-soft: returns nil on any failure, and the caller falls back to pushing the unresolved id.
    static func imdbID(forCatalogID cid: String, type: String) async -> String? {
        if cid.hasPrefix("tt") { return cid }
        let tmdbNumber: Int?
        if cid.hasPrefix("tmdb:") { tmdbNumber = Int(cid.dropFirst(5)) }
        else if let n = Int(cid) { tmdbNumber = n }
        else { tmdbNumber = nil }
        guard let tid = tmdbNumber else { return nil }
        let key = ApiKeys.effectiveTMDBKey()
        let primary = (type == "series") ? "tv" : "movie"
        let secondary = (primary == "tv") ? "movie" : "tv"
        for media in [primary, secondary] {
            if let ext = await get("/\(media)/\(tid)/external_ids?api_key=\(key)"),
               let imdb = ext["imdb_id"] as? String, imdb.hasPrefix("tt") {
                return imdb
            }
        }
        return nil
    }

}
