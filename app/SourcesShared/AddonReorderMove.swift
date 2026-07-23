import Foundation

/// The pure move + focus math behind the tvOS installed-add-on reorder (`AddonReorderTVView`). tvOS has no
/// touch/pointer drag, so it reorders with two focusable controls per row (Move up / Move down); this type
/// owns exactly the logic that must be right for that to feel good on a remote - the swap, the top/bottom
/// enable rules, and the focus-follow that keeps a FOCUSABLE control under the remote after a move (so holding
/// Move up keeps the same add-on climbing instead of stranding focus on a control that just went disabled).
///
/// Extracted (Foundation-only) so `AddonReorderOrderTests` compiles and asserts THIS code, not a copy: the
/// view maps its `[CoreDescriptor]` to transport-url keys, calls `move`, and applies the returned order.
enum AddonReorderMove {
    /// The focusable control under the remote, keyed by the add-on's transportUrl (STABLE across a reorder,
    /// since `CoreDescriptor.id == transportUrl`) so focus FOLLOWS the moved add-on.
    enum Control: Hashable {
        case up(String)
        case down(String)
    }

    /// A Move up control is focusable/enabled except on the first row.
    static func upEnabled(index: Int, count: Int) -> Bool { index > 0 }
    /// A Move down control is focusable/enabled except on the last row.
    static func downEnabled(index: Int, count: Int) -> Bool { index < count - 1 }

    /// Move the add-on `key` by `delta` (±1) within `keys` (transportUrls in display order). Returns the new
    /// order and the focus target that keeps a still-enabled control under the remote, or nil when the move is
    /// out of bounds (edge press - no change). The focus rule: after moving, prefer the same-direction control,
    /// but if that direction just hit the edge (top has no Move up, bottom no Move down) fall back to the other.
    static func move(_ keys: [String], key: String, by delta: Int) -> (order: [String], focus: Control)? {
        guard let from = keys.firstIndex(of: key) else { return nil }
        let to = from + delta
        guard to >= 0, to < keys.count else { return nil }
        var next = keys
        next.swapAt(from, to)
        let focus: Control
        if delta < 0 {
            focus = (to == 0) ? .down(key) : .up(key)
        } else {
            focus = (to == next.count - 1) ? .up(key) : .down(key)
        }
        return (next, focus)
    }
}
