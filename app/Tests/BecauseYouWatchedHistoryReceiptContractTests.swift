// Production-state proof for the owner-tagged Apple Home history receipt.
//
// Run from repository root:
//   swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/because-you-watched-history-receipt \
//     app/SourcesShared/BecauseYouWatchedHistoryPolicy.swift \
//     app/Tests/BecauseYouWatchedHistoryReceiptContractTests.swift && \
//   /tmp/because-you-watched-history-receipt .

import Foundation

@main
@MainActor
private struct BecauseYouWatchedHistoryReceiptContractTests {
    private typealias Policy = BecauseYouWatchedHistoryPolicy
    private typealias Admission = BecauseYouWatchedHistoryAdmission
    private static var failures = 0

    private static func check(_ condition: Bool, _ name: String) {
        if condition { print("PASS  \(name)") }
        else { failures += 1; print("FAIL  \(name)") }
    }

    private static func read(_ root: String, _ path: String) -> String? {
        try? String(
            contentsOf: URL(fileURLWithPath: root).appendingPathComponent(path),
            encoding: .utf8)
    }

    private static func snapshot(
        _ owner: Policy.Owner?, revision: Int, fields: Set<String> = []) -> Policy.Snapshot {
        .init(owner: owner, revision: revision, changedFields: fields)
    }

    static func main() {
        let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
        guard let policy = read(root, "app/SourcesShared/BecauseYouWatchedHistoryPolicy.swift"),
              let bridge = read(root, "app/SourcesShared/CoreBridge.swift"),
              let account = read(root, "app/SourcesShared/StremioAccount.swift"),
              let tv = read(root, "app/SourcesTV/HomeView.swift"),
              let ios = read(root, "app/SourcesiOS/iOSRootView.swift") else {
            print("FAIL  could not read history-receipt sources")
            exit(1)
        }

        let history = Set(["library"])
        let profileA = UUID()
        let profileB = UUID()
        let ownerA = Policy.Owner(profileID: profileA, keychainAccount: "stremiox.auth",
                                  uid: "uid-a", generation: 10)
        let ownerB = Policy.Owner(profileID: profileB, keychainAccount: "stremiox.auth",
                                  uid: "uid-b", generation: 11)
        let localOwnerA = Policy.Owner(profileID: profileA, keychainAccount: "stremiox.auth",
                                       uid: nil, generation: 12)

        // Home first appears after the owner library receipt and an unrelated board event. The
        // durable receipt remains the input even though the engine's latest changedFields would be board.
        let durableA = snapshot(ownerA, revision: 1, fields: history)
        var initialAfterBoard = Admission()
        let initialDecision = initialAfterBoard.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "binding-a",
            snapshot: durableA)
        check(initialDecision == .readyEngine && initialAfterBoard.isReady,
              "history receipt admits Home after an unrelated board event")

