// Pure synthetic source-extraction fixture. No app, SDK, account, network, or device state.
import Foundation

// PRODUCTION_JSON
// PRODUCTION_ERROR
// PRODUCTION_PREVIOUSLY_WATCHED
// BASELINE_PREVIOUSLY_WATCHED

private struct FixtureAddon {
    let transportUrl: String
    let manifest: VortxJSON?
}

private final class CurrentProjection {
    private let lock = NSRecursiveLock()
    private let registry: [FixtureAddon] = [.init(transportUrl: "https://fixture.invalid/manifest.json", manifest: .object(["id": .string("fixture")]))]
    private let resourceRegistryValid = true
    private var playback: VortxJSON?
    private var libraryRequest: VortxJSON?
    private var values: [String: VortxJSON]
    init(playback: VortxJSON?, request: VortxJSON? = nil, detailID: String = "dup") {
        self.playback = playback
        libraryRequest = request
        values = ["meta_details": .object(["selected": .object(["metaPath": .object(["id": .string(detailID)])])])]
    }
    func fields(_ state: VortxJSON) throws -> VortxJSON { .object(try stateFields(state)) }
    func library(_ state: VortxJSON, request: VortxJSON?) -> VortxJSON? { libraryProjection(state: state, request: request) }
    func search(_ state: VortxJSON, query: String, limit: Int) -> VortxJSON? { localSearchProjection(state: state, query: query, maxResults: limit) }
    // PRODUCTION_CURRENT
}

private final class BaselineProjection {
    private let lock = NSRecursiveLock()
    private let registry: [FixtureAddon] = [.init(transportUrl: "https://fixture.invalid/manifest.json", manifest: .object(["id": .string("fixture")]))]
    private let resourceRegistryValid = true
    private var playback: VortxJSON?
    private var libraryRequest: VortxJSON?
    private var values: [String: VortxJSON]
    init(playback: VortxJSON?, request: VortxJSON? = nil, detailID: String = "dup") {
        self.playback = playback
        libraryRequest = request
        values = ["meta_details": .object(["selected": .object(["metaPath": .object(["id": .string(detailID)])])])]
    }
    func fields(_ state: VortxJSON) throws -> VortxJSON { .object(try stateFields(state)) }
    func library(_ state: VortxJSON, request: VortxJSON?) -> VortxJSON? { libraryProjection(state: state, request: request) }
    func search(_ state: VortxJSON, query: String, limit: Int) -> VortxJSON? { localSearchProjection(state: state, query: query, maxResults: limit) }
    // PRODUCTION_BASELINE
}

