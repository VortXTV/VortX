import Foundation
import Combine

/// A per-detail-view `@StateObject` that runs the user's installed community JS providers for the current title
/// and publishes their streams as extra source GROUPS (one per provider) to MERGE into the source list. The
/// JS-provider analog of `TorBoxSearchSource` / `MediaServerSource`: an `ObservableObject` with a monotonic
/// epoch, fail-soft, session-cached, and DORMANT unless the feature gate is on.
///
/// GATE (ledger discipline, and this feature ships dark): `refresh` returns synchronously BEFORE any work when
/// the master gate is off (`JSProviderStore.isFeatureEnabled`, which is the RemoteConfig fleet flag AND the
/// per-device toggle, both default OFF) or nothing is installed, so a default install runs zero provider code
/// anywhere.
///
/// IDENTITY: VortX keys auxiliary sources on the IMDb `tt...` title id, but community providers require a TMDB
/// numeric id, so this source resolves imdb -> tmdb (via `TMDBClient`) before invoking any provider. It carries
/// the same sealed `PublicationTarget` and `mergeAuthorization` as `TorBoxSearchSource`, so a detached E2
/// snapshot can never be reused for E3.
@MainActor
final class JSProviderSource: ObservableObject {

    /// The per-provider groups, ready to merge. Empty until a run completes (and always with the gate off).
    /// Replaced atomically; the epoch bump lets `SourceListModel` fold it into its O(1) rebuild signature.
    @Published private(set) var groups: [CoreStreamSourceGroup] = [] { didSet { epoch &+= 1 } }
    private(set) var epoch = 0
    /// Sealed page identity for the currently published groups.
    private(set) var publishedTarget: SourceIndexIdentity.PublicationTarget?
    /// A legitimate empty/terminal result changes settlement without changing `groups`, so settlement has its
    /// own observable generation, exactly like the other auxiliary sources.
    @Published private(set) var settlementEpoch = 0
    private var settlementContentID: String?
    private var settlementTerminal = false

    private var shownKey: String?
    private var inFlightKey: String?
    /// Session cache keyed by contentID; a hit re-publishes with no work, so browsing back and forth never
    /// re-runs the providers.
    private var cache: [String: [CoreStreamSourceGroup]] = [:]
    private var task: Task<Void, Never>?
    private var gateSubscription: AnyCancellable?

    // Injection seams (defaults read the real store / runtime / TMDB path; tests can substitute).
    typealias Gate = @MainActor () -> Bool
    typealias ProvidersFor = @MainActor (_ mediaType: String) -> [JSInstalledProvider]
    typealias SettingsFor = @MainActor (_ providerID: String) -> String
    typealias ResolveTMDB = (_ imdbID: String, _ mediaType: String) async -> String?
    typealias RunProvider = (_ provider: JSInstalledProvider, _ tmdbId: String, _ mediaType: String,
                             _ season: Int?, _ episode: Int?, _ settingsJSON: String) async -> [[String: Any]]

    private let gate: Gate
    private let providersFor: ProvidersFor
    private let settingsFor: SettingsFor
    private let resolveTMDB: ResolveTMDB
    private let runProvider: RunProvider

    init(
        gate: @escaping Gate = { JSProviderStore.shared.isFeatureEnabled },
        providersFor: @escaping ProvidersFor = { JSProviderStore.shared.providers(forMediaType: $0) },
        settingsFor: @escaping SettingsFor = { JSProviderStore.shared.settingsJSON(for: $0) },
        resolveTMDB: @escaping ResolveTMDB = { imdb, media in
            await TMDBClient.tmdbNumericID(imdbID: imdb, type: media == "tv" ? "series" : "movie").map(String.init)
        },
        runProvider: @escaping RunProvider = { provider, tmdbId, mediaType, season, episode, settingsJSON in
            let invocation = JSProviderRuntime.Invocation(
                providerID: provider.id, code: provider.code, tmdbId: tmdbId, mediaType: mediaType,
                season: season, episode: episode, settingsJSON: settingsJSON
            )
            let result = await JSProviderRuntime.shared.getStreams(invocation)
            if case let .success(streams) = result { return streams }
            return []
        }
    ) {
        self.gate = gate
        self.providersFor = providersFor
        self.settingsFor = settingsFor
        self.resolveTMDB = resolveTMDB
        self.runProvider = runProvider
        // A local OFF is an immediate revocation, not merely a condition checked on the next detail refresh.
        // Cancel the native interpreter, discard its identity cache, and publish an empty contribution at once.
        gateSubscription = JSProviderStore.shared.$userEnabled.dropFirst().sink { [weak self] enabled in
            guard !enabled else { return }
            self?.cache.removeAll()
            self?.clearResults()
        }
    }

    // MARK: Settlement (mirrors TorBoxSearchSource)

    func settlementState(for resolution: SourceIndexIdentity.TargetResolution) -> SourceContributorSettlement {
        guard let target = SourceIndexIdentity.validatedTarget(resolution), gate() else { return .inactive }
        let mediaType = Self.mediaType(for: target)
        guard !providersFor(mediaType).isEmpty else { return .inactive }
        guard settlementContentID == target.contentID else { return .pending }
        return settlementTerminal ? .terminal : .pending
    }

    private func publishSettlement(contentID: String?, terminal: Bool) {
        guard settlementContentID != contentID || settlementTerminal != terminal else { return }
        settlementContentID = contentID
        settlementTerminal = terminal
        settlementEpoch &+= 1
    }

