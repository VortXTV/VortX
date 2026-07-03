import Foundation

/// TorBox SEARCH-as-a-source: a lightweight client for `search-api.torbox.app` (a PUBLIC, IP-rate-limited
/// search index, SEPARATE from the account API `api.torbox.app`). For the current title's imdb id it pulls
/// both usenet and torrent results and turns them into extra `CoreStream`s that MERGE into the source list
/// the user sees — so a user with a TorBox key gets usenet AND torrent sources with NO usenet/torrent
/// add-on installed.
///
/// GATED on a TorBox key (`DebridKeys.isConfigured(.torBox)`): with no key the whole feature no-ops (no
/// fetch, no extra sources). The key is passed to lift the rate limits where the API accepts it. FAIL-SOFT:
/// any error/timeout yields no extra sources and no user-visible failure. It never blocks the normal add-on
/// stream load — a detail view fetches it in parallel and appends the result when it arrives (the same
/// async-contribution shape as `DebridCacheAwareness`).
///
/// NO referral / partnership code: these are the user's own search results against the public index, not a
/// VortX-curated list.

// MARK: - Client

enum TorBoxSearch {
    private static let base = "https://search-api.torbox.app"

    /// One usenet result parsed from the search index into a playable `CoreStream` (nzb link + optional
    /// pick regex), plus torrent results (infoHash / magnet). Tolerant decoding: the index wraps items
    /// under `data.nzbs` / `data.torrents` (with fallbacks), and field names vary, so every field is
    /// optional and read defensively.
    struct Response: Decodable {
        let data: Payload?
        struct Payload: Decodable {
            let nzbs: [Item]?
            let torrents: [Item]?
        }
        struct Item: Decodable {
            let hash: String?
            let rawTitle: String?
            let title: String?
            let magnet: String?
            let nzb: String?
            let link: String?
            let size: Int64?
            let seeders: Int?
            let age: String?
            let type: String?
            /// The index's own account cache-check result (`check_cache=true`), when it ran.
            let cached: Bool?

            enum CodingKeys: String, CodingKey {
                case hash, magnet, nzb, link, size, age, type, title, cached
                case rawTitle = "raw_title"
                case lastKnownSeeders = "last_known_seeders"
            }

