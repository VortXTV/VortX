import Foundation

/// Cross-target indirection so shared diagnostics (the VXProbe heartbeat and the VXDiagExport export path,
/// both in SourcesShared) can fold in the embedded streaming server's state WITHOUT SourcesShared depending
/// on a concrete `NodeServer` type. That type exists under two guises that are compiled into DIFFERENT
/// targets (`Sources/NodeServer.swift` for iOS/tvOS, `SourcesShared/MacNodeServer.swift` for macOS) and is
/// absent entirely from the Lite tvOS build, so a direct reference would fail to compile in whichever target
/// has no server. Each server registers its own status + log-tail accessors at boot; when nothing is
/// registered (the Lite build) the callers simply omit the server section.
///
/// Foundation-only and self-contained on purpose: the web-host target compiles this file individually
/// (project.yml) alongside DiagnosticsLog/VXProbe, so it must pull in nothing else. Set-once at boot, read
/// on the heartbeat / export path: a single lock is more than enough.
enum ServerDiagnostics {
    private static let lock = NSLock()
    private static var statusProvider: (() -> String)?
    private static var logTailProvider: ((Int) -> [String])?

    /// Register the running server's one-line status + log-tail accessors. Called once at boot by whichever
    /// `NodeServer` the platform compiles; re-registration harmlessly overwrites.
    static func register(status: @escaping () -> String, logTail: @escaping (Int) -> [String]) {
        lock.lock()
        statusProvider = status
        logTailProvider = logTail
        lock.unlock()
    }

    /// The current one-line server status, or nil when no server is registered (the Lite build). The provider
    /// is copied out under the lock and invoked outside it, so a status accessor that itself touches shared
    /// state never re-enters this lock.
    static func status() -> String? {
        lock.lock(); let provider = statusProvider; lock.unlock()
        return provider?()
    }

    /// The last `lines` of the server's own log, or [] when no server is registered.
    static func logTail(_ lines: Int) -> [String] {
        lock.lock(); let provider = logTailProvider; lock.unlock()
        return provider?(lines) ?? []
    }
}
