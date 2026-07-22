// AddonReorderOrderTests: a standalone, runnable verification of the tvOS installed-add-on reorder parity
// (INS-260722-03) in app/SourcesShared/AddonsView.swift (AddonReorderTVView) and the canonical order store
// in app/SourcesShared/VortXSyncManager.swift.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so,
// like app/Tests/HouseholdCryptoTests.swift and StreamRankingChipsTests.swift, this is a self-contained
// Swift executable that runs directly with the system toolchain:
//
//     swift app/Tests/AddonReorderOrderTests.swift
//
// SCOPE: a standalone script cannot link the SwiftUI app target, so this re-implements ONLY the pure logic
// that matters for the reorder contract — the persisted order store (appliedAddonOrder + normalize),
// `orderedByApplied` (the display + list spine), the CoreDetail.meta priority pick (CoreModels.swift #144 —
// the real add-on/source RESOLUTION order), the tvOS move-up/move-down swap, and the focus-target rule that
// keeps a focusable control under the remote. These mirrors MUST stay in lockstep with VortXSyncManager.swift
// and AddonReorderTVView; if the shipped rules there change, update the mirrors below.

import Foundation

// MARK: - Mirror of the canonical order store (VortXSyncManager.appliedAddonOrder + normalize)

/// A tiny persistent backing that survives a simulated relaunch: a fresh `OrderStore` reading the same
/// dictionary is the "relaunched" process reading the same UserDefaults key.
final class Backing {
    var dict: [String: [String]] = [:]   // stands in for UserDefaults
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

    // Mirror of VortXSyncManager.applyInAppAddonOrder's persistence chokepoint (the sync push is out of
    // scope for an offline test; the persisted-order write is what drives resolution + relaunch).
    func applyInAppAddonOrder(_ transportUrls: [String]) {
        let normalized = transportUrls.map { Self.normalize($0) }
        guard normalized != appliedAddonOrder else { return }
        appliedAddonOrder = normalized
    }

    // Mirror of VortXSyncManager.orderedByApplied(_:url:).
    func orderedByApplied<T>(_ items: [T], url: (T) -> String) -> [T] {
        let order = appliedAddonOrder
        guard !order.isEmpty else { return items }
        var index: [String: Int] = [:]
        for (i, u) in order.enumerated() { index[u] = i }
        return items.enumerated().sorted { a, b in
            let ia = index[Self.normalize(url(a.element))]
            let ib = index[Self.normalize(url(b.element))]
            switch (ia, ib) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return a.offset < b.offset
            }
        }.map(\.element)
    }
}

// MARK: - Mirror of a CoreDescriptor (add-on) + the real resolution pick

struct Addon: Equatable { let transportUrl: String; let name: String }

/// Mirror of CoreDetail.meta (CoreModels.swift #144): among the add-ons that returned a ready meta (in
/// ENGINE order), pick the one earliest in the applied order. This is the REAL add-on/source resolution the
/// persisted order drives — not just the on-screen list. `readyEngineOrder` is the engine's own order.
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

// MARK: - Mirror of AddonReorderTVView move + focus-follow

enum MoveControl: Hashable { case up(String), down(String) }

/// Mirror of AddonReorderTVView.move: swap with neighbor, then compute the focus target that keeps a
/// FOCUSABLE control under the remote (never one that just became disabled at the top/bottom edge).
func move(_ ordered: inout [Addon], addon: Addon, by delta: Int) -> MoveControl? {
    guard let from = ordered.firstIndex(where: { $0.transportUrl == addon.transportUrl }) else { return nil }
    let to = from + delta
    guard to >= 0, to < ordered.count else { return nil }
    ordered.swapAt(from, to)
    if delta < 0 {
        return (to == 0) ? .down(addon.transportUrl) : .up(addon.transportUrl)
    } else {
        return (to == ordered.count - 1) ? .up(addon.transportUrl) : .down(addon.transportUrl)
    }
}

/// Mirror of the per-row disabled rule: Move up is focusable/enabled except at index 0; Move down except at
/// the last index. This is the "focus reaches the move controls" structural contract.
func upEnabled(index: Int, count: Int) -> Bool { index > 0 }
func downEnabled(index: Int, count: Int) -> Bool { index < count - 1 }

// MARK: - Tiny assertion harness

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

print("AddonReorderOrderTests")

let a = Addon(transportUrl: "https://a.example/manifest.json", name: "A")
let b = Addon(transportUrl: "https://b.example/manifest.json", name: "B")
let c = Addon(transportUrl: "https://c.example/manifest.json", name: "C")

