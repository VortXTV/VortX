import SwiftUI

/// The minimum proof Home needs before it may hand engine-owned watch history to a personalized
/// recommender.  A settled UID alone is not enough: the engine can still have the previous account's
/// published library in memory until the post-auth `library`/`continue_watching_preview` receipt lands.
/// Keep this value small and value-only so it can be exercised without a CoreBridge or network harness.
enum BecauseYouWatchedHistoryPolicy {
    static let historyFields: Set<String> = ["library", "continue_watching_preview"]

    struct Owner: Equatable {
        let profileID: UUID
        let keychainAccount: String
        let uid: String
        let generation: UInt64
    }

    struct Snapshot: Equatable {
        let owner: Owner?
        let revision: Int
        let changedFields: Set<String>
    }

    enum Decision: Equatable {
        case overlay
        case unsettledEngine
        case awaitingHistorySnapshot
        case readyEngine
    }

    /// Decide whether a call may use engine-backed watch history.
    ///
    /// `minimumRevision` is captured when the Home owner boundary changes.  Requiring a strictly newer
    /// revision carrying an actual history field prevents a stale A snapshot from being relabelled as B
    /// merely because B's authenticated UID is now settled.  Overlay history deliberately bypasses this
    /// engine receipt requirement because it is already scoped to the selected local profile.
    static func decision(
        usesEngineHistory: Bool,
        activeProfileID: UUID?,
        activeKeychainAccount: String,
        snapshot: Snapshot?,
        minimumRevision: Int?
    ) -> Decision {
        guard usesEngineHistory else { return .overlay }
        guard let snapshot, let owner = snapshot.owner,
              owner.profileID == activeProfileID,
              owner.keychainAccount == activeKeychainAccount else {
            return .unsettledEngine
        }
        guard let minimumRevision,
              snapshot.revision > minimumRevision,
              !snapshot.changedFields.isDisjoint(with: historyFields) else {
            return .awaitingHistorySnapshot
        }
        return .readyEngine
    }
}

/// A profile-local "Because you watched" rail.
///
/// The inputs are deliberately passed in by Home rather than read from the engine here. That keeps the
/// rail on the same privacy boundary as Top Picks: an overlay profile only ever contributes its own local
/// history/library, and an engine-backed profile only contributes the engine snapshot selected by Home.
/// Every identifier is resolved through the existing TMDB/Cinemeta path before recommendations are fetched;
/// an unknown catalog id is ignored instead of being guessed onto an unrelated title.
@MainActor
final class BecauseYouWatchedModel: ObservableObject {
    @Published private(set) var rail: CuratedCollection?
    /// True only when the inputs most recently accepted by `refresh` belong to the current history
    /// owner. Home uses this to keep Top Picks behind the same engine-account boundary.
    private(set) var historyInputReady = false

    private static let maxSeeds = 4
    private static let maxItems = 20

    /// `lastSignature` describes the rail currently on screen. `inFlightSignature` prevents repeated Home
    /// body emissions from starting another bounded fetch while the same request is still resolving.
    private var lastSignature: String?
    private var inFlightSignature: String?
    private var loadTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private var activeProfileID: UUID?
    /// The profile UUID is not sufficient to identify the history owner: a signed-in account, local
    /// history slot, or engine principal can change while the selected profile remains the same.
    private var activeOwnerKey: String?
    /// Engine history is not usable until a published history field arrives after the current owner
    /// boundary.  This is intentionally model-local: Home can clear the personalized rail immediately
    /// without making CoreBridge expose recommendation-specific state.
    private var historyOwner: BecauseYouWatchedHistoryPolicy.Owner?
    private var historyMinimumRevision: Int?
    private var historySnapshotReady = false
    /// A published account/email boundary may precede CoreBridge's settled binding rotation. If the
    /// snapshot still names the old owner at that point, require a different binding before accepting
    /// any later history receipt; otherwise an old-account event could relabel itself as the new email.
    private var historyRequiresNewBinding = false

