import Foundation

@main
enum TVCatalogCinemaPolicyTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        let decoder = JSONDecoder()
        let preview = try decoder.decode(CoreMeta.self, from: Data(#"{"id":"opaque:film","type":"anime","name":"Actual title","poster":"poster","background":"wide","runtime":"126 min","releaseInfo":"2024","description":"Authored synopsis","links":[{"name":"8.2","category":"imdb","url":"rating"}]}"#.utf8))
        let card = TVCinemaCardPresentation.meta(preview)
        expect(card.runtime == "126 min" && card.releaseInfo == "2024" && card.rating == "8.2", "real preview facts survive the production projection")
        expect(card.type == "anime" && card.id == "opaque:film", "custom content routes retain opaque identity")
        expect(card.overview == "Authored synopsis" && card.background == "wide", "authored artwork and body survive")
        let sparse = try decoder.decode(CoreMeta.self, from: Data(#"{"id":"sparse","type":"movie","name":"Sparse"}"#.utf8))
        expect(TVCinemaCardPresentation.meta(sparse).facts == [.text("Movie")], "missing facts are absent, not synthesized")
        let numericRuntime = try decoder.decode(CoreMeta.self, from: Data(#"{"id":"number","type":"movie","name":"Still valid","runtime":99}"#.utf8))
        expect(numericRuntime.runtime == "99" && numericRuntime.name == "Still valid", "numeric authored runtime remains unitless without discarding valid previews")
        let malformedRuntime = try decoder.decode(CoreMeta.self, from: Data(#"{"id":"bad","type":"movie","name":"Still valid","runtime":[99]}"#.utf8))
        expect(malformedRuntime.runtime == nil && malformedRuntime.name == "Still valid", "malformed runtime does not discard otherwise valid previews")
        let native = try decoder.decode(CoreMeta.self, from: Data(#"{"id":"native","type":"movie","name":"Native","imdbRating":7.9,"genres":["Drama"]}"#.utf8))
        expect(native.imdbRating == "7.9" && native.genres == ["Drama"], "raw native provider facts remain authored")
        let precedence = try decoder.decode(CoreMeta.self, from: Data(#"{"id":"priority","type":"movie","name":"Priority","imdbRating":"7.9","genres":["Drama"],"links":[{"name":"8.2","category":"imdb"},{"name":"Mystery","category":"Genres"}]}"#.utf8))
        expect(precedence.imdbRating == "8.2" && precedence.genres == ["Mystery"], "existing engine links preserve their precedence")
        let malformedFacts = try decoder.decode(CoreMeta.self, from: Data(#"{"id":"optional","type":"movie","name":"Accepted","runtime":null,"imdbRating":{},"genres":42}"#.utf8))
        expect(malformedFacts.name == "Accepted" && malformedFacts.runtime == nil && malformedFacts.imdbRating == nil && malformedFacts.genres == nil, "malformed/null optional authored facts do not fail catalog decoding")
        let blank = TVCinemaCardPresentation(id: "x", type: "series", title: "X", runtime: "  ", releaseInfo: "", rating: "N/A")
        expect(blank.facts == [.text("Series")], "blank and invalid rating facts remain absent")
        expect(TVCinemaArtworkPolicy.fillsFrame(pixelWidth: 1920, pixelHeight: 1080), "real wide artwork fills the landscape frame")
        expect(!TVCinemaArtworkPolicy.fillsFrame(pixelWidth: 600, pixelHeight: 900), "portrait art uses a fit composite rather than a crop")

        let raw = #"{"catalogs":[[{"request":{"base":"https://addon.example/config/manifest.json","path":{"resource":"catalog","type":"anime","id":"popular","extra":[["genre","Drama"],["skip","0"]]}},"content":{"type":"Ready","content":[{},{}]}}]]}"#
        let board = try decoder.decode(TVCatalogBrowseBoard.self, from: Data(raw.utf8))
        let first = board.candidates[0]
        expect(first.request.filters == [["genre", "Drama"]], "paging strips only skip and captures real filters")
        expect(first.request.rowID == "https://addon.example/config/manifest.json|anime|popular", "transport/type/catalog remain exact")
        let target = first.request
        var callbackIndices: [Int] = []
        expect(TVCatalogBrowsePolicy.page(target: target, candidates: [first], ownerCurrent: true, visibleRowIDs: [target.rowID], supportsPaging: true, load: { callbackIndices.append($0) }), "actual page callback is admitted")
        expect(callbackIndices == [0], "callback uses the resolved engine row")
        let moved = TVCatalogBrowseCandidate(request: target, engineIndex: 4, itemCount: 3, lastPageCount: 1, state: .ready)
        expect(TVCatalogBrowsePolicy.page(target: target, candidates: [moved], ownerCurrent: true, visibleRowIDs: [target.rowID], supportsPaging: true, load: { callbackIndices.append($0) }), "same request can move to another engine index")
        expect(callbackIndices == [0, 4], "captured index is never dispatched after reordering")
        let changedFilter = TVCatalogRequestIdentity(base: target.base, type: target.type, catalogID: target.catalogID, filters: [["genre", "Comedy"]])
        let changed = TVCatalogBrowseCandidate(request: changedFilter, engineIndex: 0, itemCount: 2, lastPageCount: 2, state: .ready)
        let denied: [(Bool, Set<String>, Bool, [TVCatalogBrowseCandidate])] = [
            (false, [target.rowID], true, [first]),
            (true, [], true, [first]),
            (true, [target.rowID], false, [first]),
            (true, [target.rowID], true, [changed]),
            (true, [target.rowID], true, [first, first]),
            (true, [target.rowID], true, [.init(request: target, engineIndex: 0, itemCount: 2, lastPageCount: 0, state: .ready)]),
            (true, [target.rowID], true, [.init(request: target, engineIndex: 0, itemCount: 2, lastPageCount: 0, state: .loading)]),
            (true, [target.rowID], true, [.init(request: target, engineIndex: 0, itemCount: 2, lastPageCount: 0, state: .error)]),
        ]
        for (owner, visible, supported, candidates) in denied {
            expect(!TVCatalogBrowsePolicy.page(target: target, candidates: candidates, ownerCurrent: owner, visibleRowIDs: visible, supportsPaging: supported, load: { callbackIndices.append($0) }), "changed owner, hidden row, unsupported/terminal/loading/ambiguous request cannot page")
        }
        expect(callbackIndices == [0, 4], "rejected callbacks never reach the native page owner")
        let secondPage = raw.replacingOccurrences(of: "\"0\"", with: "\"2\"")
        let next = try decoder.decode(TVCatalogBrowseBoard.self, from: Data(secondPage.utf8))
        expect(next.candidates[0].request == target, "skip is not a filter identity change")
        let malformed = raw.replacingOccurrences(of: #"["genre","Drama"]"#, with: #"["genre"]"#)
        expect((try? decoder.decode(TVCatalogBrowseBoard.self, from: Data(malformed.utf8))) == nil, "malformed filter identity fails closed")
        print("TVCatalogCinemaPolicyTests: \(checks) checks passed")
    }
}
