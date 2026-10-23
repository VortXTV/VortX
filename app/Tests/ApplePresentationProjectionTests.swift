import Foundation
import Combine

// Source-only fixtures: no live accounts, persistence, native engine, UI or playback.
enum EpisodePlaybackIdentity {
    static func usesSeriesLifecycle(type: String) -> Bool { ["series", "show", "tv"].contains(type) }
}
struct FixtureBoardRow { let items: [CoreMeta] }
final class CoreBridge: ObservableObject {
    static let shared = CoreBridge()
    var usesNativeProfileState = false
    @Published var revision = 0
    @Published var continueWatching: [CoreCWItem] = []
    @Published var boardRows: [FixtureBoardRow] = []
    @Published var searchResults: [CoreMeta] = []
    @Published var searchIsLoading = false
    @Published var searchSuggestions: [String] = []
    func searchSuggestionTitles(for query: String) -> [String] { [] }
}

@main
struct ApplePresentationProjectionTests {
    static var checks = 0
    static let links = try! JSONDecoder().decode([CoreLink].self, from: Data(
        #"[{"name":"8.1","category":"imdb","url":"https://fixture.invalid"},{"name":"Drama","category":"Genres","url":"https://fixture.invalid"}]"#.utf8))
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        checks += 1
    }
    static func meta(_ index: Int, name: String? = nil, poster: String? = nil) -> CoreMeta {
        CoreMeta(id: "result-\(index)", type: ["movie", "series", "collection", "collections", "channel"][index % 5],
            name: name ?? "Title \(index)", poster: poster ?? "https://fixture.invalid/poster/\(index)",
            posterShape: nil, logo: nil, background: "https://fixture.invalid/backdrop/\(index)",
            description: "Description \(index)", releaseInfo: "2026",
            links: links)
    }
    static func main() throws {
        let core = CoreBridge()
        let profiles = ProfileStore()
        let now = ISO8601DateFormatter().string(from: Date())
        profiles.watch = Dictionary(uniqueKeysWithValues: (0..<1000).map { index in
            (String(format: "tt%07d", index), WatchEntry(videoId: nil, timeOffsetMs: 10_000 + index,
                durationMs: 100_000, lastWatched: now, name: "Watch \(index)", type: "movie",
                poster: "https://fixture.invalid/watch/\(index)"))
        })
        var home = ProductionHomeProjection(core: core, profiles: profiles)
        expect(home.refreshOverlayHistoryProjection(), "initial real overlay builds its projection")
        expect(profiles.cwBuilds == 1 && profiles.libraryBuilds == 1, "1000 watch entries sort once each")
        expect(home.overlayHistory.value?.cw.count == 1000, "the cache retains the source's full selection")
        let originalKey = home.homeHistoryKey
        expect(originalKey.count == 30, "Home's body observer is bounded to thirty")
        for _ in 0..<1000 { core.revision += 1; _ = home.homeHistoryKey }
        expect(profiles.cwBuilds == 1 && profiles.libraryBuilds == 1, "unrelated revisions never sort the watch dictionary")
        expect(!home.refreshOverlayHistoryProjection(), "duplicate source publication is a cache hit")
        expect(profiles.cwBuilds == 1 && profiles.libraryBuilds == 1, "duplicate watch source avoids both builders")
        profiles.watch["tt0000009"]?.timeOffsetMs += 500
        expect(home.refreshOverlayHistoryProjection(), "one interior watch mutation refreshes once")
        expect(profiles.cwBuilds == 2 && profiles.libraryBuilds == 2, "one mutation runs each production builder once")
        expect(home.homeHistoryKey != originalKey, "interior progress changes the bounded key")
        let progressKey = home.homeHistoryKey
        profiles.watch["tt0000009"]?.poster = "https://fixture.invalid/replacement"
        _ = home.refreshOverlayHistoryProjection()
        expect(home.homeHistoryKey != progressKey, "same-ID interior artwork changes the bounded key")
        let beforeTailKey = home.homeHistoryKey
        profiles.watch["tail-owned-title"] = WatchEntry(videoId: nil, timeOffsetMs: 1000, durationMs: 100_000,
            lastWatched: "2000-01-01T00:00:00Z", name: "Tail owned title", type: "movie", poster: nil)
        expect(home.refreshOverlayHistoryProjection(), "a real tail ownership mutation refreshes the full cached source")
        expect(home.homeHistoryKey == beforeTailKey, "tail ownership mutation leaves the bounded visible observer unchanged")
        expect(home.overlayHistory.value?.library.contains { $0.id == "tail-owned-title" } == true,
               "recommendation ownership exclusion retains titles beyond the bounded observer")
        let oldProfileBuilds = profiles.cwBuilds
        profiles.activeID = UUID()
        _ = home.refreshOverlayHistoryProjection()
        expect(profiles.cwBuilds == oldProfileBuilds + 1, "same history in another profile replaces the projection")
        let selected = ContinueWatchingPreferences.bounded(home.overlayHistory.value!.cw, window: .hundred,
            now: Date(), activity: { $0.state.lastWatched }, identity: { $0.type + "|" + $0.id })
        expect(selected.count == 100, "the selected 100-item window is preserved independently of the observer bound")
        let dated = ContinueWatchingPreferences.bounded(home.overlayHistory.value!.cw, window: .last90Days,
            now: Date(), activity: { $0.state.lastWatched }, identity: { $0.type + "|" + $0.id })
        expect(dated.count == 1000, "90-day selection retains all qualifying history")

        var resultBuilds = 0
        let presentation = AppleSearchPresentation { results in
            resultBuilds += 1
            return AppleSearchResultProjection(results)
        }
        presentation.bind(to: core)
        expect(resultBuilds == 1, "subscriber receives its initial accepted snapshot once")
        presentation.bind(to: core)
        expect(resultBuilds == 1, "second search surface reuses the existing subscription")
        let results = (0..<1000).map { meta($0) }
        core.searchResults = results
        expect(resultBuilds == 2, "one accepted 1000-result publication builds once")
        expect(presentation.results.count == 1000, "every accepted result is retained")
        expect(presentation.results.sections.map(\.id) == [.movies, .series, .collections, .other], "four groups retain their rail order")
        expect(presentation.results.sections.map { $0.items.count } == [200, 200, 400, 200], "both collection spellings share the Collections rail")
        for section in presentation.results.sections {
            let expected = results.filter { AppleSearchResultProjection.Group(type: $0.type) == section.id }
            expect(section.items.map(\.id) == expected.map(\.id), "group keeps accepted source order")
            for (card, source) in zip(section.items, expected) {
                expect(card.name == source.name && card.poster == source.poster && card.background == source.background
                    && card.description == source.description && card.releaseInfo == source.releaseInfo
                    && card.imdbRating == source.imdbRating && card.genres == source.genres && card.progress == 0,
                    "production card conversion preserves every displayed field")
            }
        }
        for _ in 0..<1000 { core.revision += 1; _ = presentation.results.sections }
        expect(resultBuilds == 2, "1000 unrelated engine revisions cause no regrouping or conversions")
        core.searchResults = results
        expect(resultBuilds == 2, "identical accepted search re-publication on a library tick never regroups or converts cards")
        core.boardRows = [FixtureBoardRow(items: results)]
        core.continueWatching = home.overlayHistory.value!.cw
        core.searchSuggestions = ["Fixture suggestion"]
        expect(resultBuilds == 2, "real unrelated board/history/suggestion publications never rebuild result cards")
        core.searchIsLoading = true
        expect(presentation.isLoading && presentation.results.count == 1000 && resultBuilds == 2,
               "incremental results stay visible while loading without rebuilding")
        var replacement = results
        replacement[9] = meta(9, name: "Replacement", poster: "https://fixture.invalid/new-art")
        core.searchResults = replacement
        expect(resultBuilds == 3, "same-count interior replacement is an accepted result publication")
        expect(presentation.results.sections.last?.items[1].name == "Replacement", "interior replacement reaches its existing rail")

        let fence = CoreSearchPublicationFence()
        let first = fence.prepare("alpha").token
        _ = fence.prepare("beta")
        let current = fence.prepare("alpha").token
        func publish(_ token: UUID, _ values: [CoreMeta]) { if fence.accepts(token) { core.searchResults = values } }
        publish(first, results)
        expect(resultBuilds == 3, "stale A-to-B-to-A result never reaches the projection")
        publish(current, results)
        expect(resultBuilds == 4, "current accepted generation refreshes once")
        _ = fence.prepare("")
        core.searchResults = []
        publish(current, results)
        expect(presentation.results.isEmpty && resultBuilds == 5, "query clearing retires old cards and rejects late results")
        let reset = fence.prepare("alpha").token
        fence.invalidate()
        publish(reset, results)
        expect(resultBuilds == 5, "owner reset rejects the old accepted generation")

        let root = CommandLine.arguments[1]
        let source = try String(contentsOfFile: root + "/app/SourcesiOS/iOSRootView.swift", encoding: .utf8)
        let homeSource = source.components(separatedBy: "struct iOSHomeView: View {")[1]
            .components(separatedBy: "/// Reorder + hide the Home rows")[0]
        expect(!homeSource.contains("observationSignature(items: profiles.cwItems)"), "Home body no longer sorts overlay to form a signature")
        expect(homeSource.contains("cw = overlayHistory.value(for: profiles.activeID)?.cw ?? []")
            && homeSource.contains("library = overlayHistory.value(for: profiles.activeID)?.library ?? []"),
            "recommendation models receive the entire cached ownership exclusion input")
        let watchObserver = homeSource.components(separatedBy: ".onReceive(profiles.$watch) { watch in")[1]
            .components(separatedBy: ".onChange(of: profiles.activeID)")[0]
        expect(watchObserver.contains("refreshOverlayHistoryProjection()") && watchObserver.contains("refreshTopPicks()"),
               "real tail watch publication refreshes recommendation exclusion even when the visible key stays unchanged")
        expect(!source.contains("core.searchResults.filter"), "both search surfaces consume the shared production projection")
        let searchSource = source.components(separatedBy: "struct iOSSearchView: View {")[1]
            .components(separatedBy: "struct iOSDiscoverView: View {")[0]
        expect(!searchSource.contains("@EnvironmentObject private var core"), "dedicated Search does not subscribe to the whole engine")
        let picker = try String(contentsOfFile: root + "/app/SourcesShared/ProfilesView.swift", encoding: .utf8)
        let pickerSource = picker.components(separatedBy: "struct ProfilePickerView: View {")[1]
            .components(separatedBy: "private struct ProfilePickerMovie:")[0]
        expect(!pickerSource.contains("@EnvironmentObject private var core") && pickerSource.contains("captureNativeProfileActionAdmission()"),
               "picker captures current action admission without observing engine publications")
        print("ApplePresentationProjectionTests: \(checks) checks passed; 1000 watch / 1000 search fixtures, production subscriber and cache")
    }
}