            /// Field-tolerant decode: one bad field must not sink the whole response. `size` rides as a
            /// number OR a numeric string (the index coerces), and seeders is `last_known_seeders` with
            /// `-1` meaning unknown, so both are normalized here.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                hash = (try? c.decodeIfPresent(String.self, forKey: .hash)) ?? nil
                rawTitle = (try? c.decodeIfPresent(String.self, forKey: .rawTitle)) ?? nil
                title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
                magnet = (try? c.decodeIfPresent(String.self, forKey: .magnet)) ?? nil
                nzb = (try? c.decodeIfPresent(String.self, forKey: .nzb)) ?? nil
                link = (try? c.decodeIfPresent(String.self, forKey: .link)) ?? nil
                if let n = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? nil {
                    size = n
                } else if let d = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? nil {
                    size = Int64(d)
                } else if let s = (try? c.decodeIfPresent(String.self, forKey: .size)) ?? nil {
                    size = Int64(s)
                } else {
                    size = nil
                }
                let known = (try? c.decodeIfPresent(Int.self, forKey: .lastKnownSeeders)) ?? nil
                seeders = (known ?? -1) >= 0 ? known : nil
                age = (try? c.decodeIfPresent(String.self, forKey: .age)) ?? nil
                type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
                cached = (try? c.decodeIfPresent(Bool.self, forKey: .cached)) ?? nil
            }
        }
    }

    /// Fetch usenet + torrent search results for an imdb id and flatten to extra streams. Returns `[]` on
    /// any failure (no key handled by the caller's gate; a network error / decode failure / timeout all
    /// collapse to empty). `apiKey` lifts the anonymous rate limit (0/min: keyless requests always 429).
    /// `season`/`episode` scope a series fetch to one episode; nil for movies.
    /// Combined usenet + torrent results plus a `rateLimited` flag: `true` when the index answered 429 (the
    /// account is over its TorBox scraper allowance / in the daily search cooldown). The caller uses the flag
    /// to back off instead of re-firing on the next title and burning more of the quota.
    static func streams(imdbId: String, season: Int? = nil, episode: Int? = nil, apiKey: String) async -> (streams: [CoreStream], rateLimited: Bool) {
        guard imdbId.hasPrefix("tt") else { return ([], false) }
        async let usenet = fetch(kind: "usenet", imdbId: imdbId, season: season, episode: episode, apiKey: apiKey)
        async let torrents = fetch(kind: "torrents", imdbId: imdbId, season: season, episode: episode, apiKey: apiKey)
        let (u, t) = await (usenet, torrents)
        return (u.streams + t.streams, u.rateLimited || t.rateLimited)
    }

    /// One `GET /{kind}/imdb_id:{id}` call, bounded and fail-soft. The id-type prefix must be `imdb_id:`
    /// (the index's IdType name); `imdb:` is unknown to it and returns nothing, which made every search
    /// come back empty. Auth is the Bearer header ONLY (the JSON endpoints take no `apikey` query param,
    /// and the key must not ride in URLs anyway); anonymous requests are hard-429'd by the index.
    /// `check_cache=true` asks the index to flag which results the user's own account already has cached.
    private static func fetch(kind: String, imdbId: String, season: Int?, episode: Int?, apiKey: String) async -> (streams: [CoreStream], rateLimited: Bool) {
        var comps = URLComponents(string: "\(base)/\(kind)/imdb_id:\(imdbId)")
        var query = [
            URLQueryItem(name: "metadata", value: "false"),
            URLQueryItem(name: "check_cache", value: "true"),
        ]
        if let season { query.append(URLQueryItem(name: "season", value: String(season))) }
        if let episode { query.append(URLQueryItem(name: "episode", value: String(episode))) }
        comps?.queryItems = query
        guard let url = comps?.url else { return ([], false) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: cfg)
        guard let (data, response) = try? await session.data(for: req),
              let code = (response as? HTTPURLResponse)?.statusCode else { return ([], false) }
        // 429 = over the TorBox scraper allowance (the account's daily search cooldown). The index returns
        // "Rate limit exceeded: 0 per 1 minute" for EVERY search until the cooldown resets (~24h), so surface
        // it as a distinct signal instead of an empty "no results" the caller can't tell apart.
        if code == 429 { return ([], true) }
        guard (200...299).contains(code),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return ([], false) }
        let items = (decoded.data?.nzbs ?? []) + (decoded.data?.torrents ?? [])
        return (items.compactMap { stream(from: $0, imdbId: imdbId) }, false)
    }

    /// Build a `CoreStream` from one search item. Usenet vs torrent is discriminated by the index's own
    /// `type` field / the presence of an nzb link, NEVER by hash-emptiness: EVERY item carries a non-empty
    /// `hash` (for usenet it is the NZB md5, TorBox's usenet cache key), so keying usenet on an empty hash
    /// mis-mapped every usenet result into a bogus torrent with an md5 "infohash". A usenet item maps to a
    /// usenet stream (`nzbUrl`); a torrent item maps to a raw torrent (`infoHash` + `sources` trackers from
    /// the magnet). Items with neither identity are dropped.
    private static func stream(from item: Response.Item, imdbId: String) -> CoreStream? {
        let displayName = item.rawTitle ?? item.title ?? "TorBox Search"
        let sizeSuffix = item.size.map { " · \(byteSize($0))" } ?? ""
        // The index's own cache-check (`check_cache=true`): a text marker so `StreamRanking.isCached`
        // lights the ⚡ badge + within-tier cache bonus with no extra provider round trip.
        let cachedSuffix = item.cached == true ? " · ⚡ Cached" : ""

        // USENET: typed usenet by the index, or carrying an nzb link.
        if (item.type ?? "").lowercased() == "usenet" || (item.nzb ?? "").isEmpty == false {
            guard let nzb = (item.nzb ?? item.link), !nzb.isEmpty, nzb.lowercased().hasPrefix("http") else { return nil }
            let desc = "TorBox Usenet\(sizeSuffix)\(cachedSuffix)"
            // Carry the index's authoritative NZB md5 so the usenet cache-check / resolve poll can key on
            // it (md5-of-the-link-string is only a fallback guess that misses for index-served nzbs).
            let marker = item.hash.flatMap { $0.isEmpty ? nil : ["usenethash:" + $0.lowercased()] }
            return make(name: "📰 " + displayName, description: desc, nzbUrl: nzb, sources: marker)
        }

        // TORRENT: an infohash (or a magnet we can pull one from).
        if let hash = torrentHash(item), !hash.isEmpty {
            let seeders = item.seeders.map { " · 👤 \($0)" } ?? ""
            let desc = "TorBox Search\(sizeSuffix)\(seeders)\(cachedSuffix)"
            let magnet = item.magnet
            let trackers = magnet.map { magnetTrackers($0) } ?? []
            return make(name: displayName, description: desc, infoHash: hash.lowercased(), sources: trackers.isEmpty ? nil : trackers)
        }
        return nil
    }

    /// A torrent item's infohash: the explicit `hash`, else parsed from the magnet `xt=urn:btih:`.
    private static func torrentHash(_ item: Response.Item) -> String? {
        if let h = item.hash, !h.isEmpty { return h }
        guard let magnet = item.magnet,
              let range = magnet.range(of: "btih:", options: .caseInsensitive) else { return nil }
        let after = magnet[range.upperBound...]
        let hex = after.prefix { $0.isHexDigit }
        return hex.isEmpty ? nil : String(hex)
    }

    /// `tracker:`-prefixed trackers from a magnet's `tr=` params, in the shape `DebridResolve.magnet`
    /// expects on `CoreStream.sources` (the same convention the resolve path reads).
    private static func magnetTrackers(_ magnet: String) -> [String] {
        guard let comps = URLComponents(string: magnet) else { return [] }
        return (comps.queryItems ?? []).filter { $0.name == "tr" }.compactMap {
            $0.value.flatMap { "tracker:" + $0 }
        }
    }

    private static func byteSize(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .binary
        return fmt.string(fromByteCount: bytes)
    }

    /// Build a `CoreStream` via JSON decode so it tracks the struct's own (all-optional) field set with no
    /// manual memberwise init — the same technique `CoreMetaItem.placeholder` uses.
    private static func make(name: String, description: String, nzbUrl: String? = nil,
                             infoHash: String? = nil, sources: [String]? = nil) -> CoreStream? {
        var json: [String: Any] = ["name": name, "description": description]
        if let nzbUrl { json["nzbUrl"] = nzbUrl }
        if let infoHash { json["infoHash"] = infoHash }
        if let sources { json["sources"] = sources }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(CoreStream.self, from: data)
    }
}

