import Foundation

/// TorBox SEARCH-as-a-source: a lightweight client for `search-api.torbox.app` (a PUBLIC, IP-rate-limited
/// search index, SEPARATE from the account API `api.torbox.app`). For the current title's imdb id it pulls
/// both usenet and torrent results and turns them into extra `CoreStream`s that MERGE into the source list
/// the user sees, so a user with a TorBox key gets usenet AND torrent sources with NO usenet/torrent
/// add-on installed.
///
/// GATED on a TorBox key (`DebridKeys.isConfigured(.torBox)`): with no key the whole feature no-ops (no
/// fetch, no extra sources). The key is passed to lift the rate limits where the API accepts it. FAIL-SOFT:
/// any error/timeout yields no extra sources and no user-visible failure. It never blocks the normal add-on
/// stream load; a detail view fetches it in parallel and appends the result when it arrives (the same
/// async-contribution shape as `DebridCacheAwareness`).
///
/// NO referral / partnership code: these are the user's own search results against the public index, not a
/// VortX-curated list.

// MARK: - Client

enum TorBoxSearch {
    private static let base = "https://search-api.torbox.app"
    /// The HEALTHY account host, used ONLY as the A1 resilience fallback when `base` never answers (its DNS
    /// went dead). Its torrent search is live and used by other clients; it returns torrent rows only (no
    /// usenet). Never the primary path: the public index at `base` is what this source is built around.
    private static let fallbackBase = "https://api.torbox.app"

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
    /// Combined usenet + torrent results plus two signal flags. `rateLimited` is `true` when the index
    /// answered 429 (the account is over its TorBox scraper allowance / in the daily search cooldown), so the
    /// caller backs off instead of re-firing on the next title and burning more of the quota. `transportError`
    /// is `true` when a leg's request never completed (offline, DNS/TLS failure, timeout), so the caller keeps
    /// the empty result OUT of the session cache and re-fetches for real once the network is back.
    static func streams(imdbId: String, season: Int? = nil, episode: Int? = nil, apiKey: String) async -> (streams: [CoreStream], rateLimited: Bool, transportError: Bool) {
        guard imdbId.hasPrefix("tt") else { return ([], false, false) }
        async let usenet = fetch(kind: "usenet", imdbId: imdbId, season: season, episode: episode, apiKey: apiKey)
        async let torrents = fetch(kind: "torrents", imdbId: imdbId, season: season, episode: episode, apiKey: apiKey)
        let (u, t) = await (usenet, torrents)
        let combined = u.streams + t.streams
        let rateLimited = u.rateLimited || t.rateLimited
        let transportError = u.transportError || t.transportError
        // A1 resilience: `base` (search-api.torbox.app) is the DNS-dead host. When neither leg completed and
        // we have nothing to show, fall back ONCE to the HEALTHY host's torrent search so a TorBox user still
        // gets torrent sources instead of a silent nothing. A completed fallback (even an empty 200) clears the
        // transportError signal, so the caller caches it and resets its consecutive-transport-error streak; a
        // fallback that also fails to complete returns nil and we fall through to the existing transportError
        // path (offline blip self-heals on the next open).
        if transportError, combined.isEmpty, let fallback = await fallbackTorrentSearch(imdbId: imdbId, apiKey: apiKey) {
            return (fallback, rateLimited, false)
        }
        return (combined, rateLimited, transportError)
    }

