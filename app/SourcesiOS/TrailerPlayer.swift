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
// origin/Referer, which YouTube rejected with "Error 153". A later attempt hosted the IFrame player via
// `loadHTMLString(baseURL:)`; that also broke once YouTube's July-2025 enforcement began REQUIRING a real
// network `Referer` (every trailer showed "Error code: 152-4"), because loadHTMLString never sends a
// Referer for the cross-origin iframe_api/player requests (WebKit bug 169846). `YouTubeEmbedView` now
// serves the player HTML from a real loaded document via a `WKURLSchemeHandler` and loads it with
// `webView.load(URLRequest)`, so a youtube.com Referer reaches YouTube (see that file's header).
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

/// Probes whether a `trailer.vortx.tv/clip` mp4 is actually warmed in R2, shared by every iOS/Mac
/// Trailer button (hero + detail). A cold clip returns an INSTANT 404 (`x-vortx-reason: clip_warming`,
/// CDN-cached ~2 min) while the worker extracts in the background; handing that 404 to libmpv dead-ends
/// on the full source-error screen ("Trailer unavailable."), so callers probe first and fall back to the
/// YouTube IFrame embed on a miss. HEAD keeps the probe to headers only — the worker ignores `Range`, so
/// a ranged GET would pull the entire mp4 just to learn it exists (verified: HEAD returns 200 on an
/// R2 hit, 404 clip_warming on a miss, and still triggers the worker's background extract).
/// Fail-soft: any transport error reads as not-ready (the caller falls back).
enum TrailerClipProbe {
    static func isReady(_ url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "HEAD"
        req.setValue("VortX", forHTTPHeaderField: "User-Agent")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (200...299).contains(code)
        } catch { return false }
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

    /// The embed reported it cannot play. NEVER hand off to a browser - that is the "Trailer flashes a YouTube
    /// error then Safari opens" report. The in-app trailer must stay in-app: just dismiss the cover, the detail
    /// page keeps its still backdrop. The native libmpv /clip path (preferred in playTrailer) is the real source.
    private func openOnYouTube() {
        onClose()
    }
}
