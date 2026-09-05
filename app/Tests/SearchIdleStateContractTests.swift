// Standalone executable for the search idle/loading contract: the `CoreBoardState.selected` decode in
// CoreModels.swift, and the two places in CoreBridge.swift that depend on it.
//
//   xcrun swiftc -o /tmp/search-idle-state-test \
//     app/SourcesShared/DetailMetaRecoveryPolicy.swift \
//     app/SourcesShared/CatalogRowResolution.swift \
//     app/SourcesShared/UsenetStreamValidation.swift \
//     app/SourcesShared/CoreModels.swift \
//     app/SourcesShared/SubtitleReleaseFingerprint.swift \
//     app/Tests/SearchIdleStateContractTests.swift && \
//     /tmp/search-idle-state-test
//
// What is actually at stake. The engine re-announces its `search` field as changed on every
// LibraryChanged, searched or not, and a never-searched CatalogsWithExtra serializes zero catalogs. Zero
// catalogs is therefore ambiguous: it is both "nobody has searched" and "a search is in flight but no page
// has been seeded yet". `selected` is the only member that separates the two, so the loading flag rests
// entirely on how `selected` decodes:
//
//   * nil for a never-searched or unloaded field, or an idle app reports a permanent search in progress
//     and a real search that matches nothing shows "Searching..." forever instead of "No results";
//   * non-nil for the WHOLE in-flight window, or a real search flashes "No results" in the instant
//     between Load and LoadRange;
//   * never throwing on an unexpected payload, because a throw fails the whole CoreBoardState decode, and
//     a failed decode reads as zero pages, which now means idle.
//
// The two engine truths the rest of the derivation rests on, both read off `catalogs_with_extra.rs` at the
// pinned rev f1f0228:
//
//   * `Load` sets `selected` and PLANS `catalogs` in one update, so a non-nil `selected` over an empty
//     plan is settled ("no installed add-on offers a searchable catalog"), never half-built;
//   * `LoadRange` fetches exactly the plan indices where `range.start <= index && index <= range.end`
//     (inclusive both ends). Everything past `end` is seeded once with a nil content and never revisited,
//     because a re-plan only reuses a catalog whose page already HAS a content. `catalogs` is one inner
//     array per planned catalog, so the outer index is that range-checked index, and flattening the pages
//     destroys the only thing that separates "fetch pending" from "never requested".
//
// The last assertions read CoreBridge.swift as text: this repository has no test bundle, and neither the
// loading derivation nor the clear-path Unload can be linked standalone.

import Foundation

// MARK: - Minimal CoreModels dependencies

enum DebridService: String { case torBox }
struct DebridEpisode { let season: Int; let episode: Int }

enum LastStreamStore {
    struct Entry {
        let videoId: String
        let url: String
        let type: String
        let debridService: String?
        let infoHash: String?
        let linkSavedAt: Date?
        let debridTorrentId: Int?
        let debridFileId: Int?
        let fileIdx: Int?
        let season: Int?
        let episode: Int?
    }
}

actor DebridCoordinator {
    static let shared = DebridCoordinator()
    func reresolve(service: DebridService, infoHash: String, torrentId: Int?, fileId: Int?, fileIdx: Int?,
                   episode: DebridEpisode? = nil, requiresSemanticSelection: Bool) async throws -> URL {
        throw StubError.unavailable
    }
}

enum StubError: Error { case unavailable }

enum VortXSyncManager { static let appliedAddonOrder: [String] = [] }
enum AddonTombstones { static func normalize(_ value: String) -> String { value } }

final class DebridKeys {
    static let shared = DebridKeys()
    func isConfigured(_ service: DebridService) -> Bool { false }
}

enum UsenetProviderStore { static let isConfigured = false }

enum StremioServer {
    static let usenetNodeBase: String? = nil
    static let base = "http://127.0.0.1:11470"
    static let trailerResolverBase = "https://trailer.invalid"
}

enum PlaybackSettings { static let torrentsDisabled = false }

