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
let accountSource = source("SourcesShared/StremioAccount.swift")
let syncSource = source("SourcesShared/VortXSyncManager.swift")
let nativeIngress = section(syncSource, from: "private static func decodeDecryptedSyncDocument", until: "/// DEPRECATED single-state pull")
check(nativeIngress.contains("VortxProfileOverlayWitness.decodeObject(json: plaintext)")
      && syncSource.components(separatedBy: "Self.decodeDecryptedSyncDocument(pt)").count == 4,
      "all decrypted native pull paths reject original duplicate/unsafe numeric JSON before Foundation projection")
let profileSource = source("SourcesShared/Profiles.swift")
let autoAddSource = source("SourcesShared/LibraryAutoAdd.swift")
let seed = section(bridge, from: "private func seedInitialState()", until: "/// Refresh the installed-addons")
let refresh = section(bridge, from: "private func refreshAddons()", until: "/// Remove an installed addon")
let continueWatching = section(bridge, from: "func rebuildContinueWatching()", until: "/// FLOOR each engine")
let event = section(bridge, from: "fileprivate func handleEvent", until: "// MARK: meta_details coalesce")
let libraryEvent = section(event, from: "if fields.contains(\"library\")", until: "if fields.contains(\"search\")")
let catalogAdd = section(bridge, from: "func addToLibrary(metaId:", until: "/// Add a fully-formed meta object")
let catalogWatched = section(bridge, from: "func setCatalogWatched(metaId:", until: "/// The raw `MetaItemPreview`")
let tvCards = source("SourcesTV/SharedUI.swift")
let iosCards = source("SourcesiOS/iOSRootView.swift")
let meta = section(bridge, from: "private func scheduleMetaDetailsRepublish()", until: "private static func appleCWMetaRefreshIsSettled")
let board = section(bridge, from: "private func scheduleBoardRebuild()", until: "private func buildBoardRows()")
let rebuild = section(bridge, from: "func rebuildBoardRows()", until: "/// The Home board rows")
let repair = section(bridge, from: "private func scheduleSessionRepair()", until: "/// Refresh the library")
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
let nativeRevoke = section(bridge, from: "private func revokeNativeSession()", until: "private func clearNativePublishedState()")
let nativeClear = section(bridge, from: "private func clearNativePublishedState()", until: "/// Bumped on every")

check(nativeRevoke.contains("DispatchQueue.main.sync")
                && appearsBefore("invalidatePublicationEpoch()", "clearNativePublishedState()", in: nativeRevoke)
                && !nativeClear.contains("DispatchQueue.main.async")
                && nativeClear.contains("continueWatching = []; boardRows = []; library = nil; metaDetails = nil; discover = nil")
                && nativeClear.contains("searchResults = []; searchSuggestions = []; searchIsLoading = false")
                && nativeClear.contains("addons = []; rawAddonsByUrl = [:]; manifestPreviewCache = [:]")
                && nativeClear.contains("AddonMetaGate.publish(false)")
                && appearsBefore("revokeNativeSession()", "restoreNativeCheckpoint()", in: profileChange),
              "native owner/profile revoke clears all published rows and capabilities synchronously before reopen")
let nativeTarget = section(accountSource, from: "static func capture(core:", until: "func stillOwnsOwnerHistoryContext")
let nativeSave = section(accountSource, from: "func saveProgress(for", until: "/// Fetch a single library item")
let nativeResume = section(accountSource, from: "func resumeOffset(for", until: "/// Upsert the library item")
let nativeBinding = section(bridge, from: "func captureNativePlaybackTarget", until: "@MainActor @discardableResult")
for start in ["func add(_ profile:", "func update(_ profile:", "func remove(_ profile:", "func select(_ profile:"] {
    let admission = section(profileSource, from: start, until: "#endif")
    check(appearsBefore("let target = CoreBridge.shared.captureNativePlaybackTarget()", "Task { @MainActor", in: admission)
          && admission.contains("target: target"), "profile wrapper captures immutable account/session before queued Task: \(start)")
}
check(nativeTarget.contains("core.captureNativePlaybackTarget()")
                && nativeTarget.contains("core.nativePlaybackTargetIsCurrent(self)")
                && nativeBinding.contains("CredentialScopeRegistry.shared.isCurrent(capture)")
                && nativeBinding.contains("sessionGeneration: nativeInstallGeneration")
                && nativeBinding.contains("PlaybackMutationOwnershipPolicy.allowsNative(target, binding: binding)")
                && nativeBinding.contains("nativePlaybackBinding(target)?.0 === facade")
                && nativeBinding.contains("facade.dispatchForProfile(.object(action), profileID: profile.uuidString, expectedAccountGeneration: epoch)")
                && appearsBefore("reportNativeProgress", "if let profileID = target.overlayProfileID", in: nativeSave)
                && appearsBefore("nativeResumeSeconds", "ProfileStore.shared.resumeOffset", in: nativeResume),
              "native player callbacks carry account capture and bypass legacy overlay/network resume/progress")
