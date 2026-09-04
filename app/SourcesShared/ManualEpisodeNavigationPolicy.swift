import Foundation

/// A one-shot manual Next/Previous request made before an accepted series inventory can identify the
/// current episode. The UI owns storage and cancellation; this policy only proves whether a request still
/// belongs to the current physical playback and, if it does, resolves its adjacent episode.
struct AppleManualEpisodeNavigationIntent: Equatable {
    enum Direction: Equatable { case previous, next }

    let direction: Direction
    let sessionID: String
    let episodeGeneration: Int
    let sourceGeneration: Int
    let loadOwner: String?
}

struct AppleManualEpisodeNavigationCandidate: Equatable {
    let id: String
    let season: Int?
    let episode: Int?
}

enum AppleManualEpisodeNavigationPolicy {
    enum Decision: Equatable {
        case navigate(String)
        case waitForInventory
        case unavailable
    }

    /// Exact IDs are canonical. Season/episode is intentionally a fallback for Continue Watching rows whose
    /// stored episode id predates a freshly loaded inventory. A different session, load, or generation can
    /// never consume the intent.
    static func currentIndex(
        currentID: String?,
        currentSeason: Int?,
        currentEpisode: Int?,
        inventory: [AppleManualEpisodeNavigationCandidate]
    ) -> Int? {
        if let currentID, let exact = inventory.firstIndex(where: { $0.id == currentID }) {
            return exact
        }
        guard let currentSeason, currentSeason >= 0,
              let currentEpisode, currentEpisode > 0 else { return nil }
        return inventory.firstIndex {
            $0.season == currentSeason && $0.episode == currentEpisode
        }
    }

    static func owns(
        _ intent: AppleManualEpisodeNavigationIntent,
        sessionID: String,
        episodeGeneration: Int,
        sourceGeneration: Int,
        loadOwner: String?
    ) -> Bool {
        intent.sessionID == sessionID
            && intent.episodeGeneration == episodeGeneration
            && intent.sourceGeneration == sourceGeneration
            && intent.loadOwner == loadOwner
    }

    static func decision(
        intent: AppleManualEpisodeNavigationIntent,
        sessionID: String,
        episodeGeneration: Int,
        sourceGeneration: Int,
        loadOwner: String?,
        currentID: String?,
        currentSeason: Int?,
        currentEpisode: Int?,
        inventory: [AppleManualEpisodeNavigationCandidate],
        inventoryRefreshPending: Bool
    ) -> Decision {
        guard owns(intent, sessionID: sessionID, episodeGeneration: episodeGeneration,
                   sourceGeneration: sourceGeneration, loadOwner: loadOwner) else {
            return .unavailable
        }
        guard !inventory.isEmpty else {
            return inventoryRefreshPending ? .waitForInventory : .unavailable
        }

        let resolvedIndex = currentIndex(
            currentID: currentID,
            currentSeason: currentSeason,
            currentEpisode: currentEpisode,
            inventory: inventory
        )
        guard let resolvedIndex else {
            return inventoryRefreshPending ? .waitForInventory : .unavailable
        }

        switch intent.direction {
        case .previous:
            guard resolvedIndex > 0 else {
                return inventoryRefreshPending ? .waitForInventory : .unavailable
            }
            return .navigate(inventory[resolvedIndex - 1].id)
        case .next:
            guard resolvedIndex + 1 < inventory.count else {
                return inventoryRefreshPending ? .waitForInventory : .unavailable
            }
            return .navigate(inventory[resolvedIndex + 1].id)
        }
    }
}
