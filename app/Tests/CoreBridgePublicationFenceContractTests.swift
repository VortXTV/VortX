// Standalone production-wiring regression contract for account/profile publication fences.
//
//   xcrun swiftc -warnings-as-errors -o /tmp/corebridge-publication-fence \
//     app/Tests/CoreBridgePublicationFenceContractTests.swift && \
//     /tmp/corebridge-publication-fence
//
// CoreBridge is linked to the Rust engine in app targets, so this executable verifies the real
// production closure wiring rather than a duplicate implementation.  The behaviour predicate is
// covered by PlaybackMutationOwnershipPolicyTests; this catches a future edit that forgets to
// carry that predicate through one of the long-lived NewState publication paths.

import Foundation

private enum Contract {
    static var failures = 0
}

private func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS  \(name)") }
    else { Contract.failures += 1; print("FAIL  \(name)") }
}

private func source(_ relativePath: String) -> String {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let candidates = [
        cwd.appendingPathComponent("app").appendingPathComponent(relativePath),
        cwd.appendingPathComponent(relativePath),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
    }
    fatalError("Run from the repository root or app directory")
}

private func section(_ source: String, from start: String, until end: String) -> String {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else { return "" }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func appearsBefore(_ needle: String, _ other: String, in source: String) -> Bool {
    guard let left = source.range(of: needle), let right = source.range(of: other) else { return false }
    return left.lowerBound < right.lowerBound
}

let bridge = source("SourcesShared/CoreBridge.swift")
let stremioCard = source("SourcesShared/StremioConnectCard.swift")
let seed = section(bridge, from: "private func seedInitialState()", until: "/// Refresh the installed-addons")
let refresh = section(bridge, from: "private func refreshAddons()", until: "/// Remove an installed addon")
let continueWatching = section(bridge, from: "func rebuildContinueWatching()", until: "/// FLOOR each engine")
let event = section(bridge, from: "fileprivate func handleEvent", until: "// MARK: meta_details coalesce")
let meta = section(bridge, from: "private func scheduleMetaDetailsRepublish()", until: "private static func appleCWMetaRefreshIsSettled")
let board = section(bridge, from: "private func scheduleBoardRebuild()", until: "private func buildBoardRows()")
let rebuild = section(bridge, from: "func rebuildBoardRows()", until: "/// The Home board rows")
let repair = section(bridge, from: "private func scheduleSessionRepair()", until: "/// Refresh installed addons")
let settlement = section(bridge, from: "private func settleAccountBindingIfProven()", until: "private func finishSettledAccountBinding()")
let finishSettlement = section(bridge, from: "private func finishSettledAccountBinding()", until: "/// Dispatch an `Action::Ctx")
let invalidation = section(bridge, from: "private func invalidatePublicationEpoch()", until: "/// ProfileStore calls")
let profileChange = section(bridge, from: "func activeProfileDidChange()", until: "private func verifyAccountBinding")
let bootstrap = section(bridge, from: "private func bootstrapAuth()", until: "/// Self-heal a stale")
let logout = section(bridge, from: "func logOut(rearmSignedOutRepair", until: "/// Clear the published")
let beginBinding = section(bridge, from: "private func beginAccountBinding", until: "private func cancelAccountBindingVerification")
let invalidateAuth = section(bridge, from: "private func invalidateAuthenticationGeneration()", until: "private func retireSignedOutRepairRequest()")
let signedOutRearm = section(bridge, from: "private func rearmSignedOutRepairWhenSafe", until: "/// Clear the published")
let importedCapture = section(bridge, from: "private func captureImportedAwayBootstrapContext", until: "/// Clear the old binding")
let publicationGate = section(bridge, from: "private var enginePublicationBlocked", until: "/// Invalidate every captured")
let localRecovery = section(bridge, from: "private func captureImportedAwayLocalRecoveryContext", until: "/// Clear the old binding")
let dispatch = section(bridge, from: "func dispatch(action:", until: "/// Compact human name")
let uninstallAddon = section(bridge, from: "func uninstallAddon(_ descriptor:", until: "/// Normalize a pasted")
let installAddon = section(bridge, from: "func installAddonConfirmed", until: "struct AddonManifestPreview")
let hydrateAddons = section(bridge, from: "func hydrateAddonsFromAccount", until: "/// stremio-core")

check(bridge.contains("private let publicationEpochLock = NSLock()")
                && bridge.contains("private func capturePublicationToken() -> PublicationToken")
                && bridge.contains("private func invalidatePublicationEpoch()"),
              "production owns a lock-backed worker-safe publication epoch")
check(!event.contains("let publicationGeneration = authBindingGeneration")
                && event.contains("let publicationToken = capturePublicationToken()"),
              "Rust NewState worker never reads main-owned auth generation")
check(appearsBefore("let bindingSettled = self.settleAccountBindingIfProven()", "guard !self.enginePublicationBlocked", in: event)
                && !event.contains("guard let self, self.publicationStillCurrent(publicationToken) else { return }\n                // `ctx` is control-plane"),
              "pending-B ctx receipt reaches identity settlement before data publication is gated")
check(settlement.contains("invalidatePublicationEpoch()")
                && invalidation.contains("continueWatchingRebuildGeneration &+= 1"),
              "settlement advances epoch and invalidates stale Continue Watching rebuilds")
check(finishSettlement.contains("let completingLegacyMigration = awaitingAuthMigration")
                && finishSettlement.contains("awaitingAuthMigration = false")
                && finishSettlement.contains("refreshFromAPI()")
                && finishSettlement.contains("ProfileStore.shared.replayPendingAccountLibraryAdds(core: self)"),
              "early PullUser ctx plus a late matching proof completes legacy migration exactly at settlement")
check(repair.contains("self.sessionRepairWork?.cancel()")
                && repair.contains("repairGeneration == self.sessionRepairGeneration")
                && repair.contains("DispatchQueue.main.asyncAfter")
                && invalidation.contains("sessionRepairWork?.cancel()")
                && invalidation.contains("sessionRepairGeneration &+= 1"),
              "stale launch repair is cancelled and only the newest context-bound timer may fire")
check(finishSettlement.contains("scheduleSessionRepair()")
                && profileChange.contains("scheduleSessionRepair()")
                && bootstrap.contains("Keychain.set(nil, for: importedAwayContext.keychainAccount)")
                && bootstrap.contains("self.scheduleSessionRepair()"),
              "settled, no-token, and imported-away logout contexts each rearm one valid repair timer")
check(finishSettlement.contains("if switchInFlight {")
                && finishSettlement.contains("switchInFlight = false")
                && finishSettlement.contains("switchFromUID = nil")
                && appearsBefore("switchInFlight = false", "scheduleSessionRepair()", in: finishSettlement),
              "proof-first legacy switch retires its gate before binding replay or repair")
check(bridge.contains("private struct SignedOutRepairRequest: Equatable")
                && logout.contains("SignedOutRepairRequest(")
                && logout.contains("publicationToken: capturePublicationToken()")
                && signedOutRearm.contains("signedOutRepairRequestStillCurrent(request)")
                && signedOutRearm.contains("signedOutRepairRequest = nil")
                && stremioCard.contains("account.signOut()")
                && stremioCard.contains("core.logOut()"),
              "explicit Stremio disconnect rearms exactly one local repair after safe engine logout")
check(beginBinding.contains("retireSignedOutRepairRequest()")
                && invalidateAuth.contains("retireSignedOutRepairRequest()")
                && invalidateAuth.contains("awaitingAuthMigration = false")
                && invalidateAuth.contains("switchInFlight = false")
                && invalidateAuth.contains("switchFromUID = nil"),
              "logout, profile changes, and rapid reconnect retire old auth gates and logout repair identity")
check(bootstrap.contains("guard let importedAwayContext = captureImportedAwayBootstrapContext()")
                && bootstrap.contains("guard self.importedAwayBootstrapStillCurrent(importedAwayContext) else { return }")
                && bootstrap.contains("Keychain.set(nil, for: importedAwayContext.keychainAccount)")
                && bootstrap.contains("captureImportedAwayLocalRecoveryContext")
                && bootstrap.contains("for _ in 0 ..< 30")
                && bootstrap.contains("importedAwayLocalRecoveryReady(localRecovery)")
                && bootstrap.contains("signed-out ctx receipt timed out")
                && !bootstrap.contains("Keychain.set(nil, for: self.activeTokenAccount)"),
              "imported-away A await is fenced to its captured profile, token slot, auth epoch, and recovery context")
check(importedCapture.contains("profileID: profile.id")
                && importedCapture.contains("keychainAccount: ProfileStore.shared.activeKeychainAccount")
                && importedCapture.contains("credentialFingerprint: Self.credentialFingerprint(token)")
                && importedCapture.contains("authGeneration: authBindingGeneration")
                && importedCapture.contains("publicationToken: capturePublicationToken()")
                && importedCapture.contains("importedAway: importedAwayFromStremio"),
              "imported-away bootstrap captures exact account identity before its await")
check(publicationGate.contains("signedOutRepairPending: signedOutRepairRequest != nil")
                && signedOutRearm.contains("signedOutRepairRequestStillCurrent(request)")
                && signedOutRearm.contains("receiptPublicationToken == request.publicationToken")
                && signedOutRearm.contains("!isLoggedIn(), currentUID() == nil")
                && signedOutRearm.contains("signedOutRepairRequest = nil")
                && signedOutRearm.contains("if request.rearmSessionRepair")
                && event.contains("if let signedOutRepairRequest = self.signedOutRepairRequest, !self.isLoggedIn()")
                && event.contains("receiptPublicationToken: publicationToken"),
              "old account data stays gated during logout until only the exact signed-out control receipt clears it")
check(localRecovery.contains("signedOutRequest: SignedOutRepairRequest")
                && localRecovery.contains("signedOutRepairRequestStillCurrent(signedOutRequest)")
                && localRecovery.contains("signedOutRepairRequest == nil")
                && localRecovery.contains("confirmedSignedOutRepairRequest == context.signedOutRequest")
                && localRecovery.contains("!isLoggedIn(), currentUID() == nil"),
              "imported-away recovery times out unless the exact logout receipt is cleared and engine identity is blank")
check(dispatch.contains("blocksAccountMutationDuringSignedOutRepair")
                && dispatch.contains("dropped account mutation pending signed-out receipt")
                && dispatch.contains("beforeDispatch?()")
                && dispatch.contains("return false")
                && dispatch.contains("return true"),
              "central engine dispatch gate rejects pending-logout account mutations while leaving overlay state local")
check(uninstallAddon.contains("let mutationToken = capturePublicationToken()")
                && uninstallAddon.contains("guard addonMutationStillAllowed(mutationToken) else { return }")
                && appearsBefore("guard addonMutationStillAllowed(mutationToken) else { return }", "AddonTombstones.tombstone", in: uninstallAddon)
                && appearsBefore("guard addonMutationStillAllowed(mutationToken) else { return }", "rawAddonsByUrl", in: uninstallAddon),
              "pending logout or unresolved binding cannot create an add-on tombstone, sync push, raw lookup, or uninstall")
check(installAddon.contains("let mutationToken = capturePublicationToken()")
                && installAddon.components(separatedBy: "addonMutationStillAllowed(mutationToken)").count >= 5
                && installAddon.contains("dispatchCtx([\"action\": \"UninstallAddon\", \"args\": existing])")
                && installAddon.contains("beforeDispatch: {")
                && installAddon.contains("AddonTombstones.forget(identityURL.absoluteString)"),
              "installer rechecks after awaits and mutates tombstones only on an accepted install dispatch")
check(hydrateAddons.contains("guard !owned.isEmpty, addonMutationStillAllowed(mutationToken) else { return }")
                && hydrateAddons.contains("if dispatchCtx([\"action\": \"InstallAddon\", \"args\": addon.installDescriptor])")
                && hydrateAddons.contains("installedCount += 1"),
              "account hydration reports only install actions accepted by the dispatch gate")
check(seed.contains("capturePublicationToken()")
                && seed.contains("publicationStillCurrent(publicationToken)")
                && seed.contains("rebuildContinueWatching(capturedPublicationToken: publicationToken)")
                && seed.contains("refreshAddons(capturedPublicationToken: publicationToken)"),
              "initial board, addon, and Continue Watching seeds retain one immutable context")
check(refresh.contains("Task { @MainActor")
                && refresh.contains("publicationStillCurrent(publicationToken)")
                && refresh.contains("AddonMetaGate.publish")
                && refresh.contains("rawAddonsByUrl = publishedRaw"),
              "ctx addon publish and delayed tombstone uninstall validate before mutation")
check(continueWatching.contains("publicationStillCurrent(publicationToken)"),
              "Continue Watching final assignment rejects a stale snapshot")
check(event.contains("scheduleBoardRebuild(capturedPublicationToken: publicationToken)")
                && event.contains("scheduleMetaDetailsRepublish(capturedPublicationToken: publicationToken)")
                && event.contains("refreshAddons(capturedPublicationToken: publicationToken)")
                && event.contains("self.library = value")
                && event.contains("self.discover = value"),
              "account-scoped event branches pass one token into each downstream publisher")
check(event.contains("guard let self, self.publicationStillCurrent(publicationToken), self.searchLoaded else { return }")
                && event.contains("self.loadSearchRange()"),
              "ctx search-range redispatch is dropped for stale or blocked account context")
check(event.contains("guard let self, self.publicationStillCurrent(publicationToken) else { return }\n                    guard fingerprint != self.discoverPublishedFingerprint")
                && event.contains("self.discoverPublishedFingerprint = fingerprint"),
              "Discover fingerprint mutation is main-gated by the captured publication token")
check(meta.contains("publicationStillCurrent(publicationToken)")
                && meta.contains("self.metaDetailsWork?.cancel()"),
              "meta-details coalescer checks the token at schedule and final publication")
check(board.contains("publicationStillCurrent(publicationToken)")
                && board.contains("self.boardRebuildWork?.cancel()")
                && board.contains("self.boardRows = rows"),
              "board debounce/background/final assignment cannot publish after replacement")
check(rebuild.contains("capturePublicationToken()")
                && rebuild.contains("publicationStillCurrent(publicationToken)"),
              "direct library-derived board rebuild validates its captured context")
check(repair.contains("let publicationToken = capturePublicationToken()")
                && repair.contains("await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()")
                && repair.components(separatedBy: "publicationStillCurrent(publicationToken)").count >= 3,
              "14-second recovery validates before and after awaited account hydration")

if Contract.failures > 0 { exit(1) }
