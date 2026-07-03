import Foundation
import Combine

/// Discover pack, part 1 (app side): localized TITLE + POSTER + LOGO in the user's language across EVERY
/// catalog, including add-on catalogs, the detail page, and the hero. The engine / add-ons send whatever
/// title + art they have (usually English); this store OVERRIDES the display values with a localized entry
/// looked up by imdb/tmdb id + the user's language from the shared VortX pool worker (catalogs.vortx.tv
/// /meta/l10n), self-seeded from users who have their own TMDB key.
///
/// Fallback chain (server + client agree on this): user-language localized -> textless/international art ->
/// original / English (whatever the add-on sent). NEVER blank: a miss returns nil and the view keeps the
/// add-on's own value, so a flaky pool never breaks a screen.
///
/// Shape:
///   - `LocalizedMetadataStore.shared` is a `@MainActor ObservableObject` a view observes. Views read
///     `title(for:)` / `poster(for:)` / `logo(for:)` and fall back to the engine value when nil, then call
///     `resolve(ids:)` when a batch of cards / a detail id appears. A publish of the resolved dict re-renders.
///   - Lookups are BATCHED (a hub screen's worth per request, capped by the worker at 60) and cached locally
///     both in memory and on disk (a title + two short paths is tiny + near-immutable).
///   - When the user has their OWN TMDB key, a miss is also fetched from TMDB directly (localized title via
///     `language=`, posters/logos via `/images` `include_image_language=<base>,null`) and CONTRIBUTED back to
///     the pool (POST, signed) so the pool self-seeds. All 100+ app locales are supported via `AppLanguage`.
///
/// Gating: off unless the resolved app language is non-English (English needs no override) AND the fleet
/// flag `features.localizedMetadata` is on (baked true). English users and a remote `false` get exactly
/// today's behavior.

// MARK: - Model

/// A pooled localized entry for one title: any of the three fields may be empty (the pool stores "" for a
/// field TMDB had nothing for). The view treats an empty string as "no override" and keeps the add-on value.
struct LocalizedMeta: Codable, Hashable {
    let title: String
    let posterPath: String
    let logoPath: String

    var localizedTitle: String? { title.isEmpty ? nil : title }
    /// The full poster URL (the pool stores TMDB image PATHS only; the client prepends the CDN host + size).
    var posterURL: String? { posterPath.isEmpty ? nil : "https://image.tmdb.org/t/p/w342\(posterPath)" }
    /// The full logo URL (PNG clearlogo where available). w500 matches the hero/logo sizing elsewhere.
    var logoURL: String? { logoPath.isEmpty ? nil : "https://image.tmdb.org/t/p/w500\(logoPath)" }

    var isEmpty: Bool { title.isEmpty && posterPath.isEmpty && logoPath.isEmpty }
}

// MARK: - Language resolution

/// The single place the app resolves "which language does the user want localized metadata in", as a full
/// `AppLanguage` code (keeps `zh-Hans` / `pt-BR` distinct, exactly what the pool keys on). Priority: the
/// pinned app UI language (Settings) first, then the first device language mapped onto a shipped app code,
/// else "en". This is the SAME language the app resolves for its UI, so all locales are covered.
enum LocalizedMetadataLanguage {
    /// The resolved app-language code (e.g. "de", "pt-BR", "zh-Hans"). Never empty.
    static var current: String {
        if let pinned = AppLanguage.current, !pinned.isEmpty { return canonical(pinned) }
        // No pin: map the first device language onto a shipped app code (base match), else English.
        if let dev = TrackPreferences.deviceLanguages.first { return deviceToApp(dev) }
        return "en"
    }

    /// True when the resolved language is English (the localized-metadata override is a no-op then, since the
    /// add-ons already send English). Used to gate the whole subsystem cheaply.
    static var isEnglish: Bool { canonical(current).lowercased().hasPrefix("en") }

    /// The bare ISO 639 base of the resolved language ("zh-Hans" -> "zh", "pt-BR" -> "pt"), for callers that
    /// only need the base (e.g. matching art tagged by base code).
    static var baseCode: String {
        let c = current
        return (c.contains("-") ? String(c.prefix(while: { $0 != "-" })) : c).lowercased()
    }

    /// Snap a code to a shipped `AppLanguage` spelling when possible (so "zh-hans" -> "zh-Hans"); otherwise
    /// return it trimmed. Casing only; unknown-but-valid codes pass through (the worker canonicalizes too).
    private static func canonical(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return "en" }
        if let exact = AppLanguage.supported.first(where: { $0.code.caseInsensitiveCompare(v) == .orderedSame }) {
            return exact.code
        }
        return v
    }

    /// Map a device language id (which may be a full BCP-47 like "pt-BR" or a bare "de") onto a shipped app
    /// code. Prefer an exact app-code match, then a base-language match (so "de-CH" -> "de"), else the bare
    /// base as-is. Keeps script/region variants (pt-BR, zh-Hant) when the device actually carries them.
    private static func deviceToApp(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        if let exact = AppLanguage.supported.first(where: { $0.code.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact.code
        }
        let base = (Locale(identifier: trimmed).language.languageCode?.identifier ?? String(trimmed.prefix(2))).lowercased()
        if let baseMatch = AppLanguage.supported.first(where: { $0.code.caseInsensitiveCompare(base) == .orderedSame }) {
            return baseMatch.code
        }
        return base.isEmpty ? "en" : base
    }
}