// MARK: - Per-view contributor

/// A per-detail-view `@StateObject` that fetches TorBox search results for the current title and publishes
/// them as an extra source group to MERGE into the list (mirrors `DebridCacheAwareness`'s shape). Gated on
/// a TorBox key; no key = no fetch = empty group = the list is unchanged. De-dups by imdb id so a re-render
/// of the same title does not re-hit the index.
@MainActor
final class TorBoxSearchSource: ObservableObject {
    /// The extra streams from the search index, ready to merge. Empty until a fetch completes (and always
    /// with no TorBox key). One group so the source list shows a single "TorBox Search" section.
    @Published private(set) var streams: [CoreStream] = []

    /// The title currently shown (its fetch key). Switching titles resets `streams` so a previous title's
    /// results can never leak onto one we don't (or can't) fetch.
    private var shownKey: String?
    /// The fetch key currently in flight, so the paired `.onChange` + `.onAppear` for the same title issue
    /// exactly one network round trip instead of two.
    private var inFlightKey: String?
    /// Session cache of completed results, keyed by "imdb|season|episode". A hit re-publishes with no network,
    /// so browsing back and forth never re-hits the TorBox scraper. Re-hitting on every open is exactly what
    /// exhausts the account's small daily search allowance and trips its ~24h `cooldown_until`.
    private var cache: [String: [CoreStream]] = [:]
    /// Set when the index last answered 429 (over the scraper allowance). While in the future, `refresh`
    /// short-circuits so the app stops firing requests against a `0 per 1 minute` wall. We can't read the
    /// exact reset from the 429, so we back off a short window and re-probe: the feature self-heals the
    /// moment the allowance frees, without hammering in between.
    private var cooldownUntil: Date?
    private var task: Task<Void, Never>?

