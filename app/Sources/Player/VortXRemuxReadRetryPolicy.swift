import Foundation

/// Bounded wait policy for a retryable, already-classified source read failure. FFmpeg still owns its own
/// HTTP reconnects; this only prevents VortX from immediately hot-looping the same live AVIO context.
enum VortXRemuxReadRetryPolicy {
    static let maximumReadRetries = 4

    private static let steps: [TimeInterval] = [0.5, 1.0, 1.5, 2.0]
    static let totalBackoffSeconds = steps.reduce(0, +)

    static func backoffSeconds(readRetries: Int) -> TimeInterval {
        steps[min(max(readRetries, 1), maximumReadRetries) - 1]
    }

    /// Wait in short slices so teardown does not wait for an otherwise valid reconnect pause. The caller owns
    /// the input context for the entire wait and checks the same cancellation state as the read loop.
    @discardableResult
    static func sleepAbortableSlices(seconds: TimeInterval, isCancelled: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, seconds)
        while !isCancelled() {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return true }
            Thread.sleep(forTimeInterval: min(0.05, remaining))
        }
        return false
    }
}
