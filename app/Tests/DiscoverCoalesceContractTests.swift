// Standalone executable for the discover no-op-suppression contract and the mid-search re-plan
// re-dispatch, both added to CoreBridge.swift alongside the search idle fix (666de16).
//
//   xcrun swiftc -o /tmp/discover-coalesce-test \
//     app/SourcesShared/DetailMetaRecoveryPolicy.swift \
//     app/SourcesShared/CatalogRowResolution.swift \
//     app/SourcesShared/UsenetStreamValidation.swift \
//     app/SourcesShared/CoreModels.swift \
//     app/SourcesShared/SubtitleReleaseFingerprint.swift \
//     app/Tests/DiscoverCoalesceContractTests.swift && \
//     /tmp/discover-coalesce-test
//
// What is actually at stake, two engine truths read off the pinned rev f1f0228:
//
//   * FIX 1 (discover no-op suppression). `catalog_with_filters.rs` returns `Effects::none()` (changed,
//     NOT `.unchanged()`) for `Internal::LibraryChanged`, so the engine re-announces `discover` as
//     changed on every ~20-90s library tick with nothing actually different. The discover branch had no
//     guard and re-decoded its full catalog + re-wrote the `@Published` var every tick. A fingerprint
//     over the RAW field bytes, compared before decode, suppresses that no-op. The contract: byte-
//     identical payloads publish ONCE; any change to `selected` (encoded in `selectable`) or to any
//     catalog item changes the fingerprint and re-publishes. A fingerprint can only drop a genuine no-op,
//     never a real change, because it hashes every byte.
//
//   * FIX 2 (mid-search re-plan). `catalogs_with_extra.rs`: `Internal::ProfileChanged` runs
//     `catalogs_update(..., range: None, ...)`, which re-seeds every planned catalog still lacking
//     content to a nil content again WITH NO fetch effect (the `_` arm), while reusing any catalog that
//     already has content untouched. A newly planned catalog at an in-range index then parks at nil
//     forever and holds the search spinner. The app must re-dispatch the SAME `LoadRange` it first used
//     so those holes get fetched, and it must do so ONLY when a search is actually loaded.
//
// Neither the loading derivation, the fingerprint helper, nor the dispatch paths can be linked
// standalone (this repository has no test bundle), so the load-bearing assertions read CoreBridge.swift
// as text and pin the mirrors below to it.

import Foundation

// MARK: - Minimal CoreModels dependencies (identical to the search suite so CoreModels.swift compiles)

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

// MARK: - Fingerprint mirror

/// A MIRROR of `CoreBridge.fieldFingerprint`, restated so the fixtures below can be run through it. The
/// source assertions keep the two equal. Hashing the length then EVERY byte means any change to the field
/// changes the fingerprint, so a comparison against it can only drop a genuine no-op, never a real change.
/// `Hasher` is seeded per process, which is all this needs: a fingerprint is only ever compared against
/// another taken in the same run, exactly as the production branch compares against its stored value.
private func fingerprint(_ data: Data) -> Int {
    var hasher = Hasher()
    hasher.combine(data.count)
    data.withUnsafeBytes { hasher.combine(bytes: $0) }
    return hasher.finalize()
}

/// The discover branch's publish gate, restated: walk a sequence of raw payloads as the engine would
/// re-announce them and count how many the fingerprint guard actually lets through to a republish. This
/// is a MIRROR of `if fingerprint != discoverPublishedFingerprint { discoverPublishedFingerprint = ... }`.
private func publishCount(_ payloads: [String]) -> Int {
    var lastFingerprint: Int?
    var published = 0
    for payload in payloads {
        let fp = fingerprint(Data(payload.utf8))
        if fp != lastFingerprint { lastFingerprint = fp; published += 1 }
    }
    return published
}

/// The discover branch's publish gate WITH the in-flight guard: while a next-page load is in flight the
/// fingerprint suppression is bypassed (the settle that clears `discoverPageInFlight` and latches
/// `discoverExhausted` must never be swallowed, even if it settles to byte-identical bytes); otherwise an
/// identical re-announce is suppressed. MIRROR of
/// `if fingerprint != discoverPublishedFingerprint || discoverPageInFlight`.
private func publishCountGuarded(_ steps: [(payload: String, pageInFlight: Bool)]) -> Int {
    var lastFingerprint: Int?
    var published = 0
    for step in steps {
        let fp = fingerprint(Data(step.payload.utf8))
        if fp != lastFingerprint || step.pageInFlight { lastFingerprint = fp; published += 1 }
    }
    return published
}

