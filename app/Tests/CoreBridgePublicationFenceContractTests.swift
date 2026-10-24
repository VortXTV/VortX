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
// Select the native/legacy lane from the production declaration itself.  Do not
// infer a lane from a helper's presence or absence: an incomplete extraction is
// a hard failure, never permission to run the legacy assertions.
let nativeModeDeclaration = member(bridge, "var usesNativeProfileState: Bool {")
let normalizedNativeModeDeclaration = nativeModeDeclaration.trimmingCharacters(in: .whitespacesAndNewlines)
let guardedMetadata: Bool
if normalizedNativeModeDeclaration == "var usesNativeProfileState: Bool {\n        true\n    }" {
    guardedMetadata = true
} else if normalizedNativeModeDeclaration == "var usesNativeProfileState: Bool {\n        false\n    }" {
    guardedMetadata = false
} else {
    fatalError("Cannot classify explicit usesNativeProfileState mode")
}
// Narrow current-source contract selection, NOT a compiler/extraction/runtime proof.
private func member(_ source: String, _ marker: String) -> String {
    guard source.components(separatedBy: marker).count == 2,
          let start = source.range(of: marker),
          let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else { return "" }
    return String(source[start.lowerBound..<end.upperBound])
}

let stremioCard = source("SourcesShared/StremioConnectCard.swift")
let accountSource = source("SourcesShared/StremioAccount.swift")
let syncSource = source("SourcesShared/VortXSyncManager.swift")
let nativeIngress = section(syncSource, from: "private static func decodeDecryptedSyncDocument", until: "/// DEPRECATED single-state pull")
check(nativeIngress.contains("VortxProfileOverlayWitness.decodeObject(json: plaintext)")
      && syncSource.components(separatedBy: "Self.decodeDecryptedSyncDocument(pt)").count == 4,
      "all decrypted native pull paths reject original duplicate/unsafe numeric JSON before Foundation projection")
let profileSource = source("SourcesShared/Profiles.swift")
let nativeCredentialResolver = section(bridge, from: "func nativeCredentialSlot", until: "func nativeAccountMode")
let ownerConnection = section(bridge, from: "private func authenticateNativeOwnerAccount", until: "private static func readNativeCredential")
let profileCredentialResolver = section(profileSource, from: "var activeKeychainAccount", until: "static func legacyKeychainAccount")
let legacyTokenMigration = section(accountSource, from: "private func migrateTokenToKeychain", until: "func signIn(email")
if guardedMetadata {
    check(nativeCredentialResolver.contains("selectedOwnerSlot(scope: capture.namespace, ownerProfileID: ownerID")
          && nativeCredentialResolver.contains(".string(\"shared\")")
          && !nativeCredentialResolver.contains("primaryTokenAccount")
          && profileCredentialResolver.contains("vortx.native.streaming.unavailable.no-profile")
          && profileCredentialResolver.contains("return CoreBridge.shared.nativeCredentialSlot(profileID: profile.id)")
          && !profileCredentialResolver.contains("primaryTokenAccount")
          && !accountSource.contains("private func migrateTokenToKeychain"),
          "native owner/shared credentials never borrow global legacy primary or migrate unqualified defaults")
} else {
    check(nativeCredentialResolver.contains("selectedOwnerSlot(scope: capture.namespace, ownerProfileID: ownerID")
          && nativeCredentialResolver.contains(".string(\"shared\")")
          && !nativeCredentialResolver.contains("primaryTokenAccount")
          && profileCredentialResolver.contains("vortx.native.streaming.unavailable.no-profile")
          && profileCredentialResolver.contains("#else\n        return Self.legacyKeychainAccount")
          && legacyTokenMigration.contains("#if !VORTX_NATIVE_DATA_ENGINE"),
          "legacy owner/shared credentials retain explicit migration/default isolation")
}
check(appearsBefore("authenticatedIdentity(authKey: token)", "connectOwner(token: token", in: ownerConnection)
      && ownerConnection.contains("expectedSelection: target.expectedOwnerSelection")
      && ownerConnection.contains("generations: [generation]")
      && ownerConnection.contains("nativePlaybackBinding(.native(target.binding))")
      && !ownerConnection.contains("mutateProfiles"),
      "owner reauthentication verifies UID and captured revision before secure CAS without changing native library authority")
check(accountSource.components(separatedBy: "error is VortxNativeAccountCredentials.OwnerPublicationUncertain").count == 3
      && accountSource.contains("The connection outcome could not be confirmed. Secure account state will be checked before use")
      && ownerConnection.contains("selectionAttempted: { VortxNativeOwnAccountProducer.invalidateContext() }"),
      "uncertain owner publication is explicitly shown and credential authority retires before publication")
let autoAddSource = source("SourcesShared/LibraryAutoAdd.swift")
let seed = section(bridge, from: "private func seedInitialState()", until: "/// Refresh the installed-addons")
let refresh = section(bridge, from: "private func refreshAddons()", until: "/// Remove an installed addon")
let continueWatching = section(bridge, from: "func rebuildContinueWatching()", until: "/// FLOOR each engine")
let event = guardedMetadata
    ? member(bridge, "private func admitNativeLegacyChange(") + member(bridge, "private func publishNativeLegacySample(")
    : section(bridge, from: "fileprivate func handleEvent", until: "// MARK: meta_details coalesce")
