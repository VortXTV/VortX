// Standalone regression contract for the mirror-off add-on mutation and warm-hydration paths.
//
// xcrun swiftc -warnings-as-errors -o /tmp/addon-local-mutation-contract \
//   app/Tests/AddonLocalMutationContractTests.swift && /tmp/addon-local-mutation-contract

import Foundation

private enum Contract {
    static var failures = 0
}

private func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS  \(name)") }
    else { Contract.failures += 1; print("FAIL  \(name)") }
}

private func source(_ relativePath: String) -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let candidates = [root.appendingPathComponent(relativePath), root.appendingPathComponent("app/") .appendingPathComponent(relativePath)]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        if let value = try? String(contentsOf: url, encoding: .utf8) { return value }
    }
    fatalError("Run from the repository root or app directory")
}

private func section(_ text: String, from start: String, until end: String) -> String {
    guard let lower = text.range(of: start),
          let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else { return "" }
    return String(text[lower.lowerBound..<upper.lowerBound])
}

private func occursBefore(_ first: String, _ second: String, in text: String) -> Bool {
    guard let a = text.range(of: first), let b = text.range(of: second) else { return false }
    return a.lowerBound < b.lowerBound
}

let bridge = source("SourcesShared/CoreBridge.swift")
let view = source("SourcesShared/AddonsView.swift")
let sync = source("SourcesShared/VortXSyncManager.swift")
let installer = section(bridge, from: "func installAddonConfirmed", until: "struct AddonManifestPreview")
let hydration = section(bridge, from: "func hydrateAddonsFromAccount", until: "/// The native host presentation schema version.")
let syncDown = section(sync, from: "func syncDown(force: Bool = false, credentialCapture suppliedCapture:", until: "// MARK: - Account owns everything")
let warmHydration = section(syncDown, from: "case .warmHydrate:", until: "case .apply:")
let nativeAcknowledgement = section(syncDown,
    from: "guard await NativeForegroundSyncPolicy.mayAcknowledgeDocument(",
    until: "        withRemoteApplySuppressed {")

check(bridge.contains("MirrorSettings.mirrorAddons ? mirrored : local"),
      "mirror-off selects local core mutation actions")
check(installer.contains("ReplaceAddonLocal") && installer.contains("ReplaceAddon")
        && !installer.contains("dispatchCtx([\"action\": \"UninstallAddon\", \"args\": existing])"),
      "installer never pre-uninstalls a same-URL replacement")
check(installer.contains("That add-on URL is already installed.")
        && installer.contains("Replacement did not confirm. Your existing add-on was kept.")
        && installer.contains("replacingDescriptor.isProtected")
        && installer.contains("[\"configurationRequired\"] as? Bool"),
      "replacement rejects a distinct pre-existing target and retains protected/uncertain old descriptors")
check(installer.contains("AddonTombstones.tombstone(replacingDescriptor.transportUrl)")
        && occursBefore("let installConfirmed = await", "AddonTombstones.tombstone(replacingDescriptor.transportUrl)", in: installer)
        && installer.components(separatedBy: "addonMutationStillAllowed(mutationToken)").count >= 5,
      "changed URL tombstones old identity only after owner-fenced confirmation")
check(view.contains("replacingDescriptor: addon") && !view.contains("uninstallAddon(addon, tombstone: false)"),
      "Change URL dispatches one atomic replacement rather than an install/uninstall pair")
check(hydration.contains("\"InstallAddonLocal\"") && !hydration.contains("\"InstallAddon\", \"args\": addon.installDescriptor"),
      "account hydration is always local regardless of mirror setting")
check(syncDown.contains("AddonSyncPullPolicy.decision(")
        && syncDown.contains("effectiveForce: effectiveForce || requireNativeReceipt")
        && syncDown.contains("hasPendingAccountDocApply: hasPendingAccountDocApply(for: capture)")
        && syncDown.contains("credentialIsCurrent: isCurrent(capture)")
        && warmHydration.contains("CoreBridge.shared.hydrateAddonsFromAccount(Self.ownedAddons(from: pulled.doc))")
        && warmHydration.contains("outcome = .completed") && warmHydration.contains("return false")
        && !warmHydration.contains("pullDocVersionedRetrying(")
        && syncDown.components(separatedBy: "CoreBridge.shared.hydrateAddonsFromAccount(").count == 2,
      "equal-document warm hydration reuses one pulled document under the current owner policy")
