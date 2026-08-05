import Foundation

/// Deduplicated emitter for the `[dv] route ...` engine-routing line, shared by both player screens.
///
/// WHY THIS EXISTS. `routedToAVPlayer` is a SwiftUI COMPUTED property on `TVPlayerView` and on its
/// `PlayerScreen` twin. `engineLatch` caps it to the render passes that happen BEFORE `onAppear` seeds the
/// latch (#76 b163, which is what stopped it running on every body pass), but "a handful of pre-latch
/// passes" is still 3-4 identical lines per load, and on tvOS the screen wrote that same text TWICE per
/// pass: once through `VXProbe.log` and once through the breadcrumb, whose `DiagnosticsLog` hop mirrors
/// into the very same probe file. Diag-21 counted the decision 3-4x per load for that reason. The
/// exportable diagnostic file is a ~3 MiB rolling buffer, so every repeated line evicts one that said
/// something new. One emitter, deduplicated, replaces both.
///
/// WHY THE ALWAYS-ON CHANNEL. `DiagnosticsLog` reaches BOTH surfaces at once: the always-on
/// `diagnostics.log` (so a user build still records which engine played a title even with probe logging
/// off) and, whenever probing IS on, the exportable probe log through `DiagnosticsLog`'s own mirror. A
/// second direct `VXProbe.log` of identical text therefore adds no information to any reader.
///
/// The CALLER owns the content of the line: identifiers must already be tokenised through
/// `VXProbeRedaction.identityToken` before they arrive here, exactly as at the two original call sites.
///
/// Lock-guarded rather than `@MainActor` so the isolation of a SwiftUI computed property is never part of
/// the contract; the lock is held only for the comparison and the two stores, never across the log write.
enum DVRouteBreadcrumb {

    /// Two IDENTICAL route decisions closer together than this are one decision being re-rendered, not two
    /// loads, so only the first is written. WHY A TIME WINDOW rather than a plain "has the text changed?"
    /// latch: the pre-latch render passes all land inside a single SwiftUI update (sub-millisecond apart),
    /// so one second folds every one of them, while a genuine replay of the SAME title with the SAME routing
    /// decision minutes later is still recorded instead of being swallowed forever by an unbounded latch.
    static let dedupeWindowSeconds: TimeInterval = 1

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastMessage = ""
    /// Monotonic-ish (`systemUptime` does not advance while the device sleeps, which for a one-second
    /// window can only ever fold one extra re-render and never drops a distinct decision).
    nonisolated(unsafe) private static var lastAt: TimeInterval = -.greatestFiniteMagnitude

    static func log(_ message: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        let duplicate = message == lastMessage && now - lastAt < dedupeWindowSeconds
        if !duplicate {
            lastMessage = message
            lastAt = now
        }
        lock.unlock()
        guard !duplicate else { return }
        DiagnosticsLog.log("dv", message)
    }
}