let libraryEvent = guardedMetadata ? member(bridge, "private func publishNativeLegacyHistory(")
    : section(event, from: "if fields.contains(\"library\")", until: "if fields.contains(\"search\")")
let catalogAdd = section(bridge, from: "func addToLibrary(metaId:", until: "func addToLibraryFromMenu(")
let catalogWatched = section(bridge, from: "func setCatalogWatched(metaId:", until: "/// The raw `MetaItemPreview`")
let menuAdd = section(bridge, from: "func addToLibraryFromMenu(", until: "func removeFromLibraryFromMenu(")
let menuRemove = section(bridge, from: "func removeFromLibraryFromMenu(", until: "/// Add a fully-formed meta object")
let tvCards = source("SourcesTV/SharedUI.swift")
let iosCards = source("SourcesiOS/iOSRootView.swift")
let meta = guardedMetadata ? member(bridge, "private func scheduleOwnedMetadata(") + member(bridge, "private func publishOwnedMetadata(")
    : section(bridge, from: "private func scheduleMetaDetailsRepublish()", until: "private static func appleCWMetaRefreshIsSettled")
let board = guardedMetadata ? member(bridge, "private func scheduleNativeLegacyBoard(")
    : section(bridge, from: "private func scheduleBoardRebuild()", until: "private func buildBoardRows()")
let rebuild = section(bridge, from: "func rebuildBoardRows()", until: "/// The Home board rows")
let repair = section(bridge, from: "private func scheduleSessionRepair()", until: "/// Refresh the library")
let settlement = section(bridge, from: "private func settleAccountBindingIfProven()", until: "private func finishSettledAccountBinding()")
let finishSettlement = section(bridge, from: "private func finishSettledAccountBinding()", until: "/// Dispatch an `Action::Ctx")
let invalidation = guardedMetadata ? member(bridge, "private func detachPublicationEpochStorage(")
    : section(bridge, from: "private func invalidatePublicationEpoch()", until: "/// ProfileStore calls")
let profileChange = section(bridge, from: "func activeProfileDidChange()", until: "private func verifyAccountBinding")
let bootstrap = section(bridge, from: "private func bootstrapAuth()", until: "/// Self-heal a stale")
let logout = member(bridge, "func logOut(rearmSignedOutRepair")
let disconnect = member(stremioCard, "private func disconnect()")
let accountSignOut = member(accountSource, "func signOut()")
let beginBinding = section(bridge, from: "private func beginAccountBinding", until: "private func cancelAccountBindingVerification")
let invalidateAuth = section(bridge, from: "private func invalidateAuthenticationGeneration()", until: "private func retireSignedOutRepairRequest()")
let signedOutRearm = section(bridge, from: "private func rearmSignedOutRepairWhenSafe", until: "/// Clear the published")
let importedCapture = section(bridge, from: "private func captureImportedAwayBootstrapContext", until: "/// Clear the old binding")
let publicationGate = section(bridge, from: "private var enginePublicationBlocked", until: "/// Invalidate every captured")
let localRecovery = section(bridge, from: "private func captureImportedAwayLocalRecoveryContext", until: "/// Clear the old binding")
let dispatch = section(bridge, from: "func dispatch(action:", until: "/// Compact human name")
let uninstallAddon = section(bridge, from: "func uninstallAddon(_ descriptor:", until: "/// Normalize a pasted")
let installAddon = section(bridge, from: "func installAddonConfirmed", until: "struct AddonManifestPreview")
let hydrateAddons = section(bridge, from: "func hydrateAddonsFromAccount", until: "/// The native host presentation schema version.")
let nativeRevoke = guardedMetadata ? member(bridge, "private func revokeNativeSession(")
    : section(bridge, from: "private func revokeNativeSession()", until: "private func clearNativePublishedState()")
let nativeClear = guardedMetadata ? member(bridge, "private func clearNativePublishedState(")
    : section(bridge, from: "private func clearNativePublishedState()", until: "/// Bumped on every")

