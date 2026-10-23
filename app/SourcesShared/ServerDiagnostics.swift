import Foundation
import os

/// Cross-target indirection so shared diagnostics (the VXProbe heartbeat and the VXDiagExport export path,
/// both in SourcesShared) can fold in the embedded streaming server's state WITHOUT SourcesShared depending
/// on a concrete `NodeServer` type. That type exists under two guises that are compiled into DIFFERENT
/// targets (`Sources/NodeServer.swift` for iOS/tvOS, `SourcesShared/MacNodeServer.swift` for macOS) and is
/// absent entirely from the Lite tvOS build, so a direct reference would fail to compile in whichever target
/// has no server. Each server registers its own status + log-tail accessors at boot; when nothing is
/// registered (the Lite build) the callers simply omit the server section.
///
/// Foundation/os and self-contained on purpose: the web-host target compiles this file individually
/// (project.yml) alongside DiagnosticsLog/VXProbe, so it must pull in no app or engine types. Providers are
/// read on heartbeat / export threads, so callbacks must safely support concurrent invocation.
enum ServerDiagnostics {
    private struct Providers: Sendable {
        let status: (@Sendable () -> String)?
        let logTail: (@Sendable (Int) -> [String])?
    }

    private static let providers = OSAllocatedUnfairLock(
        initialState: Providers(status: nil, logTail: nil)
    )

    /// Register the running server's one-line status + log-tail accessors. Called once at boot by whichever
    /// `NodeServer` the platform compiles; re-registration harmlessly overwrites.
    static func register(
        status: @escaping @Sendable () -> String,
        logTail: @escaping @Sendable (Int) -> [String]
    ) {
        let previous = providers.withLock { state in
            let previous = state
            state = Providers(status: status, logTail: logTail)
            return previous
        }
        // Retire old captures outside the lock: their deinitializers may re-enter diagnostics.
        withExtendedLifetime(previous) {}
    }

    /// The current one-line server status, or nil when no server is registered (the Lite build). The provider
    /// is copied out under the lock and invoked outside it, so a status accessor that itself touches shared
    /// state never re-enters this lock.
    static func status() -> String? {
        let provider = providers.withLock { $0.status }
        return provider?()
    }

    /// The last `lines` of the server's own log, or [] when no server is registered.
    static func logTail(_ lines: Int) -> [String] {
        let provider = providers.withLock { $0.logTail }
        return provider?(lines) ?? []
    }
}
