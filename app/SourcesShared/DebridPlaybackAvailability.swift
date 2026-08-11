import Foundation

final class DebridPlaybackAvailability: @unchecked Sendable {
    static let shared = DebridPlaybackAvailability()

    private let lock = NSLock()
    private var torBoxConfigured = false

    private init() {}

    func publish(torBoxConfigured: Bool) {
        lock.withLock {
            self.torBoxConfigured = torBoxConfigured
        }
    }

    var canResolveUsenet: Bool {
        lock.withLock { torBoxConfigured }
    }
}
