import Foundation
import os

/// In-memory authority only. No token, history or cursor is persisted by this fence.
/// A process restart has no surviving debounce task; within a process, a fresh epoch prevents
/// same-token sign-out/rejoin and profile A -> B -> A from reviving an old queued write.
enum LegacyWatchOwnership {
    enum ApplicationEpochState: Sendable {
        case current
        case transitioning
        case stale
    }
    enum TaskAdmission: Sendable {
        case admitted
        case transitioning
        case stale
    }
    struct SubtitleRendererEpochObservation: Sendable {
        fileprivate let id: UUID
        fileprivate init(id: UUID) { self.id = id }
    }
    private struct SubtitleRendererObserver: Sendable {
        let originalEpoch: UUID
        let retire: @Sendable () -> Void
    }
    private struct Epoch: Sendable {
        var value = UUID()
        var profileMutationDepth = 0
        var notifyWhenSettled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var subtitleRenderers: [UUID: SubtitleRendererObserver] = [:]
    }
    private static let epoch = OSAllocatedUnfairLock(initialState: Epoch())
    static let sessionDidChange = Notification.Name("vortx.legacyWatchSessionDidChange")
    static func session() -> UUID { epoch.withLock { $0.value } }

    @MainActor
    static func invalidateSession() {
        let retired = epoch.withLock { state in
            let original = state.value
            state.value = UUID()
            let callbacks = detachSubtitleRenderers(&state, originalEpoch: original)
            if state.profileMutationDepth > 0 {
                state.notifyWhenSettled = true
                return (callbacks, false)
            }
            return (callbacks, true)
        }
        for retire in retired.0 { retire() }
        if retired.1 { publishSessionChange() }
    }

    /// Every roster/selection assignment must bracket its entire publication and mutation.
    /// Only a material id/isOwner/usesOwnAccount change retires an existing playback witness.
    /// Equal/name/theme-only changes still block transient reentrant capture, without retiring it.
    @MainActor
    static func beginProfileMutation(retire: Bool) {
        let callbacks = epoch.withLock { state -> [@Sendable () -> Void] in
            state.profileMutationDepth += 1
            if retire {
                let original = state.value
                state.value = UUID()
                state.notifyWhenSettled = true
                return detachSubtitleRenderers(&state, originalEpoch: original)
            }
            return []
        }
        for callback in callbacks { callback() }
    }

    /// Installs only against the ORIGINAL settled epoch. A material assignment detaches and
    /// invokes this exact callback after E unlock, before that assignment's caller can proceed.
    static func observeSubtitleRendererRetirement(ifCurrent original: UUID,
        retire: @escaping @Sendable () -> Void) -> SubtitleRendererEpochObservation? {
        epoch.withLock { state in
            guard state.value == original, state.profileMutationDepth == 0,
                  state.subtitleRenderers.count < 16 else { return nil }
            let id = UUID()
            state.subtitleRenderers[id] = .init(originalEpoch: original, retire: retire)
            return .init(id: id)
        }
    }

    static func removeSubtitleRendererRetirement(_ observation: SubtitleRendererEpochObservation) {
        epoch.withLock { _ = $0.subtitleRenderers.removeValue(forKey: observation.id) }
    }

    private static func detachSubtitleRenderers(_ state: inout Epoch,
        originalEpoch: UUID) -> [@Sendable () -> Void] {
        let retiring = state.subtitleRenderers.filter { $0.value.originalEpoch == originalEpoch }
        for id in retiring.keys { state.subtitleRenderers.removeValue(forKey: id) }
        return retiring.values.map(\.retire)
    }

