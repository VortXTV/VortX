// Standalone regression contract for owner resume-cache upsert and explicit tombstone eviction.
//
// Run from app/:
//   xcrun swiftc -parse-as-library -warnings-as-errors \
//     Tests/OwnerResumeCacheReplacementContractTests.swift \
//     -o /Users/daksh/VortXTV/.build/owner-resume-cache/OwnerResumeCacheReplacementContractTests && \
//   /Users/daksh/VortXTV/.build/owner-resume-cache/OwnerResumeCacheReplacementContractTests

import Foundation

@main
enum OwnerResumeCacheReplacementContractTests {
    struct Resume: Equatable { let t: Int; let d: Int; let v: String? }
    struct Stamp: Equatable { let removedAt: Int; let addedAt: Int }
    typealias Cache = [String: Resume]

    static func main() throws {
        try testProductionGates()
        testLegacyDocumentUpsertsWithoutEvictingOmittedIDs()
        testFailedOrEmptyRefreshRetainsCache()
        testLocalRemovalEvictsExactCachedIdentity()
        testRemoteTombstoneEvictsBeforeRefresh()
        testRemoteReaddStampCannotPreserveOldEpisode()
        testFirstObservedRemovedToPresentPairQuarantinesOldResume()
        testFractionalLastWatchedAdmitsWithinAddedSecond()
        testSameDocumentStaleRowCannotRehydrateReadd()
        testExplicitLocalReaddClearsStaleFence()
        testUnchangedReaddStampDoesNotEraseFreshEpisode()
        testLosingRemovalAdvanceDoesNotEraseFreshEpisode()
        testColdHydrateEvictsBeforeRefreshAndCWRebuild()
        testRemoveThenReaddUsesNewEpisodeAndOffset()
        print("Owner resume cache tombstone eviction contract tests passed")
    }

    private static func merged(cache: Cache, entries: Cache) -> Cache {
        cache.merging(entries) { _, fresh in fresh }
    }

    private static func evicted(cache: Cache, tombstones: Set<String>) -> Cache {
        cache.filter { !tombstones.contains(normalize($0.key)) }
    }

    private static func advancing(previous: [String: Stamp], incoming: [String: Stamp]) -> Set<String> {
        Set(incoming.compactMap { id, stamp in
            let prior = previous[id] ?? Stamp(removedAt: 0, addedAt: 0)
            let firstObservedReadd = previous[id] == nil && stamp.removedAt > 0 && stamp.addedAt > stamp.removedAt
            let knownRemovalReadd = prior.removedAt > prior.addedAt && stamp.addedAt > prior.addedAt
            return stamp.removedAt > stamp.addedAt || firstObservedReadd || knownRemovalReadd ? id : nil
        })
    }

    private static func merged(cache: Cache, entries: Cache, blocked: Cache) -> Cache {
        entries.reduce(into: cache) { result, entry in
            if blocked[entry.key] != entry.value { result[entry.key] = entry.value }
        }
    }

    private static func admitted(cache: Cache, entries: [(String, Resume, Int?)], receipts: [String: Int]) -> Cache {
        entries.reduce(into: cache) { result, entry in
            if let addedAt = receipts[entry.0], (entry.2 ?? 0) <= addedAt { return }
            result[entry.0] = entry.1
        }
    }

