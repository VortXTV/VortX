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
enum LoopbackPlaybackAssertion {
    #if canImport(UIKit)
    private static let lock = NSLock()
    private static var task: UIBackgroundTaskIdentifier = .invalid

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Begin the assertion iff `url` is a loopback stream. Idempotent; a no-op for direct/debrid URLs.
    static func begin(for url: URL) {
        guard isLoopback(url) else { return }
        lock.lock(); defer { lock.unlock() }
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "vortx.playback.loopback") { end() }
    }

    /// End the assertion if held. Safe to call unconditionally (player teardown / foreground).
    static func end() {
        lock.lock(); defer { lock.unlock() }
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
    #else
    static func begin(for url: URL) {}
    static func end() {}
    #endif
}