    /// Recompute from the active profile's recent watch/library titles. Calls are cheap when the exact
    /// relevant inputs are unchanged, but a watch-progress or watched-count mutation changes the signature.
    func refresh(
        profileID: UUID?,
        cw: [CoreCWItem],
        library: [CoreCWItem],
        ownerKey: String = "",
        usesEngineHistory: Bool = true,
        activeKeychainAccount: String? = nil,
        historySnapshot: BecauseYouWatchedHistoryPolicy.Snapshot? = nil,
    ) {
        let signature = ownerKey + "|" + (profileID?.uuidString ?? "main") + "|" +
            Self.seedSignature(cw: cw, library: library)
        let ownerChanged = activeProfileID != profileID || activeOwnerKey != ownerKey

        if ownerChanged {
            let previousOwner = historyOwner
            let previousOwnerKey = activeOwnerKey
            let ownerChangedWithFreshHistory = usesEngineHistory
                && previousOwner != nil
                && historySnapshot?.owner != nil
                && previousOwner != historySnapshot?.owner
                && !(historySnapshot?.changedFields.isDisjoint(with: BecauseYouWatchedHistoryPolicy.historyFields) ?? true)
            historyRequiresNewBinding = usesEngineHistory
                && previousOwner != nil
                && previousOwner == historySnapshot?.owner
                && previousOwnerKey != ownerKey
            requestGeneration &+= 1
            loadTask?.cancel()
            loadTask = nil
            inFlightSignature = nil
            rail = nil
            lastSignature = nil
            activeProfileID = profileID
            activeOwnerKey = ownerKey
            historyOwner = historySnapshot?.owner
            historyMinimumRevision = historySnapshot?.revision
            // The first valid B history event can be the same revision that makes the settled B binding
            // observable. Accept that event when the prior owner was already known and the new exact
            // owner differs; there is no old-A callback left to publish after CoreBridge's epoch fence.
            historySnapshotReady = ownerChangedWithFreshHistory
            historyInputReady = ownerChangedWithFreshHistory
        }

        if usesEngineHistory {
            if historyRequiresNewBinding {
                guard let snapshotOwner = historySnapshot?.owner,
                      snapshotOwner != historyOwner else {
                    historyInputReady = false
                    loadTask?.cancel()
                    loadTask = nil
                    inFlightSignature = nil
                    rail = nil
                    lastSignature = nil
                    return
                }
                // The binding/principal changed. The owner-boundary baseline was captured when this
                // owner arrived, so the new owner still needs its own newer history receipt below.
                historyOwner = snapshotOwner
                historyRequiresNewBinding = false
            }
            if historySnapshotReady {
                // Keep a ready owner usable across unrelated engine revisions. A later owner change
                // resets this latch above, before any old data can reach the recommender.
                guard let snapshot = historySnapshot,
                      snapshot.owner == historyOwner,
                      snapshot.owner?.profileID == profileID,
                      snapshot.owner?.keychainAccount == activeKeychainAccount else {
                    historyInputReady = false
                    rail = nil
                    lastSignature = nil
                    return
                }
            } else {
                let decision = BecauseYouWatchedHistoryPolicy.decision(
                    usesEngineHistory: true,
                    activeProfileID: profileID,
                    activeKeychainAccount: activeKeychainAccount ?? "",
                    snapshot: historySnapshot,
                    minimumRevision: historyMinimumRevision
                )
                guard decision == .readyEngine else {
                    // Keep the owner identity/baseline so repeated Home body emissions do not move the
                    // baseline forward and accidentally make an old snapshot look fresh.  The rail and
                    // any in-flight work are retired synchronously at the boundary.
                    loadTask?.cancel()
                    loadTask = nil
                    inFlightSignature = nil
                    historyInputReady = false
                    rail = nil
                    lastSignature = nil
                    return
                }
                historySnapshotReady = true
                historyInputReady = true
            }
        } else {
            // Local overlay history is already scoped by ProfileStore; no Stremio binding or engine
            // receipt is required. Reset engine-only readiness so a later owner-profile return starts a
            // new post-boundary proof instead of inheriting this overlay's state.
            historyOwner = nil
            historyMinimumRevision = nil
            historySnapshotReady = false
            historyInputReady = true
        }

        let seeds = Self.eligibleSeeds(cw: cw, library: library)

        if !ownerChanged, signature == lastSignature, rail != nil {
            activeProfileID = profileID
            return
        }
        if !ownerChanged, signature == inFlightSignature { return }

        requestGeneration &+= 1
        let generation = requestGeneration
        loadTask?.cancel()
        inFlightSignature = signature

        // Never display the previous owner's personalized row during a profile/account boundary. A
        // same-owner retry may retain an existing rail until a non-empty replacement is ready.
        if ownerChanged {
            rail = nil
            lastSignature = nil
        }
        activeProfileID = profileID
        activeOwnerKey = ownerKey

        guard !seeds.isEmpty else {
            inFlightSignature = nil
            rail = nil
            lastSignature = nil
            return
        }

        // Exclude everything the active profile already owns. Temporary and removed engine entries are not
        // valid ownership evidence and are ignored on both the seed and exclusion paths.
        let owned = Set((cw + library)
            .filter { !$0.id.isEmpty && $0.removed != true && $0.temp != true }
            .map(\.id))
        loadTask = Task { [seeds, owned, signature, generation, profileID, ownerKey] in
            let built = await Self.build(seeds: seeds, owned: owned)
            guard !Task.isCancelled, self.requestGeneration == generation else { return }

            self.inFlightSignature = nil
            guard let built else {
                // A transient network/provider failure must not replace a valid rail with an error/empty
                // result. The next input mutation retries because the successful signature was not saved.
                self.lastSignature = nil
                return
            }

            // If the response has the same card ids but a provider omitted artwork this time, preserve an
            // already-valid poster from the previous rail. A newer, non-empty response still wins by id and
            // order; this only prevents a late sparse artwork response from blanking a useful card.
            self.rail = Self.preservingArtwork(in: built, from: self.rail)
            self.lastSignature = signature
            self.activeProfileID = profileID
            self.activeOwnerKey = ownerKey
        }
    }

