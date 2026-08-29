import Foundation

/// Safety gates shared by the Apple source-row player choosers. Internal-player compatibility stays in
/// `PlayerEngineRouter`; this policy only decides whether a source is self-contained enough to leave VortX.
enum SourcePlayerChoicePolicy {
    static func canHandOffExternally(
        url: URL?,
        isTorrent: Bool,
        isUsenet: Bool,
        requestHeaders: [String: String]?
    ) -> Bool {
        guard !isTorrent, !isUsenet, requestHeaders?.isEmpty ?? true,
              let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return host != "127.0.0.1" && host != "localhost" && host != "::1"
    }
}
