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
        expect(iosRoot.contains("guard core.metaDetails?.meta?.id == item.id else { return [] }"), "late metadata is read at warm time")
        expect(iosRoot.contains("ProfileStore.shared.activeID == pid") && iosRoot.contains("account.credentialBoundaryGeneration == accountBoundary"), "CW fences profile and account changes")
        expect(detail.contains("@StateObject private var nextEpisodePreparer = iOSNextEpisodePreparer()"), "detail uses the same reusable preparer")
        expect(preparer.contains("never dispatches `loadMeta`") && !preparer.contains("core.loadMeta")
            && !preparer.contains("loadEnginePlayer"), "preparation leaves current meta and source identity unchanged")
        expect(preparer.contains("SeriesSourceSticky.snapshot") && preparer.contains("desiredAudioLanguage: choice.audioLanguage")
            && preparer.contains("preserveChosenRelease: true"), "sticky addon, language, and release are retained")
        expect(preparer.contains("prepareWarmTorrentEngine") && preparer.contains("BoundedRangeWarmup.fetch") && preparer.contains("prepareRemuxTransport"), "torrent, byte warm, and remux preparation remain in shared path")
        print("ALL PASS")
    }
    private static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }
}
