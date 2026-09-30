// Deterministic policy proof for the Apple Home recommendation owner boundary.
//
// Run from repository root:
//   swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/because-you-watched-history-policy \
//     app/SourcesShared/BecauseYouWatchedHistoryPolicy.swift \
//     app/Tests/BecauseYouWatchedHistoryPolicyContractTests.swift && \
//   /tmp/because-you-watched-history-policy .

import Foundation

@main
@MainActor
private struct BecauseYouWatchedHistoryPolicyContractTests {
    private typealias Policy = BecauseYouWatchedHistoryPolicy
    private typealias Admission = BecauseYouWatchedHistoryAdmission
    private static var failures = 0

    private static func check(_ condition: Bool, _ name: String) {
        if condition { print("PASS  \(name)") }
        else { failures += 1; print("FAIL  \(name)") }
    }

    private static func read(_ root: String, _ relativePath: String) -> String? {
        let path = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
        return try? String(contentsOf: path, encoding: .utf8)
    }

    private static func snapshot(
        _ owner: Policy.Owner?,
        revision: Int,
        changedFields: Set<String> = []
    ) -> Policy.Snapshot {
        .init(owner: owner, revision: revision, changedFields: changedFields)
    }

    static func main() {
        let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
        guard let policySource = read(root, "app/SourcesShared/BecauseYouWatchedHistoryPolicy.swift"),
              let model = read(root, "app/SourcesShared/BecauseYouWatchedModel.swift"),
              let tv = read(root, "app/SourcesTV/HomeView.swift"),
              let ios = read(root, "app/SourcesiOS/iOSRootView.swift") else {
            print("FAIL  could not read Apple recommendation sources")
            exit(1)
        }

        check(policySource.contains("enum BecauseYouWatchedHistoryPolicy") &&
                policySource.contains("struct BecauseYouWatchedHistoryAdmission") &&
                policySource.contains("acceptsFirstCurrentOwnerReceipt") &&
                policySource.contains("retireForUnsettledHistory"),
              "production policy and owner/revision admission state are Foundation-only and reusable")
        check(model.contains("historyAdmission.evaluate") &&
                model.contains("historyInputReady = historyAdmission.isReady") &&
                model.contains("historyAdmission.isCurrent(admissionGeneration)") &&
                model.contains("retireRecommendationWork()") &&
                model.contains("func retireForUnsettledHistory"),
              "BecauseYouWatchedModel consumes the production admission state")

        for (name, source) in [("tvOS", tv), ("iOS", ios)] {
            check(source.contains("BecauseYouWatchedHistoryPolicy.Snapshot"),
                  "\(name) Home carries a settled-owner history snapshot")
            check(source.contains("owner.profileID == profiles.activeID") &&
                    source.contains("owner.keychainAccount == activeKeychainAccount") &&
                    source.contains("becauseYouWatched.retireForUnsettledHistory"),
                  "\(name) Home preserves the admission boundary while engine ownership is unsettled")
            check(source.contains("historySnapshot: historySnapshot") &&
                    source.contains("if becauseYouWatched.historyInputReady") &&
                    source.contains("account.$credentialBoundaryGeneration"),
                  "\(name) Home gates consumers and observes same-slot account boundaries")
        }
        check(ios.contains(".onChange(of: core.revision) { _ in") &&
                ios.contains("core.changedFields.contains(\"continue_watching_preview\")"),
              "iOS Home retries on the published history receipt rather than every engine revision")

        let profileA = UUID()
        let profileB = UUID()
        let ownerA = Policy.Owner(profileID: profileA, keychainAccount: "stremiox.auth",
                                  uid: "A-uid", generation: 10)
        let ownerB = Policy.Owner(profileID: profileB, keychainAccount: "stremiox.auth",
                                  uid: "B-uid", generation: 11)
        let ownerBForSameSlot = Policy.Owner(profileID: profileA, keychainAccount: "stremiox.auth",
                                             uid: "B-uid", generation: 11)
        let history = Set(["library"])

        // Initial Home appearance: a current owner plus its first history receipt is immediately usable;
        // an unrelated second engine event is not required.
        var initial = Admission()
        let initialDecision = initial.evaluate(
            usesEngineHistory: true, activeProfileID: profileB,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-b-binding",
            snapshot: snapshot(ownerB, revision: 10, changedFields: history)
        )
        check(initialDecision == .readyEngine && initial.isReady,
              "initial exact owner plus first history receipt is immediately usable")

        // Establish an A owner and deliberately retain a delayed completion token. An unsettled clear
        // must retire that token and keep the old owner from being relabelled as B.
        var admission = Admission()
        _ = admission.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-a",
            snapshot: snapshot(ownerA, revision: 100)
        )
        let aDecision = admission.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-a",
            snapshot: snapshot(ownerA, revision: 101, changedFields: history)
        )
        let delayedA = admission.generation
        check(aDecision == .readyEngine && admission.isReady,
              "a settled owner becomes eligible only after its history publication")

        admission.retireForUnsettledHistory(ownerKey: "account-b-pending", snapshot: nil)
        check(!admission.isReady && !admission.isCurrent(delayedA),
              "unsettled clear retires the delayed A completion immediately")

        let staleA = admission.evaluate(
            usesEngineHistory: true, activeProfileID: profileB,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-b-pending",
            snapshot: snapshot(ownerA, revision: 102, changedFields: history)
        )
        check(staleA == .awaitingHistorySnapshot && !admission.isReady,
              "resident A history cannot be relabelled as B while binding is pending")

        // The first exact B receipt is allowed even when it shares the boundary revision with the clear.
        let bDecision = admission.evaluate(
            usesEngineHistory: true, activeProfileID: profileB,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-b-binding",
            snapshot: snapshot(ownerB, revision: 102, changedFields: history)
        )
        check(bDecision == .readyEngine && admission.isReady,
              "first exact B history receipt after a clear restores admission without a second tick")

        // Same-slot true -> true replacement: the non-secret owner key changes while the old binding is
        // still visible. The exact old owner is held pending, and only B's bound receipt can reopen it.
        var sameSlot = Admission()
        _ = sameSlot.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-a",
            snapshot: snapshot(ownerA, revision: 200)
        )
        _ = sameSlot.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-a",
            snapshot: snapshot(ownerA, revision: 201, changedFields: history)
        )
        let replacement = sameSlot.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-b-email",
            snapshot: snapshot(ownerA, revision: 202, changedFields: history)
        )
        check(replacement == .awaitingHistorySnapshot && !sameSlot.isReady,
              "same-slot owner replacement blocks the resident A receipt")
        let duplicateOld = sameSlot.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-b-email",
            snapshot: snapshot(ownerA, revision: 203, changedFields: history)
        )
        check(duplicateOld == .awaitingHistorySnapshot && !sameSlot.isReady,
              "repeated old-owner receipts do not advance the replacement latch")
        let replacementReady = sameSlot.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-b-binding",
            snapshot: snapshot(ownerBForSameSlot, revision: 204, changedFields: history)
        )
        check(replacementReady == .readyEngine && sameSlot.isReady,
              "same-slot replacement opens only after the exact B binding receipt")

        // A ready-owner mismatch must invalidate old work, and the next valid current-owner receipt must
        // restore historyInputReady rather than leaving the model permanently latched false.
        let beforeMismatch = sameSlot.generation
        let mismatch = sameSlot.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-b-binding",
            snapshot: snapshot(nil, revision: 205)
        )
        check(mismatch == .unsettledEngine && !sameSlot.isReady && sameSlot.generation > beforeMismatch,
              "ready-owner mismatch invalidates the admission generation")
        let recovered = sameSlot.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "account-b-binding",
            snapshot: snapshot(ownerBForSameSlot, revision: 205, changedFields: history)
        )
        check(recovered == .readyEngine && sameSlot.isReady,
              "a valid receipt after mismatch restores readiness")

        var overlay = Admission()
        let overlayDecision = overlay.evaluate(
            usesEngineHistory: false, activeProfileID: profileB,
            activeKeychainAccount: "stremiox.auth", ownerKey: "overlay",
            snapshot: nil
        )
        check(overlayDecision == .overlay && overlay.isReady,
              "overlay local history remains usable without Stremio login")

        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }
}
