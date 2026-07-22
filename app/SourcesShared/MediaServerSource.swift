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
    /// The SEALED identity for the currently published direct-play groups: the exact `MediaServerTarget` the
    /// resolve was issued for, with no ordinary construction route outside SourceIndexIdentity.swift (the
    /// seal and its memory-safety exclusions are documented on the type). `SourceListModel`
    /// authorizes its merge against this typed value (via `SourceIndexIdentity.mediaServerMergeAuthorization`),
    /// so an instance reused across episodes can never lend one episode's direct-play rows to another, and no
    /// raw page token can stand in for the published identity. This replaced `publishedContentID: String?`,
    /// the merge path's last raw-string identity.
    private(set) var publishedTarget: SourceIndexIdentity.MediaServerTarget?

    /// The title currently shown (its fetch key). Switching titles resets `groups`.
    private var shownKey: String?
    /// The fetch key in flight, so the paired `.onChange` + `.onAppear` for the same title resolve once.
    private var inFlightKey: String?
    /// Session cache keyed by "id|season|episode|title|year"; a hit re-publishes with no network.
    private var cache: [String: [CoreStreamSourceGroup]] = [:]
    private var task: Task<Void, Never>?

    /// Resolve the current title on the connected servers, if any. Fail-soft and session-cached. Safe on every
    /// meta change / `.onAppear`. `imdb` is the detail id (imdb `tt...` or tmdb `tmdb:...`); `title`/`year` are
    /// the name+year fallback for GUID-less libraries; `season`/`episode` scope a series to one episode.
    /// `publicationTarget` is the SEALED page identity the published groups will be merge-gated against,
    /// buildable through no ordinary route but the `SourceIndexIdentity.mediaServerTarget` factories; a nil
    /// target publishes nothing. That includes an IMDb-less page whose meta id is the empty string (the
    /// factories reject empty parts), so such a page darkens this lane entirely, title/year fallback
    /// included -- fail-closed, effectively unreachable; see the SCOPE EDGE note on the fallback factory.
    func refresh(imdb: String?, season: Int? = nil, episode: Int? = nil, title: String? = nil,
                 year: Int? = nil, publicationTarget: SourceIndexIdentity.MediaServerTarget?) {
        // DORMANCY GATE (synchronous, before any resolver work): no server -> no network, ever.
        guard !MediaServerStore.shared.servers.isEmpty else { clearResults(); return }
        // No sealed page identity -> nothing may publish or merge, so nothing may fetch either. The old
        // internal `idKey:season:episode` token composition is gone: the caller always states the typed
        // target, so this owner never derives a page identity of its own.
        guard let target = publicationTarget else { clearResults(); return }
        let idKey = imdb ?? ""
        guard !idKey.isEmpty || !(title ?? "").isEmpty else { clearResults(); return }
        let fetchKey = "\(idKey)|\(season ?? -1)|\(episode ?? -1)|\(title ?? "")|\(year ?? -1)|\(target.token)"
        if fetchKey != shownKey {
            shownKey = fetchKey
            publishedTarget = target
            groups = cache[fetchKey] ?? []
        }
        if cache[fetchKey] != nil { return }          // cached: already published above
        if inFlightKey == fetchKey { return }         // the paired onChange/onAppear for this id: resolve once
        task?.cancel()
        inFlightKey = fetchKey
        task = Task { [weak self] in
            let hits = await MediaServerCoordinator.shared.find(imdb: imdb, season: season, episode: episode,
                                                                title: title, year: year)
            guard !Task.isCancelled, let self else { return }
            self.inFlightKey = nil
            let built = Self.buildGroups(from: hits)
            self.cache[fetchKey] = built
            if self.shownKey == fetchKey { self.groups = built }
        }
    }

    /// Empty the published groups without touching the session cache (for an owner that reuses one instance
    /// across titles). A title that cannot resolve (no server / no id) must see it EMPTY.
    func clearResults() {
        shownKey = nil
        publishedTarget = nil
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

    /// Merge the per-server groups into `groups`, deduped by url against streams already present. `nonisolated
    /// static` so `SourceListModel`'s off-main assembly can run it over a snapshot. Pass-through when empty.
    ///
    /// AUTHORIZATION-REQUIRED, mirroring `TorBoxSearchSource.merge` / `SourceIndexServeSource.merge`: the
    /// identity-free signature left `SourceListModel` gating this merge on a hand-rolled comparison of two raw
    /// page tokens, the last raw-identifier route on the main merge path. The required
    /// `MediaServerMergeAuthorization` has no ordinary construction route outside the identity file, which
    /// builds it only from the sealed target this source published, so a caller that has not proven "these
    /// rows belong to this page" cannot merge: a nil authorization is a pure pass-through.
    nonisolated static func merge(
        authorizedBy authorization: SourceIndexIdentity.MediaServerMergeAuthorization?,
        _ extra: [CoreStreamSourceGroup],
        into groups: [CoreStreamSourceGroup]
    ) -> [CoreStreamSourceGroup] {
        guard authorization != nil, !extra.isEmpty else { return groups }
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
