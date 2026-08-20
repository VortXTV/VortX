import Foundation

/// A per-detail-view `@StateObject` that resolves the current title against the user's connected media servers
/// (Plex / Jellyfin / Emby) and publishes the direct-play hits as extra source GROUPS (one per server) to merge
/// into the source list. The media-server analog of `TorBoxSearchSource` / `SourceIndexServeSource`: an
/// `ObservableObject` with a monotonic epoch, fail-soft, session-cached, and DORMANT without configuration.
///
/// DORMANCY (ledger-18 lesson): `refresh` returns synchronously BEFORE any resolver work when no server is
/// connected, so a fresh install with no server makes zero media-server network calls anywhere. One group per
/// server, id `mediaserver:<uuid>`, labelled with the server's display name; every stream carries the server
/// UUID in `CoreStream.vortxProvider` so the ranker tiers it and the player shows the honest direct-play error.
@MainActor
final class MediaServerSource: ObservableObject {
    /// The per-server direct-play groups, ready to merge. Empty until a resolve completes (and always with no
    /// server connected). Replaced atomically; the epoch bump lets `SourceListModel` fold it into its O(1)
    /// rebuild signature.
    @Published private(set) var groups: [CoreStreamSourceGroup] = [] { didSet { epoch &+= 1 } }
    private(set) var epoch = 0
    /// Sealed page identity for the currently published direct-play groups.
    private(set) var publishedTarget: SourceIndexIdentity.MediaServerTarget?
    @Published private(set) var settlementEpoch = 0
    private var settlementContentID: String?
    private var settlementActive = false
    private var settlementTerminal = false

    /// The title currently shown (its fetch key). Switching titles resets `groups`.
    private var shownKey: String?
    /// The fetch key in flight, so the paired `.onChange` + `.onAppear` for the same title resolve once.
    private var inFlightKey: String?
    /// Session cache keyed by "id|season|episode|title|year"; a hit re-publishes with no network.
    private var cache: [String: [CoreStreamSourceGroup]] = [:]
    private var task: Task<Void, Never>?

    func settlementState(for contentID: String?) -> SourceContributorSettlement {
        guard let contentID, !MediaServerStore.shared.servers.isEmpty else { return .inactive }
        guard settlementContentID == contentID else { return .pending }
        guard settlementActive else { return .inactive }
        return settlementTerminal ? .terminal : .pending
    }

    func settlementState(for target: SourceIndexIdentity.MediaServerTarget?) -> SourceContributorSettlement {
        settlementState(for: target?.token)
    }

    private func publishSettlement(contentID: String?, active: Bool, terminal: Bool) {
        guard settlementContentID != contentID || settlementActive != active
                || settlementTerminal != terminal else { return }
        settlementContentID = contentID
        settlementActive = active
        settlementTerminal = terminal
        settlementEpoch &+= 1
    }

    /// Resolve the current title on the connected servers, if any. Fail-soft and session-cached. Safe on every
    /// meta change / `.onAppear`. `imdb` is the detail id (imdb `tt...` or tmdb `tmdb:...`); `title`/`year` are
    /// the name+year fallback for GUID-less libraries; `season`/`episode` scope a series to one episode.
    func refresh(imdb: String?, season: Int? = nil, episode: Int? = nil, title: String? = nil,
                 year: Int? = nil, publicationTarget: SourceIndexIdentity.MediaServerTarget? = nil) {
        // DORMANCY GATE (synchronous, before any resolver work): no server -> no network, ever.
        guard !MediaServerStore.shared.servers.isEmpty else {
            clearResults(settlementTarget: publicationTarget)
            return
        }
        let idKey = imdb ?? ""
        guard !idKey.isEmpty || !(title ?? "").isEmpty else {
            clearResults(settlementTarget: publicationTarget)
            return
        }

        guard let target = publicationTarget else {
            clearResults(settlementTarget: nil)
            return
        }
        let fetchKey = "\(idKey)|\(season ?? -1)|\(episode ?? -1)|\(title ?? "")|\(year ?? -1)|\(target.token)"
        if fetchKey != shownKey {
            task?.cancel()
            task = nil
            inFlightKey = nil
            shownKey = fetchKey
            publishedTarget = target
            groups = cache[fetchKey] ?? []
            publishSettlement(contentID: target.token, active: true, terminal: cache[fetchKey] != nil)
        }
        if cache[fetchKey] != nil {
            publishSettlement(contentID: target.token, active: true, terminal: true)
            return
        }                                              // cached: already published above
        if inFlightKey == fetchKey { return }         // the paired onChange/onAppear for this id: resolve once
        task?.cancel()
        inFlightKey = fetchKey
        publishSettlement(contentID: target.token, active: true, terminal: false)
        task = Task { [weak self] in
            let hits = await MediaServerCoordinator.shared.find(imdb: imdb, season: season, episode: episode,
                                                                title: title, year: year)
            guard !Task.isCancelled, let self,
                  self.shownKey == fetchKey,
                  self.inFlightKey == fetchKey else { return }
            self.inFlightKey = nil
            self.task = nil
            let built = Self.buildGroups(from: hits)
            self.cache[fetchKey] = built
            self.groups = built
            self.publishSettlement(contentID: target.token, active: true, terminal: true)
        }
    }

