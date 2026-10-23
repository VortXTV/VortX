import SwiftUI

/// A left-to-right layout that wraps onto a new line when a row runs out of width. The hero action rows
/// use it so a chip that doesn't fit the (now hard-width-capped) hero moves to the next line, instead of
/// being compressed into a vertical sliver ("Tr / ail / er"). Each child is measured and placed at its
/// natural size, so labels never wrap. iOS 16+ Layout protocol (the deployment target).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    /// Source badges can contain arbitrarily long add-on names. Ordinary action flows keep their
    /// historical intrinsic-width behavior; this opt-in lets a single oversized badge truncate safely.
    var constrainOversizedItems = false

    private func itemSize(_ subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard constrainOversizedItems, natural.width > maxWidth else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = itemSize(s, maxWidth: maxWidth)
            if x > 0, x + sz.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let sz = itemSize(s, maxWidth: maxWidth)
            if x > bounds.minX, x + sz.width - bounds.minX > maxWidth { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
    }
}
