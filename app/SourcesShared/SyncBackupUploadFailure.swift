/// Only allowlisted protocol categories can enter diagnostics or user-facing sync status.
/// The server's arbitrary error body may contain account data and must never be echoed.
enum SyncBackupUploadFailure: Equatable {
    case tooLarge
    case invalidRevision
    case authorization
    case serverRejected
    case unavailable
    case upgradeRequired

    static func classify(status: Int, serverCode: String?) -> Self {
        if status == 426 { return .upgradeRequired }
        if status == 413 { return .tooLarge }
        if status == 401 || status == 403 { return .authorization }
        if status == 400 {
            switch serverCode {
            case "document_too_large", "request_too_large", "payload_too_large", "backup_too_large":
                return .tooLarge
            case "bad_version": return .invalidRevision
            default: return .serverRejected
            }
        }
        return .unavailable
    }

    var diagnosticCode: String {
        switch self {
        case .tooLarge: return "backup_too_large"
        case .invalidRevision: return "invalid_revision"
        case .authorization: return "authorization"
        case .serverRejected: return "server_rejected"
        case .unavailable: return "unavailable"
        case .upgradeRequired: return "upgrade_required"
        }
    }

    var message: String {
        switch self {
        case .upgradeRequired:
            return "Update VortX to sync this account. Your changes are still on this device."
        case .tooLarge:
            return "VortX couldn't save your backup because it is larger than the server accepts. Your changes are still on this device."
        case .invalidRevision, .serverRejected:
            return "VortX couldn't accept this backup. Your changes are still on this device. Try syncing again."
        case .authorization:
            return "VortX couldn't verify your account. Your changes are still on this device. Open Account settings and try again."
        case .unavailable:
            return "VortX couldn't save your backup right now. Your changes are still on this device. It will retry."
        }
    }
}
