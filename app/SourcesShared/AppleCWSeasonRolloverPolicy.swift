import Foundation

/// A coordinate-bearing episode identity used by the Apple terminal successor policy. The policy never
/// treats an id-only or partially decoded metadata row as proof of a complete series inventory.
struct AppleCWSeriesEpisode: Equatable, Hashable {
    let id: String
    let season: Int
    let episode: Int

    init(id: String, season: Int, episode: Int) {
        self.id = id
        self.season = season
        self.episode = episode
    }
}

/// The only two inventory sources the player is allowed to distinguish. A launch list is useful for safe
/// successor navigation, but it cannot prove that its last visible episode is the title finale. The second
/// case is a settled backfill handoff for successor navigation only; it is never an app-side finality proof.
struct AppleCWSeriesInventory: Equatable {
    enum Authority: Equatable {
        case launch
        case authoritativeFullSeries
    }

    let raw: [AppleCWSeriesEpisode]
    let ordered: [AppleCWSeriesEpisode]
    let authority: Authority

    init?(raw: [AppleCWSeriesEpisode], authority: Authority) {
        guard !raw.isEmpty,
              raw.allSatisfy({ !$0.id.isEmpty && $0.season >= 0 && $0.episode > 0 }),
              Set(raw.map(\.id)).count == raw.count else { return nil }
        let ordered = raw.sorted {
            if $0.season != $1.season { return $0.season < $1.season }
            if $0.episode != $1.episode { return $0.episode < $1.episode }
            return $0.id < $1.id
        }
        // A refresh may normalize a launch list for successor navigation. A settled backfill must arrive in
        // source order too, so a raw unsorted tvOS array cannot alter the successor list.
        if authority == .authoritativeFullSeries, raw != ordered { return nil }
        self.raw = raw
        self.ordered = ordered
        self.authority = authority
    }

    func index(of id: String) -> Int? { ordered.firstIndex { $0.id == id } }
}

/// Holds the best inventory observed by one playback session. A later settled backfill replaces a partial
/// launch list only when it retains the older identities, so a transient shrink cannot erase useful successor
/// knowledge or turn unknown finality into a destructive action.
struct AppleCWSeriesInventoryLedger: Equatable {
    private(set) var current: AppleCWSeriesInventory?

    init(launch: [AppleCWSeriesEpisode]) {
        current = AppleCWSeriesInventory(raw: launch, authority: .launch)
    }

    @discardableResult
    mutating func acceptAuthoritativeBackfill(_ raw: [AppleCWSeriesEpisode]) -> Bool {
        guard let candidate = AppleCWSeriesInventory(raw: raw, authority: .authoritativeFullSeries) else {
            return false
        }
        if let current,
           !current.ordered.allSatisfy({ candidate.ordered.contains($0) }) {
            return false
        }
        current = candidate
        return true
    }
}

enum AppleCWSeriesRefreshResult: Equatable {
    case notAttempted
    case completedWithoutFullInventory
    case completedWithFullInventory
}

/// A refresh may certify metadata only after CoreBridge marks a settled receipt with the exact request
/// generation that owned it. A pre-existing same-ID payload, even when nonempty, and an unrelated event
/// after a no-op Load both carry no request generation and cannot certify the refresh.
struct AppleCWMetaRefreshReceipt: Equatable {
    let requestGeneration: Int?
    let selectedMetaID: String?
    let loadedMetaID: String?
    let settled: Bool
    let requestedStreamID: String?

    init(requestGeneration: Int?, selectedMetaID: String?, loadedMetaID: String?, settled: Bool,
         requestedStreamID: String? = nil) {
        self.requestGeneration = requestGeneration
        self.selectedMetaID = selectedMetaID
        self.loadedMetaID = loadedMetaID
        self.settled = settled
        self.requestedStreamID = requestedStreamID
    }
}

