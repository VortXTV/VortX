import Foundation

// The runner extracts the production query, grouping, state helpers, HubTarget and CoreMeta into a
// disposable fixture. These small inventory/prefs fixtures never load accounts, content or artwork.
enum DiscoverList: String, CaseIterable, Hashable {
    case trending, popular, latest, upcoming
    var title: String { rawValue.capitalized }
}
struct GenreSpec: Hashable { let title: String }
struct DecadeSpec: Hashable { let title: String; let startYear: Int }
struct ProviderTile { let providerID: Int; let name: String }
final class CollectionsHubModel {
    static var isAvailable = true
    var discover = DiscoverList.allCases
    var providers = [ProviderTile(providerID: 8, name: "Netflix"),
                     ProviderTile(providerID: 350, name: "Apple TV+"),
                     ProviderTile(providerID: 777, name: "Crème Cinema")]
    var genres = [GenreSpec(title: "Action"), GenreSpec(title: "Anime")]
    var decades = [DecadeSpec(title: "1990s", startYear: 1990), DecadeSpec(title: "2000s", startYear: 2000)]
}
final class CatalogPreferences {
    var hidden = Set<String>()
    func isCategoryHidden(_ key: String) -> Bool { hidden.contains(key) }
}
final class CoreBridge {
    var searchResults: [CoreMeta] = []
    var searchIsLoading = false
}

@main
enum TVSearchCollectionsTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        checks += 1
    }
    static func meta(id: String, type: String) throws -> CoreMeta {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "type": type, "name": id])
        return try JSONDecoder().decode(CoreMeta.self, from: data)
    }
    static func main() throws {
        let search = ProductionTVSearch()
        let baseline = CommandLine.arguments.contains("--baseline")
        search.query = "  NETFLIX  "
        search.core.searchResults = [try meta(id: "addon-collection", type: "collection")]
        if baseline {
            expect(search.matchingCollections.isEmpty, "baseline has no collection inventory consumer")
            expect(search.sectionSnapshot().map { $0.0 } == ["Other"], "baseline sends addon collections to Other")
            print("RED baseline: Netflix has no browse target; addon collection is in Other")
            return
        }
        expect(search.matchingCollections == [.service(id: 8, name: "Netflix")],
               "trimmed case-insensitive query retains the real provider id and name")
        expect(search.sectionSnapshot().map { $0.0 } == ["Collections"],
               "inventory and addon results share one Collections section")
        expect(search.sectionSnapshot()[0].1.map(\.id) == ["addon-collection"],
               "an addon collection keeps its original metadata target")
        search.core.searchResults = []
        expect(search.sectionSnapshot().map { $0.0 } == ["Collections"],
               "a real inventory match renders without any addon result")

        for (query, target) in [("Tren", HubTarget.discover(.trending)),
                                ("anim", .genre(GenreSpec(title: "Anime"))),
                                ("1990", .decade(DecadeSpec(title: "1990s", startYear: 1990))),
                                ("creme", .service(id: 777, name: "Crème Cinema"))] {
            search.query = query
            expect(search.matchingCollections == [target], "\(query) matches an existing browse target")
        }
        search.query = "n"
        expect(!search.hasSearchQuery && search.matchingCollections.isEmpty,
               "one character never publishes a collection match")
        expect(search.emptyText.hasPrefix("Start typing"), "one character does not claim no matches")
        search.query = " \n "
        expect(!search.isTyping && search.matchingCollections.isEmpty, "whitespace clears the collection rail")
        search.query = "zz-no-such-inventory"
        expect(search.matchingCollections.isEmpty && search.sectionSnapshot().isEmpty,
               "an unknown name never invents a collection entity")
        expect(search.emptyText.hasPrefix("No matches"), "settled empty search retains its no-match state")
        search.searchDebouncePending = true
        expect(search.emptyText == "Searching...", "pending debounce retains its loading state")
        search.searchDebouncePending = false
        search.core.searchIsLoading = true
        expect(search.emptyText == "Searching...", "addon loading retains its loading state")
        search.query = ""
        expect(!search.isWaitingForCurrentQuery, "cleared query cannot show a stale addon spinner")
        search.core.searchIsLoading = false

        for (query, key) in [("trending", HubCategoryKey.discover(.trending)),
                             ("anime", HubCategoryKey.genre(GenreSpec(title: "Anime"))),
                             ("1990", HubCategoryKey.decade(DecadeSpec(title: "1990s", startYear: 1990))),
                             ("Netflix", HubCategoryKey.streamingSection),
                             ("trending", HubCategoryKey.discoverSection),
                             ("anime", HubCategoryKey.genresSection),
                             ("1990", HubCategoryKey.decadesSection)] {
            search.query = query
            search.catalogPrefs.hidden = [key]
            expect(search.matchingCollections.isEmpty, "\(key) hiding applies to live search")
            search.catalogPrefs.hidden = []
            expect(search.matchingCollections.count == 1, "\(key) showing restores the existing target")
        }
        CollectionsHubModel.isAvailable = false
        expect(search.matchingCollections.isEmpty, "remote availability gate hides only hub targets")
        search.core.searchResults = [try meta(id: "addon-owned", type: "collections")]
        expect(search.sectionSnapshot().map { $0.0 } == ["Collections"],
               "addon collection remains supported when the hub is unavailable")
        CollectionsHubModel.isAvailable = true

        search.query = "nothing-in-inventory"
        search.core.searchResults = try [
            ("first-collection", "collection"), ("first-movie", "movie"), ("first-series", "series"),
            ("second-collection", "collections"), ("second-movie", "movie"), ("channel", "tv"),
            ("unknown", "unrecognized"), ("second-series", "series")
        ].map { try meta(id: $0.0, type: $0.1) }
        let sections = search.sectionSnapshot()
        expect(sections.map { $0.0 } == ["Movies", "Series", "Collections", "Other"],
               "result sections retain the requested order")
        expect(sections.map { $0.1.map(\.id) } == [["first-movie", "second-movie"],
            ["first-series", "second-series"], ["first-collection", "second-collection"], ["channel", "unknown"]],
               "classification retains source order and exact addon identities")
        expect(sections[2].1.map(\.type) == ["collection", "collections"],
               "both real addon collection type spellings use the Collections rail")
        search.core.searchResults = []
        expect(search.sectionSnapshot().isEmpty, "empty groups never create empty rails")
        print("PASS TVSearchCollectionsTests: \(checks) actual-source query, target, grouping and state checks")
    }
}