    /// Fetch search results for `imdbId` if the user has a TorBox key. Fail-soft, session-cached, and backed
    /// off during a scraper cooldown. Safe to call on every meta change / `.onAppear`. Pass `season`/`episode`
    /// from an episode context so the index scopes usenet/torrent results to that episode (nil = movie level).
    func refresh(imdbId: String?, season: Int? = nil, episode: Int? = nil) {
        guard let imdbId, imdbId.hasPrefix("tt") else { return }
        guard DebridKeys.shared.isConfigured(.torBox) else { return }   // gate: no TorBox key -> no-op
        let fetchKey = "\(imdbId)|\(season ?? -1)|\(episode ?? -1)"
        // New title: publish its cached results (or clear), so the prior title's streams never linger.
        if fetchKey != shownKey {
            shownKey = fetchKey
            streams = cache[fetchKey] ?? []
        }
        if cache[fetchKey] != nil { return }              // cached: already published above, no round trip
        if inFlightKey == fetchKey { return }             // the paired onChange/onAppear for this id: fetch once
        if let until = cooldownUntil, until > Date() { return }   // in scraper cooldown: don't burn requests
        task?.cancel()
        inFlightKey = fetchKey
        let key = DebridKeys.shared.key(for: .torBox)
        // H9 diagnostic (terminal-run repro): confirm refresh actually fires with a key. Logs the id + whether
        // a non-empty TorBox key is present (never the key itself). If this line never appears, the gate above
        // no-op'd; if it appears but the count line below is 0, the index returned nothing for the id.
        NSLog("[torbox-search] refresh id=%@ s=%d e=%d hasKey=%@", imdbId, season ?? -1, episode ?? -1,
              key.isEmpty ? "no" : "yes")
        task = Task { [weak self] in
            let result = await TorBoxSearch.streams(imdbId: imdbId, season: season, episode: episode, apiKey: key)
            guard !Task.isCancelled, let self else { return }
            self.inFlightKey = nil
            if result.rateLimited {
                // Over the TorBox scraper allowance. Back off ~15 min before re-probing; do NOT cache the
                // empty result, so it re-fetches for real once the cooldown lifts.
                self.cooldownUntil = Date().addingTimeInterval(15 * 60)
                NSLog("[torbox-search] rate-limited (scraper cooldown) for id=%@ - backing off ~15m", imdbId)
                return
            }
            NSLog("[torbox-search] fetched %d stream(s) for id=%@", result.streams.count, imdbId)
            self.cache[fetchKey] = result.streams
            if self.shownKey == fetchKey { self.streams = result.streams }
        }
    }

    /// Merge the fetched search streams into `groups` as one extra group, deduped against the streams
    /// already present (by infoHash for torrents, nzbUrl for usenet, url otherwise). Returns `groups`
    /// unchanged when there is nothing to add — so a no-key / empty-result path is a pure pass-through.
    func merged(into groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard !streams.isEmpty else { return groups }
        var seenHashes: Set<String> = []
        var seenNZB: Set<String> = []
        var seenURLs: Set<String> = []
        for group in groups {
            for s in group.streams {
                if let h = s.infoHash?.lowercased() { seenHashes.insert(h) }
                if let n = s.nzbUrl { seenNZB.insert(n) }
                if let u = s.url { seenURLs.insert(u) }
            }
        }
        let fresh = streams.filter { s in
            if let h = s.infoHash?.lowercased() { return !seenHashes.contains(h) }
            if let n = s.nzbUrl { return !seenNZB.contains(n) }
            if let u = s.url { return !seenURLs.contains(u) }
            return true
        }
        guard !fresh.isEmpty else { return groups }
        // H9 diagnostic: how many of the fetched search streams survived the dedup into the visible list. A
        // fetched>0 but merged=0 here means every result collided with an add-on stream (dedup dropped them);
        // a healthy line means the rows are in `streamGroups` and any invisibility is a downstream render/rank
        // problem, not a fetch/merge one.
        NSLog("[torbox-search] merged %d new row(s) into %d group(s)", fresh.count, groups.count)
        return groups + [CoreStreamSourceGroup(id: "vortx.torbox.search", addon: "TorBox Search", streams: fresh)]
    }
}
