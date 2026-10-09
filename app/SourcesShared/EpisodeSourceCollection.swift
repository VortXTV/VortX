import Foundation

/// Read-only authority captured before episode work. The profile-selection epoch rejects A -> B -> A;
/// credential and source snapshots reject a same-profile account/provider replacement without depending
/// on the playback mutation queue being idle.
@MainActor
struct EpisodeSourceOwner {
    private let profileID = ProfileStore.shared.activeID
    private let profileEpoch = ContinueWatchingPreferences.selectionEpoch
    private let credential = CredentialScopeRegistry.shared.capture()
    private let inventory: EpisodeSourceInventory?
    private let legacySources: [StreamSource]
    private let authority: @MainActor () -> Bool

    init(core: CoreBridge = .shared, account: StremioAccount) {
        let sources = account.streamSources, epoch = account.credentialBoundaryGeneration
        self.init(core: core, legacySources: sources, legacyIsCurrent: {
            account.credentialBoundaryGeneration == epoch && account.streamSources == sources
        })
    }

    init(core: CoreBridge = .shared, legacySources: [StreamSource], legacyIsCurrent: @escaping @MainActor () -> Bool) {
#if VORTX_NATIVE_DATA_ENGINE
        let captured = core.captureNativeEpisodeSourceRegistry()
        inventory = captured.flatMap { try? JSONDecoder().decode(EpisodeSourceInventory.self, from: $0.data) }
        self.legacySources = []
        authority = { captured?.isCurrent() == true }
#else
        inventory = nil
        self.legacySources = legacySources
        authority = legacyIsCurrent
#endif
    }

    func sources(for videoID: String) -> [StreamSource] {
#if VORTX_NATIVE_DATA_ENGINE
        inventory?.sources(for: videoID) ?? []
#else
        legacySources
#endif
    }

    var isCurrent: Bool {
        guard !Task.isCancelled && profileID != nil && ProfileStore.shared.activeID == profileID
            && ContinueWatchingPreferences.selectionEpoch == profileEpoch
            && CredentialScopeRegistry.shared.isCurrent(credential)
            && authority() else { return false }
#if VORTX_NATIVE_DATA_ENGINE
        return inventory != nil
#else
        return true
#endif
    }
}

/// Decode complete native manifests rather than CoreManifest's display-only subset. Matching mirrors
/// the native manifest contract: nonempty resource types override manifest types; absent prefixes inherit.
struct EpisodeSourceInventory: Decodable {
    private struct Descriptor: Decodable {
        let transportUrl: String
        let manifest: Manifest
    }
    private struct DescriptorRow: Decodable {
        let value: Descriptor?
        init(from decoder: Decoder) throws { value = try? Descriptor(from: decoder) }
    }
    private struct Manifest: Decodable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
        let resources: [Resource]?
    }
    private struct Resource: Decodable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
        enum CodingKeys: String, CodingKey { case name, types, idPrefixes }
        init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.name = name; types = nil; idPrefixes = nil
            } else {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                types = try c.decodeIfPresent([String].self, forKey: .types)
                idPrefixes = try c.decodeIfPresent([String].self, forKey: .idPrefixes)
            }
        }
    }
    private let descriptors: [Descriptor]
    init(from decoder: Decoder) throws { descriptors = try decoder.singleValueContainer().decode([DescriptorRow].self).compactMap(\.value) }
    func sources(for videoID: String) -> [StreamSource] {
        descriptors.compactMap { descriptor in
            let manifest = descriptor.manifest
            guard (manifest.resources ?? []).contains(where: { resource in
                let types = resource.types?.isEmpty == false ? resource.types! : manifest.types ?? []
                let prefixes = resource.idPrefixes ?? manifest.idPrefixes ?? []
                return resource.name == "stream" && (types.isEmpty || types.contains("series"))
                    && (prefixes.isEmpty || prefixes.contains(where: videoID.hasPrefix))
            }), var url = URLComponents(string: descriptor.transportUrl), url.host != nil,
                ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                url.user == nil, url.password == nil, url.fragment == nil else { return nil }
            if url.percentEncodedPath.hasSuffix("/manifest.json") {
                url.percentEncodedPath = String(url.percentEncodedPath.dropLast("/manifest.json".count))
            }
            guard let base = url.string else { return nil }
            return StreamSource(base: base, name: manifest.name)
        }
    }
}

/// An in-memory, task-scoped handoff, never a global cache or a PlayerEpisodeStream schema change.
@MainActor final class EpisodeSourceReceipt {
    let videoID: String
    let owner: EpisodeSourceOwner
    private(set) var groups: [CoreStreamSourceGroup]?
    init(videoID: String, owner: EpisodeSourceOwner) { self.videoID = videoID; self.owner = owner }
    func accept(_ groups: [CoreStreamSourceGroup], videoID: String) {
        guard self.videoID == videoID, owner.isCurrent else { return }
        self.groups = groups
    }
}

enum EpisodeRefindCompletionPolicy {
    enum Action { case ignore, clear, restoreFailure }
    static func action(attempt: UUID, active: UUID?, sameMediaGeneration: Bool,
                       sameTarget: Bool, exited: Bool, cancelled: Bool) -> Action {
        guard active == attempt else { return .ignore }
        return sameMediaGeneration && sameTarget && !exited && !cancelled ? .restoreFailure : .clear
    }
}

/// No CoreBridge input: resolving E+1 must never replace the mounted episode's shared detail slot.
/// Each call owns its auxiliary publishers, so cancellation/ABA cleanup cannot clear another request.
enum EpisodeSourceCollection {
    @TaskLocal static var receipt: EpisodeSourceReceipt?
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
        let result = displayGroups(groups)
        receipt?.accept(result, videoID: videoID)
        return result
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

    static func resourceURL(base: String, episodeID: String) -> URL? {
        guard var url = URLComponents(string: base), url.host != nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.fragment == nil,
              let escaped = episodeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) else { return nil }
        url.percentEncodedPath = url.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty ? "/stream/series/\(escaped).json"
            : url.percentEncodedPath + (url.percentEncodedPath.hasSuffix("/") ? "" : "/") + "stream/series/\(escaped).json"
        return url.url
    }

    private static func fetchStreams(_ source: StreamSource, episodeID: String, timeout: TimeInterval) async -> CoreStreamSourceGroup? {
        guard let url = resourceURL(base: source.base, episodeID: episodeID) else { return nil }
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
