import Foundation

/// List import: paste a public Letterboxd, MDBList, or Trakt list URL and browse it as a native catalog
/// row (see `ImportedListCatalog` in CatalogPreferences). This file owns the coordinator (`ListImport`) plus
/// the Letterboxd and Trakt fetchers; the MDBList fetcher lives in `MDBListClient.swift`. Every path is
/// fail-soft: a bad URL, a private list, or a network hiccup returns a clear `ImportedListError`, never a
/// crash, and each resolved item carries an engine-safe id (an IMDb `tt…` id, or a `tmdb:…` id) so the row
/// taps straight into Detail through the engine, exactly like an add-on catalog card. Nothing here writes
/// account/library state (invariant): the resolved list is stored only in this app's own preferences.

// MARK: - Shared value types

/// A raw list entry parsed from a provider before id normalization. A provider fills whatever it knows
/// (some give an imdb id outright, some only a title), and `ListImport.resolve` turns each into an
/// engine-safe `ImportedListItem`.
struct RawListEntry: Sendable {
    var imdbID: String?      // "tt…" when the provider exposes it
    var tmdbID: Int?         // numeric TMDB id when known
    var tmdbType: String?    // "movie" | "tv"
    var title: String?       // display title (also the search fallback key)
    var year: Int?           // release year when known
    var typeHint: String?    // "movie" | "series"
}

/// A fetched list: its display name (when the provider exposes one) plus the raw entries in list order.
struct RawList: Sendable {
    let title: String?
    let entries: [RawListEntry]
}

/// Why a list import could not complete. `errorDescription` is user-facing copy the paste screen can show
/// verbatim (no em dashes, per house style).
enum ImportedListError: Error, LocalizedError, Equatable {
    case unsupportedURL
    case empty
    case network
    case notConfigured(ImportedListProvider)

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "That does not look like a Letterboxd, MDBList, or Trakt list link. Paste the public URL of a list."
        case .empty:
            return "No titles could be read from that list. Make sure the list is public and try again."
        case .network:
            return "Could not reach that list. Check your connection and try again."
        case .notConfigured(let provider):
            return "\(provider.label) list import is not available in this build."
        }
    }
}

// MARK: - Coordinator

/// The single entry point the paste-URL screen calls. `importList(from:)` detects the provider from the
/// URL, fetches the list, resolves every entry to an engine-safe id, and returns an un-persisted
/// `ImportedListCatalog`. The caller previews it and, on confirm, hands it to `ImportedCatalogs.shared`.
enum ListImport {
    /// Hard cap on titles per imported row, so a 1,000-item list stays a quick browse and the id-resolution
    /// fan-out stays bounded.
    static let maxItems = 150

    /// A browser-like User-Agent. Several of these hosts (Cinemeta, Letterboxd) reject the default URLSession
    /// agent, the same lesson `AddonClient` and the libmpv stream fetches already learned.
    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// A parsed, provider-scoped list reference. Hosts are fixed per provider (never taken from the pasted
    /// URL) so a crafted link cannot point the fetch at an arbitrary host (SSRF-safe).
    struct Detected: Equatable {
        let provider: ImportedListProvider
        let user: String
        let slug: String
        let canonicalURL: String
    }

