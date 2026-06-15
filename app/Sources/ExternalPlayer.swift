#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Hands a captured Stremio stream off to a third-party player (Infuse, VLC) via its documented
/// URL scheme, for users who prefer an external player to the built-in libmpv one. Works on iOS
/// (UIApplication) and macOS (NSWorkspace); tvOS does not compile this file (it cannot launch other
/// apps and uses SourcesTV/ExternalPlayers.swift's own curated handoff instead).
enum ExternalPlayer {
    /// A supported external player and how to deep-link a stream into it.
    struct Target: Identifiable {
        let id: String                      // stable key (also used if we ever persist a default)
        let name: String                    // display name in the chooser
        let icon: String                    // SF Symbol for the chooser row
        fileprivate let probe: URL          // scheme URL used for `canOpenURL`
        fileprivate let make: (URL) -> URL? // builds the deep link for a given stream URL

        /// Is the app installed? On iOS the scheme must be listed in `LSApplicationQueriesSchemes`;
        /// on macOS NSWorkspace resolves a handler for the scheme.
        @MainActor var isInstalled: Bool {
            #if canImport(UIKit)
            UIApplication.shared.canOpenURL(probe)
            #elseif canImport(AppKit)
            NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
            #else
            false
            #endif
        }

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
        #if canImport(UIKit)
        UIApplication.shared.open(link)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(link)
        #endif
        return true
    }

    /// Percent-encode a whole URL so it can be embedded as the `url=` value of an x-callback link.
    /// `.alphanumerics` is intentionally aggressive (encodes `:/?&=`) so the inner URL can't break
    /// out of the outer query.
    private static func encoded(_ url: URL) -> String? {
        url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    }

    // MARK: - Default player (auto-route on Play)

    /// UserDefaults key for the chosen default player. Internal so Settings can bind a Picker to it
    /// via `@AppStorage` (empty string in that store == built-in / no default).
    static let defaultKey = "stremiox.player.defaultExternalID"

    /// The user's chosen DEFAULT player: a Target.id to auto-open every eligible stream in, or nil/empty for
    /// the built-in libmpv player (Settings' @AppStorage Picker writes "" for built-in; defaultTarget treats
    /// any id that matches no installed Target as built-in too). Set from Settings. Persisted across launches.
    static var defaultPlayerID: String? {
        get { UserDefaults.standard.string(forKey: defaultKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: defaultKey) }
            else { UserDefaults.standard.removeObject(forKey: defaultKey) }
        }
    }

    /// The installed default target, if the user picked one and it is still installed; else nil (built-in).
    @MainActor static var defaultTarget: Target? {
        guard let id = defaultPlayerID else { return nil }
        return installed.first { $0.id == id }
    }

    /// Whether `stream` can be handed to an external app: external players need a DIRECT remote URL
    /// (debrid / CDN), not the embedded server's loopback torrent/proxy URL (they can't apply our request
    /// headers or reach an in-process torrent). So torrents and 127.0.0.1/localhost URLs stay built-in.
    static func canRouteExternally(_ stream: URL, isTorrent: Bool) -> Bool {
        guard !isTorrent, let host = stream.host else { return false }
        return host != "127.0.0.1" && host != "localhost"
    }

    /// If a default external player is set and `stream` is eligible, open it there and return true; the
    /// caller then dismisses the built-in player. Returns false to play in the built-in player as usual.
    @MainActor static func routeToDefaultIfSet(_ stream: URL, isTorrent: Bool) -> Bool {
        guard canRouteExternally(stream, isTorrent: isTorrent), let target = defaultTarget else { return false }
        return open(target, stream: stream)
    }
}