if guardedMetadata {
    let commit = member(bridge, "private func commitOriginalMetadataClear(")
    check(!nativeRevoke.isEmpty && !nativeClear.isEmpty && !nativeRevoke.contains("DispatchQueue.main.sync")
        && nativeRevoke.contains("nativeCallbackLifetime.retire()")
        && nativeClear.contains("let owns = { self.originalMetadataClearAuthorityIsCurrent(clear) }")
        && nativeClear.contains("continueWatching = []; guard owns() else { return nil }")
        && nativeClear.contains("addons = []; guard owns() else { return nil }")
        && commit.contains("guard commitOwnedMetadataClear(bumpStreams: bumpStreams, preservingClear: clear.identity,")
        && commit.contains("finalAdmission: .localOriginal) else { return false }"),
        "native owner clear uses actor entry, original authority and guarded final nil frame without main.sync")
} else {
check(nativeRevoke.contains("DispatchQueue.main.sync")
                && appearsBefore("invalidatePublicationEpoch()", "clearNativePublishedState()", in: nativeRevoke)
                && !nativeClear.contains("DispatchQueue.main.async")
                && nativeClear.contains("continueWatching = []; boardRows = []; library = nil; metaDetails = nil; discover = nil")
                && nativeClear.contains("searchResults = []; searchSuggestions = []; searchIsLoading = false")
                && nativeClear.contains("addons = []; rawAddonsByUrl = [:]; manifestPreviewCache = [:]")
                && nativeClear.contains("AddonMetaGate.publish(false)")
                && appearsBefore("revokeNativeSession()", "restoreNativeCheckpoint()", in: profileChange),
              "native owner/profile revoke clears all published rows and capabilities synchronously before reopen")
}
let nativeTarget = section(accountSource, from: "static func capture(core:", until: "func stillOwnsOwnerHistoryContext")
let nativeSave = section(accountSource, from: "func saveProgress(for", until: "/// Fetch a single library item")
let nativeResume = section(accountSource, from: "func resumeOffset(for", until: "/// Upsert the library item")
let nativeBinding = section(bridge, from: "func captureNativePlaybackTarget", until: "@MainActor @discardableResult")
let watchedInventoryIntent = section(bridge, from: "private func nativeWatchedInventoryIntent", until: "private func resolveNativeWatchedInventory")
let watchedInventoryResolution = section(bridge, from: "private func resolveNativeWatchedInventory", until: "private func nativeDismissContinueWatching")
check(watchedInventoryIntent.contains("let epoch = binding.accountGeneration")
      && watchedInventoryIntent.contains("expectedAccountGeneration: epoch"),
      "resident watched inventory keeps the gesture's captured account epoch")
check(appearsBefore("let epoch = binding.accountGeneration", "Task {", in: watchedInventoryResolution)
      && watchedInventoryResolution.contains("expectedAccountGeneration: epoch"),
      "deferred watched inventory captures account epoch before scheduling its task")
