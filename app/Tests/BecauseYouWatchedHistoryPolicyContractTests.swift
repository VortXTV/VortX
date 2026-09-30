// Deterministic policy proof for the Apple Home recommendation owner boundary.
//
// Run from repository root:
//   swiftc -parse-as-library -warnings-as-errors -o /tmp/because-you-watched-history-policy \
//     app/Tests/BecauseYouWatchedHistoryPolicyContractTests.swift && \
//   /tmp/because-you-watched-history-policy .

import Foundation

private struct Owner: Equatable {
    let profileID: UUID
    let keychainAccount: String
    let uid: String
    let generation: UInt64
}

private struct Snapshot {
    let owner: Owner?
    let revision: Int
    let changedFields: Set<String>
}

/// A tiny deterministic stand-in for the model's owner/revision latch. It intentionally records both
/// network launches and a generation-fenced delayed completion so this test proves behavior, not only
/// source spelling. The production policy is source-checked below because the full Home model also owns
/// SwiftUI, TMDB, and Core model dependencies.
private struct RecommendationHarness {
    private(set) var rail: [String] = ["A-recommendation"]
    private(set) var networkLaunches = 0
    private(set) var generation: UInt64 = 1
    private var owner: Owner?
    private var baselineRevision: Int?
    private var ready = false

    mutating func refresh(
        usesEngineHistory: Bool,
        activeProfileID: UUID?,
        activeKeychainAccount: String,
        snapshot: Snapshot?,
        seeds: [String]
    ) -> UInt64? {
        let ownerChanged = owner != snapshot?.owner
        if ownerChanged {
            generation &+= 1
            owner = snapshot?.owner
            baselineRevision = snapshot?.revision
            ready = false
            rail = []
        }

        if !usesEngineHistory {
            ready = true
        } else {
            guard let snapshot, let owner = snapshot.owner,
                  owner.profileID == activeProfileID,
                  owner.keychainAccount == activeKeychainAccount else {
                ready = false
                rail = []
                return nil
            }
            if !ready,
               let baselineRevision,
               snapshot.revision > baselineRevision,
               !snapshot.changedFields.isDisjoint(with: ["library", "continue_watching_preview"]) {
                ready = true
            }
            guard ready else {
                rail = []
                return nil
            }
        }

        guard !seeds.isEmpty else {
            rail = []
            return nil
        }
        networkLaunches += 1
        rail = ["fresh-recommendation"]
        return generation
    }

    mutating func complete(generation completedGeneration: UInt64, cards: [String]) {
        guard completedGeneration == generation else { return }
        rail = cards
    }
}

@main
private struct BecauseYouWatchedHistoryPolicyContractTests {
    private static var failures = 0

    private static func check(_ condition: Bool, _ name: String) {
        if condition { print("PASS  \(name)") }
        else { failures += 1; print("FAIL  \(name)") }
    }

    private static func read(_ root: String, _ relativePath: String) -> String? {
        let path = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
        return try? String(contentsOf: path, encoding: .utf8)
    }

