import Foundation

// Minimal dependency fixture for the standalone owner-history executable.
struct CredentialScope: Hashable {
    let keychainOwnerID: String
    init?(canonicalRemoteAccountID: String) {
        guard !canonicalRemoteAccountID.isEmpty else { return nil }
        keychainOwnerID = canonicalRemoteAccountID
    }
}

final class CredentialScopeRegistry: @unchecked Sendable {
    static let shared = CredentialScopeRegistry()
    var owner = "fixture"
    struct Capture: Hashable { let scope: CredentialScope; let generation: UInt64 }
    var generation: UInt64 = 0
    func capture() -> Capture { Capture(scope: CredentialScope(canonicalRemoteAccountID: owner)!, generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool {
        capture.scope.keychainOwnerID == owner && capture.generation == generation
    }
}

@main
enum OwnerHistoryStoreTests {
    static func row(
        id: String = "tt-history", type: String = "movie", name: String = "History",
        v: String = "tt-history", t: Double = 0, d: Double = 120,
        event: Double, extra: [String: Any] = [:]
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": id, "type": type, "name": name, "poster": "p", "v": v,
            "t": t, "d": d, "lastWatched": "2026-10-01T12:00:00.000Z", "eventEpochMs": event
        ]
        for (key, item) in extra { value[key] = item }
        return value
    }

    static func main() {
        let owner = "owner-history-test-" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "vortx.owner.history.v1." + owner) }
        CredentialScopeRegistry.shared.owner = owner
        OwnerHistoryStore.bind(ownerID: owner)

        // A genuine zero-position progress event is still history, and no membership API exists here.
        MainActor.assumeIsolated {
            precondition(OwnerHistoryStore.recordPlayback(titleID: "tt-history", type: "movie", name: "History",
                poster: nil, videoID: "tt-history", positionSeconds: 0, durationSeconds: 120))
        }
        precondition(OwnerHistoryStore.validRows().count == 1,
                     "accepted actual playback creates one local row even at zero position")

        let local = OwnerHistoryStore.validRows().first!
        let localClock = (local["eventEpochMs"] as! NSNumber).doubleValue
        let equalPeer = row(event: localClock, extra: [
            "androidOnly": "keep-me", "watched": "android-opaque-marker",
            "currentVideoWatched": true, "wholeTitleWatched": NSNull(), "timesWatched": 2
        ])
        let unknown = ["futureSchema": ["opaque": true]] as [String: Any]
        let exported = OwnerHistoryStore.wire(merging: [equalPeer, unknown]) ?? []
        precondition(exported.contains { ($0["androidOnly"] as? String) == "keep-me" },
                     "equal-clock peer representation wins and keeps unknown future fields")
        precondition(exported.contains { ($0["watched"] as? String) == "android-opaque-marker" },
                     "Android opaque watched string and nullable typed flags remain interoperable")
        precondition(exported.contains { $0["futureSchema"] != nil },
                     "opaque malformed/unknown peer row survives export")

        let malformed = ["id": "tt-history", "type": "movie", "eventEpochMs": 9_999] as [String: Any]
        precondition(!OwnerHistoryStore.mergeWire([malformed]),
                     "malformed remote section cannot erase or replace valid local history")
        precondition(OwnerHistoryStore.validRows().count == 1,
                     "failed/malformed merge preserves valid local cache")

        let newer = row(t: 55, event: localClock + 100)
        precondition(OwnerHistoryStore.mergeWire([newer]), "newer real event merges")
        precondition((OwnerHistoryStore.validRows().first?["t"] as? NSNumber)?.doubleValue == 55,
                     "newer peer position wins atomically")

        // Identity is typed: the same catalog id in a different supported type is not silently lost.
        let series = row(id: "tt-history", type: "series", v: "tt-history:1:1", t: 10, event: localClock + 200)
        precondition(OwnerHistoryStore.mergeWire([series]), "typed same-id row is retained")
        precondition(OwnerHistoryStore.validRows().count == 2, "movie and series identities remain distinct")

        let mixed: [Any] = [row(event: localClock + 300), "future-non-object-row"]
        precondition(OwnerHistoryStore.wire(merging: mixed) == nil,
                     "mixed peer carrier is never replaced by a local subset")
        let oversized = (0...10_000).map { row(id: "tt-overflow-\($0)", event: localClock + 400 + Double($0)) }
        precondition(OwnerHistoryStore.wire(merging: oversized) == nil,
                     "over-limit peer carrier is preserved rather than rewritten")

        let staleSameAccountCapture = CredentialScopeRegistry.shared.capture()
        CredentialScopeRegistry.shared.generation += 1
        MainActor.assumeIsolated {
            precondition(!OwnerHistoryStore.recordPlayback(titleID: "tt-stale", type: "movie", name: "Stale",
                poster: nil, videoID: "tt-stale", positionSeconds: 1, durationSeconds: 120,
                capture: staleSameAccountCapture),
                "same-account credential rotation rejects a delayed player session")
        }

        CredentialScopeRegistry.shared.owner = "other-owner"
        CredentialScopeRegistry.shared.generation += 1
        precondition(!OwnerHistoryStore.mergeWire([row(event: localClock + 300)]),
                     "account switch rejects delayed old-owner remote apply")
        print("Owner history store tests passed")
    }
}
