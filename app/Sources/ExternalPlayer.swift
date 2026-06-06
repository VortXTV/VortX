import UIKit

/// Hands a captured Stremio stream off to a third-party iOS player (Infuse, VLC) via its
/// documented URL scheme, for users who prefer an external player to the built-in libmpv one.
///
/// iOS-only by design: this file lives in `Sources/` (not `Sources/Player/`), so it is compiled
/// into the iOS target only. tvOS cannot launch other apps, so there is deliberately no tvOS
/// equivalent.
enum ExternalPlayer {
    /// A supported external player and how to deep-link a stream into it.
    struct Target: Identifiable {
        let id: String                      // stable key (also used if we ever persist a default)
        let name: String                    // display name in the chooser
        let icon: String                    // SF Symbol for the chooser row
        fileprivate let probe: URL          // scheme URL used for `canOpenURL`
        fileprivate let make: (URL) -> URL? // builds the deep link for a given stream URL

        /// Is the app installed? Requires the scheme to be listed in `LSApplicationQueriesSchemes`.
        @MainActor var isInstalled: Bool { UIApplication.shared.canOpenURL(probe) }

        func deepLink(for stream: URL) -> URL? { make(stream) }
    }

    /// Every supported target (installed or not). Order = chooser order.
    static let all: [Target] = [
        Target(id: "infuse", name: "Infuse", icon: "play.rectangle.on.rectangle.fill",
               probe: URL(string: "infuse://")!,
               make: { stream in
                   encoded(stream).flatMap { URL(string: "infuse://x-callback-url/play?url=\($0)") }
               }),
        Target(id: "vlc", name: "VLC", icon: "play.tv.fill",
               probe: URL(string: "vlc-x-callback://")!,
               make: { stream in
                   encoded(stream).flatMap { URL(string: "vlc-x-callback://x-callback-url/stream?url=\($0)") }
               }),
    ]

    /// Only the targets actually installed on this device, what the chooser should offer.
    @MainActor static var installed: [Target] { all.filter(\.isInstalled) }

    /// Open `stream` in `target`. Returns false if the app isn't installed or the link couldn't be
    /// built, so the caller can fall back to the built-in player.
    @discardableResult
    @MainActor static func open(_ target: Target, stream: URL) -> Bool {
        guard target.isInstalled, let link = target.deepLink(for: stream) else { return false }
        UIApplication.shared.open(link)
        return true
    }

    /// Percent-encode a whole URL so it can be embedded as the `url=` value of an x-callback link.
    /// `.alphanumerics` is intentionally aggressive (encodes `:/?&=`) so the inner URL can't break
    /// out of the outer query.
    private static func encoded(_ url: URL) -> String? {
        url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    }
}
