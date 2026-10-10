import Foundation

/// One invocation, not an episode or retry number, owns preparation. Retry numbers can restart at one
/// after a source change, and the same episode can be requested again while cancelled work winds down.
struct NextEpisodePreparationAttemptOwner {
    private(set) var currentID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        currentID = id
        return id
    }

    func isCurrent(_ id: UUID) -> Bool { currentID == id }

    @discardableResult
    mutating func finish(_ id: UUID) -> Bool {
        guard isCurrent(id) else { return false }
        currentID = nil
        return true
    }

    mutating func cancel() { currentID = nil }
}