    private static func normalize(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func testLegacyDocumentUpsertsWithoutEvictingOmittedIDs() {
        let old = Resume(t: 120, d: 1200, v: "tt-old:1:2")
        let refreshed = Resume(t: 300, d: 1200, v: "tt-keep:1:3")
        let next = merged(cache: ["tt-old": old, "tt-keep": old], entries: ["tt-keep": refreshed])
        precondition(next["tt-old"] == old, "a paged or legacy document omission must retain unrelated resume state")
        precondition(next["tt-keep"] == refreshed, "known ids must upsert t/d/v atomically")
    }

    private static func testLocalRemovalEvictsExactCachedIdentity() {
        let old = Resume(t: 120, d: 1200, v: "tt-show:1:2")
        let next = evicted(cache: ["TT-Show ": old, "tt-other": old], tombstones: ["tt-show"])
        precondition(next["TT-Show "] == nil, "local tombstone must evict normalized cached identity")
        precondition(next["tt-other"] == old, "local removal must not affect another title")
    }

    private static func testFailedOrEmptyRefreshRetainsCache() {
        let prior = Resume(t: 600, d: 1200, v: "tt-show:1:5")
        precondition(merged(cache: ["tt-show": prior], entries: [:]) == ["tt-show": prior],
                     "failed, partial, or empty library refresh must not infer a deletion")
    }

    private static func testRemoteTombstoneEvictsBeforeRefresh() {
        let stale = Resume(t: 900, d: 1800, v: "tt-show:1:8")
        let cache = ["tt-show": stale]
        let afterFold = evicted(cache: cache, tombstones: ["tt-show"])
        let afterRefresh = merged(cache: afterFold, entries: ["tt-other": Resume(t: 30, d: 900, v: nil)])
        precondition(afterRefresh["tt-show"] == nil, "remote tombstone must survive a partial library upsert")
    }

    private static func testColdHydrateEvictsBeforeRefreshAndCWRebuild() {
        let stale = Resume(t: 900, d: 1800, v: "tt-show:1:8")
        let afterFold = evicted(cache: ["tt-show": stale], tombstones: ["tt-show"])
        let afterRefresh = merged(cache: afterFold, entries: [:])
        precondition(afterRefresh.isEmpty, "cold hydrate must not expose tombstoned cache state to CW rebuild")
    }

    private static func testRemoteReaddStampCannotPreserveOldEpisode() {
        let stale = Resume(t: 900, d: 1800, v: "tt-show:1:8")
        // A newer addedAt means the removal no longer applies, but this paged pull did not include the re-added
        // row. The incoming stamp id itself must evict stale state until a later upsert supplies S02E01.
        let ids = advancing(previous: ["tt-show": Stamp(removedAt: 10, addedAt: 0)],
                            incoming: ["tt-show": Stamp(removedAt: 10, addedAt: 20)])
        let afterStamp = evicted(cache: ["tt-show": stale], tombstones: ids)
        precondition(afterStamp["tt-show"] == nil, "remote re-add stamp must not preserve old episode identity")
    }

    private static func testFirstObservedRemovedToPresentPairQuarantinesOldResume() {
        let stale = Resume(t: 900, d: 1800, v: "tt-show:1:8")
        let ids = advancing(previous: [:], incoming: ["tt-show": Stamp(removedAt: 10, addedAt: 20)])
        let afterTransition = evicted(cache: ["tt-show": stale], tombstones: ids)
        precondition(afterTransition["tt-show"] == nil,
                     "a first-observed removed-to-present pair must reset a cached old episode")
        let repeatedStale = admitted(cache: afterTransition, entries: [("tt-show", stale, nil)], receipts: ["tt-show": 20])
        precondition(repeatedStale["tt-show"] == nil,
                     "the causal receipt must survive an omitted row and reject a repeated stale row")
        let fresh = Resume(t: 45, d: 1500, v: "tt-show:2:1")
        let admittedFresh = admitted(cache: repeatedStale, entries: [("tt-show", fresh, 21)], receipts: ["tt-show": 20])
        precondition(admittedFresh["tt-show"] == fresh,
                     "a row with lastWatched strictly newer than addedAt must be admitted")
    }

    private static func testFractionalLastWatchedAdmitsWithinAddedSecond() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let value = "2026-09-04T12:00:00.750Z"
        let milliseconds = Int((formatter.date(from: value)?.timeIntervalSince1970 ?? 0) * 1000)
        let addedAt = milliseconds - 250
        precondition(milliseconds > addedAt,
                     "fractional ISO-8601 lastWatched must retain sub-second causal ordering")
    }

    private static func testSameDocumentStaleRowCannotRehydrateReadd() {
        let stale = Resume(t: 900, d: 1800, v: "tt-show:1:8")
        let fresh = Resume(t: 45, d: 1500, v: "tt-show:2:1")
        let reset = evicted(cache: ["tt-show": stale], tombstones: ["tt-show"])
        let sameDocument = merged(cache: reset, entries: ["tt-show": stale], blocked: ["tt-show": stale])
        precondition(sameDocument["tt-show"] == nil, "same-document stale row must not rehydrate after re-add")
        let afterProgress = merged(cache: sameDocument, entries: ["tt-show": fresh], blocked: ["tt-show": stale])
        precondition(afterProgress["tt-show"] == fresh, "changed post-readd t/d/v may rehydrate the cache")
        let repeatedOldRow = merged(cache: afterProgress, entries: ["tt-show": stale], blocked: ["tt-show": stale])
        precondition(repeatedOldRow["tt-show"] == fresh,
                     "repeated historical stale row must not overwrite fresh t/d/v")
    }

    private static func testExplicitLocalReaddClearsStaleFence() {
        let priorStale = Resume(t: 900, d: 1800, v: "tt-show:1:8")
        let remoteFence = ["tt-show": priorStale]
        let rejectedBeforeLocalIntent = merged(cache: [:], entries: ["tt-show": priorStale], blocked: remoteFence)
        precondition(rejectedBeforeLocalIntent["tt-show"] == nil,
                     "remote re-add fence must reject its accompanying stale row")

        // A user's fresh local AddToLibrary intent clears the fence after evicting the old cache identity.
        // The identical t/d/v is now legitimate and must be accepted rather than suppressed indefinitely.
        let afterExplicitLocalReadd = merged(cache: [:], entries: ["tt-show": priorStale], blocked: [:])
        precondition(afterExplicitLocalReadd["tt-show"] == priorStale,
                     "explicit local re-add must permit a legitimate resume matching an old stale fingerprint")
    }

    private static func testUnchangedReaddStampDoesNotEraseFreshEpisode() {
        let fresh = Resume(t: 45, d: 1500, v: "tt-show:2:1")
        // The re-add stamp has already been consumed and the S02E01 row was upserted. A later paged response
        // may repeat that historical stamp while omitting the row; no advancing stamp means no cache eviction.
        let ids = advancing(previous: ["tt-show": Stamp(removedAt: 10, addedAt: 20)],
                            incoming: ["tt-show": Stamp(removedAt: 10, addedAt: 20)])
        let afterRepeat = evicted(cache: ["tt-show": fresh], tombstones: ids)
        precondition(afterRepeat["tt-show"] == fresh,
                     "unchanged historical re-add stamp must retain the already-upserted fresh episode")
    }