let selectedProgress = section(bridge, from: "func reportProgress(timeSeconds:", until: "private func dispatchMetaDetails")
check(selectedProgress.contains("let (facade, _) = nativePlaybackBinding(target)")
                && selectedProgress.contains("facade.dispatchCaptured(data: data, field: \"player\", expectedAccountGeneration: epoch)")
                && appearsBefore("timeSeconds * 1000 < Double(Int.max)", "Int(timeSeconds * 1000)", in: selectedProgress),
              "selected native progress keeps the captured facade and bounds millisecond conversion")
let nativeAutoAdd = section(bridge, from: "func addCatalogItemToAccount", until: "/// VortX-owned cold recovery")
check(appearsBefore("facade.addCatalogItem", "let binding = settledActiveAccountBinding()", in: nativeAutoAdd)
                && nativeAutoAdd.contains("nativePlaybackBinding(target)?.0 === facade")
                && nativeAutoAdd.contains("allowInsert: stampIntent"),
              "native auto-add uses captured native metadata and durable membership without a Stremio receipt")
let nativeBootstrap = section(syncSource, from: "func restoreNativeCheckpoint", until: "/// Shared account-owner epoch")
check(appearsBefore("await self.prepareNativeLegacyMaterial(document, capture: capture, enforceMountedFence: false)", "await CoreBridge.shared.closeNativeSession()", in: nativeBootstrap)
      && appearsBefore("validateLegacyCompatibility", "await CoreBridge.shared.closeNativeSession()", in: nativeBootstrap)
      && nativeBootstrap.contains("let finalCheckpoint = try probe.authenticatedCheckpoint(scope: scope)"),
      "source preflight keeps current native data visible and replacement revalidates the final checkpoint")
let ownPreparation = section(syncSource, from: "private func prepareNativeLegacyMaterial", until: "private static func nativeWebsiteEvents")
check(ownPreparation.contains("classifyDeferredOwnAccountOverlays(document: documentBytes")
      && ownPreparation.contains("deferredOwnAccountOverlays: deferred")
      && ownPreparation.contains("archive(sources, pendingOverlays: pendingOverlays)")
      && ownPreparation.contains("VortxNativeOwnAccountProducer.pendingRecord(disposition: disposition")
      && ownPreparation.contains("(!enforceMountedFence || mountedSourceFence())")
      && ownPreparation.contains("if validatedSync != nil && !attributed")
      && ownPreparation.contains("if historical == nil || historical?[\"verifiedStreamingUid\"] == source[\"verifiedStreamingUid\"]"),
      "cold own overlay evidence remains UID-bound and pending is sealed alongside the native candidate")
check(nativeBootstrap.contains("resolveRoster(from: document, fullOnly: true)")
                && nativeBootstrap.contains("let checkpoint = try probe.authenticatedCheckpoint(scope: scope)")
                && nativeBootstrap.contains("let hadCheckpoint = checkpoint != nil")
                && nativeBootstrap.contains("if !hadCheckpoint")
                && nativeBootstrap.contains("await self.prepareNativeLegacyMaterial(document, capture: capture, enforceMountedFence: false)")
                && nativeBootstrap.contains("VortxNativeBootstrapArchive.encode(document: documentBytes, material: material, authenticatedSourceArchive: prepared.sourceArchive)")
                && nativeBootstrap.contains("allowNewAccount: !hadCheckpoint, initialActions: initialActions")
                && nativeBootstrap.contains("if didImportLegacy || !websiteEvents.isEmpty { self.requestSyncSoon() }")
                && appearsBefore("validateLegacyCompatibility", "let session = try VortxNativeSession", in: nativeBootstrap)
                && appearsBefore("await self.prepareNativeLegacyMaterial(document, capture: capture, enforceMountedFence: false)", "if !hadCheckpoint", in: nativeBootstrap)
                && autoAddSource.contains("case .native(let binding): return binding?.profileID")
                && autoAddSource.contains("keyPrefix).native.\\(namespace)")
                && autoAddSource.contains("only the acknowledged native save"),
              "native first import is absent-only and atomic; account-scoped auto-add waits for durable acknowledgement")
