import Foundation

/// iOS/tvOS streaming server facade. The server is the VortX engine's in-process streaming server
/// (`VortxNativeServer`); this type keeps the platform-neutral `NodeServer` call sites shared with
/// macOS (`SourcesShared/MacNodeServer.swift`), where the same engine server runs as a child process.
enum NodeServer {
    /// One-line state for the Settings diagnostics.
    static var statusDescription: String { VortxNativeServer.statusDescription }

    /// The in-process engine server writes no separate log file; its events go to DiagnosticsLog.
    static func logTail(_ lines: Int = 4) -> [String] { [] }

    static func startIfNeeded() {
        ServerDiagnostics.register(status: { VortxNativeServer.statusDescription }, logTail: { _ in [] })
        VortxNativeServer.startIfNeeded()
    }
}
