import Foundation

/// Errors crossing the UI boundary never interpolate source bytes, URLs, IDs or fingerprints.
enum XperiencePersistenceFailure: Error, Equatable, LocalizedError {
    case unavailable, busy, staleContext, staleRegister, cancelled, invalidSavedImport, unsupportedSavedFormat
    case alreadyImported, exportBaseUnavailable, exportTooLarge, persistenceUncertain, invalidRegistry
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Collection import is unavailable until this account and profile are ready."
        case .busy: return "A collection save is still being confirmed. Wait before saving another import."
        case .staleContext: return "The account, profile or installed add-ons changed. Open a fresh preview."
        case .staleRegister: return "This saved import changed. Open a fresh preview before replacing it."
        case .cancelled: return "The import was cancelled before it was saved."
        case .invalidSavedImport: return "A saved collection import could not be read safely. It has not been changed."
        case .unsupportedSavedFormat: return "A saved import uses a newer format. It has not been changed."
        case .alreadyImported: return "This collection export is already saved in this profile."
        case .exportBaseUnavailable: return "The complete account backup could not be checked. Nothing was imported. Try again after syncing."
        case .exportTooLarge: return "This import would exceed the account backup limit. Existing collections and add-ons have not been removed."
        case .persistenceUncertain: return "The save could not be confirmed. Reopen this page after the account state has been checked."
        case .invalidRegistry: return "The installed add-on catalog could not be matched safely."
        }
    }
}

/// Volatile observation fence only: never stores an account document or secret on disk.
/// A newly observed complete backup retires older witnesses even for the same account/profile.
final class XperienceExportObservationFence: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var generation = UUID()
    @discardableResult func observe() -> UUID {
        lock.withLock { generation = UUID(); return generation }
    }
    func capture() -> UUID { lock.withLock { generation } }
    func withCurrent(_ expected: UUID, _ operation: () throws -> Void) throws {
        try lock.withLock {
            guard generation == expected else { throw XperiencePersistenceFailure.exportBaseUnavailable }
            try operation()
        }
    }
}
