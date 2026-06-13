import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Trailers play in the native mpv `PlayerScreen`, resolved via the embedded server's `/yt` route
// (the same path tvOS uses) — see `iOSDetailView.playTrailer` and `FeaturedHeroView.trailerButton`.
// The previous WKWebView YouTube-IFrame embed (TrailerLaunch / TrailerPlayerScreen / YouTubeWebView /
// AutoplayTrailerWebView) was removed: loading the embed as a top-level document with no controllable
// origin/Referer made YouTube reject playback with "Error 153 — Video player configuration error".
// The native stream path sidesteps the IFrame entirely. Only the external-open fallback remains.

/// System-browser / app hand-off for the trailer fallback, the cross-platform twin of ExternalPlayer's
/// open helper (UIApplication on iOS, NSWorkspace on macOS). Used when no playable trailer URL resolves
/// (e.g. the embedded server is still cold-starting, or a no-server build).
enum TrailerOpener {
    @MainActor static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
