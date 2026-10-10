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
        let addons = account.addons, capabilities = EpisodeSourceInventory(legacyAddons: addons)
        self.init(core: core, legacySources: sources, legacyAddons: addons, legacyIsCurrent: {
            account.credentialBoundaryGeneration == epoch && account.streamSources == sources
                && EpisodeSourceInventory(legacyAddons: account.addons) == capabilities
        })
    }

    init(core: CoreBridge = .shared, legacySources: [StreamSource], legacyAddons: [AddonDescriptor] = [],
         legacyIsCurrent: @escaping @MainActor () -> Bool) {
#if VORTX_NATIVE_DATA_ENGINE
        let captured = core.captureNativeEpisodeSourceRegistry()
        inventory = captured.flatMap { try? JSONDecoder().decode(EpisodeSourceInventory.self, from: $0.data) }
        self.legacySources = []
        authority = { captured?.isCurrent() == true }
#else
        inventory = legacyAddons.isEmpty ? nil : EpisodeSourceInventory(legacyAddons: legacyAddons)
        self.legacySources = legacySources
        authority = legacyIsCurrent
#endif
    }

    func providers(seriesID: String?, videoID: String) -> [EpisodeSourceProvider] {
        if let inventory { return inventory.providers(seriesID: seriesID, videoID: videoID) }
#if VORTX_NATIVE_DATA_ENGINE
        return []
#else
        // A source-only legacy snapshot carries no proof of metadata capability.
        return legacySources.map { EpisodeSourceProvider(source: $0, videoID: videoID, streamID: videoID, metadataID: nil) }
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
struct EpisodeSourceInventory: Decodable, Equatable {
    private struct Descriptor: Decodable, Equatable {
        let transportUrl: String
        let manifest: Manifest
    }
    private struct DescriptorRow: Decodable {
        let value: Descriptor?
        init(from decoder: Decoder) throws { value = try? Descriptor(from: decoder) }
    }
    private struct Manifest: Decodable, Equatable {
        let id: String?
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
        let resources: [Resource]?
    }
    private struct Resource: Decodable, Equatable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
        enum CodingKeys: String, CodingKey { case name, types, idPrefixes }
        init(name: String, types: [String]?, idPrefixes: [String]?) {
            self.name = name; self.types = types; self.idPrefixes = idPrefixes
        }
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
    init(legacyAddons: [AddonDescriptor]) {
        descriptors = legacyAddons.map { addon in
            Descriptor(transportUrl: addon.transportUrl, manifest: Manifest(id: addon.manifest.id,
                name: addon.manifest.name, types: addon.manifest.types, idPrefixes: addon.manifest.idPrefixes,
                resources: addon.manifest.resources.map { Resource(name: $0.name, types: $0.types, idPrefixes: $0.idPrefixes) }))
        }
    }
    func sources(for videoID: String) -> [StreamSource] {
        providers(seriesID: nil, videoID: videoID).map(\.source)
    }
    func providers(seriesID: String?, videoID: String) -> [EpisodeSourceProvider] {
        descriptors.compactMap { descriptor in
            let manifest = descriptor.manifest
            func supports(_ name: String, id: String) -> Bool {
                guard !id.isEmpty else { return false }
                return (manifest.resources ?? []).contains(where: { resource in
                    let types = resource.types?.isEmpty == false ? resource.types! : manifest.types ?? []
                    let prefixes = resource.idPrefixes ?? manifest.idPrefixes ?? []
                    return resource.name == name && (types.isEmpty || types.contains("series"))
                        && (prefixes.isEmpty || prefixes.contains(where: id.hasPrefix))
                })
            }
            let streamID = supports("stream", id: videoID) ? videoID : nil
            let metadataID = seriesID.flatMap { supports("meta", id: $0) ? $0 : nil }
            guard streamID != nil || metadataID != nil,
                var url = URLComponents(string: descriptor.transportUrl), url.host != nil,
                ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                url.user == nil, url.password == nil, url.fragment == nil else { return nil }
            if url.percentEncodedPath.hasSuffix("/manifest.json") {
                url.percentEncodedPath = String(url.percentEncodedPath.dropLast("/manifest.json".count))
            }
            guard let base = url.string else { return nil }
            return EpisodeSourceProvider(source: StreamSource(base: base, name: manifest.name),
                                         videoID: videoID, streamID: streamID, metadataID: metadataID)
        }
    }
}

/// Immutable, resource-specific eligibility for one exact title and video. Metadata-only addons never
/// acquire a stream capability, and a legacy source without a manifest remains stream-only.
struct EpisodeSourceProvider: Sendable {
    let source: StreamSource
    let videoID: String
    let streamID: String?
    let metadataID: String?
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
    typealias MetadataFetch = @Sendable (StreamSource, String, String, TimeInterval) async -> CoreStreamSourceGroup?
    @MainActor
    static func collect(seriesID: String, videoID: String, season: Int?, episode: Int?, title: String?,
                        defaultVideoID: String? = nil, sources: [StreamSource], wantedAddon: String?,
                        deadline: TimeInterval, isSignedIn: Bool,
                        fetch: @escaping Fetch = { await fetchStreams($0, episodeID: $1, timeout: $2) },
                        isCurrent: () -> Bool) async -> [CoreStreamSourceGroup]? {
        await collect(seriesID: seriesID, videoID: videoID, season: season, episode: episode, title: title,
            defaultVideoID: defaultVideoID,
            providers: sources.map { EpisodeSourceProvider(source: $0, videoID: videoID, streamID: videoID, metadataID: nil) },
            wantedAddon: wantedAddon, deadline: deadline, isSignedIn: isSignedIn, fetch: fetch, isCurrent: isCurrent)
    }

    @MainActor
    static func collect(seriesID: String, videoID: String, season: Int?, episode: Int?, title: String?,
                        defaultVideoID: String? = nil, providers: [EpisodeSourceProvider], wantedAddon: String?,
                        deadline: TimeInterval, isSignedIn: Bool,
                        fetch: @escaping Fetch = { await fetchStreams($0, episodeID: $1, timeout: $2) },
                        fetchMetadata: @escaping MetadataFetch = { await fetchMetadataStreams($0, titleID: $1, episodeID: $2, timeout: $3) },
                        isCurrent: () -> Bool) async -> [CoreStreamSourceGroup]? {
        guard !Task.isCancelled, isCurrent(), deadline > ProcessInfo.processInfo.systemUptime else { return nil }
        let torbox = TorBoxSearchSource(), sourceIndex = SourceIndexServeSource(), mediaServers = MediaServerSource()
        defer { torbox.clearResults(); sourceIndex.clearResults(); mediaServers.clearResults() }
        let roles = SourceIndexIdentity.Roles(catalogID: seriesID, defaultVideoID: defaultVideoID,
                                               currentVideoID: videoID, kind: .series)
        let titleID = SourceIndexIdentity.resolve(roles).titleID
        let target = SourceIndexIdentity.publicationTarget(roles, season: season, episode: episode)
        let mediaTarget = SourceIndexIdentity.mediaServerTarget(preferring: target, metaID: seriesID, videoID: videoID)
        // A snapshot is usable only for the title whose owner admitted this request.
        let exactProviders = providers.map {
            EpisodeSourceProvider(source: $0.source, videoID: $0.videoID, streamID: $0.streamID,
                                  metadataID: $0.metadataID == seriesID ? $0.metadataID : nil)
        }
        async let raw = rawGroups(providers: exactProviders, episodeID: videoID, wantedAddon: wantedAddon,
                                 deadline: deadline, fetchBudget: SourceSettlementPolicy.maximumWait,
                                 fetch: fetch, fetchMetadata: fetchMetadata)
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
        await rawGroups(providers: sources.map { EpisodeSourceProvider(source: $0, videoID: episodeID, streamID: episodeID, metadataID: nil) },
                        episodeID: episodeID, wantedAddon: wantedAddon, deadline: deadline,
                        attemptSequence: attemptSequence, fetchBudget: fetchBudget, fetch: fetch)
    }

    private struct ResourceWork: Sendable {
        let providerIndex: Int
        let source: StreamSource
        let metadataID: String?
    }

    static func rawGroups(providers: [EpisodeSourceProvider], episodeID: String, wantedAddon: String?, deadline: TimeInterval,
                          attemptSequence: Int = 1,
                          fetchBudget: TimeInterval = NextEpisodePreparationBudget.addonFetchBudget,
                          fetch: @escaping Fetch = { await fetchStreams($0, episodeID: $1, timeout: $2) },
                          fetchMetadata: @escaping MetadataFetch = { await fetchMetadataStreams($0, titleID: $1, episodeID: $2, timeout: $3) }) async -> [CoreStreamSourceGroup] {
        let remaining = max(0, min(fetchBudget, deadline - ProcessInfo.processInfo.systemUptime))
        guard remaining > 0, !Task.isCancelled, !episodeID.isEmpty else { return [] }
        let order = PreloadProviderRotation.order(count: providers.count, attemptSequence: attemptSequence,
            stride: NextEpisodePreparationBudget.providerRotationStride,
            prioritizedIndex: wantedAddon.flatMap { wanted in providers.firstIndex { $0.source.name.caseInsensitiveCompare(wanted) == .orderedSame } })
        // Pool resource requests, rather than doubling network concurrency for mixed-capability providers.
        // Metadata precedes stream within each provider, matching the existing detail projection contract.
        let work = order.flatMap { index -> [ResourceWork] in
            let provider = providers[index]
            guard provider.videoID == episodeID else { return [] }
            var requests: [ResourceWork] = []
            if let metadataID = provider.metadataID, !metadataID.isEmpty {
                requests.append(ResourceWork(providerIndex: index, source: provider.source, metadataID: metadataID))
            }
            if provider.streamID == episodeID {
                requests.append(ResourceWork(providerIndex: index, source: provider.source, metadataID: nil))
            }
            return requests
        }
        let fetched: [CoreStreamSourceGroup?] = await BoundedPreloadWorkPool.map(work,
            limit: NextEpisodePreparationBudget.addonConcurrencyLimit,
            timeoutNanoseconds: UInt64(remaining * 1_000_000_000),
            operationTimeoutFor: { UInt64(NextEpisodePreparationBudget.requestTimeout(addon: $0.source.name, wantedAddon: wantedAddon) * 1_000_000_000) }
        ) { request in
            let timeout = NextEpisodePreparationBudget.requestTimeout(addon: request.source.name, wantedAddon: wantedAddon)
            if let titleID = request.metadataID { return await fetchMetadata(request.source, titleID, episodeID, timeout) }
            return await fetch(request.source, episodeID, timeout)
        }
        var groups = Array<CoreStreamSourceGroup?>(repeating: nil, count: providers.count)
        for (request, result) in zip(work, fetched) {
            guard let result, !result.streams.isEmpty else { continue }
            let index = request.providerIndex, source = request.source
            var streams = groups[index]?.streams ?? []
            for stream in result.streams where !streams.contains(stream) { streams.append(stream) }
            groups[index] = CoreStreamSourceGroup(id: source.base, addon: source.name, streams: streams)
        }
        return groups.compactMap { $0 }
    }

    static func resourceURL(base: String, episodeID: String) -> URL? {
        resourceURL(base: base, resource: "stream", id: episodeID)
    }

    static func resourceURL(base: String, resource: String, id: String) -> URL? {
        guard var url = URLComponents(string: base), url.host != nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.fragment == nil,
              ["stream", "meta"].contains(resource), !id.isEmpty,
              let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) else { return nil }
        url.percentEncodedPath = url.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty ? "/\(resource)/series/\(escaped).json"
            : url.percentEncodedPath + (url.percentEncodedPath.hasSuffix("/") ? "" : "/") + "\(resource)/series/\(escaped).json"
        return url.url
    }

    private static func fetchStreams(_ source: StreamSource, episodeID: String, timeout: TimeInterval) async -> CoreStreamSourceGroup? {
        struct Response: Decodable { let streams: [CoreStream]? }
        guard let data = await fetchResource(source, resource: "stream", id: episodeID, timeout: timeout),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let streams = decoded.streams, !streams.isEmpty else { return nil }
        return CoreStreamSourceGroup(id: source.base, addon: source.name, streams: streams)
    }

    private static func fetchMetadataStreams(_ source: StreamSource, titleID: String, episodeID: String,
                                            timeout: TimeInterval) async -> CoreStreamSourceGroup? {
        struct Response: Decodable {
            struct Meta: Decodable {
                struct Video: Decodable { let id: String; let streams: [CoreStream]? }
                struct VideoRow: Decodable {
                    let value: Video?
                    init(from decoder: Decoder) throws { value = try? Video(from: decoder) }
                }
                let id: String
                let type: String?
                let videos: [VideoRow]?
            }
            let meta: Meta?
        }
        guard let data = await fetchResource(source, resource: "meta", id: titleID, timeout: timeout),
              let meta = (try? JSONDecoder().decode(Response.self, from: data))?.meta,
              meta.id == titleID, meta.type == nil || meta.type == "series",
              let streams = meta.videos?.compactMap(\.value).first(where: { $0.id == episodeID })?.streams,
              !streams.isEmpty else { return nil }
        return CoreStreamSourceGroup(id: source.base, addon: source.name, streams: streams)
    }

    private static func fetchResource(_ source: StreamSource, resource: String, id: String, timeout: TimeInterval) async -> Data? {
        guard let url = resourceURL(base: source.base, resource: resource, id: id) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // Match AddonClient's CDN-compatible request identity; configured credentials remain in the
        // captured source base, and playback-specific headers remain on the decoded CoreStream.
        request.setValue("Mozilla/5.0 (Apple TV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), !Task.isCancelled,
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
}