        let boardAfterReceipt = initialAfterBoard.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "binding-a",
            snapshot: durableA)
        check(boardAfterReceipt == .readyEngine && initialAfterBoard.isReady,
              "latest board/meta state cannot erase the durable owner receipt")

        // A clear while B is unsettled must make the first exact B history publication sufficient. A
        // subsequent board event is represented by the same durable B receipt, not by raw changedFields.
        var clearedForB = Admission()
        _ = clearedForB.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "binding-a",
            snapshot: durableA)
        let oldCompletion = clearedForB.generation
        clearedForB.retireForUnsettledHistory(ownerKey: "binding-b-pending", snapshot: nil)
        check(!clearedForB.isReady && !clearedForB.isCurrent(oldCompletion),
              "clearing for B retires the old recommendation completion")
        let firstB = snapshot(ownerB, revision: 1, fields: history)
        let firstBDecision = clearedForB.evaluate(
            usesEngineHistory: true, activeProfileID: profileB,
            activeKeychainAccount: "stremiox.auth", ownerKey: "binding-b",
            snapshot: firstB)
        check(firstBDecision == .readyEngine && clearedForB.isReady,
              "first exact B history publication restores admission")
        let afterBBoard = clearedForB.evaluate(
            usesEngineHistory: true, activeProfileID: profileB,
            activeKeychainAccount: "stremiox.auth", ownerKey: "binding-b",
            snapshot: firstB)
        check(afterBBoard == .readyEngine && clearedForB.isReady,
              "B remains admitted after a later unrelated board event")

        // An old A receipt must not be relabelled as B while the selected binding is pending or settled.
        var staleA = Admission()
        _ = staleA.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "binding-a",
            snapshot: durableA)
        staleA.retireForUnsettledHistory(ownerKey: "binding-b-pending", snapshot: nil)
        let staleDecision = staleA.evaluate(
            usesEngineHistory: true, activeProfileID: profileB,
            activeKeychainAccount: "stremiox.auth", ownerKey: "binding-b",
            snapshot: snapshot(ownerA, revision: 2, fields: history))
        check(staleDecision == .awaitingHistorySnapshot && !staleA.isReady,
              "old A receipt never admits B")

        // Signed-out/imported-away owner history is an explicit local authority. A nil UID is not a
        // wildcard: a different local generation is a different owner and cannot reuse the old receipt.
        var localAdmission = Admission()
        let localDecision = localAdmission.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "local-owner-12",
            snapshot: snapshot(localOwnerA, revision: 3, fields: history))
        check(localOwnerA.uid == nil && localDecision == .readyEngine && localAdmission.isReady,
              "explicit nil-UID local owner receipt admits signed-out history")
        let oldLocalGeneration = localAdmission.generation
        let localOwnerB = Policy.Owner(profileID: profileA, keychainAccount: "stremiox.auth",
                                       uid: nil, generation: 13)
        localAdmission.retireForUnsettledHistory(ownerKey: "local-owner-13-pending", snapshot: nil)
        let staleLocal = localAdmission.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "local-owner-13",
            snapshot: snapshot(localOwnerA, revision: 4, fields: history))
        check(!localAdmission.isCurrent(oldLocalGeneration) &&
                staleLocal == .awaitingHistorySnapshot && !localAdmission.isReady,
              "old local owner receipt cannot cross a local authority generation")
        let localReplacement = localAdmission.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "local-owner-13",
            snapshot: snapshot(localOwnerB, revision: 5, fields: history))
        check(localReplacement == .readyEngine && localAdmission.isReady,
              "new local owner receipt restores admission after a local boundary")

        // Production source contracts: only accepted decoded account history creates the durable
        // receipt; epoch/profile resets clear it; Home consumes it instead of raw changedFields; and
        // auth awaits carry an exact non-secret owner context.
        check(policy.contains("struct BecauseYouWatchedHistoryAdmission") &&
                bridge.contains("lastAcceptedHistoryReceipt") &&
                bridge.contains("acceptedHistoryReceiptRevision") &&
                bridge.contains("recordAcceptedHistoryReceipt") &&
                bridge.contains("settledActiveAccountBinding()") &&
                bridge.contains("func settledLocalHistoryOwner()") &&
                bridge.contains("CredentialScopeRegistry.shared.capture()") &&
                bridge.contains("isMigrationEligible(credentialCapture)") &&
                bridge.contains("localHistoryRecoveryInFlight"),
              "CoreBridge owns the production owner-tagged history receipt")
        check(bridge.contains("lastAcceptedHistoryReceipt = nil") &&
                bridge.contains("acceptedHistoryReceiptRevision = 0") &&
                bridge.contains("fields: [\"continue_watching_preview\"]") &&
                bridge.contains("fields: [\"library\"]"),
              "receipt is cleared at boundaries and recorded only for concrete history fields")
        for (name, source) in [("tvOS", tv), ("iOS", ios)] {
            check(source.contains("let receipt = core.lastAcceptedHistoryReceipt") &&
                    source.contains("let localOwner = core.settledLocalHistoryOwner()") &&
                    source.contains("owner: validReceipt?.owner ?? binding.map") &&
                    source.contains("?? localOwner") &&
                    source.contains("changedFields: validReceipt?.changedFields ?? []") &&
                    source.contains("onChange(of: core.lastAcceptedHistoryReceipt?.revision)") &&
                    !source.contains("changedFields: core.changedFields"),
                  "\(name) Home uses the durable receipt, never latest changedFields")
        }
        check(account.contains("struct AuthOperationContext") &&
                account.contains("authOperationStillCurrent(context)") &&
                account.contains("Keychain.set(key, for: context.keychainAccount)") &&
                account.contains("await loadAddons(for: context)") &&
                account.contains("await backfillEmail(for: context)"),
              "Stremio auth validates the initiating profile across awaited writes")
        let boundarySource: String = {
            guard let start = account.range(of: "private func publishCredentialBoundary"),
                  let end = account.range(of: "credentialBoundaryGeneration = generation",
                                          range: start.lowerBound..<account.endIndex) else { return "" }
            return String(account[start.lowerBound..<end.upperBound])
        }()
        check(boundarySource.contains("\"profileID\": ProfileStore.shared.active?.id.uuidString") &&
                boundarySource.contains("\"keychainAccount\": ProfileStore.shared.activeKeychainAccount") &&
                !boundarySource.contains("authKey") &&
                !boundarySource.contains("email"),
              "credential boundary carries only non-secret owner identity")
        check(bridge.contains("let eventProfileID = note.userInfo?[\"profileID\"] as? String") &&
                bridge.contains("eventProfileID == ProfileStore.shared.active?.id.uuidString") &&
                bridge.contains("eventKeychainAccount == ProfileStore.shared.activeKeychainAccount"),
              "CoreBridge rejects a delayed credential event for another selected owner")

        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }
}
