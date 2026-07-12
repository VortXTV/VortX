import UIKit

/// #95: hand a trailer to the YouTube app when in-app playback cannot serve it (tvOS only; iOS/Mac
/// already have `TrailerOpener`). tvOS has no WKWebView and no external-player sheet, so when both
/// in-app resolves die (device-direct InnerTube AND the worker `/yt` route) the only surface left that
/// can still play the trailer is the YouTube app itself.
///
/// The open is attempted DIRECTLY, with the completion handler deciding the fallback:
/// `UIApplication.open` reports `success == false` when nothing handles the scheme (no YouTube app
/// installed), which needs NO `canOpenURL` probe and therefore NO `LSApplicationQueriesSchemes`
/// Info.plist allowlist entry. The id passed in is the SAME D11 language-preferred id the in-app
/// path plays, so the user's trailer-language preference carries into the YouTube app.
@MainActor enum YouTubeAppOpener {
    /// Try to open `youtube://watch?v=<id>` in the YouTube app. Calls `completion(true)` when the
    /// hand-off happened (the YouTube app is installed and fronting), `completion(false)` when it
    /// cannot (no YouTube app, or a malformed id); the caller then shows its own note or plays in-app.
    /// Fail-soft: never throws, never blocks; the completion always fires exactly once, on the main actor.
    static func openTrailer(youTubeID: String, completion: @escaping @MainActor (Bool) -> Void) {
        // A YouTube id is [A-Za-z0-9_-]; percent-encode anything else so a junk id from a meta can
        // never smuggle extra query parameters into the hand-off URL.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        guard !youTubeID.isEmpty,
              let encoded = youTubeID.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "youtube://watch?v=\(encoded)") else {
            completion(false)
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            Task { @MainActor in completion(opened) }
        }
    }
}