// MARK: - Store

@MainActor
final class LocalizedMetadataStore: ObservableObject {
    static let shared = LocalizedMetadataStore()

    /// Fleet gate: baked true. A remote `features.localizedMetadata=false` disables the override fleet-wide
    /// (e.g. the pool edge is down) with no app update. English users are also short-circuited (no override
    /// needed) so the subsystem never touches the network for them.
    static var isEnabled: Bool {
        !LocalizedMetadataLanguage.isEnglish
            && RemoteConfig.snapshot.isFeatureOn("localizedMetadata", default: true)
    }

    /// The resolved entries keyed by (lang-scoped) id, published so an observing view re-renders when a batch
    /// resolves. A stored NEGATIVE (all-empty `LocalizedMeta`) marks "looked up, pool had nothing" so a miss
    /// is not re-fetched every layout. The key is `"<lang>|<id>"` so a language switch never serves stale art.
    @Published private var entries: [String: LocalizedMeta] = [:]

    /// Ids currently in flight (per lang-scoped key), so overlapping card batches don't double-fetch.
    private var inFlight = Set<String>()
    private var flushTask: Task<Void, Never>?
    /// Ids queued for the next batched flush (deduped), pending a short debounce so a burst of cards coalesces.
    private var pending = Set<String>()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData   // the pool edge caches; we cache on disk ourselves
        return URLSession(configuration: cfg)
    }()

    private init() { loadDiskCache() }

    // MARK: reads (view-facing)

    /// The localized title for an id, or nil to keep the add-on's own title. Also enqueues a resolve so the
    /// value is fetched if not yet cached (the first paint shows the add-on title, the next shows localized).
    func title(for id: String) -> String? {
        guard Self.isEnabled, isResolvableID(id) else { return nil }
        request(id)
        return entries[scopedKey(id)]?.localizedTitle
    }

    /// The localized poster URL for an id, or nil to keep the add-on's own poster.
    func poster(for id: String) -> String? {
        guard Self.isEnabled, isResolvableID(id) else { return nil }
        request(id)
        return entries[scopedKey(id)]?.posterURL
    }

    /// The localized logo URL for an id, or nil to keep the add-on's own logo.
    func logo(for id: String) -> String? {
        guard Self.isEnabled, isResolvableID(id) else { return nil }
        request(id)
        return entries[scopedKey(id)]?.logoURL
    }

    /// Enqueue a batch of ids for resolution (call when a rail / grid / hub page appears). Cheap + idempotent;
    /// already-cached or in-flight ids are skipped. No-op when the subsystem is disabled.
    func resolve(ids: [String]) {
        guard Self.isEnabled else { return }
        for id in ids where isResolvableID(id) { request(id) }
    }

    // MARK: batching

    /// Queue one id for the next flush unless it is already cached or in flight. Schedules a short debounce so
    /// a burst of cards (a whole grid appearing) coalesces into one or two worker calls.
    private func request(_ id: String) {
        let key = scopedKey(id)
        guard entries[key] == nil, !inFlight.contains(key) else { return }
        pending.insert(id)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)   // 120 ms debounce
            await self?.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        guard Self.isEnabled else { pending.removeAll(); return }
        let lang = LocalizedMetadataLanguage.current
        // Take up to the worker's per-read cap; leave the rest queued for the next flush.
        let batch = Array(pending.prefix(Self.maxIDsPerRead))
        pending.subtract(batch)
        guard !batch.isEmpty else { return }
        for id in batch { inFlight.insert(scopedKey(id, lang: lang)) }

        let fetched = await fetchPool(ids: batch, lang: lang)
        var updates: [String: LocalizedMeta] = [:]
        var misses: [String] = []
        for id in batch {
            let key = scopedKey(id, lang: lang)
            inFlight.remove(key)
            if let hit = fetched[id], !hit.isEmpty {
                updates[key] = hit
            } else {
                misses.append(id)
                // Record a negative so we do not hammer the pool on every layout; a later user-key backfill
                // can still overwrite it (see backfillFromUserKey).
                updates[key] = LocalizedMeta(title: "", posterPath: "", logoPath: "")
            }
        }
        if !updates.isEmpty {
            for (k, v) in updates { entries[k] = v }
            saveDiskCache()
        }
        // If there is still a backlog, keep draining.
        if !pending.isEmpty && flushTask == nil {
            flushTask = Task { [weak self] in await self?.flush() }
        }
        // For real misses, backfill from the user's own TMDB key (if any) and contribute back to seed the pool.
        if !misses.isEmpty, ApiKeys.tmdbKey() != nil {
            await backfillFromUserKey(ids: misses, lang: lang)
        }
    }

    // MARK: pool read

    /// GET /meta/l10n?ids=<csv>&lang=<code> against the catalogs edge, signed via VortXEdgeAuth. Fail-soft to
    /// an empty map (the caller then records negatives + optionally backfills).
    private func fetchPool(ids: [String], lang: String) async -> [String: LocalizedMeta] {
        guard let base = poolBase() else { return [:] }
        var comps = URLComponents(string: base + "/meta/l10n")
        comps?.queryItems = [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "lang", value: lang),
        ]
        guard let url = comps?.url else { return [:] }
        var req = URLRequest(url: url)
        VortXEdgeAuth.sign(&req)
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = obj["items"] as? [String: Any] else { return [:] }
            var out: [String: LocalizedMeta] = [:]
            for (id, raw) in items {
                guard let row = raw as? [String: Any] else { continue }   // null = miss; skip
                out[id] = LocalizedMeta(
                    title: (row["title"] as? String) ?? "",
                    posterPath: (row["posterPath"] as? String) ?? "",
                    logoPath: (row["logoPath"] as? String) ?? "")
            }
            return out
        } catch { return [:] }
    }

    // MARK: user-key backfill + contribute (self-seed the pool)

    /// For ids the pool missed, when the user has their OWN TMDB key: fetch the localized title + language-
    /// matched poster + logo directly from TMDB, apply it locally, and CONTRIBUTE it back (signed POST) so the
    /// pool self-seeds for every other user. Bounded so one flush never fans out unbounded upstream.
    private func backfillFromUserKey(ids: [String], lang: String) async {
        let capped = Array(ids.prefix(Self.maxBackfillPerFlush))
        var contributions: [[String: String]] = []
        await withTaskGroup(of: (String, LocalizedMeta?).self) { group in
            for id in capped {
                group.addTask { [weak self] in
                    (id, await self?.tmdbLocalized(id: id, lang: lang) ?? nil)
                }
            }
            for await (id, meta) in group {
                guard let meta, !meta.isEmpty else { continue }
                entries[scopedKey(id, lang: lang)] = meta
                contributions.append([
                    "id": id, "title": meta.title,
                    "posterPath": meta.posterPath, "logoPath": meta.logoPath,
                ])
            }
        }
        if !contributions.isEmpty {
            saveDiskCache()
            await contribute(items: contributions, lang: lang)
        }
    }

    /// Fetch the localized title + language-matched poster + logo for one id from TMDB with the user's key.
    /// Mirrors the worker's backfill: `language=` for the title, `/images` `include_image_language=<base>,null`
    /// for art, base-language image match then textless, path-only. nil when TMDB has nothing / no id match.
    private func tmdbLocalized(id: String, lang: String) async -> LocalizedMeta? {
        guard let key = ApiKeys.tmdbKey() else { return nil }
        let base = LocalizedMetadataLanguage.baseCode
        // Resolve the TMDB kind + numeric id (imdb via /find, or a direct tmdb ref).
        let ref = await tmdbRef(for: id, key: key)
        guard let ref else { return nil }
        let tmdbLangParam = Self.tmdbLangForm(lang)
        var comps = URLComponents(string: "https://api.themoviedb.org/3/\(ref.kind)/\(ref.tmdbID)")
        comps?.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "language", value: tmdbLangParam),
            URLQueryItem(name: "append_to_response", value: "images"),
            URLQueryItem(name: "include_image_language", value: "\(base),null,en"),
        ]
        guard let url = comps?.url,
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = (ref.kind == "tv"
            ? (obj["name"] as? String) ?? (obj["original_name"] as? String)
            : (obj["title"] as? String) ?? (obj["original_title"] as? String)) ?? ""
        let images = obj["images"] as? [String: Any]
        let poster = Self.pickImagePath(images?["posters"] as? [[String: Any]], lang: base)
        let logo = Self.pickImagePath(images?["logos"] as? [[String: Any]], lang: base)
        let meta = LocalizedMeta(title: title, posterPath: poster, logoPath: logo)
        return meta.isEmpty ? nil : meta
    }

    /// Resolve an app id (`tt...` or `tmdb:movie:123`) to a TMDB kind + numeric id using the user's key.
    private func tmdbRef(for id: String, key: String) async -> (kind: String, tmdbID: String)? {
        if id.hasPrefix("tmdb:") {
            let parts = id.split(separator: ":")
            if parts.count == 3, let n = Int(parts[2]) { return (String(parts[1]), String(n)) }
            return nil
        }
        guard id.hasPrefix("tt"),
              let url = URL(string: "https://api.themoviedb.org/3/find/\(id)?external_source=imdb_id&api_key=\(key)"),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let m = (obj["movie_results"] as? [[String: Any]])?.first, let n = m["id"] as? Int {
            return ("movie", String(n))
        }
        if let t = (obj["tv_results"] as? [[String: Any]])?.first, let n = t["id"] as? Int {
            return ("tv", String(n))
        }
        return nil
    }

    /// POST /meta/l10n batch contribute (signed). Fail-soft: a failed contribute never surfaces (the local
    /// entry already applied); the pool simply is not seeded from this client this time.
    private func contribute(items: [[String: String]], lang: String) async {
        guard let base = poolBase(), let url = URL(string: base + "/meta/l10n") else { return }
        let body: [String: Any] = ["lang": lang, "items": items]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        VortXEdgeAuth.sign(&req)
        _ = try? await session.data(for: req)
    }

    // MARK: helpers

    /// The pool base URL: the SAME catalogs edge every keyless TMDB call uses (RemoteConfig `endpoints.catalogs`)
    /// but WITHOUT the trailing `/3` TMDB namespace, since the l10n routes live at `/meta/l10n`. Validated
    /// https + *.vortx.tv (RemoteConfig already guarantees that for the catalogs endpoint).
    private func poolBase() -> String? {
        var s = RemoteConfig.snapshot.catalogsEndpoint.absoluteString
        if s.hasSuffix("/3") { s.removeLast(2) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    /// Only imdb (`tt…`) and tmdb refs are resolvable through the pool. A live/channel or synthetic id is not,
    /// so we never enqueue or override it.
    private func isResolvableID(_ id: String) -> Bool {
        id.hasPrefix("tt") || id.hasPrefix("tmdb:movie:") || id.hasPrefix("tmdb:tv:")
    }

    private func scopedKey(_ id: String) -> String { scopedKey(id, lang: LocalizedMetadataLanguage.current) }
    private func scopedKey(_ id: String, lang: String) -> String { "\(lang)|\(id)" }

    private static let maxIDsPerRead = 60          // matches the worker's MAX_IDS_PER_READ
    private static let maxBackfillPerFlush = 8     // cap user-key TMDB fan-out per flush

    /// Map an app language code to TMDB's `language=` form, mirroring the worker's `tmdbLang`: script subtags
    /// map to a region form, region subtags are kept, everything else falls to the base language.
    private static func tmdbLangForm(_ code: String) -> String {
        switch code {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "pt-BR": return "pt-BR"
        case "pt-PT": return "pt-PT"
        case "fil": return "tl"
        case "nb": return "no"
        default:
            guard let dash = code.firstIndex(of: "-") else { return code }
            let sub = code[code.index(after: dash)...]
            let baseStr = String(code[..<dash]).lowercased()
            return sub.count == 2 ? "\(baseStr)-\(sub.uppercased())" : baseStr
        }
    }

    /// Pick a TMDB image PATH from an `/images` array: exact base-language, then textless (iso_639_1 == null),
    /// then any, highest vote first. Returns "" when there is nothing. Mirrors the worker's `pickImage`.
    private static func pickImagePath(_ list: [[String: Any]]?, lang: String) -> String {
        guard let list, !list.isEmpty else { return "" }
        func path(_ x: [String: Any]) -> String? { x["file_path"] as? String }
        let byLang = list.filter { ($0["iso_639_1"] as? String) == lang && path($0) != nil }
        let textless = list.filter { $0["iso_639_1"] == nil || ($0["iso_639_1"] as? NSNull) != nil }
            .filter { path($0) != nil }
        let anyWithPath = list.filter { path($0) != nil }
        let pool = !byLang.isEmpty ? byLang : (!textless.isEmpty ? textless : anyWithPath)
        let best = pool.max { (($0["vote_average"] as? Double) ?? 0) < (($1["vote_average"] as? Double) ?? 0) }
        return best.flatMap(path) ?? ""
    }

    // MARK: disk cache (a tiny, near-immutable title + two paths; safe to persist)

    private var cacheURL: URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return dir?.appendingPathComponent("vortx-l10n-meta.json")
    }

    private func loadDiskCache() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: LocalizedMeta].self, from: data) else { return }
        entries = decoded
    }

    private func saveDiskCache() {
        // Cap the persisted set so the cache never grows without bound across sessions.
        let capped = entries.count > Self.diskCacheCap
            ? Dictionary(uniqueKeysWithValues: entries.prefix(Self.diskCacheCap).map { ($0.key, $0.value) })
            : entries
        guard let url = cacheURL, let data = try? JSONEncoder().encode(capped) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let diskCacheCap = 4000
}
