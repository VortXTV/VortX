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
let hydration = section(bridge, from: "func hydrateAddonsFromAccount", until: "/// stremio-core")
let syncDown = section(sync, from: "func syncDown(force: Bool = false, credentialCapture suppliedCapture:", until: "// MARK: - Account owns everything")

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
        && syncDown.contains("effectiveForce: effectiveForce")
        && syncDown.contains("hasPendingAccountDocApply: hasPendingAccountDocApply(for: capture)")
        && syncDown.components(separatedBy: "CoreBridge.shared.hydrateAddonsFromAccount(Self.ownedAddons(from: doc))").count == 2,
      "warm sync hydrates only current certified equal/new documents without another pull")
check(occursBefore("guard isCurrent(capture), !providerSettlement.superseded else { return false }",
                   "CoreBridge.shared.hydrateAddonsFromAccount(Self.ownedAddons(from: doc))", in: syncDown),
      "new-document warm hydration follows credential settlement")

if Contract.failures > 0 { exit(1) }
