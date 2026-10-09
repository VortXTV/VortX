import Foundation

/// Read-only TV queue presentation. The manager remains the sole order/capacity/action owner.
enum TVDownloadQueuePresentationPolicy {
    struct Capacity: Equatable {
        let maximum: Int
        let allowedRange: ClosedRange<Int>
        var canDecrease: Bool { maximum > allowedRange.lowerBound }
        var canIncrease: Bool { maximum < allowedRange.upperBound }
    }

    struct Priority: Equatable {
        let position: Int
        let count: Int
        var canMoveEarlier: Bool { position > 1 }
        var canMoveLater: Bool { position < count }
    }

    /// Use the manager's captured drain order, never episode order or the store's newest-first order.
    static func priority(for id: UUID, orderedIDs: [UUID]) -> Priority? {
        let matches = orderedIDs.indices.filter { orderedIDs[$0] == id }
        guard matches.count == 1, let index = matches.first else { return nil }
        return .init(position: index + 1, count: orderedIDs.count)
    }

    /// Queued rows render once in priority order. Other rows retain their existing show grouping/order.
    static func groupsExcludingQueued(_ groups: [DownloadGroup]) -> [DownloadGroup] {
        groups.compactMap { group in
            let records = group.records.filter { $0.state != .queued }
            guard !records.isEmpty else { return nil }
            return DownloadGroup(id: group.id, title: group.title, poster: group.poster,
                                 type: group.type, records: records)
        }
    }
}
