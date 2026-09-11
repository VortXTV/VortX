import Foundation

// Minimal dependency fixture for the standalone store-policy executable.
struct CredentialScope {
    let keychainOwnerID: String
    init?(canonicalRemoteAccountID: String) { guard !canonicalRemoteAccountID.isEmpty else { return nil }; keychainOwnerID = canonicalRemoteAccountID }
}
final class CredentialScopeRegistry {
    static let shared = CredentialScopeRegistry()
    var owner = "fixture"
    struct Capture { let scope: CredentialScope }
    func capture() -> Capture { Capture(scope: CredentialScope(canonicalRemoteAccountID: owner)!) }
    func isCurrent(_ capture: Capture) -> Bool { true }
}

@main
enum OwnerWatchedIntentStoreTests {
    static func row(_ title: String, _ video: String, _ watched: Bool, _ at: Double, _ actor: String) -> [String: Any] {
        ["t": title, "v": video, "w": watched, "u": at, "a": actor]
    }
    static func main() {
        let owner = "owner-watch-test-" + UUID().uuidString
        CredentialScopeRegistry.shared.owner = owner
        MainActor.assumeIsolated { OwnerWatchedIntentStore.bind(ownerID: owner) }
        precondition(OwnerWatchedIntentStore.mergeWire(["old": row("tt1", "tt1:1:1", true, 100, "a")]))
        precondition(OwnerWatchedIntentStore.watchedVideoIDs(forTitle: "tt1") == ["tt1:1:1"])
        // Newer explicit unwatch wins and a delayed old delivery cannot resurrect it.
        precondition(OwnerWatchedIntentStore.mergeWire(["new": row("tt1", "tt1:1:1", false, 200, "b")]))
        precondition(OwnerWatchedIntentStore.watchedVideoIDs(forTitle: "tt1").isEmpty)
        _ = OwnerWatchedIntentStore.mergeWire(["old": row("tt1", "tt1:1:1", true, 100, "a")])
        precondition(OwnerWatchedIntentStore.watchedVideoIDs(forTitle: "tt1").isEmpty)
        // Exact title operation overrides a stale engine title badge; another title remains isolated.
        _ = OwnerWatchedIntentStore.mergeWire(["title": row("tt1", "tt1", false, 300, "b"),
                                                "other": row("tt2", "tt2", true, 300, "b")])
        precondition(OwnerWatchedIntentStore.effectiveTitleIDs(engine: ["tt1"]) == ["tt2"])
        // Whole-title false clears stale engine/older episode state; a later exact rewatch wins.
        let title = "tt-series"
        _ = OwnerWatchedIntentStore.mergeWire([
            "oldEpisode": row(title, "tt-series:1:1", true, 10, "a"),
            "wholeOff": row(title, title, false, 20, "a")
        ])
        precondition(OwnerWatchedIntentStore.effectiveVideoIDs(forTitle: title,
            engine: ["tt-series:1:1", "tt-series:1:2"], knownVideoIDs: ["tt-series:1:1", "tt-series:1:2"]).isEmpty)
        _ = OwnerWatchedIntentStore.mergeWire(["newEpisode": row(title, "tt-series:1:2", true, 30, "a")])
        precondition(OwnerWatchedIntentStore.effectiveVideoIDs(forTitle: title, engine: [],
            knownVideoIDs: ["tt-series:1:1", "tt-series:1:2"]) == ["tt-series:1:2"])
        _ = OwnerWatchedIntentStore.mergeWire(["wholeOn": row(title, title, true, 40, "a")])
        precondition(OwnerWatchedIntentStore.effectiveVideoIDs(forTitle: title, engine: [],
            knownVideoIDs: ["tt-series:1:1", "tt-series:1:2"]) == ["tt-series:1:1", "tt-series:1:2"])
        // Registry can switch before the next owner bind. The previous account's cached snapshot
        // must be invisible in that interval rather than leaking watched badges across accounts.
        CredentialScopeRegistry.shared.owner = "different-owner-" + UUID().uuidString
        precondition(OwnerWatchedIntentStore.watchedVideoIDs(forTitle: "tt1").isEmpty,
                     "unbound registry switch hides the previous owner snapshot")
        print("Owner watched intent store tests passed")
    }
}
