import Foundation

/// A one-bit, bounded latest-state obligation. Readiness events coalesce while an outbound
/// control is busy; completion drives the next drain. This intentionally has no retry timer.
struct WatchPartyReplayObligation: Equatable {
    private(set) var isDirty = false
    private(set) var isSending = false

    var needsDrain: Bool { isDirty && !isSending }

    mutating func markReady() { isDirty = true }

    /// Leaves the obligation dirty if another control or queued local intent owns the writer.
    mutating func begin(outboundBusy: Bool) -> Bool {
        guard isDirty, !isSending, !outboundBusy else { return false }
        isDirty = false
        isSending = true
        return true
    }

    /// A successful fresh snapshot settles only the publication in flight. A newer ready event
    /// recorded during that send remains dirty and must be drained after completion.
    mutating func complete() { isSending = false }

    /// Retain the latest-state obligation after a reservation was retired before publish.
    mutating func retryAfterRetirement() {
        isSending = false
        isDirty = true
    }

    mutating func cancel() {
        isDirty = false
        isSending = false
    }
}
