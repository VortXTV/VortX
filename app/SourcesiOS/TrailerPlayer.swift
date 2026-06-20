import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Trailer playback (iOS/iPad/Mac):
//   • A non-YouTube (direct) trailer stream plays in the native mpv `PlayerScreen`.
//   • A YouTube trailer plays via the keyless YouTube IFrame embed (`YouTubeEmbedView`) in the
//     `TrailerEmbedCover` below — the same mechanism the official Stremio client uses.
// The earlier embed attempt (YouTubeWebView / AutoplayTrailerWebView) was removed because it navigated
// the WKWebView straight TO `youtube.com/embed/<id>` as a top-level document with no controllable
// origin/Referer, which YouTube rejected with "Error 153". `YouTubeEmbedView` fixes that by hosting the
// IFrame player via `loadHTMLString(baseURL:)` with a real embedding origin (see that file's header).
// `TrailerOpener` remains the last-resort external hand-off. tvOS keeps the native mpv `/yt` path
// (no WKWebView there).

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

/// Full-screen cover that plays a YouTube trailer via the keyless IFrame embed (Bug A). A black canvas
/// fills the cover with the interactive `YouTubeEmbedView`; a Done button dismisses. Used by both the
/// detail page Trailer button and (potentially) any other surface that has a yt id and a title.
struct TrailerEmbedCover: View {
    let youTubeID: String
    let title: String
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            YouTubeEmbedView(youTubeID: youTubeID, mode: .interactive, onFailure: openOnYouTube)
                .ignoresSafeArea()
                .accessibilityLabel("\(title) trailer")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(Theme.Space.md)
            .accessibilityLabel("Close trailer")
        }
    }

    /// The embed reported it cannot play (the owner disabled embedding, or the video was removed). Rather
    /// than leave YouTube's "unavailable" card on screen, hand the trailer off to the system (YouTube app
    /// or browser) where the same video plays unrestricted, then dismiss the cover.
    private func openOnYouTube() {
        if let url = URL(string: "https://www.youtube.com/watch?v=\(youTubeID)") {
            TrailerOpener.open(url)
        }
        onClose()
    }
}
