import Foundation

/// Source-level receipt for the CW/direct-resume prewarm handoff. This is intentionally independent of an
/// engine/provider fixture: it protects the launch contract that otherwise silently leaves PlayerScreen's
/// `warmNextIfNeeded` guard with a nil callback.
@main
enum AppleCWNextEpisodePreparationContractTests {
    static func main() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let iosRoot = read(root.appendingPathComponent("app/SourcesiOS/iOSRootView.swift"))
        let detail = read(root.appendingPathComponent("app/SourcesiOS/iOSDetailView.swift"))
        let preparer = read(root.appendingPathComponent("app/SourcesiOS/iOSNextEpisodePreparer.swift"))
        expect(iosRoot.contains("warmNextEpisode: item.warmNextEpisode"), "CW cover forwards prewarm callback")
        expect(iosRoot.contains("let preparer = iOSNextEpisodePreparer()"), "CW owns a launch-local provider scope")
        expect(iosRoot.contains("appleCWNavigationMeta(for: item.id, streamID: entry.videoId)"), "late metadata uses request-owned CW alias inventory")
        expect(iosRoot.contains("ProfileStore.shared.activeID == pid") && iosRoot.contains("account.credentialBoundaryGeneration == accountBoundary"), "CW fences profile and account changes")
        expect(iosRoot.contains("cancelNextEpisodePreparation") && iosRoot.contains("item.cancelNextEpisodePreparation?()"), "player teardown cancels its launch owner")
        expect(detail.contains("@StateObject private var nextEpisodePreparer = iOSNextEpisodePreparer()"), "detail uses the same reusable preparer")
        expect(preparer.contains("never dispatches `loadMeta`") && !preparer.contains("core.loadMeta")
            && !preparer.contains("loadEnginePlayer"), "preparation leaves current meta and source identity unchanged")
        expect(preparer.contains("SeriesSourceSticky.snapshot") && preparer.contains("desiredAudioLanguage: choice.audioLanguage")
            && preparer.contains("preserveChosenRelease: true"), "sticky addon, language, and release are retained")
        expect(preparer.contains("prepareWarmTorrentEngine") && preparer.contains("BoundedRangeWarmup.fetch") && preparer.contains("prepareRemuxTransport"), "torrent, byte warm, and remux preparation remain in shared path")
        expect(preparer.contains("withTaskCancellationHandler") && preparer.contains("task.cancel()"), "parent cancellation stops owned provider work")
        expect(preparer.contains("var lease: PreparedTorrentEngineLease?") && preparer.contains("guard admitted() else { return nil }"), "late lease admission is registered for cleanup")
        expect(preparer.contains("stale after remux readiness") && preparer.contains("attachment?.abandon"), "late remux admission abandons its handle")
        countedOwnershipCoordinatorTests()
        print("ALL PASS")
    }
    /// Pure executable model of the two resources acquired across awaits. This protects the lifecycle rule
    /// independent of network/media frameworks: cancellation after either acquisition must clean it once;
    /// replacement must not let an old owner cancel a future owner.
    private static func countedOwnershipCoordinatorTests() {
        final class Counted { var releases = 0; func release() { releases += 1 } }
        final class Owner {
            var generation = 0; var lease: Counted?; var remux: Counted?
            func replace() { cancel(generation); generation += 1 }
            func cancel(_ owner: Int) {
                guard owner == generation else { return }
                lease?.release(); lease = nil; remux?.release(); remux = nil
            }
            func attachLease(_ resource: Counted, owner: Int) { if owner != generation { resource.release() } else { lease = resource } }
            func attachRemux(_ resource: Counted, owner: Int) { if owner != generation { resource.release() } else { remux = resource } }
        }
        let owner = Owner(); let lease = Counted(); let remux = Counted()
        owner.attachLease(lease, owner: 0); owner.replace()
        expect(lease.releases == 1, "parent cancellation cleans lease exactly once")
        owner.attachRemux(remux, owner: 0)
        expect(remux.releases == 1, "stale remux is cleaned without touching future scope")
        let currentRemux = Counted(); owner.attachRemux(currentRemux, owner: 1); owner.cancel(1)
        expect(currentRemux.releases == 1, "current owner cleans remux exactly once")
    }
    private static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }
}