    /// Clear when the profile signs out or switches to one with no eligible history.
    func clear() {
        requestGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        inFlightSignature = nil
        activeProfileID = nil
        activeOwnerKey = nil
        historyOwner = nil
        historyMinimumRevision = nil
        historySnapshotReady = false
        historyRequiresNewBinding = false
        historyInputReady = false
        rail = nil
        lastSignature = nil
    }

    // MARK: - Shared build (also used by HomeCollectionGroups' nested-group path)

    /// A recent-watch seed: the original catalog id/type/name. The id is resolved immediately before the
    /// recommendation request, so callers do not need to fabricate replacement identifiers.
    struct Seed {
        let id: String
        let type: String
        let name: String
    }

    /// Pick up to `maxSeeds` eligible seeds newest-first: Continue Watching first (freshest intent), then
    /// library. A seed needs actual watch evidence (resume progress, watched count, or watched flag), cannot
    /// be temporary/removed, and must use one of the identifier shapes the existing resolver understands.
    static func eligibleSeeds(cw: [CoreCWItem], library: [CoreCWItem]) -> [Seed] {
        var seen = Set<String>()
        return (cw + library)
            .filter { item in
                !item.id.isEmpty && item.removed != true && item.temp != true &&
                    hasWatchEvidence(item) && supportsResolution(item.id)
            }
            .filter { seen.insert($0.id).inserted }
            .prefix(maxSeeds)
            .map { Seed(id: $0.id, type: $0.type, name: $0.name) }
    }

    /// A stable, profile-independent signature for recommendation-relevant local state. Include ownership
    /// ids so a library mutation removes a newly-owned recommendation, and include watch state so a resume or
    /// watched mutation can promote/reseed without relying on a coarse first-id observer.
    static func seedSignature(cw: [CoreCWItem], library: [CoreCWItem]) -> String {
        let history = cw + library
        let seeds = eligibleSeeds(cw: cw, library: library)
            .map { "\($0.type):\($0.id):\($0.name)" }
            .joined(separator: ",")
        let owned = history
            .filter { !$0.id.isEmpty && $0.removed != true && $0.temp != true }
            .map(\.id)
            .sorted()
            .joined(separator: ",")
        let watchState = history
            .filter { !$0.id.isEmpty && $0.removed != true && $0.temp != true }
            .map(watchFingerprint)
            .sorted()
            .joined(separator: ",")
        return "seeds=\(seeds)|owned=\(owned)|watch=\(watchState)"
    }

    /// Bounded Home observer key for overlay history (the profile store caps this collection at 30). It
    /// includes progress and watched counters, not just ids, so an interior watch mutation refreshes the rail.
    static func observationSignature(items: [CoreCWItem]) -> String {
        items.map(watchFingerprint).joined(separator: "\u{1}")
    }

    /// Build the non-secret ownership key used by Apple Home call sites. `StremioAccount` intentionally
    /// does not republish `isSignedIn` for a true-to-true replacement, so its published email assignment
    /// is included as a stable identity hint until the engine's settled uid/binding is available. No auth
    /// token or credential material belongs in this key.
    static func recommendationOwnerKey(
        profileKeychainAccount: String,
        isSignedIn: Bool,
        usesEngineHistory: Bool,
        accountEmail: String?,
        principal: String?,
        authorityGeneration: UInt64?
    ) -> String {
        let email = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "-"
        let principal = principal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
        let generation = authorityGeneration.map(String.init) ?? "-"
        return [profileKeychainAccount, String(isSignedIn), String(usesEngineHistory), email,
                principal, generation].joined(separator: "|")
    }

