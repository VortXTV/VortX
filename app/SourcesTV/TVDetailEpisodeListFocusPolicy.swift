import SwiftUI

/// The series episode-list Up boundary. Only its first row hands focus to the selected season;
/// every deeper row belongs to tvOS's native previous-row navigation.
enum TVDetailEpisodeListFocusPolicy {
    enum Destination: Equatable {
        case seasonPicker
        case episode(Int)
        case native
    }

    static func rowOwnsUpEscape(at index: Int) -> Bool {
        index == 0
    }

    /// Row zero owns the detail-page escape and its first downward list handoff. The latter is explicit
    /// because a registered `onMoveCommand` must not depend on framework propagation to reach row one.
    static func destination(for direction: MoveCommandDirection,
                            fromEpisodeIndex index: Int,
                            episodeCount: Int) -> Destination {
        guard rowOwnsUpEscape(at: index) else { return .native }
        switch direction {
        case .up:
            return .seasonPicker
        case .down where episodeCount > 1:
            return .episode(1)
        default:
            return .native
        }
    }
}
