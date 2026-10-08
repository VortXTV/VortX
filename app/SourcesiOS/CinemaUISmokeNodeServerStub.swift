#if CINEMA_UI_SMOKE_RENDERER && os(iOS) && VORTX_NO_EMBEDDED_SERVER
/// Compile-only Settings diagnostics surface. The offline renderer never creates the real server;
/// reaching either property is an isolation violation, not a simulated server state.
enum NodeServer {
    static var statusDescription: String {
        preconditionFailure("Cinema UI renderer must not read NodeServer diagnostics")
    }

    static func logTail(_ count: Int) -> [String] {
        preconditionFailure("Cinema UI renderer must not read NodeServer logs")
    }
}
#endif
