import Foundation

struct TraktNextEpisodeTarget: Equatable, Sendable {
    let key: String
    let type: String
    let metaID: String
    let videoID: String
    let titleSpellings: [String]
    let season: Int
    let episode: Int
    let showTraktID: Int
    let episodeTraktID: Int
}

/// A value projection of already accepted CoreMetaItem/CoreVideo data, not a metadata request.
struct TraktNextEpisodeOwnedMetadata: Sendable {
    struct Video: Equatable, Sendable {
        let id: String
        let season: Int?
        let episode: Int?
    }
    let id: String
    let type: String
    let videos: [Video]
}

struct TraktNextEpisodeVerdict: Equatable, Sendable {
    enum Disposition: String, Sendable { case eligible, suppressed, unresolved }
    let key: String
    let disposition: Disposition
}

/// The adapter captures this before the first provider await. Its current check includes queued
/// native intents, not only acknowledged account/profile state. No SDK support is implied by this DTO.
struct TraktNextEpisodeNativeLease: Sendable {
    let metadata: [TraktNextEpisodeOwnedMetadata]
    let isCurrent: @Sendable () -> Bool
    let query: @Sendable ([TraktNextEpisodeTarget]) async throws -> [TraktNextEpisodeVerdict]
    let prepareMetadata: (@Sendable (String) async throws -> TraktNextEpisodeOwnedMetadata)?
    init(metadata: [TraktNextEpisodeOwnedMetadata], isCurrent: @escaping @Sendable () -> Bool,
         query: @escaping @Sendable ([TraktNextEpisodeTarget]) async throws -> [TraktNextEpisodeVerdict],
         prepareMetadata: (@Sendable (String) async throws -> TraktNextEpisodeOwnedMetadata)? = nil) {
        self.metadata = metadata; self.isCurrent = isCurrent; self.query = query
        self.prepareMetadata = prepareMetadata
    }
}

/// Read-only orchestration. Native authority is injected by the real host adapter; absence of that
/// adapter cannot become an allow result. Owner is the original immutable Home selection intent.
final class TraktNextEpisodeConsumer<Owner: Hashable & Sendable>: @unchecked Sendable {
    struct Row: Identifiable, Sendable {
        let name: String
        let target: TraktNextEpisodeTarget
        let activity: String?
        let isCurrent: @Sendable () -> Bool
        var id: String { target.type + "|" + target.metaID }
    }
    struct Dependencies: Sendable {
        let inventory: @Sendable (Owner, TraktSessionID) -> TraktWatchedShowInventory?
        let refreshInventory: @Sendable (TraktSessionID, @escaping @Sendable () -> Bool) async throws -> Void
        let progress: @Sendable (TraktWatchedShowInventoryEntry, TraktSessionID) async throws -> TraktNextEpisodeProgress.Result
        let ownerIsCurrent: @Sendable (Owner, TraktSessionID) -> Bool
        let uptime: @Sendable () -> TimeInterval
        let changed: @Sendable () -> Void
    }
    private struct Cache {
        let revision: UUID
        let entry: TraktWatchedShowInventoryEntry
        let row: Row?
    }
    static var requestsPerRefresh: Int { 8 }
    static var refreshInterval: TimeInterval { 300 }
    private let dependencies: Dependencies
    private let lock = NSLock()
    private var owner: Owner?
    private var session: TraktSessionID?
    private var flight: UUID?
    private var lastAttempt: TimeInterval?
    private var lastVisitedShow: Int?
    private var cache: [Int: Cache] = [:]

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    /// Auth boundaries clear private in-memory evidence before a replacement owner can use it.
    func retire() {
        lock.withLock {
            owner = nil; session = nil; flight = nil; lastAttempt = nil
            lastVisitedShow = nil; cache.removeAll()
        }
    }

    func rows(owner expectedOwner: Owner, session expectedSession: TraktSessionID) -> [Row] {
        guard dependencies.ownerIsCurrent(expectedOwner, expectedSession) else { return [] }
        let values: [Row] = lock.withLock {
            guard owner == expectedOwner, session == expectedSession else { return [] }
            return cache.values.compactMap(\.row)
        }
        let current = values.filter { $0.isCurrent() }
        let counts = Dictionary(grouping: current, by: \.id).mapValues(\.count)
        return current.filter { counts[$0.id] == 1 }.sorted { $0.id < $1.id }
    }

