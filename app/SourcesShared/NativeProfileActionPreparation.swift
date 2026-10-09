import Foundation

/// A cached profile list is not an acknowledged engine target. Preparation never grants an
/// action to a different account/profile, and a cancelled presentation cannot admit it later.
@MainActor
enum NativeProfileActionPreparation {
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
