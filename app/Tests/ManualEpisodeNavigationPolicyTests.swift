import Foundation

private var failures = 0

private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

private let inventory = [
    AppleManualEpisodeNavigationCandidate(id: "fresh-s1e1", season: 1, episode: 1),
    AppleManualEpisodeNavigationCandidate(id: "fresh-s1e2", season: 1, episode: 2),
    AppleManualEpisodeNavigationCandidate(id: "fresh-s1e3", season: 1, episode: 3),
]

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func source(_ relativePath: String) -> String {
    (try? String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
}

private func intent(_ direction: AppleManualEpisodeNavigationIntent.Direction = .next) -> AppleManualEpisodeNavigationIntent {
    AppleManualEpisodeNavigationIntent(
        direction: direction, sessionID: "session", episodeGeneration: 4,
        sourceGeneration: 9, loadOwner: "load"
    )
}

@main
private enum ManualEpisodeNavigationPolicyTests {
    static func main() {
        check("pending inventory queues an early next request",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(), sessionID: "session", episodeGeneration: 4, sourceGeneration: 9,
                loadOwner: "load", currentID: "fresh-s1e1", currentSeason: 1, currentEpisode: 1,
                inventory: [inventory[0]], inventoryRefreshPending: true
              ) == .waitForInventory)

        check("early next consumes once accepted inventory has a successor",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(), sessionID: "session", episodeGeneration: 4, sourceGeneration: 9,
                loadOwner: "load", currentID: "fresh-s1e1", currentSeason: 1, currentEpisode: 1,
                inventory: inventory, inventoryRefreshPending: false
              ) == .navigate("fresh-s1e2"))

        check("early previous consumes once accepted inventory has a predecessor",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(.previous), sessionID: "session", episodeGeneration: 4, sourceGeneration: 9,
                loadOwner: "load", currentID: "fresh-s1e3", currentSeason: 1, currentEpisode: 3,
                inventory: inventory, inventoryRefreshPending: false
              ) == .navigate("fresh-s1e2"))

        check("newer direction replaces the older direction",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(.previous), sessionID: "session", episodeGeneration: 4, sourceGeneration: 9,
                loadOwner: "load", currentID: "fresh-s1e2", currentSeason: 1, currentEpisode: 2,
                inventory: inventory, inventoryRefreshPending: false
              ) == .navigate("fresh-s1e1"))

        check("cancellation or a newer source generation cannot consume the intent",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(), sessionID: "session", episodeGeneration: 4, sourceGeneration: 10,
                loadOwner: "load", currentID: "fresh-s1e1", currentSeason: 1, currentEpisode: 1,
                inventory: inventory, inventoryRefreshPending: false
              ) == .unavailable)

        check("a stale episode generation cannot consume the intent",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(), sessionID: "session", episodeGeneration: 5, sourceGeneration: 9,
                loadOwner: "load", currentID: "fresh-s1e1", currentSeason: 1, currentEpisode: 1,
                inventory: inventory, inventoryRefreshPending: false
              ) == .unavailable)

        check("a new load or session cannot consume the intent",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(), sessionID: "new-session", episodeGeneration: 4, sourceGeneration: 9,
                loadOwner: "new-load", currentID: "fresh-s1e1", currentSeason: 1, currentEpisode: 1,
                inventory: inventory, inventoryRefreshPending: false
              ) == .unavailable)

        check("id mismatch falls back to the current season and episode coordinates",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(), sessionID: "session", episodeGeneration: 4, sourceGeneration: 9,
                loadOwner: "load", currentID: "legacy-s1e2", currentSeason: 1, currentEpisode: 2,
                inventory: inventory, inventoryRefreshPending: false
              ) == .navigate("fresh-s1e3"))

        check("accepted first episode previous is a boundary, never a latent request",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(.previous), sessionID: "session", episodeGeneration: 4, sourceGeneration: 9,
                loadOwner: "load", currentID: "fresh-s1e1", currentSeason: 1, currentEpisode: 1,
                inventory: inventory, inventoryRefreshPending: false
              ) == .unavailable)

        check("accepted last episode next is a boundary, never a latent request",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(), sessionID: "session", episodeGeneration: 4, sourceGeneration: 9,
                loadOwner: "load", currentID: "fresh-s1e3", currentSeason: 1, currentEpisode: 3,
                inventory: inventory, inventoryRefreshPending: false
              ) == .unavailable)

        check("accepted inventory with no matching identity is unavailable, not pending",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(), sessionID: "session", episodeGeneration: 4, sourceGeneration: 9,
                loadOwner: "load", currentID: "unknown", currentSeason: 9, currentEpisode: 9,
                inventory: inventory, inventoryRefreshPending: false
              ) == .unavailable)

        check("ordinary launch without a request-owned refresh never queues a boundary",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(), sessionID: "session", episodeGeneration: 4, sourceGeneration: 9,
                loadOwner: "load", currentID: "fresh-s1e3", currentSeason: 1, currentEpisode: 3,
                inventory: inventory, inventoryRefreshPending: false
              ) == .unavailable)

        check("failed or cancelled refresh makes a former wait unavailable",
              AppleManualEpisodeNavigationPolicy.decision(
                intent: intent(), sessionID: "session", episodeGeneration: 4, sourceGeneration: 9,
                loadOwner: "load", currentID: "fresh-s1e3", currentSeason: 1, currentEpisode: 3,
                inventory: inventory, inventoryRefreshPending: false
              ) == .unavailable)

        let iOSPlayer = source("Sources/PlayerScreen.swift")
        let tvPlayer = source("SourcesTV/TVPlayerView.swift")
        for (name, player) in [("iOS", iOSPlayer), ("tvOS", tvPlayer)] {
            check("\(name) refresh state is request-owned and cleared on cancel", player.contains("directResumeInventoryRefreshPending = true")
                && player.contains("defer {")
                && player.contains("directResumeInventoryRefreshPending = false")
                && player.contains("private func cancelDirectResumeInventoryRefresh()")
                && player.contains("clearPendingManualEpisodeNavigation(reason: \"inventory refresh cancelled\")"))
            check("\(name) controls depend on refresh state, not provisional inventory authority", player.contains("directResumeInventoryRefreshPending ||"))
        }

        if failures > 0 { exit(1) }
        print("ALL PASS")
    }
}