    static func main() {
        let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
        guard let model = read(root, "app/SourcesShared/BecauseYouWatchedModel.swift"),
              let tv = read(root, "app/SourcesTV/HomeView.swift"),
              let ios = read(root, "app/SourcesiOS/iOSRootView.swift") else {
            print("FAIL  could not read Apple recommendation sources")
            exit(1)
        }

        check(model.contains("enum BecauseYouWatchedHistoryPolicy") &&
                model.contains("case awaitingHistorySnapshot") &&
                model.contains("snapshot.revision > minimumRevision") &&
                model.contains("historyFields"),
              "production policy requires a post-boundary published history revision")
        check(model.contains("historyInputReady = false") &&
                model.contains("loadTask?.cancel()") &&
                model.contains("rail = nil"),
              "unsettled engine input retires the rail and cancels recommendation work")
        for (name, source) in [("tvOS", tv), ("iOS", ios)] {
            check(source.contains("BecauseYouWatchedHistoryPolicy.Snapshot"),
                  "\(name) Home carries a settled-owner history snapshot")
            check(source.contains("owner.profileID == profiles.activeID") &&
                    source.contains("owner.keychainAccount == activeKeychainAccount") &&
                    source.contains("becauseYouWatched.clear()"),
                  "\(name) Home clears and returns while the engine owner is unsettled")
            check(source.contains("historySnapshot: historySnapshot") &&
                    source.contains("if becauseYouWatched.historyInputReady"),
                  "\(name) Home gates recommendation consumers on the same history proof")
        }
        check(ios.contains(".onChange(of: core.revision) { _ in") &&
                ios.contains("core.changedFields.contains(\"continue_watching_preview\")"),
              "iOS Home retries on the published history receipt rather than every engine revision")

        let profileA = UUID()
        let profileB = UUID()
        let ownerA = Owner(profileID: profileA, keychainAccount: "stremiox.auth",
                           uid: "A-uid", generation: 10)
        let ownerB = Owner(profileID: profileB, keychainAccount: "stremiox.auth",
                           uid: "B-uid", generation: 11)
        let history = Set(["library"])
        var harness = RecommendationHarness()

        // Establish an A rail, then replace it with B's email while the binding is nil. The old A UID
        // is deliberately absent from the snapshot, so no seed/network work may cross that gap.
        _ = harness.refresh(usesEngineHistory: true, activeProfileID: profileA,
                            activeKeychainAccount: "stremiox.auth",
                            snapshot: Snapshot(owner: ownerA, revision: 100, changedFields: []),
                            seeds: ["ttA"])
        let aLaunch = harness.refresh(usesEngineHistory: true, activeProfileID: profileA,
                                      activeKeychainAccount: "stremiox.auth",
                                      snapshot: Snapshot(owner: ownerA, revision: 101, changedFields: history),
                                      seeds: ["ttA"])
        check(harness.networkLaunches == 1 && !harness.rail.isEmpty,
              "a settled owner becomes eligible only after its history publication")
        let delayedA = harness.refresh(usesEngineHistory: true, activeProfileID: profileB,
                                       activeKeychainAccount: "stremiox.auth",
                                       snapshot: Snapshot(owner: nil, revision: 102, changedFields: []),
                                       seeds: ["ttA"])
        check(delayedA == nil && harness.networkLaunches == 1 && harness.rail.isEmpty,
              "B email plus resident A history with nil binding clears without network or seeds")

        // A late A completion cannot repopulate the cleared rail after the B boundary.
        harness.complete(generation: aLaunch ?? 0, cards: ["late-A"])
        check(harness.rail.isEmpty,
              "late A recommendation completion cannot rebuild the post-switch rail")

        // A valid B binding still waits for B's own published library/CW receipt, then is allowed.
        _ = harness.refresh(usesEngineHistory: true, activeProfileID: profileB,
                            activeKeychainAccount: "stremiox.auth",
                            snapshot: Snapshot(owner: ownerB, revision: 103, changedFields: []),
                            seeds: ["ttB"])
        let bLaunch = harness.refresh(usesEngineHistory: true, activeProfileID: profileB,
                                      activeKeychainAccount: "stremiox.auth",
                                      snapshot: Snapshot(owner: ownerB, revision: 104, changedFields: history),
                                      seeds: ["ttB"])
        check(bLaunch != nil && harness.networkLaunches == 2,
              "exact settled B owner plus a fresh history receipt is allowed")

        // Overlay history is already profile-scoped and remains available without any Stremio binding.
        let overlayLaunch = harness.refresh(usesEngineHistory: false, activeProfileID: profileB,
                                            activeKeychainAccount: "stremiox.auth", snapshot: nil,
                                            seeds: ["local-overlay"])
        check(overlayLaunch != nil && harness.networkLaunches == 3,
              "overlay local history remains usable without Stremio login")

        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }
}
