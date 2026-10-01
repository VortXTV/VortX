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
        check(sync.contains("OwnerHistoryStore.mergeWire(history[\"ownerHistory\"], capture: capture)") &&
              sync.contains("withRemoteApplySuppressed") && sync.contains("refreshOwnerResumeCache(from: doc)"),
              "remote owner history is capture-fenced, self-echo-suppressed, and hydrates resume")
        check(history.contains("validOwnerHistoryRow") && history.contains("History rows come first intentionally"),
              "document history admits only causal rows and keeps unsaved genuine history separate from membership")
        check(bridge.contains("history: BecauseYouWatchedDocumentHistory.ownerHistoryItems") &&
              bridge.contains("engine + pruneFinished(history) + pruneFinished(synthesized)"),
              "Continue Watching can render owner history without adding it to the engine library")

        let saveProgress = body(account, after: "func saveProgress(for meta: PlaybackMeta", until: "/// Fetch a single library item")
        check(saveProgress.contains("OwnerHistoryStore.recordPlayback") && saveProgress.contains("credentialCapture") &&
              saveProgress.contains("if let credentialCapture = target.ownerHistoryCapture") &&
              saveProgress.contains("target.stillOwnsOwnerHistoryContext") &&
              !saveProgress.contains("let credentialCapture = CredentialScopeRegistry.shared.capture()") &&
              saveProgress.range(of: "OwnerHistoryStore.recordPlayback")!.lowerBound < saveProgress.range(of: "guard ProfileSync.alsoSyncToStremio")!.lowerBound,
              "only immutable launch-captured owner progress enters history before the optional mirror gate")
        check(ownership.contains("historyCapture: CredentialScopeRegistry.Capture?") &&
              account.contains("profiles.activeID == UserProfile.ownerID && profiles.active?.isOwner == true") &&
              account.contains("profileID == UserProfile.ownerID") &&
              account.contains("CredentialScopeRegistry.shared.isCurrent(historyCapture)"),
              "only the canonical owner profile with its original credential epoch can write history")
        let manualWatch = body(bridge, after: "func markPlaybackWatched", until: "private func drainPendingEpisodeWatched")
        let libraryWatch = body(bridge, after: "func setLibraryItemWatched", until: "/// Drop finished titles")
        check(!manualWatch.contains("OwnerHistoryStore") && !libraryWatch.contains("OwnerHistoryStore"),
              "manual watched actions cannot manufacture owner playback history")

        if failures == 0 { print("ALL TESTS PASSED"); exit(0) }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }
}
