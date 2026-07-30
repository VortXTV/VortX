import Foundation

/// Lock-owned consumption state for a rolling HLS playlist.
///
/// A seek has two protected phases. Registration pins the old playback clock while queued admission waits for
/// publication ownership. Successful admission then pins the destination until AVPlayer confirms completion.
/// Periodic samples are accepted only outside both phases. Superseding a request is deliberately only a
/// cancellation: the controller registers a replacement after it has proved that the replacement will enter
/// server admission, so deferred pre-ready and item-replacement intents cannot create phantom pins.
struct VortXHLSSeekAnchorState {
    private(set) var currentPlaybackSeconds: Double?
    private(set) var pendingAdmissionRequestID: UInt64?
    private(set) var pendingReceipt: (requestID: UInt64, playerSeconds: Double)?
    private(set) var latestRequestID: UInt64 = 0

    mutating func reportPlaybackPosition(_ playerSeconds: Double) {
        guard playerSeconds.isFinite,
              playerSeconds >= 0,
              pendingAdmissionRequestID == nil,
              pendingReceipt == nil else { return }
        currentPlaybackSeconds = playerSeconds
    }

    mutating func registerSeek(requestID: UInt64) {
        latestRequestID = requestID
        pendingAdmissionRequestID = requestID
        pendingReceipt = nil
        currentPlaybackSeconds = nil
    }

    func isPendingLatestAdmission(requestID: UInt64) -> Bool {
        latestRequestID == requestID && pendingAdmissionRequestID == requestID
    }

    mutating func admitSeek(
        requestID: UInt64,
        playerSeconds: Double,
        targetIsPublished: Bool
    ) -> Bool {
        guard playerSeconds.isFinite,
              playerSeconds >= 0,
              isPendingLatestAdmission(requestID: requestID) else { return false }
        pendingAdmissionRequestID = nil
        guard targetIsPublished else {
            currentPlaybackSeconds = nil
            return false
        }
        currentPlaybackSeconds = playerSeconds
        pendingReceipt = (requestID, playerSeconds)
        return true
    }

    mutating func completeSeek(requestID: UInt64, playerSeconds: Double) {
        guard playerSeconds.isFinite, playerSeconds >= 0 else {
            cancelSeek(requestID: requestID)
            return
        }
        guard pendingReceipt?.requestID == requestID else { return }
        pendingReceipt = nil
        currentPlaybackSeconds = playerSeconds
    }

    mutating func cancelSeek(requestID: UInt64) {
        let cancelledAdmission = pendingAdmissionRequestID == requestID
        let cancelledReceipt = pendingReceipt?.requestID == requestID
        if cancelledAdmission { pendingAdmissionRequestID = nil }
        if cancelledReceipt { pendingReceipt = nil }
        if cancelledAdmission || cancelledReceipt { currentPlaybackSeconds = nil }
    }

    mutating func invalidate() {
        pendingAdmissionRequestID = nil
        pendingReceipt = nil
        currentPlaybackSeconds = nil
    }
}