    #if SOURCE_INDEX_IDENTITY_TESTING
    var ownerStateForTesting: (shownKey: String?, inFlightKey: String?, hasTask: Bool) {
        (shownKey: shownKey, inFlightKey: inFlightKey, hasTask: task != nil)
    }
    #endif

    /// Empty the published groups without touching the session cache (for an owner that reuses one instance
    /// across titles). A title that cannot resolve (no server / no id) must see it EMPTY.
    func clearResults() {
        clearResults(settlementTarget: nil)
    }

    /// Re-find sources: drop the SESSION cache so the next `refresh` re-resolves the title on the connected
    /// servers instead of re-publishing the cached hits, then blank the published groups via `clearResults`.
    /// The whole store is emptied because this source is a per-detail-view `@StateObject` (its cache only ever
    /// holds this one screen's title/episodes), and the dormancy gate (no server -> no network) and every
    /// other protection are untouched. Only the per-title result cache is invalidated.
    func invalidateCache() {
        cache.removeAll()
        clearResults()
    }

    private func clearResults(settlementTarget: SourceIndexIdentity.MediaServerTarget?) {
        task?.cancel()
        task = nil
        inFlightKey = nil
        shownKey = nil
        publishedTarget = nil
        publishSettlement(contentID: settlementTarget?.token, active: false, terminal: true)
        if !groups.isEmpty { groups = [] }
    }

    // MARK: Mapping (pure, off-main-safe)

    /// One `CoreStreamSourceGroup` per server from the hits. `nonisolated` so it can run off the main actor.
    private nonisolated static func buildGroups(from hits: [MediaServerHit]) -> [CoreStreamSourceGroup] {
        var order: [UUID] = []
        var byServer: [UUID: (name: String, streams: [CoreStream])] = [:]
        for hit in hits {
            guard let stream = synthetic(from: hit) else { continue }
            if byServer[hit.serverId] == nil { byServer[hit.serverId] = (hit.serverName, []); order.append(hit.serverId) }
            byServer[hit.serverId]?.streams.append(stream)
        }
        return order.compactMap { id in
            guard let val = byServer[id], !val.streams.isEmpty else { return nil }
            return CoreStreamSourceGroup(id: "mediaserver:\(id.uuidString)",
                                         addon: val.name.isEmpty ? "My Server" : val.name, streams: val.streams)
        }
    }

    /// Map a hit to a synthetic `CoreStream` via JSON round-trip (mirrors `TorBoxSearch.make`, so it tracks the
    /// struct's optional field set with no manual memberwise init). Sets the `vortxProvider` provenance marker.
    private nonisolated static func synthetic(from hit: MediaServerHit) -> CoreStream? {
        var descParts = ["Direct Play"]
        if let f = hit.fileName, !f.isEmpty { descParts.append(f) }
        if let c = hit.container, !c.isEmpty { descParts.append(c) }
        if let r = hit.resolution { descParts.append("\(r)p") }
        if let s = hit.sizeBytes { descParts.append(byteSize(s)) }
        var behaviorHints: [String: Any] = ["bingeGroup": "vortx-ms-\(hit.serverId.uuidString)"]
        if let f = hit.fileName, !f.isEmpty { behaviorHints["filename"] = f }
        let json: [String: Any] = [
            "url": hit.streamURL.absoluteString,
            "name": hit.serverName.isEmpty ? "My Server" : hit.serverName,
            "description": descParts.joined(separator: " · "),
            "vortxProvider": hit.serverId.uuidString,
            "behaviorHints": behaviorHints,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(CoreStream.self, from: data)
    }

    private nonisolated static func byteSize(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .binary
        return fmt.string(fromByteCount: bytes)
    }

    // MARK: Merge

    /// Merge only with the typed media-server capability proving the published token matches the page token.
    nonisolated static func merge(
        authorizedBy authorization: SourceIndexIdentity.MediaServerMergeAuthorization?,
        _ extra: [CoreStreamSourceGroup],
        into groups: [CoreStreamSourceGroup]
    ) -> [CoreStreamSourceGroup] {
        guard authorization != nil else { return groups }
        guard !extra.isEmpty else { return groups }
        var seenURLs: Set<String> = []
        for g in groups { for s in g.streams { if let u = s.url { seenURLs.insert(u) } } }
        let fresh = extra.compactMap { g -> CoreStreamSourceGroup? in
            let streams = g.streams.filter { s in s.url.map { !seenURLs.contains($0) } ?? true }
            guard !streams.isEmpty else { return nil }
            return CoreStreamSourceGroup(id: g.id, addon: g.addon, streams: streams)
        }
        guard !fresh.isEmpty else { return groups }
        return groups + fresh
    }
}
