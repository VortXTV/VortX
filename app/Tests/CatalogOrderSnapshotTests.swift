// Compile the complete production CatalogPreferences.swift with
// -D PORTRAIT_ADAPTIVE_LAYOUT_CONTRACT_ONLY to select its Foundation-only contracts.
// This checks the production rank snapshot, not SwiftUI/CoreBridge or device latency.
import Foundation

@main
struct CatalogOrderSnapshotTests {
    static func main() {
        var checks = 0
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition {
                failures += 1
                print("FAIL: \(name)")
            }
        }

        let empty = CatalogOrderSnapshot([])
        expect(empty.rank("missing") == Int.max, "empty order leaves rows unlisted")
        let duplicates = CatalogOrderSnapshot(["b", "a", "b", "", "a"])
        expect(duplicates.rank("b") == 0, "first duplicate wins")
        expect(duplicates.rank("a") == 1, "later duplicate does not move first rank")
        expect(duplicates.rank("") == 3, "empty keys retain existing firstIndex behavior")
        expect(duplicates.rank("missing") == Int.max, "unlisted rank stays max")

        var mutableOrder = ["a", "b"]
        let captured = CatalogOrderSnapshot(mutableOrder)
        mutableOrder = ["b", "a"]
        expect(captured.rank("a") == 0 && captured.rank("b") == 1,
               "later preference replacement cannot alter an existing sort")
        expect(CatalogOrderSnapshot(mutableOrder).rank("b") == 0,
               "next build uses the new order")

        let orders = [[], ["a"], ["b", "a"], ["b", "b", "a"],
                      ["", "a", ""], ["absent", "c", "a", "b"]]
        let inputs = [["a", "b", "c"], ["c", "b", "a"], ["b", "b", "a", ""],
                      [], ["missing", "a", "missing", "b", "c"]]
        let keys = ["", "a", "b", "c", "absent", "missing"]
        for (orderIndex, order) in orders.enumerated() {
            let snapshot = CatalogOrderSnapshot(order)
            for key in keys {
                expect(snapshot.rank(key) == (order.firstIndex(of: key) ?? Int.max),
                       "rank parity order \(orderIndex) key \(key)")
            }
            for (inputIndex, input) in inputs.enumerated() {
                // The Home caller's unchanged tie rule retains engine order, including duplicates.
                let old = input.enumerated().sorted { a, b in
                    let lhs = order.firstIndex(of: a.element) ?? Int.max
                    let rhs = order.firstIndex(of: b.element) ?? Int.max
                    return lhs != rhs ? lhs < rhs : a.offset < b.offset
                }.map(\.element)
                let next = input.enumerated().sorted { a, b in
                    let lhs = snapshot.rank(a.element), rhs = snapshot.rank(b.element)
                    return lhs != rhs ? lhs < rhs : a.offset < b.offset
                }.map(\.element)
                expect(next == old, "stable Home parity \(orderIndex)/\(inputIndex)")
            }
        }
        expect(checks == 73, "all finite parity cases executed")
        guard failures == 0 else { exit(1) }
        print("Catalog order snapshot: 74 checks passed")
    }
}
