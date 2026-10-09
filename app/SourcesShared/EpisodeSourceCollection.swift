import Foundation

/// Read-only authority captured before episode work. The profile-selection epoch rejects A -> B -> A;
/// credential and source snapshots reject a same-profile account/provider replacement without depending
/// on the playback mutation queue being idle.
@MainActor
struct EpisodeSourceOwner {
    private let profileID = ProfileStore.shared.activeID
    private let profileEpoch = ContinueWatchingPreferences.selectionEpoch
    private let credential = CredentialScopeRegistry.shared.capture()
    private let account: StremioAccount
    private let accountEpoch: UInt64
    let sources: [StreamSource]

    init(account: StremioAccount) {
        self.account = account
        accountEpoch = account.credentialBoundaryGeneration
        sources = account.streamSources
    }

    var isCurrent: Bool {
        !Task.isCancelled && ProfileStore.shared.activeID == profileID
            && ContinueWatchingPreferences.selectionEpoch == profileEpoch
            && CredentialScopeRegistry.shared.isCurrent(credential)
            && account.credentialBoundaryGeneration == accountEpoch
            && account.streamSources == sources
    }
}

/// No CoreBridge input: resolving E+1 must never replace the mounted episode's shared detail slot.
/// Each call owns its auxiliary publishers, so cancellation/ABA cleanup cannot clear another request.
enum EpisodeSourceCollection {
    typealias Fetch = @Sendable (StreamSource, String, TimeInterval) async -> CoreStreamSourceGroup?
    @MainActor
    static func collect(seriesID: String, videoID: String, season: Int?, episode: Int?, title: String?,
                        defaultVideoID: String? = nil, sources: [StreamSource], wantedAddon: String?,
                        deadline: TimeInterval, isSignedIn: Bool,
                        fetch: @escaping Fetch = { await fetchStreams($0, episodeID: $1, timeout: $2) },
                        isCurrent: () -> Bool) async -> [CoreStreamSourceGroup]? {
        guard !Task.isCancelled, isCurrent(), deadline > ProcessInfo.processInfo.systemUptime else { return nil }
        let torbox = TorBoxSearchSource(), sourceIndex = SourceIndexServeSource(), mediaServers = MediaServerSource()
        defer { torbox.clearResults(); sourceIndex.clearResults(); mediaServers.clearResults() }
        let roles = SourceIndexIdentity.Roles(catalogID: seriesID, defaultVideoID: defaultVideoID,
                                               currentVideoID: videoID, kind: .series)
        let titleID = SourceIndexIdentity.resolve(roles).titleID
        let target = SourceIndexIdentity.publicationTarget(roles, season: season, episode: episode)
        let mediaTarget = SourceIndexIdentity.mediaServerTarget(preferring: target, metaID: seriesID, videoID: videoID)
        async let raw = rawGroups(sources: sources, episodeID: videoID, wantedAddon: wantedAddon,
                                 deadline: deadline, fetchBudget: SourceSettlementPolicy.maximumWait, fetch: fetch)
        AuxiliarySourcePipeline.refresh(target: target, torBox: torbox, sourceIndex: sourceIndex, isSignedIn: isSignedIn)
        mediaServers.refresh(imdb: titleID, season: season, episode: episode, title: title, publicationTarget: mediaTarget)
        while !Task.isCancelled && isCurrent() {
            let decision = SourceSettlementPolicy.decide(raw: .terminal, auxiliary: [
                torbox.settlementState(for: target), sourceIndex.settlementState(for: target),
                mediaServers.settlementState(for: mediaTarget)
            ], deadlineExpired: ProcessInfo.processInfo.systemUptime >= deadline)
            if decision.isSettled { break }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        guard !Task.isCancelled, isCurrent() else { return nil }
        var groups = await raw
        guard !Task.isCancelled, isCurrent() else { return nil }
        groups = TorBoxSearchSource.merge(authorizedBy: SourceIndexIdentity.mergeAuthorization(published: torbox.publishedTarget, page: target), torbox.streams, into: groups)
        groups = SourceIndexServeSource.merge(authorizedBy: SourceIndexIdentity.mergeAuthorization(published: sourceIndex.publishedTarget, page: target), sourceIndex.streams, into: groups)
        groups = MediaServerSource.merge(authorizedBy: SourceIndexIdentity.mediaServerMergeAuthorization(published: mediaServers.publishedTarget, page: mediaTarget), mediaServers.groups, into: groups)
        return displayGroups(groups)
    }

    static func displayGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard PlaybackSettings.directLinksOnly else { return groups }
        return groups.compactMap { group in
            let streams = group.streams.filter { !$0.isTorrent }
            return streams.isEmpty ? nil : CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
        }
    }

    /// The same rotated, bounded pool serves preload and fallback. Completion order never becomes rank order.
    static func rawGroups(sources: [StreamSource], episodeID: String, wantedAddon: String?, deadline: TimeInterval,
                          attemptSequence: Int = 1,
                          fetchBudget: TimeInterval = NextEpisodePreparationBudget.addonFetchBudget,
                          fetch: @escaping Fetch = { await fetchStreams($0, episodeID: $1, timeout: $2) }) async -> [CoreStreamSourceGroup] {
        let remaining = max(0, min(fetchBudget, deadline - ProcessInfo.processInfo.systemUptime))
        guard remaining > 0, !Task.isCancelled else { return [] }
        let order = PreloadProviderRotation.order(count: sources.count, attemptSequence: attemptSequence,
            stride: NextEpisodePreparationBudget.providerRotationStride,
            prioritizedIndex: wantedAddon.flatMap { wanted in sources.firstIndex { $0.name.caseInsensitiveCompare(wanted) == .orderedSame } })
        let fetched: [CoreStreamSourceGroup?] = await BoundedPreloadWorkPool.map(order.map { sources[$0] },
            limit: NextEpisodePreparationBudget.addonConcurrencyLimit,
            timeoutNanoseconds: UInt64(remaining * 1_000_000_000),
            operationTimeoutFor: { UInt64(NextEpisodePreparationBudget.requestTimeout(addon: $0.name, wantedAddon: wantedAddon) * 1_000_000_000) }
        ) { source in
            await fetch(source, episodeID, NextEpisodePreparationBudget.requestTimeout(addon: source.name, wantedAddon: wantedAddon))
        }
        return PreloadProviderRotation.restoreOriginalOrder(fetched, order: order, count: sources.count).compactMap { $0 }
    }

    private static func fetchStreams(_ source: StreamSource, episodeID: String, timeout: TimeInterval) async -> CoreStreamSourceGroup? {
        let escaped = episodeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? episodeID
        guard let url = URL(string: "\(source.base)/stream/series/\(escaped).json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // Match AddonClient's CDN-compatible request identity; configured credentials remain in the
        // captured source base, and playback-specific headers remain on the decoded CoreStream.
        request.setValue("Mozilla/5.0 (Apple TV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/604.1", forHTTPHeaderField: "User-Agent")
        struct Response: Decodable { let streams: [CoreStream]? }
        guard let (data, response) = try? await URLSession.shared.data(for: request), !Task.isCancelled,
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let streams = decoded.streams, !streams.isEmpty else { return nil }
        return CoreStreamSourceGroup(id: source.base, addon: source.name, streams: streams)
    }
}