    // MARK: Refresh

    /// The community contract's media type: a movie has null season/episode; a series episode carries them.
    private static func mediaType(for target: SourceIndexIdentity.PublicationTarget) -> String {
        target.season != nil ? "tv" : "movie"
    }

    /// Run the installed providers for one resolver-built target. A mismatch/absent target, gate off, or no
    /// applicable providers clears publication synchronously and launches no work.
    func refresh(call: AuxiliarySourcePipeline.Call) {
        guard let target = SourceIndexIdentity.validatedTarget(call.resolution), gate() else {
            clearResults(); return
        }
        let mediaType = Self.mediaType(for: target)
        let providers = providersFor(mediaType)
        guard !providers.isEmpty else { clearResults(); return }

        let fetchKey = target.contentID
        if fetchKey != shownKey {
            task?.cancel()
            task = nil
            inFlightKey = nil
            shownKey = fetchKey
            publishedTarget = target
            groups = cache[fetchKey] ?? []
            publishSettlement(contentID: fetchKey, terminal: cache[fetchKey] != nil)
        }
        if cache[fetchKey] != nil {
            publishSettlement(contentID: fetchKey, terminal: true)
            return
        }
        if inFlightKey == fetchKey { return }   // paired onChange/onAppear: run once
        task?.cancel()
        inFlightKey = fetchKey
        publishSettlement(contentID: fetchKey, terminal: false)

        let imdbID = target.titleID
        let season = target.season
        let episode = target.episode
        let settingsByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, settingsFor($0.id)) })
        VXProbe.log("jsplugin", "refresh id=\(VXProbeRedaction.identityToken(imdbID)) providers=\(providers.count) mediaType=\(mediaType)")

        task = Task { [weak self] in
            guard let self else { return }
            // imdb -> tmdb (community providers require the numeric TMDB id).
            let tmdbId = await self.resolveTMDB(imdbID, mediaType)
            guard SourceContributorCompletionOwnership.accepts(
                completedKey: fetchKey, shownKey: self.shownKey, inFlightKey: self.inFlightKey,
                canceled: Task.isCancelled
            ) else { return }
            guard let tmdbId else {
                self.inFlightKey = nil
                self.task = nil
                VXProbe.log("jsplugin", "no tmdb id for id=\(VXProbeRedaction.identityToken(imdbID)), skipping")
                self.publishSettlement(contentID: fetchKey, terminal: true)
                return
            }

            // Run each applicable provider in turn; each is independently fail-soft, and each runs off-main in
            // its own disposable bounded interpreter (the await suspends here and resumes on the main actor).
            // Sequential keeps at most one provider VM alive at a time on the device.
            var built: [CoreStreamSourceGroup] = []
            for provider in providers where provider.supports(mediaType: mediaType) {
                if Task.isCancelled { break }
                let settings = settingsByID[provider.id] ?? "{}"
                let raw = await self.runProvider(provider, tmdbId, mediaType, season, episode, settings)
                if let group = JSProviderStreamMapping.group(from: raw, provider: provider) {
                    built.append(group)
                }
            }

            guard SourceContributorCompletionOwnership.accepts(
                completedKey: fetchKey, shownKey: self.shownKey, inFlightKey: self.inFlightKey,
                canceled: Task.isCancelled
            ) else { return }
            // The rollout can be withdrawn while a bounded interpreter is running. Recheck immediately before
            // publication and discard both result and session cache when it is no longer effective.
            guard self.gate() else { self.clearResults(); return }
            self.inFlightKey = nil
            self.task = nil
            self.cache[fetchKey] = built
            self.groups = built
            VXProbe.log("jsplugin", "ran \(providers.count) provider(s) -> \(built.count) group(s) for id=\(VXProbeRedaction.identityToken(imdbID))")
            self.publishSettlement(contentID: fetchKey, terminal: true)
        }
    }

    /// Empty the published groups without touching the session cache; a title that cannot run providers must
    /// see it EMPTY, never a predecessor's groups.
    func clearResults() {
        task?.cancel()
        task = nil
        inFlightKey = nil
        shownKey = nil
        publishedTarget = nil
        publishSettlement(contentID: nil, terminal: true)
        if !groups.isEmpty { groups = [] }
    }

    /// Re-find sources: drop this title's cached result so the next refresh re-runs the providers, then blank
    /// the published groups.
    func invalidateCachedResult(for resolution: SourceIndexIdentity.TargetResolution) {
        if let target = SourceIndexIdentity.validatedTarget(resolution) {
            cache.removeValue(forKey: target.contentID)
        }
        clearResults()
    }

    // MARK: Merge

    /// Merge only with a capability proving these groups and this page share one validated target.
    func merged(
        into groups: [CoreStreamSourceGroup],
        call: AuxiliarySourcePipeline.Call
    ) -> [CoreStreamSourceGroup] {
        let authorization = SourceIndexIdentity.mergeAuthorization(published: publishedTarget, page: call.resolution)
        return Self.merge(authorizedBy: authorization, self.groups, into: groups)
    }

    /// The pure merge. `nonisolated static` so `SourceListModel`'s off-main assembly can run it over a
    /// snapshotted groups array without hopping to the main actor. A nil capability is a pure pass-through, and
    /// streams whose url already appears in the list are dropped (dedup), exactly like the media-server merge.
    nonisolated static func merge(
        authorizedBy authorization: SourceIndexIdentity.MergeAuthorization?,
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
