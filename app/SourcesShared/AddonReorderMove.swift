import Foundation

/// A user edit is different from an engine snapshot or a remote apply. The nonce is also required for
/// A -> B -> A: acknowledging the first A must not acknowledge the later explicit undo.
struct AddonOrderIntent: Codable, Equatable, Sendable {
    let accountID: String
    let nonce: UUID
    let order: [String]

    init(accountID: String, order: [String]) {
        self.accountID = accountID
        self.nonce = UUID()
        self.order = AddonOrderSyncPolicy.unique(order)
    }
}

enum AddonOrderSyncPolicy {
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return Array(values.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(1024))
    }

    /// Without an explicit edit, the fetched cloud order wins. Missing engine entries are not removals.
    /// Concurrent explicit reorders are atomic local-intent-wins; remote-only entries stay at the end.
    /// Membership remains governed by the separate timestamped removal/install records, not this array.
    static func merge(remote: [String]?, seed: [String], intent: AddonOrderIntent?,
                      accountID: String, removed: Set<String>) -> [String]? {
        let desired = intent.flatMap { $0.accountID == accountID ? $0.order : nil }
        guard remote != nil || desired != nil || !seed.isEmpty else { return nil }
        let values = desired.map { $0 + (remote ?? []) + seed } ?? remote ?? seed
        return unique(values.filter { !removed.contains($0) })
    }

    static func acknowledges(_ pending: AddonOrderIntent?, sent: AddonOrderIntent?, accountID: String) -> Bool {
        guard let pending, let sent else { return false }
        return pending.accountID == accountID && pending == sent
    }

    /// Replacing an installed add-on must retain the user's explicit priority slot.  The engine replaces
    /// its descriptor atomically, but its transport URL is the order key, so rewrite that intent only after
    /// the replacement itself has been confirmed.  Remove an existing target first to avoid duplicate ranks.
    static func replacing(_ order: [String], oldURL: String, newURL: String) -> [String] {
        let old = oldURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let new = newURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = unique(order.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard !old.isEmpty, !new.isEmpty, old != new,
              let oldIndex = result.firstIndex(of: old) else { return result }
        // A stale order can still contain `new` before `old`; removing it must not make the replacement
        // drift right. Count the surviving prefix first, then insert at that logical old slot.
        let replacementIndex = result[..<oldIndex].filter { $0 != new }.count
        result.removeAll { $0 == old || $0 == new }
        result.insert(new, at: min(replacementIndex, result.count))
        return result
    }
}

/// Pure version gate for an already-pulled account document. Kept Foundation-only so the standalone
/// regression binary executes the exact policy used by `VortXSyncManager.syncDown`.
enum AddonSyncPullPolicy {
    enum Decision: Equatable { case reject, warmHydrate, apply }

    static func decision(pulledVersion: Int, lastSyncedVersion: Int, effectiveForce: Bool,
                         hasAppliedAccountDoc: Bool, hasPendingAccountDocApply: Bool,
                         credentialIsCurrent: Bool) -> Decision {
        guard credentialIsCurrent, pulledVersion >= lastSyncedVersion else { return .reject }
        guard pulledVersion == lastSyncedVersion, !effectiveForce else { return .apply }
        return hasAppliedAccountDoc && !hasPendingAccountDocApply && credentialIsCurrent
            ? .warmHydrate : .reject
    }
}

/// The same stable order drives the add-on list and source groups. Never discard unlisted add-ons:
/// new installs remain at the end, and multiple groups from one add-on retain their response order.
enum AddonAppliedOrder {
    static func sorted<T>(_ items: [T], order: [String], key: (T) -> String) -> [T] {
        guard !order.isEmpty else { return items }
        var rank: [String: Int] = [:]
        for (index, value) in order.enumerated() where rank[value] == nil { rank[value] = index }
        return items.enumerated().sorted { lhs, rhs in
            let left = rank[key(lhs.element)] ?? Int.max
            let right = rank[key(rhs.element)] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
}

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