let profileWrapperBoundaries: [(String, String)] = [
    ("func add(_ profile:", "func update(_ profile:"),
    ("func update(_ profile:", "/// Flip an add-on"),
    ("func remove(_ profile:", "/// Apply web-authored"),
    ("func select(_ profile:", "func add(_ profile:")
]
for (start, end) in profileWrapperBoundaries {
    let admission = section(profileSource, from: start, until: end)
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
let signedOutRepairRequest = section(bridge, from: "@MainActor\n    private var signedOutRepairRequest: SignedOutRepairRequest? {", until: "/// Set only by the token-matched")
let logoutPendingGate = section(bridge, from: "private var logoutAccountMutationPending: Bool {", until: "/// Add-on operations")
check(selectedProgress.contains("let (facade, _) = nativePlaybackBinding(target)")
                && selectedProgress.contains("facade.dispatchCaptured(data: data, field: \"player\", expectedAccountGeneration: epoch)")
                && appearsBefore("timeSeconds * 1000 < Double(Int.max)", "Int(timeSeconds * 1000)", in: selectedProgress)
                && selectedProgress.contains("guard usesNativeProfileState else { return }")
                && !selectedProgress.contains("if usesNativeProfileState {")
                && !selectedProgress.contains("dispatch(action: [\"action\": \"Player\"")
                && bridge.contains("private let signedOutRepairRequestState = OSAllocatedUnfairLock<SignedOutRepairRequest?>(initialState: nil)")
                && signedOutRepairRequest.contains("get { signedOutRepairRequestState.withLock { $0 } }")
                && signedOutRepairRequest.contains("set { signedOutRepairRequestState.withLock { $0 = newValue } }")
                && logoutPendingGate.contains("signedOutRepairRequestState.withLock { $0 != nil }"),
              "selected native progress retains every actual guard, removes the retired legacy Player tail, and shares one checked optional logout store with the actor-owned property")
let nativeAutoAdd = section(bridge, from: "func addCatalogItemToAccount", until: "/// VortX-owned cold recovery")
check(appearsBefore("facade.addCatalogItem", "let binding = settledActiveAccountBinding()", in: nativeAutoAdd)
                && nativeAutoAdd.contains("nativePlaybackBinding(target)?.0 === facade")
                && nativeAutoAdd.contains("allowInsert: stampIntent"),
              "native auto-add uses captured native metadata and durable membership without a Stremio receipt")
let nativeBootstrap = section(syncSource, from: "func restoreNativeCheckpoint", until: "/// Shared account-owner epoch")
let nativeAdmission = section(syncSource, from: "private func nativeRestoreDocument", until: "func restoreNativeCheckpoint")
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
check(nativeAdmission.contains("resolveRoster(from: document, fullOnly: true)")
                && nativeBootstrap.contains("self.nativeRestoreDocument(pulled, capture: capture, selectedProfile: selectedProfile, generation: generation)")
                && nativeBootstrap.contains("let checkpoint = try probe.authenticatedCheckpoint(scope: scope)")
                && nativeBootstrap.contains("let hadCheckpoint = checkpoint != nil")
                && nativeBootstrap.contains("if !hadCheckpoint")
                && section(nativeBootstrap, from: "if !hadCheckpoint {", until: "let archive = try material.map")
                    .contains("guard let material else { throw VortxNativeError.invalidSnapshot }")
                && nativeBootstrap.contains("await self.prepareNativeLegacyMaterial(document, capture: capture, enforceMountedFence: false)")
                && nativeBootstrap.contains("let material = prepared?.material")
                && nativeBootstrap.contains("let archive = try material.map { try VortxNativeBootstrapArchive.encode(document: documentBytes, material: $0, authenticatedSourceArchive: prepared?.sourceArchive) }")
                && nativeBootstrap.contains("bootstrap: archive, bootstrapScope: scope")
                && appearsBefore("let archive = try material.map", "bootstrap: archive, bootstrapScope: scope", in: nativeBootstrap)
                && nativeBootstrap.contains("allowNewAccount: !hadCheckpoint, initialActions: initialActions")
                && nativeBootstrap.contains("if didImportLegacy || !websiteEvents.isEmpty || !websiteAddonEvents.isEmpty { self.requestSyncSoon() }")
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
let nativePush = section(syncSource, from: "private func mergeLocalIntoDoc", until: "private func foldDocTombstones(")
let nativeExportReturn = guardedMetadata
    ? nativePush.contains("return DerivedSyncDoc(document: doc, baseRevision: baseRevision, credentialCapture: capture,\n"
        + "                              sourceIsCurrent: sourceIsCurrent, nativeDirtySettings: exportedDirtySettings)\n    }")
    : nativePush.contains("return DerivedSyncDoc(document: doc, baseRevision: baseRevision, credentialCapture: capture,\n"
        + "                              sourceIsCurrent: sourceIsCurrent, nativeDirtySettings: exportedDirtySettings)\n#else")
check(nativePush.contains("let conversion = nativeLegacyConversionDecision(doc, capture: capture)")
                && nativePush.contains("var prepared: NativeLegacyPreparation?")
                && nativePush.contains("if conversion.convert { prepared = try await prepareNativeLegacyMaterial(doc, capture: capture) }")
                && nativePush.contains("legacyMaterial: prepared?.material")
                && nativePush.contains("sourceAuthority: prepared?.authority, authenticatedSourceArchive: prepared?.sourceArchive")
                && nativePush.contains("if prepared != nil { recordNativeLegacyConversion(conversion.digest, capture: capture) }")
                && appearsBefore("if conversion.convert {", "CoreBridge.shared.mergeNativeAccountDocument", in: nativePush)
                && nativePush.contains("VortxNativeSyncExportPolicy.permitsStateOnlyExport")
                && nativePush.contains("hasDirtySettings: (try? nativeGlobalEdits()) == nil")
                && nativePush.contains("doc[\"nativeHostPreferences\"]")
                && nativePush.contains("orderIntent != nil || pendingAddonOrderIntent != nil")
                && nativeExportReturn,
              "native export checks the legacy receipt and returns unchanged sibling carriers without legacy mirror rewrites")

if guardedMetadata {
    check(bridge.contains("private let publicationEpochState = OSAllocatedUnfairLock")
        && member(bridge, "private func capturePublicationToken(").contains("publicationEpochState.withLock")
        && invalidation.contains("publicationEpochState.withLock { $0 &+= 1 }"),
        "production owns checked scalar worker-safe epoch capture and actor-owned retirement")
} else {
check(bridge.contains("private let publicationEpochLock = NSLock()")
                && bridge.contains("private func capturePublicationToken() -> PublicationToken")
                && bridge.contains("private func invalidatePublicationEpoch()"),
              "production owns a lock-backed worker-safe publication epoch")
}
if guardedMetadata {
    let callback = member(bridge, "private func makeNativeSourceCallback(")
    let mailbox = member(bridge, "private struct NativeSourceMailbox:")
    check(callback.contains("let epoch = publicationEpochState")
        && callback.contains("publication: epoch.withLock { PublicationToken(epoch: $0) }")
        && callback.contains("lifetime.accepts(installation, credential: credential, sourceID: event.sourceID)")
        && callback.contains("let mailbox = NativeSourceMailbox()")
        && appearsBefore("guard mailbox.append(.init(event: event, origin: origin)) else { return }",
                         "Task { @MainActor in", in: callback)
        && callback.contains("while let batch = mailbox.takeBatch() {")
        && callback.contains("for envelope in batch { receiver.receive(envelope.event, origin: envelope.origin) }")
        && mailbox.contains("value.pending.append(envelope)")
        && mailbox.contains("swap(&batch, &value.pending)")
        && !callback.contains("authBindingGeneration")
        && !callback.contains("[weak self]") && !callback.contains("self."),
        "real typed source callback retains original scalars and per-install append/drain order without mixed Bridge capture")
} else {
check(!event.contains("let publicationGeneration = authBindingGeneration")
                && event.contains("let publicationToken = capturePublicationToken()"),
              "Rust NewState worker never reads main-owned auth generation")
}
if guardedMetadata {
    let receiver = member(bridge, "private final class NativeCallbackReceiver")
    check(receiver.contains("core.nativeCallbackOriginIsCurrent(origin)")
        && appearsBefore("core.receiveOwnedMetadata(event, origin: origin)", "core.receiveNativeLegacyEvent(event, origin: origin)", in: receiver)
        && event.contains("guard nativeCallbackOriginIsCurrent(origin),"),
        "typed native source validates original context before metadata and separate legacy delivery")
} else {
check(appearsBefore("let bindingSettled = self.settleAccountBindingIfProven()", "guard !self.enginePublicationBlocked", in: event)
                && !event.contains("guard let self, self.publicationStillCurrent(publicationToken) else { return }\n                // `ctx` is control-plane"),
              "pending-B ctx receipt reaches identity settlement before data publication is gated")
}
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
                && repair.contains("Task { @MainActor [weak self] in")
                && repair.contains("try await Task.sleep(nanoseconds: 14_000_000_000)")
                && repair.contains("guard !Task.isCancelled, let self,")
                && repair.contains("CredentialScopeRegistry.shared.isCurrent(credentialCapture)")
                && invalidation.contains("let originalRepair = sessionRepairWork")
                && invalidation.contains("sessionRepairWork = nil")
                && invalidation.contains("originalRepair?.cancel()")
                && invalidation.contains("sessionRepairGeneration &+= 1"),
              "stale launch repair is cancelled and only the newest context-bound timer may fire")
check(appearsBefore("let publicationToken = capturePublicationToken()", "DispatchQueue.main.async", in: repair)
                && appearsBefore("let credentialCapture = CredentialScopeRegistry.shared.capture()", "DispatchQueue.main.async", in: repair)
                && appearsBefore("CredentialScopeRegistry.shared.isCurrent(credentialCapture)", "self.sessionRepairWork?.cancel()", in: repair)
                && !repair.contains("DispatchWorkItem"),
              "repair carries its original owner evidence through arming and does not erase timer isolation")
for signature in [
    "private var activeTokenAccount:", "private var importedAwayFromStremio:",
    "private func bootstrapAuth()", "private func refreshFromAPI(",
    "func settledActiveAccountBinding()", "func settledLocalHistoryOwner()",
    "private func settledLocalHistoryOwner(", "private func localOnlyRecoveryAllowed(",
    "private func captureLocalHistoryHydrationContext()", "private func beginLocalHistoryHydration()",
    "private func localHistoryHydrationStillCurrent(", "private func localHistoryHydrationReceiptStillCurrent(",
    "private func recordAcceptedHistoryReceipt(", "private func verifyAccountBinding(",
    "private func startVerifiedAccountSwitch(", "private func settleAccountBindingIfProven()",
    "private func finishSettledAccountBinding()"
] {
    check(bridge.contains("    @MainActor\n    " + signature), "legacy owner isolation: " + signature)
}
let profileRearmPath = guardedMetadata
    ? profileChange.contains("revokeNativeSession()")
        && profileChange.contains("NativeMetadataBootstrapContinuation")
    : profileChange.contains("scheduleSessionRepair()")
if guardedMetadata {
    check(finishSettlement.contains("scheduleSessionRepair()")
                    && profileRearmPath,
                  "native settlement and profile-change paths rearm only through the native session owner")
} else {
    check(finishSettlement.contains("scheduleSessionRepair()")
                    && profileRearmPath
                    && bootstrap.contains("Keychain.set(nil, for: importedAwayContext.keychainAccount)")
                    && bootstrap.contains("self.scheduleSessionRepair()"),
                  "settled, no-token, and imported-away legacy logout contexts each rearm one valid repair timer")
}
check(finishSettlement.contains("if switchInFlight {")
                && finishSettlement.contains("switchInFlight = false")
                && finishSettlement.contains("switchFromUID = nil")
                && appearsBefore("switchInFlight = false", "scheduleSessionRepair()", in: finishSettlement),
              "proof-first legacy switch retires its gate before binding replay or repair")
if guardedMetadata {
    check(disconnect.contains("account.signOut()")
        && disconnect.contains("core.logOut()")
        && logout.contains("loadBoard(); loadLibrary()")
        && !logout.contains("dispatchCtx(")
        && !logout.contains("nativeFacade")
        && !logout.contains("SignedOutRepairRequest")
        && accountSignOut.contains("LegacyWatchOwnership.invalidateSession()")
        && accountSignOut.contains("VortxNativeOwnAccountProducer.invalidate(slot: tokenKey)")
        && accountSignOut.contains("authOperationGeneration &+= 1")
        && accountSignOut.contains("authKey = nil; isSignedIn = false; streamSources = []; addons = []")
        && accountSignOut.contains("setEmail(nil)"),
        "native disconnect signs out the account-owned credential, while declaration-local CoreBridge logout only refreshes native UI")
} else {
    check(bridge.contains("private struct SignedOutRepairRequest: Equatable")
        && logout.contains("SignedOutRepairRequest(")
        && logout.contains("publicationToken: capturePublicationToken()")
        && signedOutRearm.contains("signedOutRepairRequestStillCurrent(request)")
        && signedOutRearm.contains("signedOutRepairRequest = nil")
        && disconnect.contains("account.signOut()")
        && disconnect.contains("core.logOut()"),
        "explicit Stremio disconnect rearms exactly one local repair after safe engine logout")
}
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
if guardedMetadata {
    check(publicationGate.contains("logoutAccountMutationPending: Bool")
        && publicationGate.contains("signedOutRepairRequestState.withLock { $0 != nil }")
        && signedOutRearm.contains("signedOutRepairRequestStillCurrent(request)")
        && signedOutRearm.contains("receiptPublicationToken == request.publicationToken")
        && signedOutRearm.contains("!isLoggedIn(), currentUID() == nil")
        && member(bridge, "private func nativeCallbackOriginIsCurrent(").contains("publicationStillCurrent(origin.publication)"),
        "logout gate and original typed source epoch prevent old account data publication; legacy signed-out proof stays exact")
} else {
check(publicationGate.contains("signedOutRepairPending: signedOutRepairRequest != nil")
                && signedOutRearm.contains("signedOutRepairRequestStillCurrent(request)")
                && signedOutRearm.contains("receiptPublicationToken == request.publicationToken")
                && signedOutRearm.contains("!isLoggedIn(), currentUID() == nil")
                && signedOutRearm.contains("signedOutRepairRequest = nil")
                && signedOutRearm.contains("if request.rearmSessionRepair")
                && event.contains("if let signedOutRepairRequest = self.signedOutRepairRequest, !self.isLoggedIn()")
                && event.contains("receiptPublicationToken: publicationToken"),
              "old account data stays gated during logout until only the exact signed-out control receipt clears it")
}
check(localRecovery.contains("signedOutRequest: SignedOutRepairRequest")
                && localRecovery.contains("signedOutRepairRequestStillCurrent(signedOutRequest)")
                && localRecovery.contains("signedOutRepairRequest == nil")
                && localRecovery.contains("confirmedSignedOutRepairRequest == context.signedOutRequest")
                && localRecovery.contains("!isLoggedIn(), currentUID() == nil"),
              "imported-away recovery times out unless the exact logout receipt is cleared and engine identity is blank")
let dispatchSuccess = guardedMetadata
    ? dispatch.contains("let accepted = nativeFacade.dispatch(data: nativeAction, field: field)")
        && dispatch.contains("return accepted")
    : dispatch.contains("return true")
check(dispatch.contains("blocksAccountMutationDuringSignedOutRepair")
                && dispatch.contains("dropped account mutation pending signed-out receipt")
                && dispatch.contains("beforeDispatch?()")
                && dispatch.contains("return false")
                && dispatchSuccess,
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
if guardedMetadata {
    let seed = member(bridge, "private func receiveNativeLegacyHostSeed(")
    check(seed.contains("origin: origin, recordsCoarseEvent: false)")
        && seed.contains("legacyFields: receipt.fields, receipt: receipt")
        && event.contains("receipt.sourceID == origin.producer.sourceID"),
        "explicit host seed retains original receipt/origin and cannot invent a source callback/coarse event")
} else {
check(seed.contains("capturePublicationToken()")
                && seed.contains("publicationStillCurrent(publicationToken)")
                && seed.contains("rebuildContinueWatching(capturedPublicationToken: publicationToken)")
                && seed.contains("refreshAddons(capturedPublicationToken: publicationToken)"),
              "initial board, addon, and Continue Watching seeds retain one immutable context")
}
let refreshPublishHop = guardedMetadata
    ? refresh.contains("DispatchQueue.main.async { [weak self] in")
        && refresh.contains("self.rawAddonsByUrl = raw")
    : refresh.contains("Task { @MainActor")
        && refresh.contains("rawAddonsByUrl = publishedRaw")
check(refreshPublishHop
                && refresh.contains("publicationStillCurrent(publicationToken)")
                && refresh.contains("AddonMetaGate.publish"),
              "ctx addon publish and delayed tombstone uninstall validate before mutation")
check(continueWatching.contains("publicationStillCurrent(publicationToken)"),
              "Continue Watching final assignment rejects a stale snapshot")
if guardedMetadata {
    check(event.contains("let work = NativeLegacyWork(receipt: receipt, fields: fieldSet,")
        && event.contains("self?.publishNativeLegacySample(sample, work: work, origin: origin,")
        && event.contains("publishNativeLegacyHistory(library: sample.library, continueWatching: sample.continueWatching,")
        && member(bridge, "private func nativeLegacyReceiptIsCurrent(").contains("origin.producer.acceptsChange(receipt, field: field)"),
        "account event branches retain original immutable source receipt and actor sink origin")
} else {
check(event.contains("scheduleBoardRebuild(capturedPublicationToken: publicationToken)")
                && event.contains("scheduleMetaDetailsRepublish(capturedPublicationToken: publicationToken)")
                && event.contains("refreshAddons(capturedPublicationToken: publicationToken)")
                && event.contains("self.library = value")
                && event.contains("self.discover = value"),
              "account-scoped event branches pass one token into each downstream publisher")
}
if guardedMetadata {
    let callback = member(bridge, "private func makeNativeSourceCallback(")
    let owned = member(bridge, "private func receiveOwnedMetadata(")
    let coarse = member(bridge, "private func recordNativeLegacyCoarseEvent(")
    check(callback.contains("playerWasActive: player.withLock { $0 }")
        && owned.contains("change.fields.contains(\"library\") && !origin.playerWasActive")
        && libraryEvent.contains("fields.contains(\"library\") && !origin.playerWasActive")
        && event.contains("if recordsCoarseEvent {")
        && coarse.contains("changedFields = Set(legacyFields)")
        && coarse.contains("if published { revision &+= 1 }"),
        "original player scalar gates only library detail overlay/CW policy; real coarse receipt remains separate")
} else {
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
}
check(catalogAdd.contains("rawMetaPreview(forId: metaId) ?? fallbackPreview?.dictionary")
                && catalogAdd.contains("canDispatchCatalogAdd")
                && catalogWatched.contains("rawMetaPreview(forId: metaId) ?? fallbackPreview?.dictionary")
                && catalogWatched.contains("canDispatchCatalogAdd"),
              "unloaded catalog actions retain a validated minimal card preview after resident lookup")
check(tvCards.contains("addToLibraryFromMenu(catalogPreview)")
                && iosCards.contains("addToLibraryFromMenu(catalogPreview)")
                && menuAdd.contains("addToLibrary(metaId: card.id, expectedType: card.type, fallbackPreview: card, target: target)"),
              "Apple card menus pass their rendered id, type, name, and poster to the guarded fallback path")
check(menuAdd.contains("guard addToLibrary(metaId: card.id")
                && menuAdd.contains("ScrobbleCoordinator.shared.addedToLibrary(")
                && menuAdd.contains("setNativeLibraryMembership(id: resident.id")
                && !menuAdd.contains("dispatchCtx(")
                && menuRemove.contains("setNativeLibraryMembership(id: saved.id")
                && menuRemove.contains("ScrobbleCoordinator.shared.removedFromLibrary(")
                && tvCards.contains("removeFromLibraryFromMenu(catalogPreview)")
                && iosCards.contains("removeFromLibraryFromMenu(catalogPreview)")
                && !catalogAdd.contains("ScrobbleCoordinator")
                && !autoAddSource.contains("FromMenu"),
              "card-menu library adds and removes mirror to Trakt/SIMKL only after the save, while auto-add on play never does")
if guardedMetadata {
    check(event.contains("nativeLegacyReceiptIsCurrent(receipt, origin: origin, field: \"ctx\")")
        && event.contains("if searchLoaded { loadSearchRange() }"),
        "ctx search-range redispatch checks original receipt before actor-local dispatch")
} else {
check(event.contains("guard let self, self.publicationStillCurrent(publicationToken), self.searchLoaded else { return }")
                && event.contains("self.loadSearchRange()"),
              "ctx search-range redispatch is dropped for stale or blocked account context")
}
let searchPublication = guardedMetadata ? event
    : section(event, from: "if fields.contains(\"search\")", until: "if fields.contains(\"local_search\")")
if guardedMetadata {
    let worker = member(bridge, "private static func prepareNativeLegacySample(")
    check(worker.contains("value: values[\"search\"]")
        && searchPublication.contains("searchPublication.capture(query: Self.nativeLegacySearchQuery(receipt))")
        && searchPublication.contains("nativeLegacyReceiptIsCurrent(receipt, origin: origin, field: \"search\")")
        && searchPublication.contains("searchPublication.accepts(searchToken)"),
        "search decodes original immutable receipt and keeps actor query generation at final sink")
} else {
check(searchPublication.contains("let data = stateData(\"search\")")
        && searchPublication.contains("searchPublication.capture(query: query)")
        && searchPublication.contains("self.publicationStillCurrent(publicationToken), let searchToken")
        && searchPublication.contains("self.searchPublication.accepts(searchToken)"),
      "search decodes one buffer and checks owner plus expected query generation at final publication")
}
let watchlistTarget = section(bridge, from: "private func captureNativeWatchlistTarget()", until: "/// Never fall back to an unrelated legacy profile token")
check(watchlistTarget.contains("CredentialScopeRegistry.shared.isCurrent(capture)")
        && watchlistTarget.contains("facade.watchlistBinding")
        && watchlistTarget.contains("nativePublishedAccountGeneration == binding.accountGeneration")
        && watchlistTarget.contains("NativeProfileActionPreparation.target")
        && watchlistTarget.contains("current.facade === target.facade && current.binding == target.binding")
        && watchlistTarget.contains("target.facade.setWatchlist(entry, present: present, expected: target.binding)")
        && watchlistTarget.contains("return membership")
        && !watchlistTarget.contains("nativePlaybackBinding(target)"),
      "watchlist preparation and acknowledgement retain stable credential/session/profile ownership through unrelated busy sync")
let rowPagination = section(bridge, from: "func loadBoardRowNextPage(engineIndex:", until: "/// Apply a catalog presentation-order change")
check(appearsBefore("deferredBoardRowPages.insert(engineIndex); return", "boardRowPageInFlight[engineIndex] = CoreBoardPageRequest", in: rowPagination)
        && rowPagination.contains("case .busy: deferredBoardRowPages.insert(engineIndex)")
        && rowPagination.contains("case .exhausted: boardRowExhausted.insert(engineIndex)")
        && rowPagination.contains("for index in deferredBoardRowPages.sorted()")
        && rowPagination.contains("if !boardRowPageInFlight.isEmpty || deferredBoardRowPages.contains(index) { break }")
        && rowPagination.contains("deferredBoardRowPages.remove(index); loadBoardRowNextPage(engineIndex: index)")
        && rowPagination.contains("!board.catalogs.joined().contains(where: { $0.content?.isLoading == true })"),
      "native row pagination waits for the active range/page without a stuck latch and retries after settlement")
check(rowPagination.contains("CoreBoardPageRequest(itemCount: itemCount, pageCount: pageCount)")
        && appearsBefore("guard request.acceptsSettlement(pageCount: pages.count", "boardRowPageInFlight[index] = nil\n            if count <= request.itemCount", in: rowPagination),
      "native row pagination ignores queued snapshots predating the appended page before retiring its latch")
let widening = section(bridge, from: "private func widenBoardRange", until: "// MARK: Discover / Library")
check(widening.contains("deferredBoardRangeDepth = max(deferredBoardRangeDepth ?? 0, needed); return")
        && widening.components(separatedBy: "widenBoardRange(to: needed)").count == 3
        && widening.contains("if depth > boardRowsLoaded { widenBoardRange(to: depth); return }"),
      "native order and Live widening coalesce absolute depth behind the same active row page fence")
if guardedMetadata {
    check(event.contains("nativeLegacyReceiptIsCurrent(receipt, origin: origin, field: \"discover\")")
        && event.contains("discoverPublishedFingerprint = next.fingerprint"),
        "Discover fingerprint mutates only behind original source field receipt")
} else {
check(event.contains("guard let self, self.publicationStillCurrent(publicationToken) else { return }\n                    guard fingerprint != self.discoverPublishedFingerprint")
                && event.contains("self.discoverPublishedFingerprint = fingerprint"),
              "Discover fingerprint mutation is main-gated by the captured publication token")
}
if guardedMetadata {
    check(meta.contains("let operation = NativeMetadataOperation(kind: kind, intent: intent, selection: selection,")
        && meta.contains("source: source, decode: decode)")
        && meta.contains("await receiver.publish(.init(details: details, status: status), operation: operation)")
        && meta.contains("let owns: @MainActor @Sendable () -> Bool = { self.nativeMetadataOperationIsCurrent(operation) }")
        && meta.contains("commitOwnedMetadataFrame(details: details, status: sample.status,")
        && meta.contains("finalAdmission: sourceAdmission), owns() else { return }")
        && !bridge.contains("private func scheduleMetaDetailsRepublish(")
        && !bridge.contains("fileprivate func handleEvent("),
        "owned metadata carries original task/source/selection to final immutable frame; removed legacy scheduler cannot be re-entered")
} else {
check(meta.contains("publicationStillCurrent(publicationToken)")
                && meta.contains("self.metaDetailsWork?.cancel()"),
              "meta-details coalescer checks the token at schedule and final publication")
}
if guardedMetadata {
    check(board.contains("nativeLegacyReceiptIsCurrent(receipt, origin: origin, field: \"board\")")
        && board.contains("nativeLegacyReceiptIsCurrent(receipt, origin: origin, field: \"ctx\")")
        && board.contains("Task.detached(priority: .userInitiated)")
        && board.contains("Self.prepareNativeLegacyBoard(receipt: receipt, preferences: preferences)")
        && board.contains("self.boardRows = sample.rows"),
        "board debounce/background/final assignment carries original source fields and immutable preferences")
} else {
check(board.contains("publicationStillCurrent(publicationToken)")
                && board.contains("self.boardRebuildWork?.cancel()")
                && board.contains("self.boardRows = rows"),
              "board debounce/background/final assignment cannot publish after replacement")
}
check(rebuild.contains("capturePublicationToken()")
                && rebuild.contains("publicationStillCurrent(publicationToken)"),
              "direct library-derived board rebuild validates its captured context")
check(repair.contains("let publicationToken = capturePublicationToken()")
                && repair.contains("await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()")
                && repair.components(separatedBy: "publicationStillCurrent(publicationToken)").count >= 2,
              "14-second recovery validates before and after awaited account hydration")

if Contract.failures > 0 { exit(1) }