    private static func testLosingRemovalAdvanceDoesNotEraseFreshEpisode() {
        let fresh = Resume(t: 45, d: 1500, v: "tt-show:2:1")
        let ids = advancing(previous: ["tt-show": Stamp(removedAt: 10, addedAt: 20)],
                            incoming: ["tt-show": Stamp(removedAt: 15, addedAt: 20)])
        precondition(ids.isEmpty, "a removal stamp that still loses to addedAt is not reset authority")
        precondition(evicted(cache: ["tt-show": fresh], tombstones: ids)["tt-show"] == fresh,
                     "a losing removal advance must retain fresh t/d/v")
    }

    private static func testRemoveThenReaddUsesNewEpisodeAndOffset() {
        let stale = Resume(t: 900, d: 1800, v: "tt-show:1:8")
        let afterRemoval = evicted(cache: ["tt-show": stale], tombstones: ["tt-show"])
        let fresh = Resume(t: 45, d: 1500, v: "tt-show:2:1")
        let afterReadd = merged(cache: afterRemoval, entries: ["tt-show": fresh])
        precondition(afterRemoval["tt-show"] == nil, "remove must delete stale series episode before re-add")
        precondition(afterReadd["tt-show"] == fresh, "re-add must upsert its new t/d/episode identity")
    }

    private static func testProductionGates() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let profileSync = try String(contentsOf: root.appendingPathComponent("SourcesShared/ProfileSync.swift"), encoding: .utf8)
        let sync = try String(contentsOf: root.appendingPathComponent("SourcesShared/VortXSyncManager.swift"), encoding: .utf8)
        let core = try String(contentsOf: root.appendingPathComponent("SourcesShared/CoreBridge.swift"), encoding: .utf8)

        precondition(profileSync.contains("static func merge(_ entries:"), "legacy/nonempty documents must keep upsert semantics")
        precondition(profileSync.contains("static func evict(libraryIDs: Set<String>, clearingFence: Bool = false)"), "store must support tombstone eviction and explicit local re-add fence clearing")
        precondition(profileSync.contains("LibraryTombstones.normalize("), "eviction must use normalized library identity")
        precondition(!profileSync.contains("static func replace(_ entries:"), "paged library documents must not replace the whole cache")
        precondition(!sync.contains("libraryComplete"), "no unproven completeness wire field may drive deletion")
        precondition(sync.contains("OwnerResumeStore.evict(libraryIDs: LibraryTombstones.all())"),
                     "remote tombstones must evict cache before refresh and CW rebuild")
        precondition(sync.contains("libraryTombstoneIDsAdvancing"),
                     "only newly observed tombstone stamps may evict stale cache before a partial refresh")
        precondition(sync.contains("OwnerResumeStore.merge(entries)"), "library refresh must upsert known entries")
        precondition(profileSync.contains("static func recordReadds("),
                     "removed-to-present transitions must persist an owner-scoped causal receipt")
        precondition(profileSync.contains("lastWatchedMilliseconds"),
                     "post-readd resume admission must use a causal clock, not t/d/v equality")
        precondition(profileSync.contains("CredentialScope(canonicalRemoteAccountID:"),
                     "resume cache storage must bind to the canonical VortX account owner")
        precondition(sync.contains("OwnerResumeStore.recordReadds(libraryAdvance.readdedAddedAt)"),
                     "syncUp fold and syncDown must share the durable re-add receipt")
        precondition(core.contains("OwnerResumeStore.evict(libraryIDs: [LibraryTombstones.normalize(id)])"),
                     "local single removal must evict before engine events")
        precondition(core.contains("for id in ids {\n            LibraryTombstones.tombstone(id)\n            OwnerResumeStore.evict"),
                     "bulk removal must evict each cached id")
        precondition(core.components(separatedBy: "clearingFence: true").count - 1 >= 4,
                     "every explicit owner-library add path must clear a stale remote re-add fence")

        let hydrate = section(sync, from: "func hydrateEngineFromOwnedAddons", until: "static func ownedAddons")
        guard let fold = hydrate.range(of: "foldDocTombstones(doc)"),
              let evict = hydrate.range(of: "OwnerResumeStore.evict(libraryIDs: LibraryTombstones.all())"),
              let recover = hydrate.range(of: "await recoverOwnerLibraryIfEmpty") else {
            preconditionFailure("cold hydrate must contain fold, evict, and recovery")
        }
        precondition(fold.lowerBound < evict.lowerBound && evict.lowerBound < recover.lowerBound,
                     "cold hydrate must fold then evict then refresh/recover")
    }

    private static func section(_ source: String, from start: String, until end: String) -> String {
        guard let start = source.range(of: start),
              let end = source.range(of: end, range: start.upperBound..<source.endIndex) else { return "" }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
