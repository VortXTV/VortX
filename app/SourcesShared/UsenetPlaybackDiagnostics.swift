import Foundation

/// Diagnostics lines for an explicit NZB play. Routes are reported as availability only: no host,
/// URL, indexer or credential ever enters the log.
enum UsenetPlaybackDiagnostics {
    static func routes(_ stream: CoreStream) -> String {
        "savedProviders=\(UsenetProviderStore.isConfigured) addonServers=\(stream.usenetServers.count) "
            + "cloud=\(DebridPlaybackAvailability.shared.canResolveUsenetRemotely)"
    }

    static func outcome(_ result: DebridCoordinator.ExplicitUsenetResolution, startedAt: TimeInterval) -> String {
        let elapsed = String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startedAt)
        switch result {
        case .ready(let ref): return "result=ready route=\(ref.usenetRoute?.rawValue ?? "unknown") elapsed=\(elapsed)s"
        case .unsupported: return "result=unsupported elapsed=\(elapsed)s"
        case .failed: return "result=failed elapsed=\(elapsed)s"
        }
    }
}
