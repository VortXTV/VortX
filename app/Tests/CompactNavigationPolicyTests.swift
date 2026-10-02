import Foundation

@main
enum CompactNavigationPolicyTests {
    private enum Route: CaseIterable { case home, discover, live, library, search, addons, settings }

    static func main() {
        let optional: [Route] = [.discover, .live, .library, .search]
        let preferred: [Route] = [.home, .discover, .library, .search]
        for mask in 0..<16 {
            for mergeSearch in [false, true] {
                let hidden = optional.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
                let visible = Route.allCases.filter { !hidden.contains($0) && !(mergeSearch && $0 == .search) }
                let layout = TabBarPrefs.compactLayout(visible: visible, preferred: preferred)
                precondition(layout.primary.count + (layout.overflow.isEmpty ? 0 : 1) <= 5)
                precondition(layout.primary + layout.overflow == visible.filter { layout.primary.contains($0) } + visible.filter { layout.overflow.contains($0) })
                precondition((layout.primary + layout.overflow).count == visible.count)
                precondition(visible.allSatisfy { layout.primary.contains($0) != layout.overflow.contains($0) })
                precondition(layout.primary.contains(.home))
                precondition((layout.primary + layout.overflow).contains(.addons))
                precondition((layout.primary + layout.overflow).contains(.settings))
                if visible.count <= 5 { precondition(layout.primary == visible && layout.overflow.isEmpty) }
                else { precondition(layout.primary.allSatisfy { preferred.contains($0) }) }
            }
        }
        print("PASS 32 visibility/merge combinations preserve all routes, order, anchors and five-target limit")
    }
}