// MARK: - Assertions

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func source(_ relativePath: String) -> String {
    let url = repositoryRoot.appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func slice(_ text: String, from start: String, to end: String) -> String {
    guard let lower = text.range(of: start),
          let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else { return "" }
    return String(text[lower.lowerBound..<upper.lowerBound])
}

private func containsInOrder(_ text: String, _ needles: [String]) -> Bool {
    var cursor = text.startIndex
    for needle in needles {
        guard let match = text.range(of: needle, range: cursor..<text.endIndex) else { return false }
        cursor = match.upperBound
    }
    return true
}

// MARK: - Fixtures

private func board(_ json: String) -> CoreBoardState? {
    try? JSONDecoder().decode(CoreBoardState.self, from: Data(json.utf8))
}

/// The end of the LoadRange the app dispatches in `CoreBridge.search`, mirrored from
/// `CoreBridge.searchLoadRangeEnd`. The source assertions keep the two equal.
private let searchLoadRangeEnd = 30

/// The loading derivation from the `search` branch of CoreBridge.swift, restated so the fixtures below can
/// be run through it. It is a MIRROR, not the production code; the source assertions keep the two equal.
private func hasLoadingPages(_ state: CoreBoardState?) -> Bool {
    let catalogs = state?.catalogs ?? []
    return state?.selected != nil && catalogs.indices.contains { index in
        let wasRequested = index <= searchLoadRangeEnd
        return catalogs[index].contains { page in
            guard let content = page.content else { return wasRequested }
            return content.isLoading
        }
    }
}

private func page(_ id: String, content: String) -> String {
    """
    {"request":{"base":"https://addon.invalid/manifest.json",
     "path":{"resource":"catalog","type":"movie","id":"\(id)"}},"content":\(content)}
    """
}

private let readyOne = #"{"type":"Ready","content":[{"id":"tt1","type":"movie","name":"One"}]}"#
private let readyNone = #"{"type":"Ready","content":[]}"#

private let neverSearched = #"{"selected":null,"catalogs":[]}"#
private let selectedOmitted = #"{"catalogs":[]}"#

/// Straight after `Load`: the engine has set `selected` and seeded one page per add-on with a null content,
/// but has not fetched anything yet. This is the window that must NOT read as settled.
private let justLoaded = """
{"selected":{"type":null,"extra":[["search","dune"]]},"catalogs":[[\(page("top", content: "null"))]]}
"""
private let loadRangeInFlight = """
{"selected":{"type":null,"extra":[["search","dune"]]},
 "catalogs":[[\(page("top", content: #"{"type":"Loading"}"#))]]}
"""
private let settledEmpty = """
{"selected":{"type":null,"extra":[["search","zzzz"]]},"catalogs":[[\(page("top", content: readyNone))]]}
"""
private let settledWithHits = """
{"selected":{"type":null,"extra":[["search","dune"]]},"catalogs":[[\(page("top", content: readyOne))]]}
"""

/// A search the engine LOADED but planned zero catalogs for (no add-on offers a searchable catalog).
private let loadedButUnplannable = #"{"selected":{"type":null,"extra":[["search","dune"]]},"catalogs":[]}"#

/// `count` planned catalogs, each its own inner array exactly as the engine emits them, with every index
/// from `unfetchedFrom` up carrying `unfetchedContent`. That is the shape a dispatched LoadRange leaves
/// behind on a large profile: the indices it covered settle, the rest are seeded once and never touched.
private func plannedCatalogs(count: Int, unfetchedFrom: Int, unfetchedContent: String = "null") -> String {
    let entries = (0..<count).map { index in
        "[\(page("c\(index)", content: index >= unfetchedFrom ? unfetchedContent : readyNone))]"
    }
    return #"{"selected":{"type":null,"extra":[["search","dune"]]},"catalogs":["# +
        entries.joined(separator: ",") + "]}"
}

/// 32 searchable catalogs. `0...30` is the whole dispatched range, so index 31 was planned, never
/// requested, and keeps its nil content for the life of the search.
private let loadedPagePastRange = plannedCatalogs(count: 32, unfetchedFrom: 31)
/// The same profile one index earlier: 30 is the LAST index the range covers (the engine's bound is
/// inclusive), so a nil content there is a fetch still in flight, not an unrequested catalog.
private let loadedNilAtRangeEdge = plannedCatalogs(count: 32, unfetchedFrom: 30)
/// A heavier profile: 40 planned catalogs, still only the first 31 ever requested.
private let loadedManyPastRange = plannedCatalogs(count: 40, unfetchedFrom: 31)
/// A shape the engine does not emit today. The range gate discounts an UNREQUESTED nil content only, so
/// an engine that started fetching wider than we asked would still read as in flight rather than settled.
private let loadedPastRangeExplicitLoading =
    plannedCatalogs(count: 32, unfetchedFrom: 31, unfetchedContent: #"{"type":"Loading"}"#)

/// Payloads the engine does not send today. Every one must survive, because a throw would fail the
/// enclosing decode and the caller reads a failed decode as an idle field.
private let tolerated: [(String, String)] = [
    ("an object with renamed members", #"{"selected":{"renamed":1},"catalogs":[]}"#),
    ("an empty object", #"{"selected":{},"catalogs":[]}"#),
    ("a bare string", #"{"selected":"dune","catalogs":[]}"#),
    ("a number", #"{"selected":7,"catalogs":[]}"#),
    ("an array", #"{"selected":[["search","dune"]],"catalogs":[]}"#),
    ("a bool", #"{"selected":true,"catalogs":[]}"#),
]

@main
enum SearchIdleStateContractTests {
    static func main() {
        // MARK: selected decode

        expect(board(neverSearched) != nil, "decode: a never-searched payload still decodes")
        expect(board(neverSearched)?.selected == nil, "decode: an explicit null selected resolves to nil")
        expect(board(selectedOmitted)?.selected == nil, "decode: an omitted selected key resolves to nil")
        expect(board(justLoaded)?.selected != nil, "decode: the engine's selected object resolves to non-nil")
        expect(board(justLoaded)?.catalogs.flatMap { $0 }.count == 1,
               "decode: adding selected does not disturb catalogs")
        expect(board(settledWithHits)?.catalogs.flatMap { $0 }.compactMap { $0.content?.ready }.flatMap { $0 }
                .map(\.id) == ["tt1"], "decode: ready page content still reaches the caller")

        for (shape, json) in tolerated {
            expect(board(json)?.selected != nil, "tolerance: selected as \(shape) decodes as present")
            expect(board(json) != nil, "tolerance: selected as \(shape) does not fail the enclosing decode")
        }

        // MARK: derived loading flag

        expect(hasLoadingPages(board(neverSearched)) == false,
               "idle: a never-searched field is NOT loading (the false alarm in the log)")
        expect(hasLoadingPages(board(selectedOmitted)) == false, "idle: an omitted selected is NOT loading")
        expect(hasLoadingPages(nil) == false, "idle: a failed decode is NOT loading")
        expect(hasLoadingPages(board(justLoaded)) == true,
               "in flight: pages seeded by Load but not yet fetched are loading (no No-results flash)")
        expect(hasLoadingPages(board(loadRangeInFlight)) == true, "in flight: a Loading page is loading")
        expect(hasLoadingPages(board(settledEmpty)) == false,
               "settled (pin): an empty result set stops loading, so the UI can say No results")
        expect(hasLoadingPages(board(settledWithHits)) == false, "settled: a ready result set stops loading")

        // The two stalls that used to be pinned here as KNOWN RESIDUALS. Both are genuinely LOADED
        // searches, so the `selected` gate could not silence them; both are now settled by the per-catalog
        // walk instead. The two in-flight cases below them are the guard rails on that walk: it must not
        // start discounting real pending fetches.
        expect(hasLoadingPages(board(loadedButUnplannable)) == false,
               "settled: a loaded search that planned zero catalogs stops loading, so the UI can say No results")
        expect(hasLoadingPages(board(loadedPagePastRange)) == false,
               "settled: a catalog past the dispatched LoadRange is never fetched, so it never holds the spinner")
        expect(hasLoadingPages(board(loadedManyPastRange)) == false,
               "settled: nine unrequested catalogs still do not hold the spinner")
        expect(hasLoadingPages(board(loadedNilAtRangeEdge)) == true,
               "in flight: index 30 is INSIDE the range (the engine's bound is inclusive), so its nil content is pending")
        expect(hasLoadingPages(board(loadedPastRangeExplicitLoading)) == true,
               "in flight: a past-range catalog carrying an explicit Loading is still loading")

        // MARK: production source contract

        let bridge = source("SourcesShared/CoreBridge.swift")
        let searchBranch = slice(bridge, from: #"if fields.contains("search") {"#,
                                 to: #"if fields.contains("local_search")"#)
        let searchFunc = slice(bridge, from: "func search(_ query: String) {",
                               to: "private func setSearchLoading(")
        let boardReconcile = slice(bridge, from: "private func reconcileBoardRowPagination(",
                                   to: "func catalogOrderDidChange()")

        expect(!bridge.isEmpty, "source: CoreBridge.swift is readable")
        expect(!searchBranch.isEmpty && !searchFunc.isEmpty, "source: both search anchors were found")
        expect(searchBranch.contains("board?.selected != nil && catalogs.indices.contains { index in"),
               "source: the search branch gates on selected, then walks catalogs BY INDEX, not flattened pages")
        expect(containsInOrder(searchBranch, [
            "let wasRequested = index <= Self.searchLoadRangeEnd",
            "guard let content = page.content else { return wasRequested }",
            "return content.isLoading",
        ]), "source: a nil content is loading only for a catalog the app actually requested")
        expect(bridge.contains("private static let searchLoadRangeEnd = 30"),
               "source: the dispatched range end is 30, inclusive engine-side, so 31 catalogs are fetched")
        expect(bridge.contains(#""end": Self.searchLoadRangeEnd"#) && searchFunc.contains("loadSearchRange()"),
               "source: the dispatched LoadRange (now in the shared loadSearchRange, called by search) and the loading derivation read the SAME constant")
        expect(containsInOrder(searchFunc, [
            "guard trimmed.count >= 2 else {",
            #"dispatch(action: ["action": "Unload"], field: "search")"#,
            "return",
            #""action": "Load""#,
        ]), "source: the clear path Unloads the engine search before returning, ahead of the Load path")

        // The discover surface had the same free-re-announce defect; its no-op-suppression fix is pinned
        // separately by DiscoverCoalesceContractTests. The Home BOARD reader is a third surface, untouched
        // by both, so assert only that it was left alone.
        expect(!boardReconcile.isEmpty && !boardReconcile.contains("selected"),
               "scope: the board reader is untouched by this fix")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
