// AddonReorderOrderTests: a standalone, runnable verification of the tvOS installed-add-on reorder parity
// (INS-260722-03). It COMPILES THE REAL move/focus helper (app/SourcesShared/AddonReorderMove.swift) so the
// swap, the edge enable rules, and the focus-follow are asserted on the exact code the tvOS view runs - not a
// copy. Because it links a second source file it is built with swiftc, not `swift` immediate mode:
//
//     swiftc -parse-as-library app/SourcesShared/AddonReorderMove.swift app/Tests/AddonReorderOrderTests.swift -o /tmp/AddonReorderOrderTests && /tmp/AddonReorderOrderTests
//
// SCOPE: the account-scoped order STORE (VortXSyncManager.appliedAddonOrder / normalize)
// and the #144 resolution pick (CoreMetaDetails.meta) live in files that pull in the whole app target, so - as
// with QRJoinerFlowTests / StreamRankingChipsTests - those are MIRRORED here (the real link is proven by the
// 4-scheme Xcode build gate). The NEW tvOS code (the move + focus math) is the part that could silently
// regress, so THAT is compiled and tested for real above. The mirrors below MUST stay in lockstep with
// VortXSyncManager.swift (appliedAddonOrder + normalize) and CoreModels.swift (#144 meta).
// Source-group ordering now compiles the actual AddonAppliedOrder helper, not a mirrored comparator.

import Foundation

// MARK: - Mirror of the canonical account-scoped order store (VortXSyncManager)

/// A tiny persistent backing that survives a simulated relaunch: a fresh `OrderStore` reading the same
/// dictionary is the "relaunched" process reading the same UserDefaults.
final class Backing {
    var dict: [String: [String]] = [:]
}

struct OrderStore {
    let backing: Backing
    static let key = "vortx.sync.appliedAddonOrder"

    // Mirror of AddonTombstones.normalize: trim + lowercase.
    static func normalize(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var appliedAddonOrder: [String] {
        get { backing.dict[Self.key] ?? [] }
        nonmutating set { backing.dict[Self.key] = newValue }
    }

    /// Mirror of VortXSyncManager.applyInAppAddonOrder's persistence chokepoint (the sync push is out of scope
    /// for an offline test; the persisted-order write is what drives resolution + relaunch).
    func applyInAppAddonOrder(_ transportUrls: [String]) {
        let normalized = transportUrls.map { Self.normalize($0) }
        guard normalized != appliedAddonOrder else { return }
        appliedAddonOrder = normalized
    }

    /// Invoke the real stable ordering helper used by VortXSyncManager and source groups.
    func orderedByApplied<T>(_ items: [T], url: (T) -> String) -> [T] {
        AddonAppliedOrder.sorted(items, order: appliedAddonOrder) { Self.normalize(url($0)) }
    }
}

struct Addon: Equatable { let transportUrl: String; let name: String }

/// Mirror of CoreMetaDetails.meta (CoreModels.swift #144): among the add-ons that returned a ready meta (in
/// ENGINE order), pick the one earliest in the applied order. This is the REAL metadata resolution the
/// persisted order drives - not just the on-screen list.
func resolvedMetaProvider(readyEngineOrder: [Addon], store: OrderStore) -> Addon? {
    guard let first = readyEngineOrder.first else { return nil }
    let order = store.appliedAddonOrder
    guard !order.isEmpty else { return first }   // no user order → engine order, unchanged
    var rank: [String: Int] = [:]
    for (i, url) in order.enumerated() { rank[url] = i }
    let best = readyEngineOrder.min { a, b in
        switch (rank[OrderStore.normalize(a.transportUrl)], rank[OrderStore.normalize(b.transportUrl)]) {
        case let (x?, y?): return x < y
        case (_?, nil):    return true
        case (nil, _?):    return false
        case (nil, nil):   return false
        }
    }
    return best ?? first
}

// MARK: - Entry point (swiftc @main, so the REAL AddonReorderMove links into this same binary)

@main
enum AddonReorderOrderTests {
    static var failures = 0
    static func check(_ cond: Bool, _ name: String) {
        if cond { print("  ok   \(name)") }
        else { failures += 1; print("  FAIL \(name)") }
    }

