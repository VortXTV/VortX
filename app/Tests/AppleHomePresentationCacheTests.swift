import Foundation

struct FixtureBoardRow { let items: [CoreMeta] }
struct FixtureMetaDetails { let meta: CoreMetaItem? }
struct FixtureVideo { let id: String; let season: Int?; let episode: Int? }
struct CoreMetaItem {
    let id: String
    let type: String
    var runtime: String? = nil
    var releaseInfo: String? = nil
    var videos: [FixtureVideo]? = nil
    var background: String? = nil
    var description: String? = nil
    var imdbRating: String? = nil
    var genres: [String]? = nil
}
enum HomeCacheCounters {
    static var selectionPasses = 0
    static var cardPasses = 0
}

@main
struct AppleHomePresentationCacheTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        checks += 1
    }
    static func item(_ index: Int, offset: Double = 10_000, poster: String? = nil) -> CoreCWItem {
        CoreCWItem(id: String(format: "watch-%04d", index), type: "movie", name: "Watch \(index)",
            poster: poster ?? "https://fixture.invalid/watch/\(index)",
            state: CoreLibState(timeOffset: offset, duration: 100_000, videoId: nil,
                lastWatched: ISO8601DateFormatter().string(from: Date())))
    }
    static func main() {
        let core = CoreBridge.shared
        core.usesNativeProfileState = false
        let profiles = ProfileStore.shared
        let profileID = UUID()
        profiles.activeID = profileID
        profiles.activeUsesEngineHistory = false
        profiles.active = UserProfile(id: profileID, usesEngineHistory: false,
            discovery: .init(continueWatchingSource: "local", continueWatchingWindow: "100"))
        core.nativeBinding = .init(profileID: profileID,
            credential: CredentialScopeRegistry.shared.capture(), sessionGeneration: UUID(), accountGeneration: UUID())
        UserDefaults.standard.reset()
        UserDefaults.standard.set("local", forKey: ContinueWatchingPreferences.sourceKey)
        UserDefaults.standard.set("100", forKey: ContinueWatchingPreferences.windowKey)
        let source = (0..<1000).map { item($0) }
        let home = ProductionHomePresentation(core: core, profiles: profiles)
        expect(home.continueWatchingRenderSnapshot.items.isEmpty
            && !home.continueWatchingSnapshot.intent.isCurrent(core: core, profiles: profiles),
            "newly mounted Home has no producer admission before a source refresh")
        home.overlayHistory.accept([:], owner: profileID) { (cw: source, library: source) }
        home.refreshContinueWatchingPresentation()
        expect(home.continueWatchingRenderSnapshot.items.count == 100, "production Home cache preserves the selected 100-card window")
        expect(HomeCacheCounters.selectionPasses == 1 && HomeCacheCounters.cardPasses == 1,
               "production Home refresh performs one selection and one conversion pass")
        for _ in 0..<1000 { _ = home.continueWatchingRenderSnapshot; _ = home.continueWatchingSnapshot }
        expect(HomeCacheCounters.selectionPasses == 1 && HomeCacheCounters.cardPasses == 1,
               "1000 unrelated body reads neither reselect nor reconvert Home cards")
        home.refreshContinueWatchingPresentation(localItems: source)
        home.refreshContinueWatchingAfterHistoryReceipt()
        expect(HomeCacheCounters.selectionPasses == 1 && HomeCacheCounters.cardPasses == 1,
               "identical history payload and its following receipt neither sort nor reconvert Home cards")

        var changed = source
        changed[9] = item(9, offset: 25_000, poster: "https://fixture.invalid/replaced-art")
        home.refreshContinueWatchingPresentation(localItems: changed)
        let card = home.continueWatchingRenderSnapshot.items.first { $0.id == "watch-0009" }
        expect(card?.progress == 0.25 && card?.resumeSeconds == 25 && card?.poster == "https://fixture.invalid/replaced-art",
               "one real interior source publication updates progress, resume and artwork")
        expect(HomeCacheCounters.selectionPasses == 2 && HomeCacheCounters.cardPasses == 2,
               "one real history refresh adds exactly one selection/conversion pass")
        core.boardRows = [FixtureBoardRow(items: [CoreMeta(id: "watch-0009", type: "movie", name: "Catalog name",
            poster: "https://fixture.invalid/catalog-poster", posterShape: nil, logo: nil,
            background: "https://fixture.invalid/resident-background", description: "Resident synopsis", releaseInfo: "2026", links: nil)])]
        home.refreshContinueWatchingPresentation(selectionChanged: false)
        let enriched = home.continueWatchingRenderSnapshot.items.first { $0.id == "watch-0009" }
        expect(enriched?.background == "https://fixture.invalid/resident-background" && enriched?.description == "Resident synopsis",
               "same-ID resident metadata enriches the retained history card")
        expect(enriched?.poster == "https://fixture.invalid/replaced-art" && enriched?.progress == 0.25,
               "resident catalog enrichment preserves history artwork and resume authority")
        expect(HomeCacheCounters.selectionPasses == 2 && HomeCacheCounters.cardPasses == 3,
               "metadata publication reconverts without sorting or selecting history again")

        let rendered = home.continueWatchingRenderSnapshot
        expect(rendered.provenance.intent.isCurrent(core: core, profiles: profiles), "cached producer is current before a boundary")
        profiles.activeID = UUID()
        expect(home.continueWatchingRenderSnapshot.items.isEmpty, "profile boundary synchronously hides cached history")
        expect(!rendered.provenance.intent.isCurrent(core: core, profiles: profiles), "rendered action retains its original retired profile intent")
        profiles.activeID = profileID
        ContinueWatchingPreferences.retireSelection()
        expect(home.continueWatchingRenderSnapshot.items.isEmpty, "preference epoch retirement hides cached history before refresh")
        home.refreshContinueWatchingPresentation()
        expect(home.continueWatchingRenderSnapshot.items.count == 100, "acknowledged refresh replaces retired presentation")
        CredentialScopeRegistry.shared.generation += 1
        expect(home.continueWatchingRenderSnapshot.items.isEmpty, "credential replacement retires the cached producer")

        // A metadata/receipt refresh can reselect after an epoch boundary. The new selection
        // must carry its own input key, so returning to the old payload is not a cache hit.
        core.usesNativeProfileState = true
        profiles.activeUsesEngineHistory = true
        profiles.active = UserProfile(id: profileID, usesEngineHistory: true,
            discovery: .init(continueWatchingSource: "local", continueWatchingWindow: "100"))
        core.nativeBinding = .init(profileID: profileID,
            credential: CredentialScopeRegistry.shared.capture(), sessionGeneration: UUID(), accountGeneration: UUID())
        core.continueWatching = source
        let race = ProductionHomePresentation(core: core, profiles: profiles)
        race.refreshContinueWatchingPresentation()
        ContinueWatchingPreferences.retireSelection()
        core.continueWatching = changed
        race.refreshContinueWatchingPresentation(selectionChanged: false)
        expect(race.cachedContinueWatching?.localInput == AppleHomeHistoryProjection.inputKey(changed),
               "retired-context reselection stores the new payload key alongside the new snapshot")
        expect(race.continueWatchingRenderSnapshot.items.first { $0.id == "watch-0009" }?.progress == 0.25,
               "metadata refresh after epoch retirement reselects the committed incoming history")
        race.refreshContinueWatchingPresentation(localItems: source)
        let restored = race.continueWatchingRenderSnapshot.items.first { $0.id == "watch-0009" }
        expect(restored?.progress == 0.1 && restored?.poster == "https://fixture.invalid/watch/9",
               "return to the previous payload replaces the newer snapshot instead of falsely hitting its old key")
        ContinueWatchingPreferences.retireSelection()
        race.refreshContinueWatchingAfterHistoryReceipt()
        expect(race.continueWatchingRenderSnapshot.items.count == 100,
               "receipt still admits a newly settled or retired producer using the committed source")
        print("AppleHomePresentationCacheTests: \(checks) checks passed; production Home selection, card conversion and stale-intent guard")
    }
}
