import Foundation

/// Presentation-only. No local progress, library, credential or account writes.
final class SIMKLContinueWatchingShadow: @unchecked Sendable {
    static let shared = SIMKLContinueWatchingShadow()
    static let changedNote = Notification.Name("vortx.simkl.continueWatching.changed")
    private let lock = NSLock()
    private let reader = SIMKLContinueWatchingReader()
    private var context: HomeContinueWatchingSelection.Context?
    private var session: SIMKLSessionID?
    private var state = SIMKLContinueWatchingReader.Snapshot()
    private var lastAttempt: Date?
    private var generation = 0
    private var running = false

    init() {
        SIMKLAuthBoundary.observe(key: "simkl-continue-watching") { [weak self] _ in self?.clear() }
    }
    func clear() {
        lock.lock(); generation &+= 1; context = nil; session = nil
        state = .init(); lastAttempt = nil; running = false; lock.unlock()
        NotificationCenter.default.post(name: Self.changedNote, object: nil)
    }
    func snapshot(context expected: HomeContinueWatchingSelection.Context, session expectedSession: SIMKLSessionID) -> SIMKLContinueWatchingReader.Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard context == expected, session == expectedSession,
              SIMKLAuth.storedSessionID == expectedSession else { return .init() }
        return state
    }
    @discardableResult
    func refresh(context expected: HomeContinueWatchingSelection.Context, now: Date = Date()) -> Task<Void, Never>? {
        guard expected.preferences.source == .simkl, expected.usesEngineHistory,
              expected.isCurrent(core: .shared, profiles: .shared), SIMKLAuth.isConfigured,
              let expectedSession = SIMKLAuth.storedSessionID else { return nil }
        lock.lock()
        if context != expected || session != expectedSession {
            generation &+= 1; context = expected; session = expectedSession
            state = .init(); lastAttempt = nil; running = false
        }
        guard !running, lastAttempt.map({ now.timeIntervalSince($0) >= 300 }) ?? true else { lock.unlock(); return nil }
        running = true; lastAttempt = now; let captured = generation; lock.unlock()
        return Task { [weak self] in
            guard let self else { return }
            let next = await reader.refresh(session: expectedSession, transport: SIMKLService.shared)
            await MainActor.run {
                self.commit(next, context: expected, session: expectedSession, generation: captured)
            }
        }
    }
    private func commit(_ next: SIMKLContinueWatchingReader.Snapshot,
                        context expected: HomeContinueWatchingSelection.Context, session expectedSession: SIMKLSessionID, generation captured: Int) {
        guard expected.isCurrent(core: .shared, profiles: .shared), SIMKLAuth.storedSessionID == expectedSession else { return }
        lock.lock()
        guard generation == captured, context == expected, session == expectedSession else { lock.unlock(); return }
        state = next; running = false; lock.unlock()
        NotificationCenter.default.post(name: Self.changedNote, object: nil)
    }
}