    /// No pre-cancelled call may retire a healthy flight or touch its throttle/cache.
    func refresh(owner expectedOwner: Owner, session expectedSession: TraktSessionID,
                 native: TraktNextEpisodeNativeLease) async {
        guard !Task.isCancelled, dependencies.ownerIsCurrent(expectedOwner, expectedSession),
              native.isCurrent() else { return }
        let now = dependencies.uptime()
        guard now.isFinite else { return }
        let ticket = UUID()
        let admitted = lock.withLock { () -> Bool in
            guard !Task.isCancelled, dependencies.ownerIsCurrent(expectedOwner, expectedSession),
                  native.isCurrent() else { return false }
            if owner != expectedOwner || session != expectedSession {
                let sameServiceSession = session == expectedSession
                owner = expectedOwner; session = expectedSession
                flight = nil; cache.removeAll()
                // Native owner receipts can change on ordinary sync publications. They retire rows,
                // but cannot bypass the account-wide provider attempt budget for this same session.
                if !sameServiceSession { lastAttempt = nil; lastVisitedShow = nil }
            }
            guard flight == nil else { return false }
            if let lastAttempt, now >= lastAttempt, now - lastAttempt < Self.refreshInterval { return false }
            flight = ticket
            // This limits attempts, not successful service freshness or any watch event.
            lastAttempt = now
            return true
        }
        guard admitted else { return }
        defer { lock.withLock { if flight == ticket { flight = nil } } }
        let current: @Sendable () -> Bool = { [self] in
            !Task.isCancelled && dependencies.ownerIsCurrent(expectedOwner, expectedSession)
                && native.isCurrent() && lock.withLock {
                    owner == expectedOwner && session == expectedSession && flight == ticket
                }
        }
        do {
            try Task.checkCancellation()
            guard current() else { return }
            try await dependencies.refreshInventory(expectedSession, current)
            try Task.checkCancellation()
            guard current(), let inventory = dependencies.inventory(expectedOwner, expectedSession),
                  inventory.sessionID == expectedSession else { return }
            let revision = inventory.revision
            let inventoryCurrent: @Sendable () -> Bool = { [dependencies] in
                guard let latest = dependencies.inventory(expectedOwner, expectedSession) else { return false }
                return latest.sessionID == expectedSession && latest.revision == revision
                    && latest.readVersion == inventory.readVersion
            }
            // Revision is minted only for immutable complete transactions. Check the exact entry
            // after async legs too; UI receipts use the constant-size revision check, not a scan.
            let entryCurrent: @Sendable (TraktWatchedShowInventoryEntry) -> Bool = { [dependencies] entry in
                inventoryCurrent() && dependencies.inventory(expectedOwner, expectedSession)?.entries.first {
                    $0.traktID == entry.traktID
                } == entry
            }
            guard inventoryCurrent() else { return }
            let available = inventory.entries.filter {
                native.prepareMetadata != nil || Self.hasOwnedTitle($0.show, metadata: native.metadata)
            }
                .sorted { $0.traktID < $1.traktID }
            let cursor = lock.withLock { lastVisitedShow }
            let rotated = available.filter { $0.traktID > (cursor ?? 0) }
                + available.filter { $0.traktID <= (cursor ?? 0) }
            let due = Array(rotated.prefix(Self.requestsPerRefresh))
            var staged: [Int: Cache] = [:]
            var targets: [TraktNextEpisodeTarget] = []
            var selected: [String: (TraktWatchedShowInventoryEntry, TraktNextEpisodeProgress.Candidate)] = [:]
            for entry in due {
                try Task.checkCancellation()
                guard current(), entryCurrent(entry) else { return }
                let attemptAdmitted = lock.withLock { () -> Bool in
                    guard !Task.isCancelled, flight == ticket,
                          owner == expectedOwner, session == expectedSession else { return false }
                    // Operational attempt cursor only. A persistent failed title cannot starve later
                    // known shows. This does not mark success, publish a row or create a watch clock.
                    lastVisitedShow = entry.traktID
                    return true
                }
                guard attemptAdmitted else { return }
                let metadata: [TraktNextEpisodeOwnedMetadata]
                if let prepare = native.prepareMetadata {
                    guard let id = Self.metadataID(entry.show) else { continue }
                    let prepared = try await prepare(id)
                    try Task.checkCancellation()
                    guard current(), entryCurrent(entry), prepared.id == id, prepared.type == "series" else { return }
                    metadata = [prepared]
                } else { metadata = native.metadata }
                let result = try await dependencies.progress(entry, expectedSession)
                try Task.checkCancellation()
                guard current(), entryCurrent(entry) else { return }
                switch result {
                case .caughtUp, .unavailable:
                    staged[entry.traktID] = Cache(revision: revision, entry: entry, row: nil)
                case .next(let candidate):
                    guard candidate.showTraktID == entry.traktID,
                          Set([candidate.id] + candidate.aliases).isSubset(of: Self.titleSpellings(entry.show)),
                          let target = Self.map(candidate, metadata: metadata) else {
                        staged[entry.traktID] = Cache(revision: revision, entry: entry, row: nil)
                        continue
                    }
                    guard selected[target.key] == nil else { return }
                    targets.append(target); selected[target.key] = (entry, candidate)
                }
            }
            guard current(), inventoryCurrent() else { return }
            guard Set(targets.map { $0.type + "|" + $0.metaID }).count == targets.count else { return }
            if !targets.isEmpty {
                let verdicts = try await native.query(targets)
                try Task.checkCancellation()
                guard current(), inventoryCurrent(), verdicts.count == targets.count,
                      Set(verdicts.map(\.key)).count == verdicts.count,
                      Set(verdicts.map(\.key)) == Set(targets.map(\.key)) else { return }
                for target in targets {
                    guard let (entry, candidate) = selected[target.key], entryCurrent(entry),
                          let verdict = verdicts.first(where: { $0.key == target.key }) else { return }
                    let row: Row?
                    if verdict.disposition == .eligible {
                        let receipt: @Sendable () -> Bool = { [dependencies] in
                            dependencies.ownerIsCurrent(expectedOwner, expectedSession)
                                && native.isCurrent() && inventoryCurrent()
                        }
                        row = Row(name: candidate.name, target: target,
                                  activity: candidate.lastWatchedAt ?? entry.lastWatchedAt,
                                  isCurrent: receipt)
                    } else { row = nil }
                    staged[entry.traktID] = Cache(revision: revision, entry: entry, row: row)
                }
            }
            try Task.checkCancellation()
            guard current(), inventoryCurrent(), due.allSatisfy(entryCurrent) else { return }
            let committed = lock.withLock { () -> Bool in
                guard flight == ticket, owner == expectedOwner, session == expectedSession,
                      !Task.isCancelled else { return false }
                // External receipt checks ran immediately above. Do not call the inventory store
                // under this lock: its refresh authority may synchronously consult this flight.
                // A concurrently retired receipt makes the private cached row unreadable at rows().
                let currentIDs = Set(inventory.entries.map(\.traktID))
                cache = cache.filter { id, prior in
                    prior.revision == revision && currentIDs.contains(id)
                }
                cache.merge(staged, uniquingKeysWith: { _, incoming in incoming })
                if cache.count > 100 {
                    let expired = cache.keys.sorted().filter { staged[$0] == nil }.prefix(cache.count - 100)
                    for id in expired { cache.removeValue(forKey: id) }
                }
                if let last = due.last { lastVisitedShow = last.traktID }
                return true
            }
            if committed { dependencies.changed() }
        } catch {
            // Failure/cancellation never creates a complete empty result or changes prior rows.
            // Their original receipts remain the read gate; stale native/source owners hide them.
        }
    }

