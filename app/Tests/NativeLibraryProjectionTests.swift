// Pure synthetic source-extraction fixture. No app, SDK, account, network, or device state.
import Foundation
import Darwin
import os

// PRODUCTION_CHANGE_RECEIPT

// PRODUCTION_JSON
// PRODUCTION_MEMBERSHIP
// PRODUCTION_LOCK
// PRODUCTION_ERROR
// PRODUCTION_PREVIOUSLY_WATCHED
// BASELINE_PREVIOUSLY_WATCHED

private struct FixtureAddon {
    let transportUrl: String
    let manifest: VortxJSON?
}

// This recorder is an in-memory fixture sink. It has no SDK, engine, network, account,
// persistence or device dependency; it only retains the actual production ChangeReceipt
// value delivered by the extracted publication closure.
private final class PublicationRecorder: Sendable {
    private struct State: Sendable {
        var owned: [ChangeReceipt] = []
        var legacy: [[String]] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func recordOwned(_ receipt: ChangeReceipt) {
        state.withLock { $0.owned.append(receipt) }
    }
    func recordLegacy(_ fields: [String]) {
        state.withLock { $0.legacy.append(fields) }
    }
    var ownedReceipts: [ChangeReceipt] { state.withLock { $0.owned } }
    var legacyEvents: [[String]] { state.withLock { $0.legacy } }
}

// Synthetic kernel inventory is distinct from the filtered worker registry below.
// Actual management selection/projection helpers are extracted by the runner.
private enum ManagementFixture {
    static let visible: VortxJSON = .object([
        "transportUrl": .string("https://fixture.invalid/manifest.json"),
        "manifest": .object(["id": .string("fixture")])])
    static let hidden: VortxJSON = .object([
        "transportUrl": .string("https://fixture.invalid/disabled/manifest.json"),
        "manifest": .object(["id": .string("disabled-fixture"),
            "opaque": .object(["preserved": .array([.bool(true), .unsigned(UInt64.max)])])])])
    static let inventory = [visible, hidden]
    static let expected: VortxJSON = .object(["profile": .object(["addons": .array(inventory)])])
}
private struct FixtureProjectionScope { let ownerProfileID = "owner" }
private struct FixtureProjectionSession { let scope = FixtureProjectionScope() }
// Actual pure exact JSON parser and native VIEW decoder are extracted alongside the projection.
// No native ABI, source import, durable receipt or checkpoint is fabricated by this fixture.
// PRODUCTION_EXACT_JSON
private enum OwnerHistorySessionPublication {
    // PRODUCTION_OWNER_LIBRARY
}

private final class CurrentProjection {
    private let lock = VortxNativeFacadeLock()
    private let registry: [FixtureAddon] = [.init(transportUrl: "https://fixture.invalid/manifest.json", manifest: .object(["id": .string("fixture")]))]
    // PRODUCTION_PRESENTATION_FIELDS
    private let session = FixtureProjectionSession()
    private let addonInventories: [String: [VortxJSON]] = ["owner": ManagementFixture.inventory]
    private let sourceID = UUID()
    private var changeSequence: UInt64 = 0
    private var latestChangeSequence: [String: UInt64] = [:]
    private var resourceSelections: [String: UUID] = [:]
    private var resourceValueTasks: [String: UUID] = [:]
    private var accountEpoch = UUID()
    private var watchlistProfileGeneration = UUID()
    private var registryGeneration = UUID()
    private let resourceRegistryValid = true
    private var playback: VortxJSON?
    private var ownerHistoryLibrary: OwnerHistorySessionPublication.Presentation?
    private var libraryRequest: VortxJSON?
    private var values: [String: VortxJSON]
    private var metadataLibraryMembership = VortxLibraryMembership()
    private var generations: [String: UUID] = [:]
    private var closed = false
    // Exact optional generic production hook, left nil in this RAM projection fixture.
    // No concrete Facade alias or typed source-event identity is manufactured here.
    // PRODUCTION_SOURCE_CHANGED_DELIVERY
    private let ownedChange: (@Sendable (ChangeReceipt) -> Void)?
    private let changed: @Sendable ([String]) -> Void
    private func observeExternalMetadata(_ value: VortxJSON) {}
    init(playback: VortxJSON?, request: VortxJSON? = nil, detailID: String = "dup",
         recorder: PublicationRecorder? = nil, ownerHistoryLibrary: OwnerHistorySessionPublication.Presentation? = nil) {
        self.playback = playback
        self.ownerHistoryLibrary = ownerHistoryLibrary
        libraryRequest = request
        values = [
            "native_state": .object(["activeProfileId": .string("ram-fixture")]),
            "meta_details": .object(["selected": .object(["metaPath": .object(["id": .string(detailID)])])])
        ]
        if let recorder {
            ownedChange = { recorder.recordOwned($0) }
            changed = { recorder.recordLegacy($0) }
        } else {
            ownedChange = nil
            changed = { _ in }
        }
    }
    func fields(_ state: VortxJSON) throws -> VortxJSON {
        let fields = try stateFields(state)
        fields.forEach { values[$0.key] = $0.value }
        return .object(fields)
    }
    func library(_ state: VortxJSON, request: VortxJSON?) -> VortxJSON? { libraryProjection(state: state, request: request) }
    func search(_ state: VortxJSON, query: String, limit: Int) -> VortxJSON? { localSearchProjection(state: state, query: query, maxResults: limit) }
    func resourceDetail(_ id: String, stale: Bool = false) -> VortxJSON? {
        let ticket = UUID()
        generations["meta_details"] = stale ? UUID() : ticket
        publish(["meta_details": .object(["selected": .object(["metaPath": .object(["id": .string(id)])]),
                                        "unknownFixtureField": .string("retained")])], field: "meta_details", ticket: ticket)
        return values["meta_details"]
    }
    // PRODUCTION_CURRENT_MANAGEMENT
    // PRODUCTION_CURRENT
    // PRODUCTION_CURRENT_PUBLICATION
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
    // The old oracle predates only this additive presentation field. Require the
    // new field's exact complete inventory and filtered-worker distinction before
    // comparing every pre-existing output field against that unchanged oracle.
    static func baselineEquivalentFields(_ value: VortxJSON) -> VortxJSON {
        check(value["addon_management"] == ManagementFixture.expected,
              "management projection preserves every acknowledged descriptor and opaque field")
        check(value["ctx"]?["profile"]?["addons"] == .array([ManagementFixture.visible]),
              "disabled management descriptor stays out of the worker registry")
        guard case .object(var fields) = value else { check(false, "state fields are an object"); return value }
        fields.removeValue(forKey: "addon_management")
        return .object(fields)
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
                 "roster": .object(["profiles": .object(["owner": .object(["addons": .string("own")])])]),
                 "libraries": .object(["owner": .object(["items": .array(saved)])]),
                 "nativeSync": .object(["scope": .string("fixture-account"), "ownerProfileId": .string("owner"),
                    "libraries": .object(["owner": .object(["records": .object(removals)])])])])
    }
    static func request(_ sort: String, type: String?) -> VortxJSON {
        .object(["sort": .string(sort), "type": type.map(VortxJSON.string) ?? .null, "page": .integer(1)])
    }
    static func main() throws {
        // #267: base native membership stays empty after a source import. Only the genuine native
        // composed VIEW owns imported membership and source-aware watched-only tombstone masking.
        let importedPlayback: VortxJSON = .object([
            "continueWatching": .array([row("imported-resume", "series", offset: 250, at: .unsigned(300))]),
            "history": .array([row("removed-source", at: .unsigned(900)), row("history-visible", at: .unsigned(400))]),
            "watchedTitles": .object(["history-visible": .unsigned(1)]),
            "watchedVideoIdsByTitle": .object([:]), "resumeById": .object([:])])
        let ownerFence: VortxJSON = .object(["scope": .string("fixture-account"), "ownerProfileId": .string("owner"),
            "profileId": .string("owner"), "mutationGeneration": .string("accepted-source-generation")])
        let fenceBytes = try JSONEncoder().encode(ownerFence)
        let viewJSON: VortxJSON = .object(["kind": .string("view"), "fence": ownerFence,
            "items": .array([saved("membership-only"), saved("imported-resume", "series")]),
            "watchedOnlyLibrary": .array([row("history-visible", at: .unsigned(400))]),
            "playback": importedPlayback, "holds": .array([.string("unresolved-held-unit")])])
        let nativeView = try OwnerHistorySessionPublication.Presentation(view: JSONEncoder().encode(viewJSON), expectedFence: fenceBytes)
        let baseSnapshot = state([], removals: ["movie:removed-source": .object(["removedAt": .unsigned(200)])])
        let imported = CurrentProjection(playback: nativeView.playback, ownerHistoryLibrary: nativeView)
        let importedFields = try imported.fields(baseSnapshot)
        let importedRows = importedFields["library"]?["catalog"]?.array ?? []
        check(importedRows.compactMap { $0["_id"] } == [.string("membership-only"), .string("imported-resume"), .string("history-visible")],
              "imported native VIEW membership and allowed watched-only rows reach the actual Library projection")
        check(importedRows[0]["state"]?["flaggedWatched"] == .integer(0)
              && importedRows[0]["state"]?["timeOffset"] == .integer(0)
              && importedRows[1]["state"]?["video_id"] == .string("imported-resume:1:2")
              && importedRows[1]["state"]?["timeOffset"] == .integer(250),
              "membership alone does not fabricate watched state; exact composed resume stays paired")
        check(importedRows[2]["previouslyWatched"] == .bool(true)
              && importedRows.allSatisfy { $0["_id"] != .string("removed-source") },
              "source history never bypasses native VIEW tombstone masking even with a newer source clock")
        check(importedFields["continue_watching_preview"]?["items"]?.array?.count == 1
              && imported.resourceDetail("membership-only")?["libraryItem"]?["_id"] == .string("membership-only"),
              "Continue Watching and detail membership consume the same acknowledged full projection")
        check(imported.library(baseSnapshot, request: request("notwatched", type: nil))?["catalog"]?.array?.contains {
            $0["_id"] == .string("membership-only")
        } == true, "explicit Library reload/filter retains composed imported membership")
        check(imported.search(baseSnapshot, query: "membership", limit: 10)?["searchResults"]?.array?.count == 1,
              "local search uses imported native VIEW membership without persisting it")
        check(nativeView.holds == ["unresolved-held-unit"], "composed VIEW holds remain explicit and do not fabricate data")
        for changedFence in [
            VortxJSON.object(["scope": .string("replacement-account"), "ownerProfileId": .string("owner"), "profileId": .string("owner")]),
            .object(["scope": .string("fixture-account"), "ownerProfileId": .string("other-owner"), "profileId": .string("owner")]),
            .object(["scope": .string("fixture-account"), "ownerProfileId": .string("owner"), "profileId": .string("replacement-profile")]),
            .object(["scope": .string("fixture-account"), "ownerProfileId": .string("owner"), "profileId": .string("owner"),
                     "mutationGeneration": .string("stale-source-generation")])
        ] {
            do {
                _ = try OwnerHistorySessionPublication.Presentation(view: JSONEncoder().encode(viewJSON),
                    expectedFence: JSONEncoder().encode(changedFence))
                check(false, "stale/wrong account/owner/profile VIEW must reject")
            } catch {}
        }
        let failedViews: [VortxJSON] = [
            .object(["kind": .string("error")]),
            .object(["kind": .string("view"), "fence": ownerFence, "items": .array([]), "watchedOnlyLibrary": .array([]),
                     "playback": .object([:]), "holds": .array([])])]
        for failed in failedViews {
            do {
                _ = try OwnerHistorySessionPublication.Presentation(view: JSONEncoder().encode(failed), expectedFence: fenceBytes)
                check(false, "failed/incomplete native VIEW must not turn into a successful empty Library")
            } catch {}
        }
        for wrongOwner in [
            VortxJSON.object(["scope": .string("fixture-account"), "ownerProfileId": .string("owner"), "profileId": .string("replacement-profile")]),
            .object(["scope": .string("replacement-account"), "ownerProfileId": .string("owner"), "profileId": .string("owner")]),
            .object(["scope": .string("fixture-account"), "ownerProfileId": .string("replacement-owner"), "profileId": .string("owner")])
        ] {
            let wrongView: VortxJSON = .object(["kind": .string("view"), "fence": wrongOwner,
                "items": .array([saved("foreign-membership")]), "watchedOnlyLibrary": .array([]), "playback": importedPlayback, "holds": .array([])])
            let wrongFence = try JSONEncoder().encode(wrongOwner)
            let mismatched = try OwnerHistorySessionPublication.Presentation(view: JSONEncoder().encode(wrongView), expectedFence: wrongFence)
            do {
                _ = try CurrentProjection(playback: mismatched.playback, ownerHistoryLibrary: mismatched).fields(baseSnapshot)
                check(false, "accepted VIEW cannot project into a replacement account/owner/profile")
            } catch {}
        }
        let crossPlayback: VortxJSON = .object([
            "continueWatching": .array([row("shared-id", "series", offset: 500)]), "history": .array([]),
            "watchedTitles": .object([:]), "watchedVideoIdsByTitle": .object([:]), "resumeById": .object([:])])
        let crossViewJSON: VortxJSON = .object(["kind": .string("view"), "fence": ownerFence,
            "items": .array([saved("shared-id", "movie")]),
            "watchedOnlyLibrary": .array([row("shared-id", "series", offset: 500)]),
            "playback": crossPlayback, "holds": .array([])])
        let crossView = try OwnerHistorySessionPublication.Presentation(view: JSONEncoder().encode(crossViewJSON), expectedFence: fenceBytes)
        let crossRows = try CurrentProjection(playback: crossView.playback, ownerHistoryLibrary: crossView)
            .fields(baseSnapshot)["library"]?["catalog"]?.array ?? []
        check(crossRows.count == 2 && crossRows[0]["type"] == .string("movie") && crossRows[1]["type"] == .string("series")
              && crossRows[0]["state"]?["timeOffset"] == .integer(0) && crossRows[1]["state"]?["timeOffset"] == .integer(500),
              "typed native VIEW retains movie membership plus same-ID series history without crossing resume identity")
        print("PASS #267 composed native owner-history Library, CW, detail/filter/search and tombstone regressions")

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
                    check(baselineEquivalentFields(got) == want, "baseline-equivalent state fields differ: " + sort + "/" + (type ?? "all") + "/" + detail)
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
            check(baselineEquivalentFields(got) == want, "invalid/default request changed fallback")
            check(current.library(document, request: req) == baseline.library(document, request: req), "invalid request admission differs")
            comparisons += 2
        }
        for source: VortxJSON? in [nil, .object([:]), playback] {
            let current = CurrentProjection(playback: source), baseline = BaselineProjection(playback: source)
            let got = try current.fields(document), want = try baseline.fields(document)
            check(baselineEquivalentFields(got) == want, "nil/empty playback differs")
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

        let movies = CurrentProjection(playback: playback, request: request("name", type: "movie"))
        let movieFields = try movies.fields(document)
        check(movieFields["library"]?["catalog"]?.array?.contains { $0["_id"] == .string("dup") } == false,
              "fixture's series really is absent from the filtered movie screen")
        let seriesDetail = movies.resourceDetail("dup")
        check(seriesDetail?["libraryItem"]?["_id"] == .string("dup"), "filtered-out saved series must retain resource Detail membership")
        check(seriesDetail?["watchedVideoIds"] == .array([.string("dup:1:1")]), "watched ids remain from the acknowledged playback projection")
        check(seriesDetail?["unknownFixtureField"] == .string("retained"), "metadata overlay retains unrelated raw fields")
        check(movies.resourceDetail("history-only")?["libraryItem"] == .null, "watched-only row is never saved membership")
        _ = movies.resourceDetail("dup")
        check(movies.resourceDetail("not-in-library", stale: true)?["libraryItem"]?["_id"] == .string("dup"),
              "actual publish ticket guard rejects stale metadata before membership lookup")
        _ = try movies.fields(state([saved("replacement")]))
        check(movies.resourceDetail("dup")?["libraryItem"] == .null &&
              movies.resourceDetail("replacement")?["libraryItem"]?["_id"] == .string("replacement"),
              "acknowledged replacement retires old membership without merging history")
        let first: VortxJSON = .object(["_id": .string("same"), "opaque": .object(["keep": .unsigned(UInt64.max)])])
        let watchedOnly: VortxJSON = .object(["_id": .string("same"), "previouslyWatched": .bool(true)])
        let second: VortxJSON = .object(["_id": .string("same"), "name": .string("later duplicate")])
        let index = VortxLibraryMembership([watchedOnly, .null, .object(["_id": .integer(7)]), first, second])
        check(index.item(for: "same") == first && index.item(for: "missing") == nil,
              "membership keeps first eligible literal-id row and all opaque values")
        check(VortxLibraryMembership().item(for: "same") == nil, "empty/retired membership has no rows")
        print("PASS filtered Library/resource metadata: current publish ticket, full membership, first-wins/opaque fields and acknowledged replacement")
        let recorder = PublicationRecorder()
        let receiptProjection = CurrentProjection(playback: playback, recorder: recorder)
        _ = try receiptProjection.fields(document)
        _ = receiptProjection.resourceDetail("receipt-title")
        let firstReceipt = recorder.ownedReceipts.first
        check(recorder.ownedReceipts.count == 1 && recorder.legacyEvents == [["meta_details"]],
              "first changed projection delivers owned receipt and legacy notification")
        check(firstReceipt?.fields == ["meta_details"]
              && firstReceipt?.values["meta_details"]?["unknownFixtureField"] == .string("retained")
              && firstReceipt?.values["native_state"] == nil
              && firstReceipt?.values["addon_management"] == ManagementFixture.expected,
              "owned receipt freezes presentation values and excludes control state")
        _ = receiptProjection.resourceDetail("receipt-title")
        check(recorder.ownedReceipts.count == 2 && recorder.legacyEvents.count == 1
              && recorder.ownedReceipts[1].sequence > recorder.ownedReceipts[0].sequence,
              "equal new resource publication carries an owned receipt without a legacy duplicate")
        print("PASS optional ChangeReceipt publication: RAM fixture receives frozen presentation values")
        if ProcessInfo.processInfo.environment["VORTX_LIBRARY_PROJECTION_FUNCTIONAL_ONLY"] == "1" { return }

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
        check(baselineEquivalentFields(newFields) == oldFields, "5k baseline-equivalent JSON differs from exact previous production oracle")
        print(String(format: "PASS 5k saved + 5k CW + 5k history baseline-field benchmark: baseline=%.4fs current=%.4fs speedup=%.2fx (host synthetic only)",
                     oldSeconds, newSeconds, oldSeconds / max(newSeconds, 0.000001)))
    }
}
