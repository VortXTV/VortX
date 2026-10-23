import Foundation

/// A cached profile list is not an acknowledged engine target. Preparation never grants an
/// action to a different account/profile, and a cancelled presentation cannot admit it later.
@MainActor
enum NativeProfileActionPreparation {
    /// A picker tap is an intent, not a stale native mutation target. It may acquire its
    /// first target after migration, but never follows a different credential generation.
    struct DeferredSelection<Owner: Equatable> {
        private(set) var profileID: UUID?
        private var owner: Owner?
        private var waitedForPreparation = false
        private(set) var waitedForAccountRestore = false

        mutating func request(_ profileID: UUID, owner: Owner, preparing: Bool = false,
                              accountRestorePreparing: Bool = false) {
            self.profileID = profileID; self.owner = owner
            waitedForPreparation = preparing
            waitedForAccountRestore = accountRestorePreparing
        }
        mutating func observePreparation(_ preparing: Bool, accountRestorePreparing: Bool = false) {
            if profileID != nil, preparing { waitedForPreparation = true }
            if profileID != nil, accountRestorePreparing { waitedForAccountRestore = true }
        }
        mutating func cancel() {
            profileID = nil; owner = nil; waitedForPreparation = false; waitedForAccountRestore = false
        }
        mutating func take(owner: Owner, preparing: Bool, ready: Bool, profileExists: (UUID) -> Bool) -> UUID? {
            guard let profileID else { return nil }
            guard self.owner == owner else { cancel(); return nil }
            observePreparation(preparing)
            guard !preparing else { return nil }
            defer { cancel() }
            return waitedForPreparation && ready && profileExists(profileID) ? profileID : nil
        }
    }

    static func target<T>(isCurrent: @MainActor () -> Bool,
                          capture: @MainActor () -> T?,
                          prepare: @MainActor () async -> Void) async -> T? {
        guard !Task.isCancelled, isCurrent() else { return nil }
        if let accepted = capture() {
            guard !Task.isCancelled, isCurrent() else { return nil }
            return accepted
        }
        await prepare()
        guard !Task.isCancelled, isCurrent() else { return nil }
        guard let acknowledged = capture() else { return nil }
        guard !Task.isCancelled, isCurrent() else { return nil }
        return acknowledged
    }
}
