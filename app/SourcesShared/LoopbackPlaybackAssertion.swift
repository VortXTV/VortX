import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// #130 secondary mitigation: hold a short background-task assertion while a LOOPBACK (torrent) stream is
/// playing, so a quick app-switch away and back does not immediately suspend the process and let iOS/tvOS
/// tear down the embedded server's bound listener. This only defers suspension by the OS grant (~30s), so it
/// helps brief app-switch hops, NOT the long-background case -- the in-node listener rebind (`NodeServer`)
/// is the real recovery for #130. It is a strict no-op for direct/debrid streams (not loopback) and on
/// macOS (no `UIApplication`; there the server is a separate child process this cannot and need not defer).
#if canImport(UIKit)
@MainActor
#endif
enum LoopbackPlaybackAssertion {
    #if canImport(UIKit)
    private static var task: UIBackgroundTaskIdentifier = .invalid
    private static var generation: UUID?
    /// Depth of overlapping loopback begins. On the tvOS binge straddle the incoming player's `begin` fires
    /// before the outgoing player's `end`, so a plain held/not-held flag would let the outgoing `end` clear the
    /// assertion out from under the new stream. Counting keeps it held until the last loopback player ends.
    private static var depth = 0

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Retire our state before calling UIKit, including a task still being acquired.
    private static func finishTask() {
        let retiringTask = task
        task = .invalid
        generation = nil
        guard retiringTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(retiringTask)
    }

    /// Begin the assertion iff `url` is a loopback stream. Depth-counted; a no-op for direct/debrid URLs.
    static func begin(for url: URL) {
        guard isLoopback(url) else { return }
        depth += 1
        guard depth == 1, task == .invalid else { return }   // start the OS task only on the 0 -> 1 transition
        let originalGeneration = UUID()
        generation = originalGeneration
        let acquiredTask = UIApplication.shared.beginBackgroundTask(withName: "vortx.playback.loopback") {
            // UIKit delivers expiration on MainActor. A retired grant cannot release a newer one.
            guard generation == originalGeneration else { return }
            depth = 0
            finishTask()
        }
        // Retain the original grant only if it survived synchronous expiration/reentry during acquisition.
        guard generation == originalGeneration, depth > 0 else {
            if acquiredTask != .invalid { UIApplication.shared.endBackgroundTask(acquiredTask) }
            return
        }
        task = acquiredTask
    }

    /// End one loopback assertion. Safe to call unconditionally (player teardown / foreground); a no-op when
    /// nothing is held, so a stray/direct end can never underflow the count.
    static func end() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }   // end the OS task only on the 1 -> 0 transition
        finishTask()
    }
    #else
    static func begin(for url: URL) {}
    static func end() {}
    #endif
}