    private static func metadataID(_ show: TraktShow) -> String? {
        if let imdb = show.ids.imdb, !imdb.isEmpty { return imdb }
        if let tmdb = show.ids.tmdb, tmdb > 0 { return "tmdb:tv:\(tmdb)" }
        return nil
    }
    private static func titleSpellings(_ show: TraktShow) -> Set<String> {
        var ids = Set<String>()
        if let imdb = show.ids.imdb, !imdb.isEmpty { ids.insert(imdb) }
        if let tmdb = show.ids.tmdb, tmdb > 0 { ids.formUnion(["tmdb:tv:\(tmdb)", "tmdb:\(tmdb)"]) }
        return ids
    }
    private static func hasOwnedTitle(_ show: TraktShow, metadata: [TraktNextEpisodeOwnedMetadata]) -> Bool {
        let ids = titleSpellings(show)
        return metadata.contains { $0.type == "series" && ids.contains($0.id) }
    }
    static func map(_ candidate: TraktNextEpisodeProgress.Candidate,
                    metadata: [TraktNextEpisodeOwnedMetadata]) -> TraktNextEpisodeTarget? {
        guard candidate.showTraktID > 0, candidate.episodeTraktID > 0,
              candidate.season > 0, candidate.episode > 0 else { return nil }
        let spellings = Set([candidate.id] + candidate.aliases)
        let matches = metadata.filter { $0.type == "series" && spellings.contains($0.id) }.flatMap { meta in
            meta.videos.filter {
                !$0.id.isEmpty && $0.season == candidate.season && $0.episode == candidate.episode
            }.map { (meta, $0) }
        }
        // Even duplicate coordinate rows are ambiguity, not permission to choose a convenient ID.
        guard matches.count == 1, let (meta, video) = matches.first,
              meta.videos.filter({ $0.id == video.id }).count == 1 else { return nil }
        return .init(key: "\(candidate.showTraktID)|\(candidate.episodeTraktID)", type: meta.type,
            metaID: meta.id, videoID: video.id, titleSpellings: spellings.sorted(),
            season: candidate.season, episode: candidate.episode,
            showTraktID: candidate.showTraktID, episodeTraktID: candidate.episodeTraktID)
    }
}