@main enum NativeLibraryProjectionTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL " + message); exit(1) }
    }
    static func saved(_ id: String, _ type: String = "movie", name: String? = nil) -> VortxJSON {
        .object(["kind": .string("standard"), "id": .string(id), "type": .string(type), "name": .string(name ?? id), "poster": .null])
    }
    static func row(_ id: String, _ type: String = "movie", offset: UInt64 = 10, at: VortxJSON = .unsigned(200), name: String? = nil) -> VortxJSON {
        .object(["metaId": .string(id), "type": .string(type), "name": .string(name ?? id), "poster": .null,
                 "offsetMs": .unsigned(offset), "durationMs": .unsigned(1_000), "timesWatched": .unsigned(2),
                 "videoId": .string(id + ":1:2"), "updatedAt": at, "watched": .bool(false)])
    }
    static func state(_ saved: [VortxJSON], removals: [String: VortxJSON] = [:]) -> VortxJSON {
        .object(["activeProfileId": .string("owner"),
                 "libraries": .object(["owner": .object(["items": .array(saved)])]),
                 "nativeSync": .object(["libraries": .object(["owner": .object(["records": .object(removals)])])])])
    }
    static func request(_ sort: String, type: String?) -> VortxJSON {
        .object(["sort": .string(sort), "type": type.map(VortxJSON.string) ?? .null, "page": .integer(1)])
    }
    static func main() throws {
        let savedRows = [
            saved("dup", "series", name: "Alpha"), saved("missing", name: "Twin"),
            saved("tie-b", name: "Twin"), saved("tie-a", name: "Twin"),
            saved("epoch"), saved("max-date"), saved("over-date"), saved("negative-date"), saved("uint-max"),
            .object(["kind": .string("external"), "id": .string("not-standard"), "type": .string("movie")]),
            .object(["kind": .string("standard"), "id": .string("untyped")]), .null
        ]
        let cw = [
            row("dup", "movie", offset: 10, at: .unsigned(100)), // first wins, including across types
            row("dup", "series", offset: 900, at: .unsigned(300)),
            row("epoch", at: .unsigned(0)), row("max-date", at: .unsigned(253_402_300_799)),
            row("over-date", at: .unsigned(253_402_300_800)), row("negative-date", at: .integer(-1)),
            row("uint-max", at: .unsigned(UInt64.max)), .null,
            .object(["metaId": .integer(7), "offsetMs": .unsigned(999)])
        ]
        let history = [
            row("history-only", at: .unsigned(200)), row("history-only", at: .unsigned(100), name: "Old"),
            row("removed-equal", at: .unsigned(200)), row("removed-newer", at: .unsigned(199)),
            row("rewatched", at: .unsigned(201)), row("", at: .unsigned(300)),
            row("untyped", "", at: .unsigned(300))
        ]
        let playback: VortxJSON = .object([
            "continueWatching": .array(cw), "history": .array(history),
            "watchedTitles": .object(["dup": .unsigned(3), "tie-a": .unsigned(2), "tie-b": .unsigned(2)]),
            "watchedVideoIdsByTitle": .object(["dup": .array([.string("dup:1:1")])])
        ])
        let removals = Dictionary(uniqueKeysWithValues: ["removed-equal", "removed-newer", "rewatched"].map {
            ("movie:" + $0, VortxJSON.object(["removedAt": .unsigned(200)]))
        })
        let document = state(savedRows, removals: removals)
        let sorts = ["lastwatched", "name", "namereverse", "timeswatched", "watched", "notwatched"]
        let types: [String?] = [nil, "movie", "series", "unknown"]
        var comparisons = 0
        for detail in ["dup", "history-only", "not-in-library"] {
            for sort in sorts {
                for type in types {
                    let req = request(sort, type: type)
                    let current = CurrentProjection(playback: playback, request: req, detailID: detail)
                    let baseline = BaselineProjection(playback: playback, request: req, detailID: detail)
                    let got = try current.fields(document), want = try baseline.fields(document)
                    check(got == want, "full state fields differ: " + sort + "/" + (type ?? "all") + "/" + detail)
                    check(current.library(document, request: req) == baseline.library(document, request: req), "standalone library differs")
                    comparisons += 2
                }
            }
        }
        let invalid: [VortxJSON?] = [
            nil, .object([:]), .object(["sort": .string("bad")]), .object(["sort": .null]),
            .object(["page": .integer(2)]), .object(["type": .string("")]), .object(["type": .integer(7)])
        ]
        for req in invalid {
            let current = CurrentProjection(playback: playback, request: req)
            let baseline = BaselineProjection(playback: playback, request: req)
            let got = try current.fields(document), want = try baseline.fields(document)
            check(got == want, "invalid/default request changed fallback")
            check(current.library(document, request: req) == baseline.library(document, request: req), "invalid request admission differs")
            comparisons += 2
        }
        for source: VortxJSON? in [nil, .object([:]), playback] {
            let current = CurrentProjection(playback: source), baseline = BaselineProjection(playback: source)
            let got = try current.fields(document), want = try baseline.fields(document)
            check(got == want, "nil/empty playback differs")
            for query in ["", "d", "dup", "TWIN", "missing"] {
                for limit in [0, 1, 20] {
                    check(current.search(document, query: query, limit: limit) == baseline.search(document, query: query, limit: limit), "local search differs")
                    comparisons += 1
                }
            }
        }
        let projected = try CurrentProjection(playback: playback).fields(document)
        let catalog = projected["library"]?["catalog"]?.array ?? []
        let duplicate = catalog.first { $0["_id"] == .string("dup") }
        check(duplicate?["state"]?["timeOffset"] == .unsigned(10), "first duplicate resume must win, not latest/max")
        check(duplicate?["type"] == .string("series"), "saved type must remain authoritative")
        check(catalog.first { $0["_id"] == .string("missing") }?["state"]?["timeOffset"] == .integer(0), "missing resume stays zero")
        check(!catalog.contains { $0["_id"] == .string("removed-equal") || $0["_id"] == .string("removed-newer") }, "equal/newer removals exclude history")
        check(catalog.contains { $0["_id"] == .string("rewatched") && $0["previouslyWatched"] == .bool(true) }, "watch after removal returns")
        check(projected["meta_details"]?["libraryItem"]?["_id"] == .string("dup"), "saved detail membership retained")
        for id in ["over-date", "negative-date", "uint-max"] {
            check(catalog.first { $0["_id"] == .string(id) }?["state"]?["lastWatched"] == .null, "invalid timestamp must remain null")
        }
        let oldInvalid = BaselineProjection(playback: playback)
        let newInvalid = CurrentProjection(playback: playback)
        var rejected = 0
        do { _ = try oldInvalid.fields(.object([:])) } catch { rejected += 1 }
        do { _ = try newInvalid.fields(.object([:])) } catch { rejected += 1 }
        check(rejected == 2, "missing active library must still reject")
        print("PASS actual production projection: \(comparisons) full JSON/library/search comparisons, all six sorts, type filters, first-match and timestamp/removal boundaries")

        // Worst-shaped ordinary library: every saved row is also in a long CW array.
        // The old oracle runs once, not per sort; timing is host-only, not an installed-device claim.
        let count = 5_000
        let manySaved = (0..<count).map { saved("tt-bench-\($0)", $0.isMultiple(of: 2) ? "movie" : "series") }
        let manyCW = (0..<count).map { row("tt-bench-\($0)", $0.isMultiple(of: 2) ? "movie" : "series", offset: UInt64($0)) }
        let manyPlayback: VortxJSON = .object(["continueWatching": .array(manyCW), "history": .array(manyCW), "watchedTitles": .object([:])])
        let manyState = state(manySaved)
        let oldStart = ProcessInfo.processInfo.systemUptime
        let oldFields = try BaselineProjection(playback: manyPlayback).fields(manyState)
        let oldSeconds = ProcessInfo.processInfo.systemUptime - oldStart
        let newStart = ProcessInfo.processInfo.systemUptime
        let newFields = try CurrentProjection(playback: manyPlayback).fields(manyState)
        let newSeconds = ProcessInfo.processInfo.systemUptime - newStart
        check(newFields == oldFields, "5k full JSON differs from exact previous production oracle")
        print(String(format: "PASS 5k saved + 5k CW + 5k history full-JSON benchmark: baseline=%.4fs current=%.4fs speedup=%.2fx (host synthetic only)",
                     oldSeconds, newSeconds, oldSeconds / max(newSeconds, 0.000001)))
    }
}