    static func main() {
        print("AddonReorderOrderTests")

        let a = Addon(transportUrl: "https://a.example/manifest.json", name: "A")
        let b = Addon(transportUrl: "https://b.example/manifest.json", name: "B")
        let c = Addon(transportUrl: "https://c.example/manifest.json", name: "C")

        let groups = [("b", 1), ("new", 2), ("a", 3), ("b", 4), ("new2", 5)]
        check(AddonAppliedOrder.sorted(groups, order: ["a", "b", "a"], key: { $0.0 }).map { $0.1 }
              == [3, 1, 4, 2, 5], "sources: user order wins over install order, same-addon groups and new installs stay stable")
        check(AddonAppliedOrder.sorted(groups, order: [], key: { $0.0 }).map { $0.1 }
              == [1, 2, 3, 4, 5], "sources: no applied order preserves engine order")

        // 1. FOCUS REACHES MOVE CONTROLS + FOCUS-FOLLOW - asserted on the REAL AddonReorderMove helper.
        do {
            let count = 3
            check(!AddonReorderMove.upEnabled(index: 0, count: count), "focus: top row has NO Move up (disabled)")
            check(AddonReorderMove.downEnabled(index: 0, count: count), "focus: top row HAS Move down (focusable)")
            check(AddonReorderMove.upEnabled(index: 1, count: count) && AddonReorderMove.downEnabled(index: 1, count: count),
                  "focus: middle row has BOTH controls")
            check(AddonReorderMove.upEnabled(index: 2, count: count), "focus: bottom row HAS Move up (focusable)")
            check(!AddonReorderMove.downEnabled(index: 2, count: count), "focus: bottom row has NO Move down (disabled)")

            // An out-of-bounds edge press is a no-op (nil), never a crash or a silent wraparound.
            check(AddonReorderMove.move([a, b, c].map(\.transportUrl), key: a.transportUrl, by: -1) == nil,
                  "move: the top add-on cannot move up (edge press is a no-op)")
            check(AddonReorderMove.move([a, b, c].map(\.transportUrl), key: c.transportUrl, by: 1) == nil,
                  "move: the bottom add-on cannot move down (edge press is a no-op)")

            // Move the bottom add-on up into the middle: focus stays on its Move up (still enabled).
            let keys = [a, b, c].map(\.transportUrl)
            guard let r1 = AddonReorderMove.move(keys, key: c.transportUrl, by: -1) else { check(false, "move r1 non-nil"); return }
            check(r1.order == [a.transportUrl, c.transportUrl, b.transportUrl], "move: bottom add-on moved up one")
            check(r1.focus == .up(c.transportUrl), "focus-follow: stays on the moved add-on's Move up (still enabled)")

            // Move it up again to the TOP: Move up becomes disabled, so focus must shift to its Move down.
            guard let r2 = AddonReorderMove.move(r1.order, key: c.transportUrl, by: -1) else { check(false, "move r2 non-nil"); return }
            check(r2.order == [c.transportUrl, a.transportUrl, b.transportUrl], "move: add-on reached the top")
            check(r2.focus == .down(c.transportUrl), "focus-follow: shifts to Move down when Move up becomes disabled at the top")
        }

        // 2. ORDER PERSISTS ACROSS RELAUNCH + WRITES THROUGH THE CANONICAL ACCOUNT-SCOPED STORE (no tvOS shadow).
        //    The order is computed by the REAL move helper, then persisted through the store.
        do {
            let backing = Backing()
            let store = OrderStore(backing: backing)
            var keys = [a, b, c].map(\.transportUrl)
            keys = AddonReorderMove.move(keys, key: c.transportUrl, by: -1)!.order   // A, C, B
            keys = AddonReorderMove.move(keys, key: c.transportUrl, by: -1)!.order   // C, A, B
            store.applyInAppAddonOrder(keys)
            check(store.appliedAddonOrder == [c, a, b].map { OrderStore.normalize($0.transportUrl) },
                  "persist: the move is written THROUGH appliedAddonOrder (normalized), not a display shadow")

            // "Relaunch": a fresh store instance reading the SAME backing must see the persisted order.
            let afterRelaunch = OrderStore(backing: backing)
            check(afterRelaunch.appliedAddonOrder == [c, a, b].map { OrderStore.normalize($0.transportUrl) },
                  "relaunch: persisted order survives a fresh process (same backing)")

            // And a live list re-sorts to that persisted order.
            let display = afterRelaunch.orderedByApplied([a, b, c], url: { $0.transportUrl })
            check(display.map(\.name) == ["C", "A", "B"], "relaunch: orderedByApplied re-sorts the live list to the persisted order")
        }

        // 3. METADATA RESOLUTION FOLLOWS THE PERSISTED ORDER (the #144 pick), not just the display.
        do {
            let backing = Backing()
            let store = OrderStore(backing: backing)
            check(resolvedMetaProvider(readyEngineOrder: [a, b, c], store: store)?.name == "A",
                  "resolution: with no applied order, engine order wins (unchanged behavior)")

            store.applyInAppAddonOrder([c, a, b].map(\.transportUrl))
            check(resolvedMetaProvider(readyEngineOrder: [a, b, c], store: store)?.name == "C",
                  "resolution: the persisted order drives which add-on resolves first (C now wins over engine order)")

            store.applyInAppAddonOrder([b, c, a].map(\.transportUrl))
            check(resolvedMetaProvider(readyEngineOrder: [a, b, c], store: store)?.name == "B",
                  "resolution: a further reorder re-points the resolution spine (B now wins)")

            let firstDisplayed = store.orderedByApplied([a, b, c], url: { $0.transportUrl }).first?.name
            check(firstDisplayed == "B", "consistency: display order and resolution order share ONE persisted spine")
        }

        // 4. A not-yet-ordered add-on (installed after the last reorder) is never hidden - it sorts to the tail.
        do {
            let backing = Backing()
            let store = OrderStore(backing: backing)
            store.applyInAppAddonOrder([c, a].map(\.transportUrl))   // b not in the order
            let display = store.orderedByApplied([a, b, c], url: { $0.transportUrl })
            check(display.map(\.name) == ["C", "A", "B"], "tail: an un-ordered add-on (B) keeps its place at the end, never hidden")
        }

        // 5. A confirmed distinct-URL replacement preserves the OLD priority slot and removes a target URL
        //    that was already present in the order. This invokes the real policy used after ReplaceAddonLocal.
        do {
            let old = b.transportUrl
            let new = "https://replacement.example/manifest.json"
            let rewritten = AddonOrderSyncPolicy.replacing([a.transportUrl, old, c.transportUrl, new],
                                                            oldURL: old, newURL: new)
            check(rewritten == [a.transportUrl, new, c.transportUrl].map(OrderStore.normalize),
                  "replace order: new URL takes old slot and is deduplicated")
            check(AddonOrderSyncPolicy.replacing([a.transportUrl, c.transportUrl], oldURL: old, newURL: new)
                    == [a, c].map { OrderStore.normalize($0.transportUrl) },
                  "replace order: absent old URL does not append an unrequested priority")
            check(AddonOrderSyncPolicy.replacing([new, a.transportUrl, old, c.transportUrl], oldURL: old, newURL: new)
                    == [a.transportUrl, new, c.transportUrl].map(OrderStore.normalize),
                  "replace order: a stale earlier target does not shift the old slot right")
        }

        // 6. Equal versions warm-hydrate only a certified, unforced current owner. A first restore after
        //    an accepted push has no applied epoch yet, so effectiveForce MUST remain an apply.
        do {
            check(AddonSyncPullPolicy.decision(pulledVersion: 7, lastSyncedVersion: 7,
                                                effectiveForce: true, hasAppliedAccountDoc: false,
                                                hasPendingAccountDocApply: false, credentialIsCurrent: true) == .apply,
                  "sync gate: forced equal first restore applies instead of early-hydrating")
            check(AddonSyncPullPolicy.decision(pulledVersion: 7, lastSyncedVersion: 7,
                                                effectiveForce: false, hasAppliedAccountDoc: true,
                                                hasPendingAccountDocApply: false, credentialIsCurrent: true) == .warmHydrate,
                  "sync gate: certified unforced equal document warm-hydrates")
            check(AddonSyncPullPolicy.decision(pulledVersion: 6, lastSyncedVersion: 7,
                                                effectiveForce: true, hasAppliedAccountDoc: false,
                                                hasPendingAccountDocApply: false, credentialIsCurrent: true) == .reject,
                  "sync gate: lower version is rejected even when forced")
            check(AddonSyncPullPolicy.decision(pulledVersion: 8, lastSyncedVersion: 7,
                                                effectiveForce: true, hasAppliedAccountDoc: true,
                                                hasPendingAccountDocApply: false, credentialIsCurrent: false) == .reject,
                  "sync gate: stale credentials reject every version")
        }

        print("")
        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        } else {
            print("FAIL: \(failures) assertion(s) failed")
            exit(1)
        }
    }
}
