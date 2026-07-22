// AddonReorderResolutionTests - proves that the add-on reorder drives the REAL resolution order for
// SOURCES (stream groups), CATALOGS (Home board rows) and the DISPLAY list, plus the tvOS move controls
// and the relaunch-survival of the persisted order.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so
// this is a self-contained Swift executable that COMPILES THE REAL SHIPPED FUNCTION under test -
// `AddonPriorityOrder` from app/SourcesShared/AddonPriorityOrder.swift - and asserts against it directly.
// It does NOT re-implement the ordering (the prior reorder attempt was blocked for testing standalone
// mirror state machines). The exact `AddonPriorityOrder.order` / `.orderCatalogRows` / `.moved` compiled
// here are the same functions the production resolution paths call:
//
//   • CoreBridge.assembleStreamGroups  -> AddonPriorityOrder.order(groups, base: { $0.id })
//       the SINGLE chokepoint feeding the source list, StreamRanking.best's add-on-order first pick,
//       and the tvOS auto-advance / Watch-Now paths (HomeView / DetailView / TVPlayerView).
//   • CoreBridge.buildBoardRows        -> AddonPriorityOrder.orderCatalogRows(...)
//   • VortXSyncManager.orderedByApplied -> AddonPriorityOrder.order(...)  (the Add-ons list + tvOS reorder)
//   • AddonReorderTVView move buttons  -> AddonPriorityOrder.moved(...)
//
// Run:
//
//     xcrun swiftc -o /tmp/addon-reorder-resolution-test \
//       app/SourcesShared/AddonPriorityOrder.swift \
//       app/Tests/AddonReorderResolutionTests.swift && \
//       /tmp/addon-reorder-resolution-test
//
// The one thing a standalone script cannot link is the CoreBridge glue that hands the engine's groups /
// rows into these functions (it pulls in the StremioXCore engine + the SwiftUI stack); that wiring is
// covered by the 4-scheme Xcode build gate. What this asserts is the load-bearing decision: given the
// engine's raw order and the user's applied order, which add-on answers first.

import Foundation

// MARK: - Fixtures (compiled types; top-level statements are illegal in a multi-file swiftc build)

/// The shape CoreBridge.assembleStreamGroups returns (id == add-on transport base; streams stand in for
/// playable URLs).
private struct Group { let id: String; let streams: [String] }

/// The shape CoreBridge.buildBoardRows sorts (key == "base|type|id", plus catalog-manager rank + engine index).
private struct Row { let key: String; let manager: Int; let engine: Int }

private func addonBase(of key: String) -> String { key.components(separatedBy: "|").first ?? key }

@main
private struct AddonReorderResolutionTests {
    // Transport URLs standing in for installed add-ons in the engine's raw `profile.addons` order.
    static let A = "https://a.example/manifest.json"
    static let B = "https://b.example/manifest.json"
    static let C = "https://c.example/manifest.json"
    static let D = "https://d.example/manifest.json"

    static var failures = 0
    static func check(_ condition: Bool, _ name: String) {
        if condition { print("  PASS  \(name)") } else { failures += 1; print("  FAIL  \(name)") }
    }

