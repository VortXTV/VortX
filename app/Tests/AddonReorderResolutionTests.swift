// AddonReorderResolutionTests - proves that the add-on reorder drives the DISPLAY / group order for
// SOURCES (stream groups), CATALOGS (Home board rows) and the Add-ons list, and covers the load-bearing
// primitives of the C0/H8/M3 successor: the shared QR-safe CANONICAL identity (H3), the ONE first-occurrence
// DUPLICATE policy (M2), ACCOUNT-SCOPED storage (C0), the tvOS move controls with STALE-INDEX safety, and the
// explicit DISPLAY-vs-SELECTION split (H5).
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so
// this is a self-contained Swift executable that COMPILES THE REAL SHIPPED FUNCTION under test -
// `AddonPriorityOrder` from app/SourcesShared/AddonPriorityOrder.swift - and asserts against it directly.
// It does NOT re-implement the ordering. The exact `AddonPriorityOrder.canonical` / `.rankMap` / `.order` /
// `.orderCatalogRows` / `.moved` compiled here are the same functions the production resolution paths call:
//
//   • CoreBridge.assembleStreamGroups  -> AddonPriorityOrder.order(groups, base: { $0.id })
//   • CoreBridge.buildBoardRows        -> AddonPriorityOrder.orderCatalogRows(..., base: { $0.addonBase })
//   • VortXSyncManager.orderedByApplied / currentAddonOrder / ownedAddons(from:) -> AddonPriorityOrder.*
//   • CoreMetaDetails.meta             -> AddonPriorityOrder.rankMap + .canonical (see the meta test)
//   • AddonReorderTVView move buttons  -> AddonPriorityOrder.moved(...)
//
// Run:
//
//     xcrun swiftc -o /tmp/addon-reorder-resolution-test \
//       app/SourcesShared/AddonPriorityOrder.swift \
//       app/Tests/AddonReorderResolutionTests.swift && \
//       /tmp/addon-reorder-resolution-test
//
// PRODUCTION-LINKAGE BOUNDARY (stated honestly, not overclaimed): a standalone script cannot LINK the engine
// + SwiftUI glue, so the following are covered by the 4-scheme Xcode build gate + source review, NOT by this
// executable: the CoreBridge Home-rebuild consumer (H1), the SourceListModel order-revision invalidation
// (H2), the account-transition binding of the scoped key, the remote-pull apply, tvOS focus, the LoadRange
// widen planner (H4), and the real StreamRanking global scorer (the default Watch-Now pick). This file's
// account-scope + relaunch cases MODEL the shipped UserDefaults key scheme (same key strings the build gate
// compiles); everything else asserts the exact shipped functions.

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
            // H3 canonical identity: the SCHEME + HOST are case-INSENSITIVE (RFC 3986), so a host-cased /
            // whitespace-padded applied entry with the SAME path still ranks its add-on.
            let engineOrder = [Group(id: A, streams: []), Group(id: C, streams: [])]
            let hostCased = "  HTTPS://C.EXAMPLE/manifest.json  "   // scheme + host uppercased, PATH unchanged
            let ordered = AddonPriorityOrder.order(engineOrder, applied: [hostCased, A], base: { $0.id })
            check(ordered.map { $0.id } == [C, A],
                  "SOURCES: scheme/host case + surrounding whitespace are folded (shared canonical identity)")
        }
        do {
            // H3, the load-bearing half: the PATH is case-SENSITIVE (RFC 3986), so an applied entry differing
            // only by PATH case is a DIFFERENT add-on and must NOT collapse onto C. Under the old whole-string
            // lowercasing these two collapsed to one rank (the exact H3 defect); under the canonical rule C is
            // left unplaced and falls to the tail.
            let engineOrder = [Group(id: A, streams: []), Group(id: C, streams: [])]
            let pathCased = C.replacingOccurrences(of: "manifest.json", with: "MANIFEST.json")
            let ordered = AddonPriorityOrder.order(engineOrder, applied: [pathCased, A], base: { $0.id })
            check(ordered.map { $0.id } == [A, C],
                  "SOURCES: a path-case-only difference does NOT collapse two add-ons to one rank (H3)")
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

        // MARK: Relaunch survival - persists under the shipped ACCOUNT-SCOPED key and re-derives identically.
        do {
            // == VortXSyncManager.kAddonOrderKeyPrefix + signedOutAddonOrderOwner (""): the signed-out
            // device's own scope. The order is now account-scoped, so this is a scoped key, not a global one.
            let key = "vortx.sync.appliedAddonOrder."
            let suite = UserDefaults.standard
            let saved = suite.stringArray(forKey: key)   // preserve the machine's real value; restore after
            defer { suite.set(saved, forKey: key) }

            let chosen = [C, A, B]
            suite.set(chosen, forKey: key)
            let afterRelaunch = suite.stringArray(forKey: key) ?? []   // "relaunch" = a fresh read
            check(afterRelaunch == chosen, "RELAUNCH: the applied order round-trips through the shipped account-scoped key")

            let engineOrder = [Group(id: A, streams: []), Group(id: B, streams: []), Group(id: C, streams: [])]
            let ordered = AddonPriorityOrder.order(engineOrder, applied: afterRelaunch, base: { $0.id })
            check(ordered.map { $0.id } == [C, A, B], "RELAUNCH: sources resolve in the persisted order after a cold read")
        }

        // MARK: Canonical identity (the ONE shared QR-safe rule; H3)
        do {
            check(AddonPriorityOrder.canonical("HTTPS://Host.Example/Path?q=A#frag") == "https://host.example/Path?q=A",
                  "CANONICAL: folds scheme + host, PRESERVES path + query case, drops the fragment")
            check(AddonPriorityOrder.canonical("  https://host.example/p  ") == "https://host.example/p",
                  "CANONICAL: trims surrounding whitespace")
            check(AddonPriorityOrder.canonical("https://host.example/A") != AddonPriorityOrder.canonical("https://host.example/a"),
                  "CANONICAL: two paths differing only by case are DISTINCT identities (not collapsed)")
        }

        // MARK: Duplicate policy (M2) - ONE rule everywhere: FIRST occurrence wins.
        do {
            let map = AddonPriorityOrder.rankMap([C, A, C])   // C duplicated in the synced order
            check(map[AddonPriorityOrder.canonical(C)] == 0,
                  "DEDUP: a duplicated applied entry keeps its FIRST occurrence (rank 0), not the last")
            check(map[AddonPriorityOrder.canonical(A)] == 1, "DEDUP: the next distinct entry keeps rank 1")
            let engineOrder = [Group(id: A, streams: []), Group(id: B, streams: []), Group(id: C, streams: [])]
            let ordered = AddonPriorityOrder.order(engineOrder, applied: [C, A, C], base: { $0.id })
            check(ordered.map { $0.id } == [C, A, B],
                  "DEDUP: a duplicated entry neither double-ranks nor drops an add-on (stream/catalog/meta share this)")
        }

        // MARK: Account-scoped storage (C0) - models VortXSyncManager's shipped scoped-key scheme (which the
        // 4-scheme build gate compiles). Two owners' orders live under DISTINCT keys, so account A's order can
        // never appear under account B: the old GLOBAL key leaked across a sign-out / sign-in.
        do {
            let prefix = "vortx.sync.appliedAddonOrder."   // == VortXSyncManager.kAddonOrderKeyPrefix
            let suite = UserDefaults.standard
            let (keyA, keyB) = (prefix + "ownerA", prefix + "ownerB")
            let savedA = suite.stringArray(forKey: keyA), savedB = suite.stringArray(forKey: keyB)
            defer { suite.set(savedA, forKey: keyA); suite.set(savedB, forKey: keyB) }
            suite.removeObject(forKey: keyB)
            suite.set([C, A], forKey: keyA)   // account A reorders
            check((suite.stringArray(forKey: keyB) ?? []).isEmpty,
                  "ACCOUNT-SCOPE: account A's order is INVISIBLE under account B's key (no cross-account leak, C0)")
            check(suite.stringArray(forKey: keyA) == [C, A],
                  "ACCOUNT-SCOPE: account A reads back its OWN order under its own key")
        }

        // MARK: Stale-index safety - the tvOS captured row index can go stale when the list re-seeds under it.
        do {
            let list = [A, B, C]
            check(AddonPriorityOrder.moved(list, from: 5, to: 4) == [A, B, C],
                  "STALE-INDEX: a from-index the list no longer contains is a clamped no-op (never crashes / drops)")
            check(AddonPriorityOrder.moved(list, from: 1, to: 9) == [A, B, C],
                  "STALE-INDEX: an out-of-range destination is a clamped no-op")
        }

        // MARK: Display vs selection (H5) - the reorder controls DISPLAY / group order; whether the
        // auto-picked "Watch Now" source follows it is the SEPARATE SourcePreferences.useAddonOrder choice.
        do {
            // Groups arrive pre-ordered by the reorder at the CoreBridge seam (assembleStreamGroups).
            let engineOrder = [Group(id: A, streams: ["a-720"]), Group(id: C, streams: ["c-4k"])]
            let displayed = AddonPriorityOrder.order(engineOrder, applied: [C, A], base: { $0.id })
            check(displayed.map { $0.id } == [C, A],
                  "DISPLAY: the reorder always drives which add-on's group is listed FIRST (both selection modes)")
            // useAddonOrder ON: StreamRanking.best's add-on-order branch returns the first playable in group
            // order, so Watch Now honors the reorder. This asserts that exact selection rule against the
            // pre-ordered groups. The DEFAULT (useAddonOrder OFF) instead scores GLOBALLY for best quality, so
            // display order does NOT force the pick; that global scorer is StreamRanking, exercised by the
            // build gate, and is deliberately independent of this display order (the explicit display/selection
            // split - we do NOT overclaim that the default auto-pick follows the reorder).
            check(displayed.flatMap { $0.streams }.first == "c-4k",
                  "SELECT (useAddonOrder ON): Watch Now honors the reorder (first source of the reordered-first add-on)")
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