    /// One `GET /{kind}/imdb_id:{id}` call, bounded and fail-soft. The id-type prefix must be `imdb_id:`
    /// (the index's IdType name); `imdb:` is unknown to it and returns nothing, which made every search
    /// come back empty. Auth is the Bearer header ONLY (the JSON endpoints take no `apikey` query param,
    /// and the key must not ride in URLs anyway); anonymous requests are hard-429'd by the index.
    /// `check_cache=true` asks the index to flag which results the user's own account already has cached.
    private static func fetch(kind: String, imdbId: String, season: Int?, episode: Int?, apiKey: String) async -> (streams: [CoreStream], rateLimited: Bool, transportError: Bool) {
        var comps = URLComponents(string: "\(base)/\(kind)/imdb_id:\(imdbId)")
        var query = [
            URLQueryItem(name: "metadata", value: "false"),
            URLQueryItem(name: "check_cache", value: "true"),
        ]
        if let season { query.append(URLQueryItem(name: "season", value: String(season))) }
        if let episode { query.append(URLQueryItem(name: "episode", value: String(episode))) }
        comps?.queryItems = query
        guard let url = comps?.url else { return ([], false, false) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: cfg)
        // A request that never completed (offline, DNS/TLS failure, timeout) yields no HTTP response. Report it
        // as a distinct transportError so the caller does not cache the empty result as "no results" for the
        // session; that is what made an offline first open stick until the app was relaunched.
        guard let (data, response) = try? await session.data(for: req),
              let code = (response as? HTTPURLResponse)?.statusCode else { return ([], false, true) }
        // 429 = over the TorBox scraper allowance (the account's daily search cooldown). The index returns
        // "Rate limit exceeded: 0 per 1 minute" for EVERY search until the cooldown resets (~24h), so surface
        // it as a distinct signal instead of an empty "no results" the caller can't tell apart.
        if code == 429 { return ([], true, false) }
        guard (200...299).contains(code),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return ([], false, false) }
        let items = (decoded.data?.nzbs ?? []) + (decoded.data?.torrents ?? [])
        return (items.compactMap { stream(from: $0, imdbId: imdbId) }, false, false)
    }

    /// A1 resilience fallback. `search-api.torbox.app` (the public index this source normally uses) is the
    /// dead host; the ACCOUNT host `api.torbox.app` is healthy and exposes a torrent search other clients use.
    /// When the index never answers, hit the healthy host ONCE for TORRENT rows (no usenet) so a TorBox user
    /// still gets sources. Bearer-auth, bounded, fail-soft. Returns `nil` ONLY when the fallback itself never
    /// completes / answers non-2xx (so `streams` falls through to the existing transportError path); a 200 with
    /// no torrents returns `[]` (a completed empty response), which the caller treats as a real "no results".
    private static func fallbackTorrentSearch(imdbId: String, apiKey: String) async -> [CoreStream]? {
        guard imdbId.hasPrefix("tt"), !apiKey.isEmpty else { return nil }
        var comps = URLComponents(string: "\(fallbackBase)/v1/api/torrents/search")
        comps?.queryItems = [URLQueryItem(name: "query", value: imdbId)]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: cfg)
        guard let (data, response) = try? await session.data(for: req),
              let code = (response as? HTTPURLResponse)?.statusCode,
              (200...299).contains(code),
              let decoded = try? JSONDecoder().decode(FallbackResponse.self, from: data) else { return nil }
        let mapped = decoded.torrentItems.compactMap { stream(from: $0, imdbId: imdbId) }
        NSLog("[torbox-search] search-api unreachable; healthy-host fallback returned %d torrent row(s)", mapped.count)
        return mapped
    }

    /// Tolerant decode of the healthy host's torrent search. TorBox wraps payloads under `data`, which is
    /// either a torrents array directly or an object carrying a `torrents` array. Every shape falls back to []
    /// rather than throwing, so a shape drift degrades to "no fallback results", never a decode crash.
    private struct FallbackResponse: Decodable {
        let torrentItems: [Response.Item]
        enum CodingKeys: String, CodingKey { case data }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let arr = (try? c.decodeIfPresent([Response.Item].self, forKey: .data)) ?? nil {
                torrentItems = arr
            } else if let obj = (try? c.decodeIfPresent(Response.Payload.self, forKey: .data)) ?? nil {
                torrentItems = obj.torrents ?? []
            } else {
                torrentItems = []
            }
        }
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
    /// manual memberwise init, the same technique `CoreMetaItem.placeholder` uses.
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
    typealias SearchResult = (streams: [CoreStream], rateLimited: Bool, transportError: Bool)
    typealias FetchStreams = (SourceIndexIdentity.PublicationTarget, String) async -> SearchResult
    typealias KeyGate = @MainActor () -> Bool
    typealias KeyProvider = @MainActor () -> String

    /// The extra streams from the search index, ready to merge. Empty until a fetch completes (and always
    /// with no TorBox key). One group so the source list shows a single "TorBox Search" section.
    @Published private(set) var streams: [CoreStream] = [] { didSet { epoch &+= 1 } }
    /// Monotonic epoch bumped whenever `streams` is REPLACED. `SourceListModel` folds this into its
    /// O(1) rebuild signature (a single Int compare instead of hashing the array).
    private(set) var epoch = 0
    /// The sealed target for the currently published rows. Merge authorization revalidates this target against
    /// the page resolution before any row can enter the visible list.
    private(set) var publishedTarget: SourceIndexIdentity.PublicationTarget?
    /// Separate from the rows epoch: a legitimate empty response or terminal transport failure changes
    /// settlement without changing `streams`, and SourceListModel must rebuild for that transition too.
    @Published private(set) var settlementEpoch = 0
    private var settlementContentID: String?
    private var settlementTerminal = false

    /// The title currently shown (its fetch key). Switching titles resets `streams` so a previous title's
    /// results can never leak onto one we don't (or can't) fetch.
    private var shownKey: String?
    /// The fetch key currently in flight, so the paired `.onChange` + `.onAppear` for the same title issue
    /// exactly one network round trip instead of two.
    private var inFlightKey: String?
    /// Until when repeated refresh ticks are suppressed from logging the open-circuit skip (F13). The
    /// breaker already refuses each attempt; without this, one detail visit while a cooldown runs logs
    /// the same "circuit open" line once per tick (26 in diag 6). One line per episode, with the
    /// seconds remaining, then silence until the cooldown lapses.
    private var circuitLogSuppressedUntil: Date?
    /// Session cache of completed results, keyed by "imdb|season|episode". A hit re-publishes with no network,
    /// so browsing back and forth never re-hits the TorBox scraper. Re-hitting on every open is exactly what
    /// exhausts the account's small daily search allowance and trips its ~24h `cooldown_until`.
    private var cache: [String: [CoreStream]] = [:]
    /// The 429/transport-error backoff itself is NOT instance state anymore: it lives in the shared
    /// `ProviderCircuitBreaker`, keyed by (provider, contentID). This type is a per-detail-view
    /// `@StateObject`, so a `cooldownUntil` kept HERE was forgotten every time a view was torn down and
    /// rebuilt (every navigation away and back), letting the next view re-fire the request that just got
    /// rate-limited. The diag-21 log shows the same content id tripping TorBox's scraper cooldown six
    /// separate times because of exactly that. `shouldAttempt`/`recordFailure`/`recordSuccess` below are
    /// the replacement; every instance shares the same breaker state.
    ///
    /// A literal, not `Self.breakerProvider`: this file also compiles standalone under
    /// `SOURCE_INDEX_IDENTITY_TESTING` (see `TorBoxIdentityBoundaryTests.swift`'s header), whose minimal
    /// `DebridService` stub carries no raw value. `DebridService` never overrides its raw values (they
    /// default to the case name), so this matches `Self.breakerProvider` in the real app exactly.
    private static let breakerProvider = "torBox"
    private var task: Task<Void, Never>?
    private let fetchStreams: FetchStreams
    private let hasKey: KeyGate
    private let keyProvider: KeyProvider

    init(
        fetchStreams: @escaping FetchStreams = { target, apiKey in
            await TorBoxSearch.streams(
                imdbId: target.titleID,
                season: target.season,
                episode: target.episode,
                apiKey: apiKey
            )
        },
        hasKey: @escaping KeyGate = {
            DebridKeys.shared.isConfigured(.torBox)
        },
        keyProvider: @escaping KeyProvider = {
            DebridKeys.shared.key(for: .torBox)
        }
    ) {
        self.fetchStreams = fetchStreams
        self.hasKey = hasKey
        self.keyProvider = keyProvider
    }

    func settlementState(for contentID: String?) -> SourceContributorSettlement {
        guard let contentID,
              SourceIndexIdentity.imdbTitleID(contentID) != nil,
              DebridKeys.shared.isConfigured(.torBox),
              RemoteConfig.snapshot.isFeatureOn(
                "torBoxSearch", default: RemoteConfigDefaults.featureTorBoxSearch
              ) else { return .inactive }
        guard settlementContentID == contentID else { return .pending }
        return settlementTerminal ? .terminal : .pending
    }

    func settlementState(for resolution: SourceIndexIdentity.TargetResolution) -> SourceContributorSettlement {
        guard let target = SourceIndexIdentity.validatedTarget(resolution) else { return .inactive }
        return settlementState(for: target.contentID)
    }

    private func publishSettlement(contentID: String?, terminal: Bool) {
        guard settlementContentID != contentID || settlementTerminal != terminal else { return }
        settlementContentID = contentID
        settlementTerminal = terminal
        settlementEpoch &+= 1
    }

    /// Fetch search results for one resolver-built target. A mismatch, absent target, malformed relationship,
    /// missing key, or fleet-off state clears publication synchronously and launches no transport.
    func refresh(call: AuxiliarySourcePipeline.Call) {
        guard let target = SourceIndexIdentity.validatedTarget(call.resolution) else {
            clearResults(); return
        }
        guard hasKey() else { clearResults(); return }
        guard RemoteConfig.snapshot.isFeatureOn(
            "torBoxSearch", default: RemoteConfigDefaults.featureTorBoxSearch
        ) else {
            clearResults(); return
        }
        let fetchKey = target.contentID
        // New title: publish its cached results (or clear), so the prior title's streams never linger.
        if fetchKey != shownKey {
            task?.cancel()
            task = nil
            inFlightKey = nil
            shownKey = fetchKey
            publishedTarget = target
            streams = cache[fetchKey] ?? []
            publishSettlement(contentID: fetchKey, terminal: cache[fetchKey] != nil)
        }
        if cache[fetchKey] != nil {
            publishSettlement(contentID: fetchKey, terminal: true)
            return
        }                                                  // cached: already published above, no round trip
        if inFlightKey == fetchKey { return }             // the paired onChange/onAppear for this id: fetch once
        task?.cancel()
        inFlightKey = fetchKey
        publishSettlement(contentID: fetchKey, terminal: false)
        let key = keyProvider()
        // H9 diagnostic (terminal-run repro): confirm refresh actually fires with a key. Logs the id + whether
        // a non-empty TorBox key is present (never the key itself). If this line never appears, the gate above
        // no-op'd; if it appears but the count line below is 0, the index returned nothing for the id.
        //
        // SCOPE, not sentinels. This used to render `s=\(season ?? -1) e=\(episode ?? -1)`, so the MOVIE case
        // (nil/nil, which is the correct movie-level query and the only thing a movie screen ever passes)
        // printed as `s=-1 e=-1`. In the diag-21 export that read as a malformed series search fired during a
        // movie teardown; it is neither. `scope=movie` says what the request is, and the episode form still
        // prints its real coordinates, so a genuinely wrong coordinate pair is now distinguishable from the
        // movie case instead of hiding behind the same two numbers.
        let scope = target.season == nil && target.episode == nil
            ? "scope=movie"
            : "scope=episode s=\(target.season.map(String.init) ?? "-") e=\(target.episode.map(String.init) ?? "-")"
        VXProbe.log("torbox-search", "refresh id=\(VXProbeRedaction.identityToken(target.titleID)) \(scope) hasKey=\(key.isEmpty ? "no" : "yes")")
        task = Task { [weak self] in
            guard let self else { return }
            // F13: consult the cooldown READ-ONLY first. Repeated refresh ticks during an open circuit
            // would each run shouldAttempt (harmless) but each log a "circuit open" line; one line per
            // episode with the seconds remaining is the honest summary. This path never consumes the
            // half-open probe: once the cooldown lapses, the ordinary shouldAttempt flow below grants it.
            if let remaining = await ProviderCircuitBreaker.shared.cooldownRemaining(
                provider: Self.breakerProvider, sourceID: fetchKey
            ) {
                guard SourceContributorCompletionOwnership.accepts(
                    completedKey: fetchKey, shownKey: self.shownKey, inFlightKey: self.inFlightKey,
                    canceled: Task.isCancelled
                ) else { return }
                self.inFlightKey = nil
                self.task = nil
                if self.circuitLogSuppressedUntil == nil || Date() >= self.circuitLogSuppressedUntil! {
                    VXProbe.log("torbox-search", "circuit open for id=\(VXProbeRedaction.identityToken(target.titleID)), skipping fetch for \(Int(remaining))s")
                    self.circuitLogSuppressedUntil = Date().addingTimeInterval(max(1, remaining - 1))
                }
                self.publishSettlement(contentID: fetchKey, terminal: true)
                return
            }
            // Ask the SHARED breaker, not instance state: an open circuit here means some earlier caller
            // (possibly a now-dead view) already saw TorBox back off for this exact content id, and that
            // memory must survive this view's own lifetime. `shouldAttempt` also grants at most one
            // half-open probe once the cooldown elapses, so this refresh may be the probe owner even while
            // the circuit was open a moment ago.
            guard await ProviderCircuitBreaker.shared.shouldAttempt(
                provider: Self.breakerProvider, sourceID: fetchKey
            ) else {
                guard SourceContributorCompletionOwnership.accepts(
                    completedKey: fetchKey, shownKey: self.shownKey, inFlightKey: self.inFlightKey,
                    canceled: Task.isCancelled
                ) else { return }
                self.inFlightKey = nil
                self.task = nil
                VXProbe.log("torbox-search", "circuit open for id=\(VXProbeRedaction.identityToken(target.titleID)), skipping fetch")
                self.publishSettlement(contentID: fetchKey, terminal: true)
                return
            }
            let result = await self.fetchStreams(target, key)
            guard SourceContributorCompletionOwnership.accepts(
                completedKey: fetchKey,
                shownKey: self.shownKey,
                inFlightKey: self.inFlightKey,
                canceled: Task.isCancelled
            ) else { return }
            self.inFlightKey = nil
            self.task = nil
            if result.rateLimited {
                // Over the TorBox scraper allowance. A 429 IS a completed HTTP response (the host is
                // reachable), so this trips the breaker on the FIRST occurrence rather than accumulating a
                // streak; do NOT cache the empty result, so it re-fetches for real once the cooldown lifts.
                await ProviderCircuitBreaker.shared.recordFailure(
                    provider: Self.breakerProvider, sourceID: fetchKey,
                    phase: .discover, reason: .httpStatus(429)
                )
                VXProbe.log("torbox-search", "rate-limited (scraper cooldown) for id=\(VXProbeRedaction.identityToken(target.titleID)), backing off")
                self.publishSettlement(contentID: fetchKey, terminal: true)
                return
            }
            if result.transportError {
                // The request never completed (offline / network failure / a DNS-dead host). Do NOT cache
                // the empty result. A single blip must self-heal immediately on the next attempt (the
                // breaker only trips after a PERSISTENT streak for a plain transport failure), so a dead
                // host is probed occasionally instead of firing failing lookups on every open.
                await ProviderCircuitBreaker.shared.recordFailure(
                    provider: Self.breakerProvider, sourceID: fetchKey,
                    phase: .discover, reason: .other("transport")
                )
                VXProbe.log("torbox-search", "transport error for id=\(VXProbeRedaction.identityToken(target.titleID)), not caching")
                self.publishSettlement(contentID: fetchKey, terminal: true)
                return
            }
            // A completed HTTP response with results (or a legit empty 200): the host is reachable, so
            // reset the breaker before caching.
            await ProviderCircuitBreaker.shared.recordSuccess(provider: Self.breakerProvider, sourceID: fetchKey)
            VXProbe.log("torbox-search", "fetched \(result.streams.count) stream(s) for id=\(VXProbeRedaction.identityToken(target.titleID))")
            self.cache[fetchKey] = result.streams
            self.streams = result.streams
            self.publishSettlement(contentID: fetchKey, terminal: true)
        }
    }

    #if SOURCE_INDEX_IDENTITY_TESTING
    func refresh(target resolution: SourceIndexIdentity.TargetResolution) {
        refresh(call: AuxiliarySourcePipeline.callForTesting(resolution))
    }

    var ownerStateForTesting: (shownKey: String?, inFlightKey: String?, hasTask: Bool) {
        (shownKey: shownKey, inFlightKey: inFlightKey, hasTask: task != nil)
    }
    #endif

    /// Empty the PUBLISHED results (and the shown-key, so a later refresh for the same title
    /// re-publishes from cache instead of being deduped into staying empty) without touching the
    /// session cache or scraper-cooldown state. Cancel and release the current request so a preload owner
    /// cannot keep a stale network operation alive after retaining its winner. For an owner that reuses ONE
    /// instance across titles (the batch-download coordinator #119, unlike the per-view @StateObjects
    /// that die with their screen): the result pool is PER-TITLE, and a title that cannot query the
    /// index (no imdb id / no key) must see it EMPTY, never a predecessor title's results - `refresh`
    /// early-returns on those gates without clearing, so the owner clears explicitly.
    func clearResults() {
        task?.cancel()
        task = nil
        inFlightKey = nil
        shownKey = nil
        publishedTarget = nil
        publishSettlement(contentID: nil, terminal: true)
        if !streams.isEmpty { streams = [] }
    }

    /// Re-find sources: drop this title's SESSION-CACHED search result so the next `refresh` re-queries the
    /// scraper instead of re-serving the stale cached rows, then blank the published streams via
    /// `clearResults`. The 429/transport cooldown lives in the shared `ProviderCircuitBreaker` (keyed by
    /// provider + contentID) and the key gate lives in `hasKey`; BOTH are left untouched, so a re-find still
    /// honors an active rate-limit cooldown and never re-fires without a configured key. Only the per-title
    /// result cache is invalidated.
    func invalidateCachedResult(for resolution: SourceIndexIdentity.TargetResolution) {
        if let target = SourceIndexIdentity.validatedTarget(resolution) {
            cache.removeValue(forKey: target.contentID)
        }
        clearResults()
    }

    /// Merge only with a capability proving that these rows and this page share one validated target.
    func merged(
        into groups: [CoreStreamSourceGroup],
        call: AuxiliarySourcePipeline.Call
    ) -> [CoreStreamSourceGroup] {
        let authorization = SourceIndexIdentity.mergeAuthorization(
            published: publishedTarget,
            page: call.resolution
        )
        return Self.merge(authorizedBy: authorization, streams, into: groups)
    }

    #if SOURCE_INDEX_IDENTITY_TESTING
    func merged(
        into groups: [CoreStreamSourceGroup],
        for resolution: SourceIndexIdentity.TargetResolution
    ) -> [CoreStreamSourceGroup] {
        merged(into: groups, call: AuxiliarySourcePipeline.callForTesting(resolution))
    }
    #endif

    /// The pure merge. `nonisolated static` so `SourceListModel`'s off-main assembly can run it over a
    /// snapshotted `streams` array without hopping to the main actor. A nil capability is a pure pass-through.
    nonisolated static func merge(
        authorizedBy authorization: SourceIndexIdentity.MergeAuthorization?,
        _ extra: [CoreStream],
        into groups: [CoreStreamSourceGroup]
    ) -> [CoreStreamSourceGroup] {
        guard authorization != nil else { return groups }
        guard !extra.isEmpty else { return groups }
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
        let fresh = extra.filter { s in
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