/// The ctx branch's re-dispatch decision, restated: re-fetch the search catalogs iff a search is loaded.
/// MIRROR of `if searchLoaded { loadSearchRange() }`.
private func ctxRedispatchesSearch(searchLoaded: Bool) -> Bool { searchLoaded }

// MARK: - Fixtures

private func board(_ json: String) -> CoreDiscover? {
    try? JSONDecoder().decode(CoreDiscover.self, from: Data(json.utf8))
}

/// One `selectable.types` entry. `selected` is where the discover "which catalog is active" state lives
/// (CoreDiscover has no top-level selected), so flipping it is the realistic "selected changed" delta.
private func typeEntry(selected: Bool) -> String {
    #"{"type":"movie","selected":"# + (selected ? "true" : "false") + #","request":{"base":"https://addon.invalid/manifest.json","path":{"resource":"catalog","type":"movie","id":"top","extra":[]}}}"#
}

/// One ready catalog page carrying a single meta. Changing `metaID` is the realistic "catalog content
/// changed" delta.
private func catalogPage(metaID: String) -> String {
    #"{"request":{"base":"https://addon.invalid/manifest.json","path":{"resource":"catalog","type":"movie","id":"top"}},"content":{"type":"Ready","content":[{"id":""# + metaID + #"","type":"movie","name":"One"}]}}"#
}

private func discoverJSON(selected: Bool, metaID: String) -> String {
    #"{"selectable":{"types":["# + typeEntry(selected: selected)
        + #"],"catalogs":[],"extra":[],"next_page":null},"catalog":["#
        + catalogPage(metaID: metaID) + "]}"
}

/// The last discover payload the engine published. The two variants differ from it in exactly one place:
/// `selected` (inside `selectable`) or a catalog item id. A byte-identical re-announce of the base is the
/// free LibraryChanged tick that must be suppressed.
private let discoverBase = discoverJSON(selected: true, metaID: "tt1")
private let discoverChangedSelected = discoverJSON(selected: false, metaID: "tt1")
private let discoverChangedItem = discoverJSON(selected: true, metaID: "tt2")