    @MainActor
    static func endProfileMutation() {
        let settled = epoch.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
            precondition(state.profileMutationDepth > 0)
            state.profileMutationDepth -= 1
            guard state.profileMutationDepth == 0 else { return (false, []) }
            let publish = state.notifyWhenSettled
            let waiters = state.waiters
            state.notifyWhenSettled = false
            state.waiters.removeAll(keepingCapacity: true)
            return (publish, waiters)
        }
        // Resume waiters and notify only after all authority locks are released.
        for waiter in settled.1 { waiter.resume() }
        if settled.0 { publishSessionChange() }
    }

    private static func publishSessionChange() {
        NotificationCenter.default.post(name: sessionDidChange, object: nil)
    }

    static func captureApplicationEpoch() -> UUID? {
        epoch.withLock { $0.profileMutationDepth == 0 ? $0.value : nil }
    }

    static func applicationEpochState(_ expected: UUID) -> ApplicationEpochState {
        epoch.withLock { state in
            guard state.value == expected else { return .stale }
            return state.profileMutationDepth == 0 ? .current : .transitioning
        }
    }

    static func applicationEpochIsCurrent(_ expected: UUID) -> Bool {
        if case .current = applicationEpochState(expected) { return true }
        return false
    }

    /// Wait only for the short synchronous profile publication/mutation to finish. No new owner
    /// is captured; callers re-check their original epoch and cancellation after waking.
    static func waitForProfileMutation() async {
        await withCheckedContinuation { continuation in
            let waiting = epoch.withLock { state in
                guard state.profileMutationDepth > 0 else { return false }
                state.waiters.append(continuation)
                return true
            }
            if !waiting { continuation.resume() }
        }
    }

    /// Lock order is transport request -> credential registry -> profile epoch.
    /// This primitive admits only a prepared URLSession task, never an arbitrary callback.
    static func resumeApplicationTask(_ task: URLSessionTask, ifCurrent expected: UUID) -> TaskAdmission {
        epoch.withLock { state in
            guard state.value == expected else { return .stale }
            guard state.profileMutationDepth == 0 else { return .transitioning }
            task.resume()
            return .admitted
        }
    }

    struct ProfileBinding: Equatable, Sendable {
        let id: UUID
        let isOwner: Bool
        let usesOwnAccount: Bool
    }
    /// Status attribution, not a credential or history store. Keep exact bytes in memory only.
    struct NoticeOwner<Owner: Equatable & Sendable>: Equatable, Sendable {
        let owner: Owner
        let session: UUID
        let profile: ProfileBinding
        private let slot: Data
        private let token: Data
        init(owner: Owner, session: UUID, profile: ProfileBinding, slot: String, token: String) {
            self.owner = owner; self.session = session; self.profile = profile
            self.slot = Data(slot.utf8); self.token = Data(token.utf8)
        }
        func matchesCredential(slot: String, token: String) -> Bool {
            self.slot == Data(slot.utf8) && self.token == Data(token.utf8)
        }
        /// Display projection only, never transport or publication admission. Real credential
        /// mutation/auth/profile transitions retire the in-process epoch before mutation.
        func matchesPresentation(owner: Owner, session: UUID, profile: ProfileBinding) -> Bool {
            self.owner == owner && self.session == session && self.profile == profile
        }
    }

    struct Capture<Owner: Equatable & Sendable>: Sendable {
        let owner: Owner
        let session: UUID
        let profileID: UUID
        private let slot: Data
        private let token: Data
        init(owner: Owner, session: UUID, profileID: UUID, slot: String, token: String) {
            self.owner = owner; self.session = session; self.profileID = profileID
            self.slot = Data(slot.utf8); self.token = Data(token.utf8)
        }
        func matches(owner: Owner, session: UUID, profileID: UUID?, usesEngineHistory: Bool,
                     slot: String, token: String?) -> Bool {
            guard self.owner == owner, self.session == session, self.profileID == profileID,
                  !usesEngineHistory, !self.token.isEmpty, self.slot == Data(slot.utf8), let token else { return false }
            return self.token == Data(token.utf8)
        }
    }

    /// Main-actor auth/profile transitions cannot interleave between admission and invoking
    /// the captured transport. An already issued remote request cannot be recalled; a late
    /// result is never authority to publish a notice or acknowledge another session's work.
    @MainActor static func perform<Result: Sendable>(isCurrent: @MainActor () -> Bool,
        operation: @MainActor () async throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let result = try await operation()
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        return result
    }
}
