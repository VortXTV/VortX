import SwiftUI

/// The series episode-list Up boundary. A list can escape to the detail hero only from its first row;
/// every deeper row belongs to tvOS's native previous-row navigation.
enum TVDetailEpisodeListFocusPolicy {
    static func rowOwnsUpEscape(at index: Int) -> Bool {
        index == 0
    }

    static func owns(direction: MoveCommandDirection, at index: Int) -> Bool {
        direction == .up && rowOwnsUpEscape(at: index)
    }
}
