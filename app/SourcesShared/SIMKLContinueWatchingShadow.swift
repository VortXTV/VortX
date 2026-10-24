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
    func snapshot(context expected: HomeContinueWatchingSelection.Context, session expectedSession: SIMKLSessionID,
                  owner: CoreBridge.NativePlaybackReadCapability) -> SIMKLContinueWatchingReader.Snapshot {
        guard expected.isCurrent(owner: owner) else { return .init() }
        lock.lock(); defer { lock.unlock() }
        guard context == expected, session == expectedSession,
              SIMKLAuth.storedSessionID == expectedSession,
              expected.isCurrent(owner: owner) else { return .init() }
        return state
    }
    @discardableResult
    func refresh(context expected: HomeContinueWatchingSelection.Context,
                 owner: CoreBridge.NativePlaybackReadCapability, now: Date = Date()) -> Task<Void, Never>? {
        guard expected.preferences.source == .simkl, expected.usesEngineHistory,
              expected.isCurrent(owner: owner), SIMKLAuth.isConfigured,
              let expectedSession = SIMKLAuth.storedSessionID else { return nil }
        lock.lock()
        guard expected.isCurrent(owner: owner), SIMKLAuth.storedSessionID == expectedSession else {
            lock.unlock(); return nil
        }
        if context != expected || session != expectedSession {
            generation &+= 1; context = expected; session = expectedSession
            state = .init(); lastAttempt = nil; running = false
        }
        guard !running, lastAttempt.map({ now.timeIntervalSince($0) >= 300 }) ?? true else { lock.unlock(); return nil }
        // A completion releases only its own attempt, including same-context B retirement.
        // Context/session resets already advance this counter; each admitted attempt does too.
        generation &+= 1
        running = true; lastAttempt = now; let captured = generation; lock.unlock()
        return Task { [weak self] in
            guard let self else { return }
            defer { self.finishRefresh(context: expected, session: expectedSession, generation: captured) }
            guard expected.isCurrent(owner: owner),
                  SIMKLAuth.storedSessionID == expectedSession else { return }
            let next = await reader.refresh(session: expectedSession, transport: SIMKLService.shared)
            await MainActor.run {
                self.commit(next, context: expected, session: expectedSession, generation: captured, owner: owner)
            }
        }
    }
    private func commit(_ next: SIMKLContinueWatchingReader.Snapshot,
                        context expected: HomeContinueWatchingSelection.Context, session expectedSession: SIMKLSessionID,
                        generation captured: Int, owner: CoreBridge.NativePlaybackReadCapability) {
        guard expected.isCurrent(owner: owner), SIMKLAuth.storedSessionID == expectedSession else { return }
        lock.lock()
        guard generation == captured, context == expected, session == expectedSession,
              SIMKLAuth.storedSessionID == expectedSession, expected.isCurrent(owner: owner) else { lock.unlock(); return }
        state = next; running = false; lock.unlock()
        guard expected.isCurrent(owner: owner), SIMKLAuth.storedSessionID == expectedSession else { return }
        NotificationCenter.default.post(name: Self.changedNote, object: nil)
    }
    private func finishRefresh(context expected: HomeContinueWatchingSelection.Context,
                               session expectedSession: SIMKLSessionID, generation captured: Int) {
        lock.lock(); defer { lock.unlock() }
        guard generation == captured, context == expected, session == expectedSession else { return }
        running = false
    }
}
