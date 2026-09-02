import UIKit

/// Hand the playing stream off to another installed player app via its URL scheme.
///
/// tvOS supports custom URL schemes the same way iOS does (UIApplication.open +
/// LSApplicationQueriesSchemes in Info.plist). The menu prefers the players it can
/// actually detect as installed (canOpenURL, which needs the scheme declared in
/// Info-tvOS.plist), but if it detects none it falls back to showing the whole
/// curated list so the user is never stuck with an empty menu and can try whichever
/// player they have. Torrent playback is excluded by the caller: its URL points at
/// this app's embedded server, which suspends with the app, so a handed-off torrent
/// would die seconds after the switch.
enum ExternalPlayers {
    struct Player: Identifiable {
        let name: String
        let scheme: String                       // bare scheme for the canOpenURL probe
        let launch: (URL, PlaybackMeta?) -> URL? // stream + optional metadata -> open URL
        var id: String { name }
    }

    /// Curated tvOS players that expose a URL-scheme handoff, preferred order. Keep the
    /// scheme list in sync with LSApplicationQueriesSchemes in Info-tvOS.plist or
    /// canOpenURL silently reports them as not installed.
    static let candidates: [Player] = [
        Player(name: "Infuse", scheme: "infuse",
               launch: { stream, metadata in InfuseDeepLink.playURL(stream: stream, metadata: metadata) }),
        Player(name: "VLC", scheme: "vlc-x-callback",
               launch: { stream, _ in
                   encoded(stream).flatMap { URL(string: "vlc-x-callback://x-callback-url/stream?url=\($0)") }
               }),
        Player(name: "Sen Player", scheme: "senplayer",
               launch: { stream, _ in
                   encoded(stream).flatMap { URL(string: "senplayer://x-callback-url/play?url=\($0)") }
               }),
        Player(name: "OutPlayer", scheme: "outplayer",
               launch: { stream, _ in
                   encoded(stream).flatMap { URL(string: "outplayer://\($0)") }
               }),
        Player(name: "nPlayer", scheme: "nplayer-stremiox",
               launch: { stream, _ in
                   encoded(stream).flatMap { URL(string: "nplayer-stremiox://weblink?action=addotgo&url=\($0)") }
               }),
        Player(name: "MX Player", scheme: "mxplayer",
               launch: { stream, _ in
                   encoded(stream).flatMap { URL(string: "mxplayer://\($0)") }
               }),
    ]

    /// Players detected as installed via canOpenURL.
    static func detected() -> [Player] {
        candidates.filter {
            guard let url = URL(string: "\($0.scheme)://") else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }

    /// What the player menu should list: ALWAYS the full curated list. canOpenURL detection is
    /// unreliable on tvOS (it can both miss an installed player and false-positive a single scheme,
    /// which is why the menu was showing only VLC even with nothing installed), so every player
    /// stays selectable and the user picks whichever they actually have. Detected players sort
    /// first so a known-installed one is the top pick; opening an absent player just no-ops.
    static func menu() -> [Player] {
        let installed = detected()
        let installedIDs = Set(installed.map(\.id))
        return installed + candidates.filter { !installedIDs.contains($0.id) }
    }

    /// True when this player is detected as installed (so the menu can mark untested rows).
    static func isInstalled(_ player: Player) -> Bool {
        guard let url = URL(string: "\(player.scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// UserDefaults key for the user's chosen default player (stores `Player.id`, the name; "" or an
    /// unknown id == the built-in libmpv player). Settings binds an @AppStorage Picker to this.
    static let defaultKey = "stremiox.player.tvDefaultPlayer"

    /// The user's chosen default player to auto-hand-off every eligible stream to, or nil for the
    /// built-in player. Resolved from the full curated list (not `detected()`): tvOS canOpenURL is
    /// unreliable, so a player the user deliberately picked is trusted even if detection misses it.
    static func defaultPlayer() -> Player? {
        guard let id = UserDefaults.standard.string(forKey: defaultKey), !id.isEmpty else { return nil }
        return candidates.first { $0.id == id }
    }

    /// Open `streamURL` in `player`. `metadata` enriches only Infuse's documented filename field.
    @discardableResult
    static func open(_ streamURL: URL, in player: Player, metadata: PlaybackMeta? = nil) -> Bool {
        guard let url = player.launch(streamURL, metadata) else { return false }
        UIApplication.shared.open(url)
        return true
    }

    private static func encoded(_ url: URL) -> String? {
        url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    }
}