let postInstall = section(nativeBootstrap, from: "try await CoreBridge.shared.installNativeSession", until: "// Upload only")
check(postInstall.contains("self.isCurrent(capture), !Task.isCancelled")
                && postInstall.contains("self.nativeCheckpointGeneration == generation")
                && postInstall.contains("ProfileStore.shared.activeID == installationProfile"),
              "final install await rechecks owner, profile, cancellation and opener generation before status or push")
let detachedSeed = section(syncSource, from: "private func publishDetachedNativeSeed", until: "private func restoreOfflineNativeCheckpoint")
check(detachedSeed.contains("VortxNativeSession.detachedLegacySync")
      && detachedSeed.contains("pushSyncDocAt(candidate, version: 0")
      && appearsBefore("pushSyncDocAt(candidate, version: 0", "pullDocVersionedResult", in: detachedSeed)
      && !detachedSeed.contains("rememberAuthenticatedScope") && !detachedSeed.contains("installNativeSession"),
      "proven-empty seed is detached until create-only PUT and authenticated winner readback")
let nativePush = section(syncSource, from: "private func mergeLocalIntoDoc", until: "// Read-merge the pulled doc's tombstone stamps")
check(nativePush.contains("await prepareNativeLegacyMaterial(doc, capture: capture)") && nativePush.contains("legacyMaterial: prepared.material")
                && nativePush.contains("VortxNativeSyncExportPolicy.permitsStateOnlyExport")
                && nativePush.contains("hasDirtySettings: (try? nativeGlobalEdits()) == nil")
                && nativePush.contains("doc[\"nativeHostPreferences\"]")
                && nativePush.contains("orderIntent != nil || pendingAddonOrderIntent != nil")
                && nativePush.contains("return doc\n#else"),
              "native export checks the legacy receipt and returns unchanged sibling carriers without legacy mirror rewrites")

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
                && finishSettlement.contains("refreshFromAPI(explicitAddonImport: explicitAddonImport)")
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
                && installAddon.contains("ReplaceAddonLocal")
                && !installAddon.contains("dispatchCtx([\"action\": \"UninstallAddon\", \"args\": existing])")
                && installAddon.contains("let clearTombstoneBeforeDispatch")
                && installAddon.contains("guard !self.usesNativeProfileState else { return }")
                && !installAddon.contains("if usesNativeProfileState { AddonTombstones.forget(identityURL.absoluteString) }")
                && installAddon.contains("AddonTombstones.forget(identityURL.absoluteString)"),
              "installer rechecks after awaits and atomically replaces without pre-uninstall or premature native tombstone changes")
check(hydrateAddons.contains("guard !owned.isEmpty, addonMutationStillAllowed(mutationToken) else { return }")
                && hydrateAddons.contains("if dispatchCtx([\"action\": \"InstallAddonLocal\", \"args\": addon.installDescriptor])")
                && hydrateAddons.contains("installedCount += 1"),
              "account hydration reports only local installs accepted by the dispatch gate")
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
check(bridge.contains("private let playerActiveSnapshotLock = NSLock()")
                && bridge.contains("private func playerActiveSnapshot() -> Bool")
                && bridge.contains("self.playerActiveSnapshotValue = active")
                && libraryEvent.contains("let playerWasActive = playerActiveSnapshot()")
                && libraryEvent.contains("if !playerWasActive { rebuildContinueWatching")
                && libraryEvent.contains("if !playerWasActive {")
                && !libraryEvent.contains("if !playerActive {")
                && !libraryEvent.contains("guard !playerActive")
                && event.contains("self.changedFields = Set(fields)")
                && event.contains("if published { self.revision &+= 1 }"),
              "a playback-time library event captures one lock-backed state snapshot, skips only detail decoding, and still publishes its revision receipt")
check(catalogAdd.contains("rawMetaPreview(forId: metaId) ?? fallbackPreview?.dictionary")
                && catalogAdd.contains("canDispatchCatalogAdd")
                && catalogWatched.contains("rawMetaPreview(forId: metaId) ?? fallbackPreview?.dictionary")
                && catalogWatched.contains("canDispatchCatalogAdd"),
              "unloaded catalog actions retain a validated minimal card preview after resident lookup")
check(tvCards.contains("fallbackPreview: catalogPreview")
                && iosCards.contains("fallbackPreview: catalogPreview")
                && tvCards.contains("expectedType: type")
                && iosCards.contains("expectedType: catalogPreview.type"),
              "Apple card menus pass their rendered id, type, name, and poster to the guarded fallback path")
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
                && repair.components(separatedBy: "publicationStillCurrent(publicationToken)").count >= 2,
              "14-second recovery validates before and after awaited account hydration")

if Contract.failures > 0 { exit(1) }
