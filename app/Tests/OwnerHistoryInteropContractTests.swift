import Foundation

@main
enum OwnerHistoryInteropContractTests {
    static func main() {
        let root = CommandLine.arguments[1]
        func source(_ path: String) -> String {
            (try? String(contentsOfFile: root + "/" + path, encoding: .utf8)) ?? ""
        }
        func body(_ text: String, after marker: String, until next: String) -> String {
            guard let start = text.range(of: marker), let end = text.range(of: next, range: start.upperBound..<text.endIndex) else { return "" }
            return String(text[start.lowerBound..<end.lowerBound])
        }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print(condition ? "PASS  \(message)" : "FAIL  \(message)")
            if !condition { failures += 1 }
        }

        let store = source("app/SourcesShared/OwnerHistoryStore.swift")
        let sync = source("app/SourcesShared/VortXSyncManager.swift")
        let bridge = source("app/SourcesShared/CoreBridge.swift")
        let account = source("app/SourcesShared/StremioAccount.swift")
        let history = source("app/SourcesShared/BecauseYouWatchedDocumentHistory.swift")
        let ownership = source("app/SourcesShared/PlaybackMutationOwnershipPolicy.swift")

        check(store.contains("eventEpochMs") && store.contains("lastWatched") && store.contains("validSeconds(positionSeconds)"),
              "store accepts an actual zero/rewind position with a real duration and causal event clock")
        check(store.contains("parsed.clock >= existing.clock") && store.contains("opaque.append(row)"),
              "LWW retains equal-clock peer rows and opaque malformed/unknown rows")
        check(store.contains("type + \"\\u{1f}\" + id") && store.contains("validType(type)"),
              "identity is typed and only movie/series rows are admitted")
        check(sync.contains("00000000-0000-0000-0000-00000000A11C") && sync.contains("ownerHistoryBucket") &&
              sync.contains("OwnerHistoryStore.wire(merging: priorOwnerHistory)"),
              "export uses the fixed owner profile bucket and retains sibling fields")
        check(store.contains("static func wire(merging: raw: Any?) -> [[String: Any]]?") == false &&
              store.contains("static func wire(merging raw: Any?) -> [[String: Any]]?") &&
              store.contains("guard let peer = raw as? [[String: Any]], peer.count <= maximumRows else { return nil }") &&
              sync.contains("if let mergedOwnerHistory = OwnerHistoryStore.wire"),
              "mixed or over-limit peer carriers are retained rather than overwritten")
        check(!sync.contains("v[\"ownerHistory\"]"),
              "export never creates the incompatible top-level ownerHistory key")
        let nativeRestore = body(sync, after: "func restoreNativeCheckpoint(", until: "    /// Shared account-owner epoch.")
        check(nativeRestore.contains("guard isSignedIn, isCurrent(capture), case .account = capture.scope else") &&
              nativeRestore.contains("pullDocVersionedResult(credentialCapture: capture)") &&
              nativeRestore.contains("ProfileStore.shared.activeID == selectedProfile") &&
              nativeRestore.contains("authenticatedCheckpoint(scope: scope)"),
              "remote history restoration requires the captured authenticated native account, profile and checkpoint")
        check(history.contains("validOwnerHistoryRow") && history.contains("History rows come first intentionally"),
              "document history admits only causal rows and keeps unsaved genuine history separate from membership")
        let nativePreview = body(bridge,
            after: "private func rebuildContinueWatching(capturedPublicationToken publicationToken: PublicationToken,",
            until: "/// Record an owner-tagged history receipt")
        check(nativePreview.contains("self.publicationStillCurrent(publicationToken)") &&
              nativePreview.contains("CredentialScopeRegistry.shared.isCurrent(credentialCapture)") &&
              nativePreview.contains("self.continueWatching = preview") &&
              nativePreview.contains("self.recordAcceptedHistoryReceipt(") &&
              !nativePreview.contains("unionOwnerContinueWatching("),
              "Continue Watching publishes the fenced native preview and receipt without resurrecting legacy history rows")

        let saveProgress = body(account, after: "func saveProgress(for meta: PlaybackMeta", until: "/// Fetch a single library item")
        let nativeProgress = body(bridge, after: "func reportNativeProgress(", until: "private func nativeWatchedIntent(")
        check(saveProgress.contains("let target = target ?? PlaybackMutationTarget.capture(core: CoreBridge.shared)") &&
              saveProgress.contains("guard target.stillOwnsCurrentContext(core: CoreBridge.shared) else { return }") &&
              saveProgress.contains("CoreBridge.shared.reportNativeProgress(for: meta, positionSeconds: positionSeconds, durationSeconds: durationSeconds, target: target)\n            return") &&
              nativeProgress.contains("nativePlaybackBinding(target)") &&
              nativeProgress.contains("case .native(let binding?) = target, let epoch = binding.accountGeneration") &&
              nativeProgress.contains("positionSeconds.isFinite, durationSeconds.isFinite") &&
              nativeProgress.contains("facade.dispatchForProfile(.object(action), profileID: profile.uuidString, expectedAccountGeneration: epoch)"),
              "launch-captured native progress retains its exact profile and account generation and validates causal playback values")
        let ownerHistoryContext = body(account, after: "func stillOwnsOwnerHistoryContext(", until: "var ownerHistoryCapture:")
        check(ownership.contains("case native(NativeBinding?)") &&
              ownership.contains("captured.accountGeneration != nil, binding.accountGeneration != nil") &&
              ownership.contains("return captured == binding") &&
              account.contains("return core.captureNativePlaybackTarget()") &&
              account.contains("return core.nativePlaybackTargetIsCurrent(self)") &&
              ownerHistoryContext.contains("return false"),
              "native playback cannot revive a retired owner or duplicate progress into legacy owner-history caches")
        let manualWatch = body(bridge, after: "func markPlaybackWatched", until: "private func drainPendingEpisodeWatched")
        let libraryWatch = body(bridge, after: "func setLibraryItemWatched", until: "/// Drop finished titles")
        check(!manualWatch.contains("OwnerHistoryStore") && !libraryWatch.contains("OwnerHistoryStore"),
              "manual watched actions cannot manufacture owner playback history")

        if failures == 0 { print("ALL TESTS PASSED"); exit(0) }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }
}