    /// Build the rail straight from raw CW + library (used by HomeCollectionGroups' nested-group path).
    /// Resolver/recommendation failures remain fail-soft and return nil.
    static func build(cw: [CoreCWItem], library: [CoreCWItem]) async -> CuratedCollection? {
        let seeds = eligibleSeeds(cw: cw, library: library)
        guard !seeds.isEmpty else { return nil }
        let owned = Set((cw + library)
            .filter { !$0.id.isEmpty && $0.removed != true && $0.temp != true }
            .map(\.id))
        return await build(seeds: seeds, owned: owned)
    }

    /// Resolve the bounded seed set, fetch each supported seed in parallel, then round-robin merge the
    /// recommendation buckets. Results are stable by seed order, deduplicated, owned/self-filtered, and capped.
    static func build(seeds: [Seed], owned: Set<String>) async -> CuratedCollection? {
        let resolved: [(seed: Seed, imdbID: String)] = await withTaskGroup(
            of: (Int, (Seed, String)?).self
        ) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask {
                    guard let imdbID = await TMDBClient.imdbID(forCatalogID: seed.id, type: seed.type) else {
                        return (index, nil)
                    }
                    return (index, (seed, imdbID))
                }
            }
            var ordered = [(Seed, String)?](repeating: nil, count: seeds.count)
            for await (index, item) in group { ordered[index] = item }
            return ordered.compactMap { $0 }.map { (seed: $0.0, imdbID: $0.1) }
        }
        guard !resolved.isEmpty else { return nil }

        let perSeed: [[MetaPreview]] = await withTaskGroup(of: (Int, [MetaPreview]).self) { group in
            for (index, entry) in resolved.enumerated() {
                group.addTask {
                    (index, await AddonClient.tmdbSimilar(type: entry.seed.type, imdbID: entry.imdbID))
                }
            }
            var buckets = [[MetaPreview]](repeating: [], count: resolved.count)
            for await (index, recs) in group { buckets[index] = recs }
            return buckets
        }

        let seedIDs = Set(seeds.map(\.id) + resolved.map(\.imdbID))
        var merged: [MetaPreview] = []
        var added = Set<String>()
        let maxDepth = perSeed.map(\.count).max() ?? 0
        outer: for depth in 0..<maxDepth {
            for bucket in perSeed where depth < bucket.count {
                let preview = bucket[depth]
                guard !owned.contains(preview.id), !seedIDs.contains(preview.id),
                      added.insert(preview.id).inserted else { continue }
                merged.append(preview)
                if merged.count >= maxItems { break outer }
            }
        }
        guard !merged.isEmpty, let primary = resolved.first?.seed else { return nil }

        let title = String(localized: "Because you watched \(primary.name)")
        return CuratedCollection(
            id: "becauseYouWatched.\(primary.id)",
            title: title,
            items: merged,
        )
    }

    private static func hasWatchEvidence(_ item: CoreCWItem) -> Bool {
        item.progress > 0 || item.isWatched || item.state.flaggedWatched > 0
    }

    private static func supportsResolution(_ id: String) -> Bool {
        switch DetailMetaRecoveryPolicy.catalogIDShape(id) {
        case .imdb, .tmdb, .tvdb, .kitsu:
            return true
        case .unsupported:
            return false
        }
    }

    private static func watchFingerprint(_ item: CoreCWItem) -> String {
        "\(item.type):\(item.id):\(item.progress):\(item.state.lastWatched ?? ""):\(item.state.flaggedWatched):\(item.state.timesWatched)"
    }

    private static func preservingArtwork(
        in newRail: CuratedCollection,
        from previous: CuratedCollection?
    ) -> CuratedCollection {
        guard let previous else { return newRail }
        let oldByID = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.id, $0) })
        let items = newRail.items.map { item -> MetaPreview in
            guard item.poster == nil, let old = oldByID[item.id], old.poster != nil else { return item }
            return MetaPreview(
                id: item.id,
                type: item.type,
                name: item.name,
                poster: old.poster,
                posterShape: item.posterShape ?? old.posterShape,
                popularity: item.popularity ?? old.popularity,
            )
        }
        return CuratedCollection(id: newRail.id, title: newRail.title, items: items)
    }
}