check(occursBefore("guard isCurrent(capture), dataKey == capturedDataKey, !providerSettlement.superseded,",
                   "guard await NativeForegroundSyncPolicy.mayAcknowledgeDocument(", in: syncDown)
        && occursBefore("if !providerSettlement.completed {",
                        "guard await NativeForegroundSyncPolicy.mayAcknowledgeDocument(", in: syncDown)
        && nativeAcknowledgement.contains("nativeDocumentCommitted: nativeAccountDocumentCommitted")
        && nativeAcknowledgement.contains("nativeCommittedTarget.map { CoreBridge.shared.nativePlaybackTargetIsCurrent($0) }")
        && nativeAcknowledgement.contains("ensureSession: { await self.ensureNativeCheckpoint(credentialCapture: capture) }")
        && nativeAcknowledgement.contains("self.commitOwnerHistoryPulled(plaintext: plaintext, version: pulled.version,")
        && nativeAcknowledgement.contains("self.commitNativePulledDocument(pulled.doc, capture: capture)")
        && occursBefore("guard await NativeForegroundSyncPolicy.mayAcknowledgeDocument(",
                        "lastSyncedVersion = max(lastSyncedVersion, pulled.version)", in: syncDown)
        && occursBefore("lastSyncedVersion = max(lastSyncedVersion, pulled.version)",
                        "rememberCompletedNativeReceive(version: pulled.version, capture: capture, target: nativeCommittedTarget)", in: syncDown),
      "new-document acknowledgement follows settled providers and a current committed native target")

let refreshView = section(view, from: "private struct EditAddonURLView:", until: "    private func update()")
check(refreshView.contains("Refresh manifest") && refreshView.contains("Update URL")
        && !refreshView.contains("url == addon.transportUrl)")
        && refreshView.contains(".disabled(working || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)"),
      "same-URL manifest refresh is an enabled explicit action, distinct from URL replacement")
check(installer.contains("if replacingExisting || replacingDescriptor != nil {")
        && occursBefore("manifestPreviewCache.removeValue(forKey: normalized)", "takeCachedManifest(normalized)", in: installer),
      "explicit refresh evicts preview cache before fetching the latest manifest")

let profiles = source("SourcesShared/Profiles.swift")
let visibility = section(profiles, from: "func setAddonDisabledForActive", until: "    /// Whether an add-on")
check(visibility.contains("await prepareNativeAction(admission, operation: \"addon_visibility\")")
        && visibility.contains("profile.id == admission.profileID")
        && visibility.contains("await self.saveNative(profile, creating: false, target: target,")
        && visibility.contains("preferenceBaseline: baseline"),
      "visibility uses the existing original-owner preparation and acknowledged native save")
check(view.contains("let admission = core.captureNativeProfileActionAdmission()")
        && view.contains("await profiles.setAddonDisabledForActive")
        && view.contains("visibilityOperation == operation, profiles.activeID == admission.profileID")
        && view.contains("visibilityMessages[addon.transportUrl] = profiles.nativeProfileError"),
      "eye action waits once and presents failure only for its original profile operation")

let nativeFacade = source("SourcesShared/VortxNativeCoreFacade.swift")
check(view.contains("core.addonsForManagement") && !view.contains("core.addons."),
      "Add-ons controls render full management membership, not the filtered worker registry")
check(nativeFacade.contains("addon_management")
        && bridge.contains("value: values[\"addon_management\"]")
        && bridge.contains("managedAddons = managementContext.profile.addons")
        && bridge.contains("field: \"addon_management\"")
        && bridge.contains("addons = typed // no old-context"),
      "management uses the original acknowledged receipt while active addons remain separate")

if Contract.failures > 0 { exit(1) }