/// A bridge action or teardown callback may act only on the exact refresh generation it captured. A
/// replacement player receives a new generation even when it reuses the same library and video IDs.
enum AppleCWMetaRefreshGenerationFence {
    static func owns(capturedGeneration: Int, activeGeneration: Int?) -> Bool {
        activeGeneration == capturedGeneration
    }
}

enum AppleCWMetaRefreshAuthorityPolicy {
    static func accepts(_ receipt: AppleCWMetaRefreshReceipt?, forRequestGeneration: Int,
                        expectedLibraryID: String, expectedStreamID: String? = nil) -> Bool {
        guard let receipt,
              receipt.requestGeneration == forRequestGeneration,
              receipt.selectedMetaID == expectedLibraryID,
              receipt.loadedMetaID == expectedLibraryID,
              receipt.settled else { return false }
        if let expectedStreamID {
            guard receipt.requestedStreamID == expectedStreamID else { return false }
        }
        return true
    }
}

/// Exact owner for one bounded terminal-finality refresh. The generations make a stale task harmless when
/// playback exits, changes episode, changes source, or mounts a replacement physical load.
struct AppleCWTerminalRefreshTarget: Equatable {
    let libraryID: String
    let videoID: String
    let sessionID: String
    let episodeGeneration: Int
    let sourceGeneration: Int
    let resumeGeneration: Int
    let loadOwner: String?
}

enum AppleCWTerminalRefreshFence {
    static func accepts(captured: AppleCWTerminalRefreshTarget,
                        current: AppleCWTerminalRefreshTarget) -> Bool {
        captured == current
    }
}

enum AppleCWSeriesTerminalDecision: Equatable {
    case refresh
    case advance(String)
    case keepState
}

/// Terminal routing for a series. Seeing a successor is sufficient to advance. Seeing no successor never
/// authorizes an app-side title rewind because CoreMetaDetails has no explicit completeness marker; the
/// engine/account owns genuine final-series removal.
enum AppleCWSeriesTerminalPolicy {
    static func decide(currentID: String, inventory: AppleCWSeriesInventory?,
                       refresh: AppleCWSeriesRefreshResult) -> AppleCWSeriesTerminalDecision {
        guard let inventory, let index = inventory.index(of: currentID) else {
            return refresh == .notAttempted ? .refresh : .keepState
        }
        if index + 1 < inventory.ordered.count {
            return .advance(inventory.ordered[index + 1].id)
        }
        return refresh == .notAttempted ? .refresh : .keepState
    }
}

/// Shared with both Apple players so an exit callback cannot flush TimeChanged after a terminal rewind.
struct AppleCWTerminalProgressGate: Equatable {
    private(set) var terminalRewindIssued = false

    mutating func issueTerminalRewind() -> Bool {
        guard !terminalRewindIssued else { return false }
        terminalRewindIssued = true
        return true
    }

    var permitsExitProgressFlush: Bool { !terminalRewindIssued }
}

/// Small pure fixtures used by the standalone contract suite and by source-level assertions around the real
/// CoreCWItem / Top Shelf paths. Production CoreCWItem remains the serialized engine shape.
struct AppleCWContinueWatchingItem: Equatable {
    enum Kind: Equatable { case movie, series }
    let id: String
    let kind: Kind
    let progress: Double

    static func movie(id: String, progress: Double) -> Self {
        Self(id: id, kind: .movie, progress: progress)
    }

    static func series(id: String, progress: Double) -> Self {
        Self(id: id, kind: .series, progress: progress)
    }
}

enum AppleCWContinueWatchingPolicy {
    static func pruneAppFinished(_ items: [AppleCWContinueWatchingItem]) -> [AppleCWContinueWatchingItem] {
        items.filter { $0.kind == .series || $0.progress < 0.9 }
    }
}

struct AppleCWTopShelfItem: Equatable {
    let id: String
}

enum AppleCWTopShelfProjection {
    static func project(_ items: [AppleCWContinueWatchingItem]) -> [AppleCWTopShelfItem] {
        AppleCWContinueWatchingPolicy.pruneAppFinished(items).map { AppleCWTopShelfItem(id: $0.id) }
    }
}
