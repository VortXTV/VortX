import Foundation

/// Selects the episode a detail page should show after playback closes.
///
/// The first-frame identity is the physical truth: it names the media the player actually rendered. Engine
/// Continue Watching is the fallback because its asynchronous persistence can still name the prior episode at
/// the exact dismissal boundary. A committed identity from another series, or one absent from the current
/// episode inventory, is never allowed to move this page.
enum EpisodeReturnIdentityPolicy {
    static func resolve(
        libraryID: String,
        isVideoAvailable: (String) -> Bool,
        committedLibraryID: String?,
        committedVideoID: String?,
        engineVideoID: String?
    ) -> String? {
        if committedLibraryID == libraryID,
           let committedVideoID,
           isVideoAvailable(committedVideoID) {
            return committedVideoID
        }
        if let engineVideoID, isVideoAvailable(engineVideoID) {
            return engineVideoID
        }
        return nil
    }
}

/// Lifecycle for one playback-close receipt. A commit belongs to the exact active request, becomes readable
/// only when that request closes, and is cleared when any newer request begins. This lets both mounted detail
/// surfaces observe the same close without turning the receipt into process-lifetime navigation state.
struct EpisodeReturnReceiptState<RequestID: Equatable, Meta> {
    private(set) var activeRequestID: RequestID?
    private var activeCommit: (requestID: RequestID, meta: Meta)?
    private(set) var closedReceipt: (requestID: RequestID, meta: Meta)?

    mutating func begin(requestID: RequestID) {
        activeRequestID = requestID
        activeCommit = nil
        closedReceipt = nil
    }

    @discardableResult
    mutating func record(_ meta: Meta, requestID: RequestID) -> Bool {
        guard activeRequestID == requestID else { return false }
        activeCommit = (requestID, meta)
        return true
    }

    @discardableResult
    mutating func close(requestID: RequestID) -> Meta? {
        guard activeRequestID == requestID else { return nil }
        activeRequestID = nil
        if let activeCommit, activeCommit.requestID == requestID {
            closedReceipt = activeCommit
        } else {
            closedReceipt = nil
        }
        activeCommit = nil
        return closedReceipt?.meta
    }
}
