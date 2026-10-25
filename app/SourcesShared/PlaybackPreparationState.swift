import Foundation

/// Resolution cleanup may finish after a manual action has replaced the old request.
/// Only the attempt that still owns preparation can settle the current spinner.
struct PlaybackPreparationState {
    private(set) var owner: UUID?
    var isActive: Bool { owner != nil }

    mutating func begin() -> UUID {
        let attempt = UUID()
        owner = attempt
        return attempt
    }

    mutating func finish(_ attempt: UUID) {
        guard owner == attempt else { return }
        owner = nil
    }

    mutating func cancel() { owner = nil }
}