    static func main() {
        print("Add-on reorder - real resolution ordering (AddonPriorityOrder)\n")

        // MARK: SOURCES
        do {
            // Engine hands sources back in raw profile.addons order [A, B, C]; the user reordered C first.
            let engineOrder = [Group(id: A, streams: ["a1"]), Group(id: B, streams: ["b1"]), Group(id: C, streams: ["c1"])]
            let ordered = AddonPriorityOrder.order(engineOrder, applied: [C, A, B], base: { $0.id })
            check(ordered.map { $0.id } == [C, A, B],
                  "SOURCES: stream groups resolve in the reordered add-on order, not engine order")
            // Exactly what StreamRanking.best consumes in add-on-order mode: the first playable stream of
            // the first group. The reordered add-on (C) genuinely answers first for playback.
            check(ordered.flatMap { $0.streams }.first == "c1",
                  "SOURCES: the reordered add-on's stream is the FIRST source answered (add-on-order playback)")
        }
        do {
            // Add-ons the user has not placed keep their engine order at the END and are never dropped.
            let engineOrder = [Group(id: A, streams: []), Group(id: B, streams: []), Group(id: C, streams: []), Group(id: D, streams: [])]
            let ordered = AddonPriorityOrder.order(engineOrder, applied: [C, A], base: { $0.id })
            check(ordered.map { $0.id } == [C, A, B, D],
                  "SOURCES: placed add-ons come first (C,A); un-placed keep engine order at the tail (B,D)")
        }
        do {
            // No applied order (a user who never reordered) is a strict no-op: engine order is preserved.
            let engineOrder = [Group(id: A, streams: []), Group(id: B, streams: [])]
            let ordered = AddonPriorityOrder.order(engineOrder, applied: [], base: { $0.id })
            check(ordered.map { $0.id } == [A, B], "SOURCES: empty applied order preserves engine order (no-op)")
        }
        do {
            // Normalization matches the persisted (trim+lowercase) key, so a differently-cased / padded
            // applied entry still ranks its add-on (guards a stray raw entry).
            let engineOrder = [Group(id: A, streams: []), Group(id: C, streams: [])]
            let ordered = AddonPriorityOrder.order(engineOrder, applied: ["  " + C.uppercased() + "  ", A], base: { $0.id })
            check(ordered.map { $0.id } == [C, A], "SOURCES: order matches case-/whitespace-insensitively (normalized key)")
        }

        // MARK: CATALOGS
        do {
            // Two add-ons, one catalog each; no explicit catalog-manager order (equal sentinel rank). The
            // reorder (applied = B before A) must group B's catalog above A's on Home, replacing engine order.
            let rows = [Row(key: "\(A)|movie|top", manager: Int.max, engine: 0),
                        Row(key: "\(B)|movie|top", manager: Int.max, engine: 1)]
            let ordered = AddonPriorityOrder.orderCatalogRows(rows, applied: [B, A],
                                                              base: { addonBase(of: $0.key) },
                                                              catalogRank: { $0.manager },
                                                              engineIndex: { $0.engine })
            check(ordered.map { addonBase(of: $0.key) } == [B, A],
                  "CATALOGS: Home rows group by the reordered add-on order when no explicit catalog order is set")
        }
        do {
            // An EXPLICIT catalog-manager order still WINS: even though the reorder puts B's add-on first, a
            // catalog-manager rank pinning A's catalog to slot 0 keeps it first.
            let rows = [Row(key: "\(A)|movie|top", manager: 0, engine: 0),
                        Row(key: "\(B)|movie|top", manager: Int.max, engine: 1)]
            let ordered = AddonPriorityOrder.orderCatalogRows(rows, applied: [B, A],
                                                              base: { addonBase(of: $0.key) },
                                                              catalogRank: { $0.manager },
                                                              engineIndex: { $0.engine })
            check(ordered.map { addonBase(of: $0.key) } == [A, B],
                  "CATALOGS: an explicit catalog-manager rank still wins over the add-on reorder")
        }

        // MARK: tvOS move controls - the exact math AddonReorderTVView's move-up / move-down buttons run.
        do {
            let list = [A, B, C]
            check(AddonPriorityOrder.moved(list, from: 2, to: 1) == [A, C, B], "tvOS: Move-up nudges an add-on one step up")
            check(AddonPriorityOrder.moved(list, from: 0, to: 1) == [B, A, C], "tvOS: Move-down nudges an add-on one step down")
            check(AddonPriorityOrder.moved(list, from: 0, to: -1) == [A, B, C], "tvOS: Move-up on the FIRST row is a clamped no-op")
            check(AddonPriorityOrder.moved(list, from: 2, to: 3) == [A, B, C], "tvOS: Move-down on the LAST row is a clamped no-op")
        }

        // MARK: Relaunch survival - persists under the shipped key and re-derives identically.
        do {
            let key = "vortx.sync.appliedAddonOrder"   // VortXSyncManager.kAddonOrderKey
            let suite = UserDefaults.standard
            let saved = suite.stringArray(forKey: key)   // preserve the machine's real value; restore after
            defer { suite.set(saved, forKey: key) }

            let chosen = [C, A, B]
            suite.set(chosen, forKey: key)
            let afterRelaunch = suite.stringArray(forKey: key) ?? []   // "relaunch" = a fresh read
            check(afterRelaunch == chosen, "RELAUNCH: the applied order round-trips through the shipped UserDefaults key")

            let engineOrder = [Group(id: A, streams: []), Group(id: B, streams: []), Group(id: C, streams: [])]
            let ordered = AddonPriorityOrder.order(engineOrder, applied: afterRelaunch, base: { $0.id })
            check(ordered.map { $0.id } == [C, A, B], "RELAUNCH: sources resolve in the persisted order after a cold read")
        }

        print("")
        if failures == 0 {
            print("PASS: all add-on-reorder resolution properties hold")
            exit(0)
        } else {
            print("FAIL: \(failures) assertion(s) failed")
            exit(1)
        }
    }
}