// 1. FOCUS REACHES MOVE CONTROLS: every movable position exposes an enabled (focusable) control; the top row
//    has no Move up, the bottom no Move down, and the focus-follow lands on a still-enabled control.
do {
    let count = 3
    check(!upEnabled(index: 0, count: count), "focus: top row has NO Move up (disabled)")
    check(downEnabled(index: 0, count: count), "focus: top row HAS Move down (focusable)")
    check(upEnabled(index: 1, count: count) && downEnabled(index: 1, count: count), "focus: middle row has BOTH controls")
    check(upEnabled(index: 2, count: count), "focus: bottom row HAS Move up (focusable)")
    check(!downEnabled(index: 2, count: count), "focus: bottom row has NO Move down (disabled)")

    // Move the bottom add-on up into the middle: focus stays on its Move up (still enabled).
    var ordered = [a, b, c]
    let f1 = move(&ordered, addon: c, by: -1)
    check(ordered.map(\.name) == ["A", "C", "B"], "move: bottom add-on moved up one")
    check(f1 == .up(c.transportUrl), "focus-follow: stays on the moved add-on's Move up (still enabled)")

    // Move it up again to the TOP: Move up would be disabled, so focus must shift to its Move down.
    let f2 = move(&ordered, addon: c, by: -1)
    check(ordered.map(\.name) == ["C", "A", "B"], "move: add-on reached the top")
    check(f2 == .down(c.transportUrl), "focus-follow: shifts to Move down when Move up becomes disabled at the top")
}

// 2. ORDER PERSISTS ACROSS RELAUNCH + WRITES THROUGH THE CANONICAL STORE (no tvOS shadow).
do {
    let backing = Backing()
    let store = OrderStore(backing: backing)
    var ordered = [a, b, c]
    _ = move(&ordered, addon: c, by: -1)            // A, C, B
    _ = move(&ordered, addon: c, by: -1)            // C, A, B
    store.applyInAppAddonOrder(ordered.map(\.transportUrl))
    check(store.appliedAddonOrder == [c, a, b].map { OrderStore.normalize($0.transportUrl) },
          "persist: reorder written THROUGH appliedAddonOrder (normalized), not a display shadow")

    // "Relaunch": a fresh store instance reading the SAME backing must see the persisted order.
    let afterRelaunch = OrderStore(backing: backing)
    check(afterRelaunch.appliedAddonOrder == [c, a, b].map { OrderStore.normalize($0.transportUrl) },
          "relaunch: persisted order survives a fresh process (same backing)")

    // And a live list re-sorts to that persisted order.
    let display = afterRelaunch.orderedByApplied([a, b, c], url: { $0.transportUrl })
    check(display.map(\.name) == ["C", "A", "B"], "relaunch: orderedByApplied re-sorts the live list to the persisted order")
}

// 3. SOURCE QUERIES OCCUR IN PERSISTED ORDER (the real resolution spine, not just display). Even when the
//    ENGINE lists add-ons A,B,C, the persisted order [C,A,B] makes C resolve first.
do {
    let backing = Backing()
    let store = OrderStore(backing: backing)
    // No user order yet → resolution follows engine order (first ready = A).
    check(resolvedMetaProvider(readyEngineOrder: [a, b, c], store: store)?.name == "A",
          "resolution: with no applied order, engine order wins (unchanged behavior)")

    // Reorder so C is first, written through the canonical store.
    store.applyInAppAddonOrder([c, a, b].map(\.transportUrl))
    check(resolvedMetaProvider(readyEngineOrder: [a, b, c], store: store)?.name == "C",
          "resolution: the persisted order drives which add-on resolves first (C now wins over engine order)")

    // Move B to the front; B must now win the resolution.
    store.applyInAppAddonOrder([b, c, a].map(\.transportUrl))
    check(resolvedMetaProvider(readyEngineOrder: [a, b, c], store: store)?.name == "B",
          "resolution: a further reorder re-points the resolution spine (B now wins)")

    // The DISPLAY spine (orderedByApplied) and the RESOLUTION spine agree on the same first item.
    let firstDisplayed = store.orderedByApplied([a, b, c], url: { $0.transportUrl }).first?.name
    check(firstDisplayed == "B", "consistency: display order and resolution order share ONE persisted spine")
}

// 4. A not-yet-ordered add-on (installed after the last reorder) is never hidden — it sorts to the tail.
do {
    let backing = Backing()
    let store = OrderStore(backing: backing)
    store.applyInAppAddonOrder([c, a].map(\.transportUrl))   // b not in the order
    let display = store.orderedByApplied([a, b, c], url: { $0.transportUrl })
    check(display.map(\.name) == ["C", "A", "B"], "tail: an un-ordered add-on (B) keeps its place at the end, never hidden")
}

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("FAIL: \(failures) assertion(s) failed")
    exit(1)
}
