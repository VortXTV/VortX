import Foundation

// Injectable dependencies for the exact shipping CoreBridge TV extension. They are deliberately
// inert: only JSON reads and page callback indices exist; no app, account, provider, or engine boots.
@MainActor final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID? = UUID()
}
struct PlaybackMutationTarget: Hashable {
    let generation: Int
    @MainActor static func capture(core: CoreBridge) -> Self { .init(generation: core.ownerGeneration) }
    @MainActor func stillOwnsCurrentContext(core: CoreBridge) -> Bool { generation == core.ownerGeneration }
}
struct CoreBoardRow {
    let id: String
    let title: String
    let type: String
    let items: [CoreMeta]
    let engineIndex: Int
}
@MainActor final class CoreBridge {
    var ownerGeneration = 1
    var boardRows: [CoreBoardRow] = []
    var raw: [String: Data] = [:]
    var callbacks: [Int] = []
    func decode<T: Decodable>(_ type: T.Type, field: String) -> T? {
        raw[field].flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    func loadBoardRowNextPage(engineIndex: Int) { callbacks.append(engineIndex) }
}

@main
enum TVCatalogBrowseNavigationTests {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let core = CoreBridge()
        let item = try JSONDecoder().decode(CoreMeta.self, from: Data(#"{"id":"film","type":"anime","name":"Film"}"#.utf8))
        let id = "https://addon.example/manifest.json|anime|popular"
        let row = CoreBoardRow(id: id, title: "Popular Anime", type: "anime", items: [item], engineIndex: 0)
        let request = #"{"base":"https://addon.example/manifest.json","path":{"resource":"catalog","type":"anime","id":"popular","extra":[["genre","Drama"],["skip","0"]]}}"#
        let page = #"{"request":REQUEST,"content":{"type":"Ready","content":[{"id":"film"}]}}"#.replacingOccurrences(of: "REQUEST", with: request)
        let board = #"{"catalogs":[[PAGE]]}"#.replacingOccurrences(of: "PAGE", with: page)
        core.raw["board"] = Data(board.utf8)
        core.raw["ctx"] = Data(#"{"profile":{"addons":[{"transportUrl":"https://addon.example/manifest.json","manifest":{"catalogs":[{"id":"popular","type":"anime","extra":[{"name":"skip"}]}]}}]}}"#.utf8)
        core.boardRows = [row]
        let target = try unwrap(core.captureTVCatalogBrowse(row: row, accountBoundaryGeneration: 7))
        expect(target.request.filters == [["genre", "Drama"]] && target.profileID == ProfileStore.shared.activeID, "activation captures actual request and owner")
        core.pageTVCatalogBrowse(target, accountBoundaryGeneration: 7)
        expect(core.callbacks == [0], "real production extension calls the existing page action")
        core.pageTVCatalogBrowse(target, accountBoundaryGeneration: 8)
        core.pageTVCatalogBrowse(target, accountBoundaryGeneration: 7, invalidated: true)
        expect(core.callbacks == [0], "boundary replacement and route invalidation cannot page")
        let originalProfile = ProfileStore.shared.activeID
        ProfileStore.shared.activeID = UUID()
        core.pageTVCatalogBrowse(target, accountBoundaryGeneration: 7)
        ProfileStore.shared.activeID = originalProfile
        core.ownerGeneration = 2
        core.pageTVCatalogBrowse(target, accountBoundaryGeneration: 7)
        expect(core.callbacks == [0], "profile replacement and same-profile owner reopen cannot page")
        core.ownerGeneration = 1
        core.raw["board"] = Data(board.replacingOccurrences(of: "Drama", with: "Comedy").utf8)
        core.pageTVCatalogBrowse(target, accountBoundaryGeneration: 7)
        expect(core.callbacks == [0], "same base/type/catalog with another filter does not reuse the target")
        core.raw["board"] = Data(board.utf8)
        core.boardRows = []
        core.pageTVCatalogBrowse(target, accountBoundaryGeneration: 7)
        expect(core.callbacks == [0], "hidden/removed published rows cannot page")
        let other = page.replacingOccurrences(of: "popular", with: "other")
        core.raw["board"] = Data(#"{"catalogs":[[OTHER],[PAGE]]}"#.replacingOccurrences(of: "OTHER", with: other).replacingOccurrences(of: "PAGE", with: page).utf8)
        core.boardRows = [.init(id: id, title: row.title, type: row.type, items: row.items, engineIndex: 1)]
        core.pageTVCatalogBrowse(target, accountBoundaryGeneration: 7)
        expect(core.callbacks == [0, 1], "production extension resolves changed engine index before dispatch")
        core.raw["ctx"] = Data(#"{"profile":{"addons":[{"transportUrl":"https://addon.example/manifest.json","manifest":{"catalogs":[{"id":"popular","type":"anime"}]}}]}}"#.utf8)
        core.pageTVCatalogBrowse(target, accountBoundaryGeneration: 7)
        expect(core.callbacks == [0, 1], "undeclared skip cannot expose a dead paging action")
        print("TVCatalogBrowseNavigationTests: \(checks) checks passed")
    }

    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "TVCatalogBrowseNavigationTests", code: 1) }
        return value
    }
}
