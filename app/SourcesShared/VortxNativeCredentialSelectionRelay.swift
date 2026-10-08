import Foundation

/// Delivers an accepted native credential selection to the account models owned by the app.
/// This is a notification relay, not an account singleton. MainActor-only synchronous delivery
/// prevents queued events from rebinding a newer selection; weak observers do not own app models.
@MainActor
final class VortxNativeCredentialSelectionRelay {
    static let shared = VortxNativeCredentialSelectionRelay()
    private struct Observer {
        weak var owner: AnyObject?
        let reload: @MainActor (AnyObject) -> Void
    }
    private var observers: [Observer] = []
    private var publication: UInt64 = 0

    func observe<Owner: AnyObject>(_ owner: Owner, reload: @escaping @MainActor (Owner) -> Void) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
        observers.append(Observer(owner: owner, reload: { value in
            guard let owner = value as? Owner else { return }
            reload(owner)
        }))
    }

    func publish(isCurrent: @MainActor () -> Bool) {
        guard isCurrent() else { return }
        publication &+= 1
        let accepted = publication
        observers.removeAll { $0.owner == nil }
        // A receiver may synchronously trigger a profile/account transition. A newer publication
        // or failed captured-selection check retires the remainder of the old delivery.
        for observer in observers {
            guard publication == accepted, isCurrent() else { return }
            if let owner = observer.owner { observer.reload(owner) }
        }
    }
}
