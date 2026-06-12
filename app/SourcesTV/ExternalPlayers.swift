import UIKit

/// Hand the playing stream off to another installed player app via its URL scheme.
///
/// tvOS supports custom URL schemes the same way iOS does (UIApplication.open +
/// LSApplicationQueriesSchemes in Info.plist), but only a handful of tvOS players
/// register one. Only players whose scheme answers canOpenURL are offered, so the
/// menu shows what is actually installed. Torrent playback is excluded by the
/// caller: its URL points at this app's embedded server, which suspends with the
/// app, so the handed-off stream would die seconds after the switch.
enum ExternalPlayers {
    struct Player {
        let name: String
        let probe: String                       // scheme URL used for the canOpenURL check
        let launch: (String) -> String          // percent-encoded stream URL -> open URL
    }

    /// Candidate tvOS players, preferred first. Schemes verified against each app's
    /// documented x-callback / URL-scheme support.
    static let candidates: [Player] = [
        Player(name: "VLC",
               probe: "vlc-x-callback://",
               launch: { "vlc-x-callback://x-callback-url/stream?url=\($0)" }),
        Player(name: "Infuse",
               probe: "infuse://",
               launch: { "infuse://x-callback-url/play?url=\($0)" }),
        Player(name: "SenPlayer",
               probe: "senplayer://",
               launch: { "senplayer://x-callback-url/play?url=\($0)" }),
    ]

    /// The installed subset of `candidates` (canOpenURL answers true only for schemes
    /// declared in LSApplicationQueriesSchemes; keep Info-tvOS.plist in sync).
    static func installed() -> [Player] {
        candidates.filter {
            guard let probe = URL(string: $0.probe) else { return false }
            return UIApplication.shared.canOpenURL(probe)
        }
    }

    /// Open `streamURL` in `player`. Returns false when the URL cannot be encoded.
    @discardableResult
    static func open(_ streamURL: URL, in player: Player) -> Bool {
        guard let encoded = streamURL.absoluteString.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics) else { return false }
        guard let url = URL(string: player.launch(encoded)) else { return false }
        UIApplication.shared.open(url)
        return true
    }
}
