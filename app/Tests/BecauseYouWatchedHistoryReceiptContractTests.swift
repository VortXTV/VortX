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
              let sync = read(root, "app/SourcesShared/VortXSyncManager.swift"),
              let documentHistory = read(root, "app/SourcesShared/BecauseYouWatchedDocumentHistory.swift"),
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

        // Cold imported-away startup retains a Stremio slot but must stay closed until the exact
        // VortX-owned hydration receipt arrives. A later board event cannot stand in for that proof.
        var coldImportedAway = Admission()
        let coldOwnerKey = "imported-cold-owner"
        let coldPending = coldImportedAway.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: coldOwnerKey,
            snapshot: snapshot(nil, revision: 6, fields: []))
        check(coldPending == .unsettledEngine && !coldImportedAway.isReady,
              "retained imported token without a hydration receipt stays gated")
        let coldReceipt = coldImportedAway.evaluate(
            usesEngineHistory: true, activeProfileID: profileA,
            activeKeychainAccount: "stremiox.auth", ownerKey: "imported-cold-owner-ready",
            snapshot: snapshot(localOwnerA, revision: 7, fields: ["library"]))
        check(coldReceipt == .readyEngine && coldImportedAway.isReady,
              "exact local owner hydration receipt restores cold imported-away admission")

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
                bridge.contains("localHistoryRecoveryInFlight") &&
                bridge.contains("captureImportedAwayColdLocalRecoveryContext") &&
                bridge.contains("importedAwayColdLocalRecoveryReady") &&
                bridge.contains("recordOwnedHistoryHydration"),
              "CoreBridge owns the production owner-tagged history receipt")
        check(bridge.contains("lastAcceptedHistoryReceipt = nil") &&
                bridge.contains("acceptedHistoryReceiptRevision = 0") &&
                bridge.contains("fields: [\"continue_watching_preview\"]") &&
                bridge.contains("fields: [\"library\"]"),
              "receipt is cleared at boundaries and recorded only for concrete history fields")
        for (name, source) in [("tvOS", tv), ("iOS", ios)] {
            check(source.contains("acceptedLocalRecommendationHistory()") &&
                    source.contains("localSource?.receipt.owner") &&
                    source.contains("binding == nil") &&
                    !source.contains("changedFields: core.changedFields"),
                  "\(name) Home uses source-owned local history, never resident fallback")

            let providerRailsLeadHistoryGuard: Bool = {
                guard let guardRange = source.range(of: "guard let owner = historySnapshot.owner"),
                      let traktRange = source.range(of: "traktRails.refresh()"),
                      let simklRange = source.range(of: "simklRails.refresh()"),
                      let mediaServerRange = source.range(of: "mediaServerRails.refresh()") else {
                    return false
                }
                return traktRange.lowerBound < guardRange.lowerBound &&
                    simklRange.lowerBound < guardRange.lowerBound &&
                    mediaServerRange.lowerBound < guardRange.lowerBound
            }()
            check(providerRailsLeadHistoryGuard,
                  "\(name) independent provider rails refresh before personalized history admission")
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
        check(bridge.contains("VortXSyncManager.credentialScopeDidChangeNote") &&
                bridge.contains("capturedCredentialCapture: credentialCapture") &&
                bridge.contains("CredentialScopeRegistry.shared.isCurrent(credentialCapture)") &&
                bridge.contains("acceptedLocalRecommendationHistory") &&
                !bridge.contains("resetSignedOutEngineForLocalHydration") &&
                bridge.contains("await self.loadLibraryAndAwait()"),
              "history source reads retain the exact VortX credential capture")
        check(sync.contains("credentialScopeDidChangeNote") &&
                sync.contains("BecauseYouWatchedDocumentHistory.snapshot") &&
                sync.contains("library: source.library") &&
                sync.contains("continueWatching: source.continueWatching") &&
                !sync.contains("awaitLocalHistoryHydrationReset"),
              "VortX owner transitions publish a boundary and hydration receipt")
        check(bridge.contains("&& (!tokenPresent || (importedAwayFromStremio && importedAwayReady))"),
              "ordinary retained Stremio tokens cannot masquerade as local-history authority")
        check(bridge.contains("private func credentialScopeDidChange(") &&
                bridge.contains("previousScope: CredentialScope?") &&
                bridge.contains("localHistoryHydrationContext = beginLocalHistoryHydration()") &&
                !bridge.contains("previousEstablishedScope") &&
                !bridge.contains("resetSignedOutEngineForLocalHydration"),
              "account-to-guest and A-to-B transitions close history without recommendation-only resets")
        check(documentHistory.contains("DetailMetaRecoveryPolicy.catalogIDShape") &&
                documentHistory.contains("case .imdb, .tmdb, .tvdb, .kitsu") &&
                documentHistory.contains("document[\"vortx\"]") &&
                documentHistory.contains("timeOffsetSeconds * 1000") &&
                documentHistory.contains("CFGetTypeID(number)") &&
                documentHistory.contains("CFBooleanGetTypeID()") &&
                documentHistory.contains("seen.insert(item.id).inserted"),
              "document mapper validates supported identifiers and excludes resident-state fallbacks")
        check(bridge.contains("recordsHistoryReceipt: true") &&
                bridge.contains("capturedCredentialCapture: credentialCapture"),
              "library-triggered Continue Watching rebuild supplies its required receipt argument")

        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }
}
