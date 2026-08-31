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

private func appearsBefore(_ needle: String, _ other: String, in source: String) -> Bool {
    guard let left = source.range(of: needle), let right = source.range(of: other) else { return false }
    return left.lowerBound < right.lowerBound
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
let settlement = section(bridge, from: "private func settleAccountBindingIfProven()", until: "private func finishSettledAccountBinding()")
let invalidation = section(bridge, from: "private func invalidatePublicationEpoch()", until: "/// ProfileStore calls")

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
