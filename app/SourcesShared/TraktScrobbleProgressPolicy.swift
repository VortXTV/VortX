import Foundation

/// Random identity for one locally authenticated Trakt credential set.
///
/// Token rotation keeps this value. Sign-out, account replacement, and a new authorization replace it.
/// The raw value is never logged or sent to Trakt.
struct TraktSessionID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func random() -> TraktSessionID {
        TraktSessionID(rawValue: UUID().uuidString)
    }
}

/// Synchronous in-process notification for an authentication boundary.
///
/// Observers clear private account state before the auth call returns. Session checks remain the
/// authority, so an observer that has not been initialized yet cannot make stale state readable.
enum TraktAuthBoundary {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var observers: [String: @Sendable (TraktSessionID?) -> Void] = [:]
    }

    private static let state = State()

    static func observe(
        key: String,
        _ observer: @escaping @Sendable (TraktSessionID?) -> Void
    ) {
        state.lock.lock()
        state.observers[key] = observer
        state.lock.unlock()
    }

    static func removeObserver(key: String) {
        state.lock.lock()
        state.observers.removeValue(forKey: key)
        state.lock.unlock()
    }

    static func publish(_ sessionID: TraktSessionID?) {
        state.lock.lock()
        let observers = Array(state.observers.values)
        state.lock.unlock()
        for observer in observers {
            observer(sessionID)
        }
    }
}

/// FIFO for Trakt's ordered playback lifecycle.
///
/// Trakt `start` is a state transition, not a progress update: it removes an existing paused-playback
/// record. The coordinator therefore emits it only for initial play/resume and puts start/pause/stop on
/// this one serial lane. A slow start request must finish before a later pause or stop can reach Trakt.
final class TraktScrobbleLifecycleQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let predecessor = tail
        let next = Task.detached(priority: .utility) {
            _ = await predecessor?.result
            await operation()
        }
        tail = next
        lock.unlock()
    }

    /// Test seam and shutdown aid: waits for everything enqueued before this call.
    func drain() async {
        let pending = pendingTask()
        _ = await pending?.result
    }

    private func pendingTask() -> Task<Void, Never>? {
        lock.lock()
        let pending = tail
        lock.unlock()
        return pending
    }
}

/// A signed-out refresh is a no-op and must not consume the next signed-in refresh window.
enum TraktPlaybackRefreshThrottlePolicy {
    static func shouldArm(signedIn: Bool, generationMatches: Bool) -> Bool {
        signedIn && generationMatches
    }
}

/// Pure account and generation guards used by the playback shadow and its adversarial tests.
enum TraktPlaybackSnapshotPolicy {
    static func canRead<Session: Equatable>(
        snapshotSession: Session?,
        currentSession: Session?
    ) -> Bool {
        guard let snapshotSession, let currentSession else { return false }
        return snapshotSession == currentSession
    }

    static func canCommit<Session: Equatable>(
        capturedSession: Session?,
        stateSession: Session?,
        currentSession: Session?,
        capturedGeneration: Int,
        currentGeneration: Int
    ) -> Bool {
        guard capturedGeneration == currentGeneration,
              let capturedSession,
              capturedSession == stateSession,
              capturedSession == currentSession else { return false }
        return true
    }
}
