import SwiftUI

/// The series episode-grid Up boundary. Only the grid's first row hands focus to the selected season;
/// every deeper row belongs to tvOS's native grid navigation. `columns == 1` is the old single list.
enum TVDetailEpisodeListFocusPolicy {
    enum Destination: Equatable {
        case seasonPicker
        case episode(Int)
        case native
    }

    static func rowOwnsUpEscape(at index: Int, columns: Int = 1) -> Bool {
        index >= 0 && index < max(1, columns)
    }

    /// A first-row card owns the detail-page escape and every other move out of it. All four directions are
    /// explicit because a registered `onMoveCommand` must not depend on framework propagation to reach its
    /// neighbours. Down from a first-row card past the last partial row lands on the final episode.
    static func destination(for direction: MoveCommandDirection,
                            fromEpisodeIndex index: Int,
                            episodeCount: Int,
                            columns: Int = 1) -> Destination {
        let columns = max(1, columns)
        guard rowOwnsUpEscape(at: index, columns: columns), index < episodeCount else { return .native }
        switch direction {
        case .up:
            return .seasonPicker
        case .down:
            let below = index + columns
            if below < episodeCount { return .episode(below) }
            return episodeCount > columns ? .episode(episodeCount - 1) : .native
        case .left:
            return index > 0 ? .episode(index - 1) : .native
        case .right:
            return index + 1 < min(columns, episodeCount) ? .episode(index + 1) : .native
        @unknown default:
            return .native
        }
    }
}
