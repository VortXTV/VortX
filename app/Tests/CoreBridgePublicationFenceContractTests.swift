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

private func source() -> String {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let candidates = [
        cwd.appendingPathComponent("app/SourcesShared/CoreBridge.swift"),
        cwd.appendingPathComponent("SourcesShared/CoreBridge.swift"),
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

let bridge = source()
let seed = section(bridge, from: "private func seedInitialState()", until: "/// Refresh the installed-addons")
let refresh = section(bridge, from: "private func refreshAddons()", until: "/// Remove an installed addon")
let continueWatching = section(bridge, from: "func rebuildContinueWatching()", until: "/// FLOOR each engine")
let event = section(bridge, from: "fileprivate func handleEvent", until: "// MARK: meta_details coalesce")
let meta = section(bridge, from: "private func scheduleMetaDetailsRepublish()", until: "private static func appleCWMetaRefreshIsSettled")
let board = section(bridge, from: "private func scheduleBoardRebuild()", until: "private func buildBoardRows()")
let rebuild = section(bridge, from: "func rebuildBoardRows()", until: "/// The Home board rows")
let repair = section(bridge, from: "private func scheduleSessionRepair()", until: "/// Refresh installed addons")

check(bridge.contains("private let publicationEpochLock = NSLock()")
                && bridge.contains("private func capturePublicationToken() -> PublicationToken")
                && bridge.contains("private func invalidatePublicationEpoch()"),
              "production owns a lock-backed worker-safe publication epoch")
check(!event.contains("let publicationGeneration = authBindingGeneration")
                && event.contains("let publicationToken = capturePublicationToken()"),
              "Rust NewState worker never reads main-owned auth generation")
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