    /// Detect the provider and pull the `<user>` / `<slug>` (or list id) out of a pasted URL. Returns nil for
    /// any URL that is not a recognized public-list link. Only the path segments are trusted; the host is
    /// re-asserted from the provider, so the fetch always targets the provider's real host.
    static func detect(_ urlString: String) -> Detected? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"),
              let rawHost = comps.host?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let parts = comps.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }

        func matches(_ base: String) -> Bool { host == base || host.hasSuffix(".\(base)") }

        // Letterboxd: /<user>/list/<slug>/...
        if matches("letterboxd.com"),
           parts.count >= 3, parts[1].lowercased() == "list" {
            let user = parts[0], slug = parts[2]
            guard isSafeSegment(user), isSafeSegment(slug) else { return nil }
            return Detected(provider: .letterboxd, user: user, slug: slug,
                            canonicalURL: "https://letterboxd.com/\(user)/list/\(slug)/")
        }
        // MDBList: /lists/<user>/<slug>
        if matches("mdblist.com"),
           parts.count >= 3, parts[0].lowercased() == "lists" {
            let user = parts[1], slug = parts[2]
            guard isSafeSegment(user), isSafeSegment(slug) else { return nil }
            return Detected(provider: .mdblist, user: user, slug: slug,
                            canonicalURL: "https://mdblist.com/lists/\(user)/\(slug)")
        }
        // Trakt: /users/<user>/lists/<slug>  (also the shorter /lists/<id> form)
        if matches("trakt.tv") {
            if parts.count >= 4, parts[0].lowercased() == "users", parts[2].lowercased() == "lists" {
                let user = parts[1], slug = parts[3]
                guard isSafeSegment(user), isSafeSegment(slug) else { return nil }
                return Detected(provider: .trakt, user: user, slug: slug,
                                canonicalURL: "https://trakt.tv/users/\(user)/lists/\(slug)")
            }
            if parts.count >= 2, parts[0].lowercased() == "lists" {
                let slug = parts[1]
                guard isSafeSegment(slug) else { return nil }
                return Detected(provider: .trakt, user: "", slug: slug,
                                canonicalURL: "https://trakt.tv/lists/\(slug)")
            }
        }
        return nil
    }

    /// Fetch + resolve a pasted list URL into an un-persisted catalog. Fail-soft to a typed error the paste
    /// screen can surface. Does NOT persist; the caller registers it with `ImportedCatalogs.shared`.
    static func importList(from urlString: String) async -> Result<ImportedListCatalog, ImportedListError> {
        guard let detected = detect(urlString) else { return .failure(.unsupportedURL) }

        let raw: RawList
        switch detected.provider {
        case .mdblist:
            raw = await MDBListClient.fetchRawList(user: detected.user, slug: detected.slug)
        case .letterboxd:
            raw = await LetterboxdImportClient.fetchRawList(user: detected.user, slug: detected.slug)
        case .trakt:
            guard !TraktAuth.clientID.isEmpty else { return .failure(.notConfigured(.trakt)) }
            raw = await TraktListImportClient.fetchRawList(user: detected.user, slug: detected.slug)
        }

        guard !raw.entries.isEmpty else { return .failure(.empty) }
        let items = await resolve(Array(raw.entries.prefix(maxItems)))
        guard !items.isEmpty else { return .failure(.empty) }

        let title = (raw.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? humanize(slug: detected.slug)
        let catalog = ImportedListCatalog(
            id: stableID(detected),
            title: title,
            provider: detected.provider,
            sourceURL: detected.canonicalURL,
            items: items,
            addedAt: Date()
        )
        DiagnosticsLog.log("list-import", "\(detected.provider.rawValue) '\(title)' -> \(items.count) titles")
        return .success(catalog)
    }

    // MARK: Resolution

    /// Resolve raw entries to engine-safe items, in list order, de-duplicated by id. Bounded concurrency so a
    /// large Letterboxd list does not open 150 sockets at once.
    static func resolve(_ entries: [RawListEntry]) async -> [ImportedListItem] {
        let resolved = await boundedMap(entries, concurrency: 6) { await resolveOne($0) }
        var seen = Set<String>()
        var out: [ImportedListItem] = []
        for item in resolved.compactMap({ $0 }) where seen.insert(item.id).inserted {
            out.append(item)
        }
        return out
    }

    /// One entry to one item. Preference order for the id, best-first: a provider IMDb id, then a TMDB id
    /// converted to IMDb through the keyless edge (`CommunityTrickplay.resolveIMDbID`, cached), then a
    /// Cinemeta title search. Every branch yields a `tt…` id where possible so the poster is the deterministic
    /// metahub image and the card taps through the engine. Returns nil when nothing resolves (item dropped).
    static func resolveOne(_ entry: RawListEntry) async -> ImportedListItem? {
        let type = entry.typeHint ?? (entry.tmdbType == "tv" ? "series" : "movie")

        if let tt = normalizedTT(entry.imdbID) {
            return ImportedListItem(id: tt, type: type, name: entry.title ?? tt, poster: metahubPoster(tt))
        }
        if let tmdb = entry.tmdbID,
           let tt = await CommunityTrickplay.resolveIMDbID(rawId: "tmdb:\(tmdb)", seriesHint: type == "series") {
            return ImportedListItem(id: tt, type: type, name: entry.title ?? tt, poster: metahubPoster(tt))
        }
        if let title = entry.title, !title.isEmpty, let hit = await searchCinemeta(title: title, type: type) {
            let poster = hit.poster ?? (hit.id.hasPrefix("tt") ? metahubPoster(hit.id) : nil)
            return ImportedListItem(id: hit.id, type: hit.type, name: hit.name, poster: poster)
        }
        return nil
    }

    /// Best Cinemeta search hit for a title: an exact case-insensitive name match when present, else the
    /// first (Cinemeta ranks by relevance). Fail-soft to nil.
    private static func searchCinemeta(title: String, type: String) async -> MetaPreview? {
        guard let hits = try? await AddonClient().search(type: type, query: title), !hits.isEmpty else { return nil }
        let exact = hits.first { $0.name.compare(title, options: .caseInsensitive) == .orderedSame }
        return exact ?? hits.first
    }

    // MARK: Helpers

    /// The standard Stremio metahub poster for an IMDb id (keyless, deterministic), matching the app's
    /// `background/big` and `logo/medium` metahub convention in CoreModels.
    static func metahubPoster(_ tt: String) -> String { "https://images.metahub.space/poster/medium/\(tt)/img" }

    /// A validated IMDb id ("tt" + digits) or nil, so a malformed value never rides into an engine id.
    static func normalizedTT(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), raw.hasPrefix("tt") else { return nil }
        let digits = raw.dropFirst(2)
        return (!digits.isEmpty && digits.allSatisfy(\.isNumber)) ? raw : nil
    }

    /// A stable per-list id so re-importing the same list updates the existing row rather than duplicating it.
    /// THE one id format for imported rows: `TraktMyListsClient` builds ids through this same call, so adding
    /// your own list from the My Lists screen and pasting that list's public URL land on the SAME id and
    /// replace each other in place instead of painting the list twice.
    static func stableID(provider: ImportedListProvider, user: String, slug: String) -> String {
        "imported:\(provider.rawValue):\(user):\(slug)".lowercased()
    }

    private static func stableID(_ d: Detected) -> String {
        stableID(provider: d.provider, user: d.user, slug: d.slug)
    }

    /// Turn a URL slug into a readable title ("official-top-250" -> "Official Top 250") as a fallback when the
    /// provider exposes no list name.
    static func humanize(slug: String) -> String {
        let words = slug.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { part -> String in
                let str = String(part)
                return str.prefix(1).uppercased() + String(str.dropFirst())
            }
        let joined = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? "Imported list" : joined
    }

    /// A path segment is safe when it is a single non-empty component with no traversal or separators (the
    /// URL parser already split on "/", this rejects the pathological rest).
    private static func isSafeSegment(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\\")
    }

    /// Percent-encode a path segment for insertion into a fixed-host URL.
    static func encodePath(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// GET a URL as UTF-8 text (HTML pages), browser UA, fail-soft to nil.
    static func fetchText(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Order-preserving, concurrency-bounded async map. Every index is dispatched exactly once and drained
    /// exactly once, so the result covers `items.indices` with no gaps.
    static func boundedMap<In: Sendable, Out: Sendable>(
        _ items: [In], concurrency: Int, _ transform: @escaping @Sendable (In) async -> Out
    ) async -> [Out] {
        guard !items.isEmpty else { return [] }
        let limit = max(1, concurrency)
        return await withTaskGroup(of: (Int, Out).self) { group in
            // Index-addressed so results land in input order regardless of completion order.
            var slots = [Out?](repeating: nil, count: items.count)
            var next = 0
            while next < min(limit, items.count) {
                let i = next, el = items[i]
                group.addTask { (i, await transform(el)) }
                next += 1
            }
            while let (i, out) = await group.next() {
                slots[i] = out
                if next < items.count {
                    let j = next, el = items[j]
                    group.addTask { (j, await transform(el)) }
                    next += 1
                }
            }
            return slots.compactMap { $0 }
        }
    }

    /// Unescape the handful of HTML entities that show up in scraped titles.
    static func unescapeHTML(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&#39;": "'", "&#x27;": "'", "&quot;": "\"", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, value) in map { out = out.replacingOccurrences(of: entity, with: value) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First capture group of `pattern` in `text`, or nil.
    static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    /// All first-capture-group matches of `pattern` in `text`, in document order.
    static func allMatches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges > group, let r = Range(m.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }
}

// MARK: - Letterboxd

/// Letterboxd exposes no list API, so a public list is scraped: the list page(s) give ordered film slugs and
/// the list name (og:title), and each film page carries its TMDB and IMDb ids as external links. Film-page
/// resolution is concurrency-bounded and capped. Fail-soft throughout (a film that will not load is dropped).
enum LetterboxdImportClient {
    private static let maxPages = 12

    static func fetchRawList(user: String, slug: String) async -> RawList {
        let u = ListImport.encodePath(user), s = ListImport.encodePath(slug)
        let base = "https://letterboxd.com/\(u)/list/\(s)"

        var slugs: [String] = []
        var seen = Set<String>()
        var listTitle: String?

        for page in 1...maxPages {
            let pageURL = page == 1 ? "\(base)/" : "\(base)/page/\(page)/"
            guard let html = await ListImport.fetchText(pageURL) else { break }
            if page == 1 { listTitle = listName(from: html) }
            let pageSlugs = filmSlugs(from: html)
            var added = 0
            for slug in pageSlugs where seen.insert(slug).inserted {
                slugs.append(slug)
                added += 1
            }
            if added == 0 || slugs.count >= ListImport.maxItems { break }
        }

        let capped = Array(slugs.prefix(ListImport.maxItems))
        let entries = await ListImport.boundedMap(capped, concurrency: 6) { await filmEntry(slug: $0) }
        return RawList(title: listTitle, entries: entries.compactMap { $0 })
    }

    /// Ordered, de-dup-later film slugs from a list page. Letterboxd tags each poster with `data-film-slug`
    /// and links to `/film/<slug>/`; both are matched so a markup tweak on one does not break scraping.
    private static func filmSlugs(from html: String) -> [String] {
        let a = ListImport.allMatches("data-film-slug=\"([^\"]+)\"", in: html)
        let b = ListImport.allMatches("/film/([a-z0-9][a-z0-9-]*)/", in: html)
        var ordered: [String] = []
        var seen = Set<String>()
        for slug in a + b where seen.insert(slug).inserted { ordered.append(slug) }
        return ordered
    }

    /// The list's display name from the page og:title, unescaped.
    private static func listName(from html: String) -> String? {
        guard let raw = ListImport.firstMatch("<meta property=\"og:title\" content=\"([^\"]+)\"", in: html) else { return nil }
        let name = ListImport.unescapeHTML(raw)
        return name.isEmpty ? nil : name
    }

    /// One film page to a raw entry: TMDB id + type from the TMDb link, IMDb id from the IMDb link, and the
    /// display name/year from og:title. Fail-soft: a page that yields neither an id nor a title is dropped.
    private static func filmEntry(slug: String) async -> RawListEntry? {
        let filmURL = "https://letterboxd.com/film/\(ListImport.encodePath(slug))/"
        guard let html = await ListImport.fetchText(filmURL) else { return nil }

        let imdb = ListImport.firstMatch("imdb\\.com/title/(tt[0-9]{6,})", in: html)
        let tmdbType = ListImport.firstMatch("themoviedb\\.org/(movie|tv)/[0-9]+", in: html)
        let tmdbID = ListImport.firstMatch("themoviedb\\.org/(?:movie|tv)/([0-9]+)", in: html).flatMap(Int.init)

        var title: String?
        var year: Int?
        if let og = ListImport.firstMatch("<meta property=\"og:title\" content=\"([^\"]+)\"", in: html) {
            let cleaned = ListImport.unescapeHTML(og)
            if let y = ListImport.firstMatch("\\(([0-9]{4})\\)\\s*$", in: cleaned) { year = Int(y) }
            title = cleaned.replacingOccurrences(of: "\\s*\\([0-9]{4}\\)\\s*$", with: "", options: .regularExpression)
        }
        if title == nil { title = ListImport.humanize(slug: slug) }

        guard imdb != nil || tmdbID != nil || (title?.isEmpty == false) else { return nil }
        let isTV = tmdbType == "tv"
        return RawListEntry(imdbID: imdb, tmdbID: tmdbID, tmdbType: isTV ? "tv" : "movie",
                            title: title, year: year, typeHint: isTV ? "series" : "movie")
    }
}

// MARK: - Trakt

/// A Trakt list read through the documented API. Public lists need only the app's `trakt-api-key` (client id)
/// header, no OAuth. Each item carries `ids.imdb` and `ids.tmdb` directly, so no title search is needed.
/// Fail-soft to an empty list on any error.
///
/// `authorized: true` additionally attaches the signed-in user's bearer, which is what makes a PRIVATE or
/// friends-only list readable (Trakt answers 404 on those without it). `TraktMyListsClient` passes true; the
/// paste-a-public-URL path keeps the default false, so pasting a link never silently reaches into the
/// connected account for a list the link itself could not open.
enum TraktListImportClient {
    static func fetchRawList(user: String, slug: String, authorized: Bool = false) async -> RawList {
        let path: String
        if user.isEmpty {
            path = "/lists/\(ListImport.encodePath(slug))/items/movie,show"
        } else {
            path = "/users/\(ListImport.encodePath(user))/lists/\(ListImport.encodePath(slug))/items/movie,show"
        }
        guard let url = URL(string: "\(TraktAuth.apiBase)\(path)?extended=full") else { return RawList(title: nil, entries: []) }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("2", forHTTPHeaderField: "trakt-api-version")
        req.setValue(TraktAuth.clientID, forHTTPHeaderField: "trakt-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized, let token = try? await TraktAuth.shared.validToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return RawList(title: nil, entries: [])
        }

        let entries: [RawListEntry] = array.compactMap { element in
            let listType = (element["type"] as? String)?.lowercased() ?? "movie"
            let key = listType == "show" ? "show" : "movie"
            guard let media = element[key] as? [String: Any] else { return nil }
            let ids = media["ids"] as? [String: Any]
            let imdb = ids?["imdb"] as? String
            let tmdb = intVal(ids?["tmdb"])
            let title = media["title"] as? String
            let year = intVal(media["year"])
            guard imdb != nil || tmdb != nil || (title?.isEmpty == false) else { return nil }
            let isShow = key == "show"
            return RawListEntry(imdbID: imdb, tmdbID: tmdb, tmdbType: isShow ? "tv" : "movie",
                                title: title, year: year, typeHint: isShow ? "series" : "movie")
        }
        return RawList(title: nil, entries: entries)
    }

    /// Read a JSON number that may arrive as Int, Double, or a numeric string.
    private static func intVal(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