@main
enum DiscoverCoalesceContractTests {
    static func main() {
        // MARK: fixtures are real discover payloads

        expect(board(discoverBase) != nil, "fixture: the base payload decodes as CoreDiscover")
        expect(board(discoverBase)?.items.map(\.id) == ["tt1"], "fixture: the base payload carries one ready item")
        expect(board(discoverChangedSelected) != nil, "fixture: the selected-changed payload decodes")
        expect(board(discoverChangedItem)?.items.map(\.id) == ["tt2"], "fixture: the item-changed payload carries the new item")

        // MARK: FIX 1 -- no-op suppression by raw-byte fingerprint

        expect(fingerprint(Data(discoverBase.utf8)) == fingerprint(Data(discoverBase.utf8)),
               "fingerprint: identical bytes hash identically within a run (the comparison the branch makes)")
        expect(publishCount([discoverBase, discoverBase]) == 1,
               "suppress: the same discover bytes twice publish ONCE (the free LibraryChanged re-announce)")
        expect(publishCount(Array(repeating: discoverBase, count: 5)) == 1,
               "suppress: five identical re-announces still publish once")

        // The signature must cover selected AND all catalog content, so a genuine change always re-publishes.
        expect(fingerprint(Data(discoverBase.utf8)) != fingerprint(Data(discoverChangedSelected.utf8)),
               "real change: a `selected` flip changes the fingerprint")
        expect(fingerprint(Data(discoverBase.utf8)) != fingerprint(Data(discoverChangedItem.utf8)),
               "real change: a catalog item change changes the fingerprint")
        expect(publishCount([discoverBase, discoverChangedItem]) == 2,
               "real change: a changed catalog item publishes again")
        expect(publishCount([discoverBase, discoverBase, discoverChangedSelected, discoverChangedSelected, discoverBase]) == 3,
               "real change: only the transitions publish (base, ->selected, ->base), the repeats are suppressed")

        // Paging-wedge guard: a next-page load that settles to bytes byte-identical to the last publish
        // (a cursorless end-of-catalog with no interim isLoadingPage emit) must STILL republish while
        // `discoverPageInFlight` is true, so the settle that clears the flag and latches exhausted is never
        // swallowed. With the flag false, the same identical bytes stay suppressed (the coalescer still
        // works for the ordinary idle re-announce).
        expect(publishCountGuarded([(discoverBase, false), (discoverBase, true)]) == 2,
               "in-flight guard: byte-identical bytes STILL republish while a discover page load is in flight (the settle is not swallowed)")
        expect(publishCountGuarded([(discoverBase, false), (discoverBase, false)]) == 1,
               "in-flight guard: with no page load in flight, byte-identical bytes are still suppressed (coalescer intact)")

        // MARK: FIX 2 -- mid-search re-dispatch fires only when a search is active

        expect(ctxRedispatchesSearch(searchLoaded: false) == false,
               "gate: a ctx change with NO search loaded does not re-dispatch (the whole point of the gate)")
        expect(ctxRedispatchesSearch(searchLoaded: true) == true,
               "gate: a ctx change with a search loaded re-dispatches the LoadRange")

        // MARK: production source contract -- FIX 1

        let bridge = source("SourcesShared/CoreBridge.swift")
        let discoverBranch = slice(bridge, from: #"if fields.contains("discover") {"#,
                                   to: #"if fields.contains("library") {"#)
        let fingerprintFunc = slice(bridge, from: "private static func fieldFingerprint(_ data: Data) -> Int {",
                                    to: "// MARK: Event callback")
        let clearUserState = slice(bridge, from: "private func clearUserState() {",
                                   to: "/// Load the Home board")

        expect(!bridge.isEmpty, "source: CoreBridge.swift is readable")
        expect(!discoverBranch.isEmpty && !fingerprintFunc.isEmpty, "source: the discover and fingerprint anchors were found")
        expect(bridge.contains("private var discoverPublishedFingerprint: Int?"),
               "source: the suppression state is a fingerprint (Int?), NOT a parallel decoded copy of discover state")
        expect(containsInOrder(discoverBranch, [
            #"if let data = stateData("discover") {"#,
            "let fingerprint = Self.fieldFingerprint(data)",
            "if fingerprint != discoverPublishedFingerprint",
            "discoverPublishedFingerprint = fingerprint",
            "try Self.decoder.decode(CoreDiscover.self, from: data)",
        ]), "source: the branch fingerprints the RAW bytes BEFORE decode, skips both when unchanged, and decodes the SAME buffer (one get_state)")
        expect(discoverBranch.contains("if fingerprint != discoverPublishedFingerprint || discoverPageInFlight {"),
               "source: suppression is bypassed while a discover page load is in flight, so a paging settle is never swallowed (mirror kept equal)")
        expect(containsInOrder(fingerprintFunc, [
            "hasher.combine(data.count)",
            "data.withUnsafeBytes { hasher.combine(bytes: $0) }",
            "return hasher.finalize()",
        ]), "source: the fingerprint hashes the length then EVERY byte, so it cannot miss a real change (mirror kept equal)")
        expect(clearUserState.contains("self.discoverPublishedFingerprint = nil"),
               "source: the fingerprint is reset wherever discover is cleared, so a fresh load after a clear is never suppressed")

        // MARK: production source contract -- FIX 2

        let ctxBranch = slice(bridge, from: #"VXProbe.log("engine", "ctx/settings changed addons="#,
                              to: #"if fields.contains("meta_details") {"#)
        let searchFunc = slice(bridge, from: "func search(_ query: String) {",
                               to: "private func setSearchLoading(")
        let loadSearchRangeFunc = slice(bridge, from: "private func loadSearchRange() {",
                                        to: "/// Search across the installed addons")

        expect(!ctxBranch.isEmpty && !searchFunc.isEmpty && !loadSearchRangeFunc.isEmpty,
               "source: the ctx, search, and loadSearchRange anchors were found")
        expect(bridge.contains("private var searchLoaded = false"),
               "source: the active-search flag defaults false, so a never-searched app never re-dispatches")
        expect(ctxBranch.contains("if searchLoaded { loadSearchRange() }"),
               "source: the ctx branch re-dispatches the search range GATED on an active search, not unconditionally")
        expect(containsInOrder(loadSearchRangeFunc, [
            #""action": "LoadRange""#,
            #""end": Self.searchLoadRangeEnd"#,
            #"field: "search""#,
        ]), "source: loadSearchRange dispatches the LoadRange over 0...searchLoadRangeEnd (the shared constant, no drift)")
        expect(searchFunc.contains("loadSearchRange()"),
               "source: search() dispatches its range through the SAME helper the re-dispatch uses (no drift)")
        expect(containsInOrder(searchFunc, [
            "guard trimmed.count >= 2 else {",
            "searchLoaded = false",
            "return",
            "searchLoaded = true",
            "loadSearchRange()",
        ]), "source: the clear path marks the search inactive before returning; the load path marks it active, then loads")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
