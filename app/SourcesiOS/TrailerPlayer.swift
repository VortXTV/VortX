import SwiftUI
import WebKit

/// Netflix-style trailer playback for the touch / Mac detail page. A meta's YouTube trailer id
/// (`CoreMetaItem.trailerYouTubeID`) is played inside a `WKWebView` YouTube IFrame embed, which is the
/// simplest reliable cross-platform path: it works on iOS and macOS without resolving the YouTube
/// stream ourselves (resolving raw googlevideo URLs is brittle and rate-limited). If the embed can't
/// load, the overlay offers "Open in YouTube" which hands the watch URL to the system browser / app.
///
/// The view is `Identifiable` so it can drive a `platformFullScreenCover(item:)` exactly like the
/// stream player launch.
struct TrailerLaunch: Identifiable {
    let id = UUID()
    let youTubeID: String
    let title: String

    /// The standard watch URL, used by the "Open in YouTube" fallback (opens the YouTube app when
    /// installed, otherwise the browser).
    var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(youTubeID)") }

    /// Autoplaying, chromeless IFrame embed. `playsinline=1` keeps it inside our cover on iPhone
    /// rather than throwing it into the system fullscreen player (which would dismiss our UI).
    var embedURL: URL? {
        URL(string: "https://www.youtube.com/embed/\(youTubeID)?autoplay=1&playsinline=1&rel=0&modestbranding=1")
    }
}

/// The muted/looping embed URL for the Netflix-style hero autoplay layer. `mute=1` is required for
/// autoplay to be honored without a user gesture; `loop=1` only loops when paired with
/// `playlist=<id>` (a single-video playlist of the same id); `controls=0` hides the chrome so the
/// art reads cleanly behind the hero overlay.
func mutedLoopingEmbedURL(forYouTubeID id: String) -> URL? {
    URL(string: "https://www.youtube.com/embed/\(id)?autoplay=1&mute=1&loop=1&controls=0&playsinline=1&rel=0&modestbranding=1&playlist=\(id)")
}

/// Full-screen trailer cover: the YouTube embed on a black canvas with a close affordance and a
/// browser fallback. Reused by `iOSDetailView` via `platformFullScreenCover`.
struct TrailerPlayerScreen: View {
    let launch: TrailerLaunch
    let onClose: () -> Void
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let embed = launch.embedURL, !failed {
                YouTubeWebView(url: embed, onFailure: { failed = true })
                    .ignoresSafeArea()
            } else {
                fallback
            }

            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.md)
                Spacer()
            }
        }
    }

    /// Shown when the embed can't load (e.g. an embedding-disabled video): a clear hand-off to the
    /// YouTube app / browser so the user can still watch the trailer.
    private var fallback: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 44)).foregroundStyle(.white.opacity(0.85))
            Text("Trailer can't play here")
                .font(Theme.Typography.cardTitle).foregroundStyle(.white)
            Text("This trailer doesn't allow embedded playback. Open it in YouTube instead.")
                .font(Theme.Typography.body).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            if let watch = launch.watchURL {
                Button {
                    TrailerOpener.open(watch)
                    onClose()
                } label: {
                    Label("Open in YouTube", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(PrimaryActionStyle())
            }
        }
        .padding(Theme.Space.lg)
    }
}

/// Minimal cross-platform `WKWebView` host that loads a single URL and reports a hard load failure
/// so the screen can fall back to the system browser. `WKWebView` exists on both UIKit and AppKit,
/// so this is `UIViewRepresentable` on iOS and `NSViewRepresentable` on macOS.
#if canImport(UIKit)
import UIKit
struct YouTubeWebView: UIViewRepresentable {
    let url: URL
    var onFailure: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = Self.makeConfiguredWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onFailure: () -> Void
        init(onFailure: @escaping () -> Void) { self.onFailure = onFailure }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure() }
    }

    private static func makeConfiguredWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []   // honor autoplay=1
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        return webView
    }
}
#elseif canImport(AppKit)
import AppKit
struct YouTubeWebView: NSViewRepresentable {
    let url: URL
    var onFailure: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []   // honor autoplay=1
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")     // transparent over the black canvas
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onFailure: () -> Void
        init(onFailure: @escaping () -> Void) { self.onFailure = onFailure }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure() }
    }
}
#endif

/// Muted, looping, controls-less `WKWebView` host for the Netflix-style autoplay layer that plays
/// behind the featured hero art. It is a sibling of `YouTubeWebView` (kept separate so the
/// full-screen Trailer chip path stays untouched) with two differences that the graceful-fallback
/// logic relies on:
///   • `onStarted` fires on the first committed navigation, so the hero can distinguish "the embed
///     began loading" from "it never started" (the timeout case).
///   • `onFailure` fires on a hard navigation error, so the hero can remove the layer silently and
///     keep the still backdrop.
/// The view never shows its own chrome or fallback UI — on any failure the *hero* simply drops the
/// layer back to the still backdrop, so a broken player can never be visible.
#if canImport(UIKit)
struct AutoplayTrailerWebView: UIViewRepresentable {
    let url: URL
    var onStarted: () -> Void = {}
    var onFailure: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onStarted: onStarted, onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = Self.makeConfiguredWebView()
        webView.navigationDelegate = context.coordinator
        webView.isUserInteractionEnabled = false   // belt-and-braces; the hero also disables hit testing
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onStarted: () -> Void
        let onFailure: () -> Void
        init(onStarted: @escaping () -> Void, onFailure: @escaping () -> Void) {
            self.onStarted = onStarted; self.onFailure = onFailure
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { onStarted() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure() }
    }

    private static func makeConfiguredWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []   // honor autoplay=1 + mute=1
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }
}
#elseif canImport(AppKit)
struct AutoplayTrailerWebView: NSViewRepresentable {
    let url: URL
    var onStarted: () -> Void = {}
    var onFailure: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onStarted: onStarted, onFailure: onFailure) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []   // honor autoplay=1 + mute=1
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")     // transparent over the hero art
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onStarted: () -> Void
        let onFailure: () -> Void
        init(onStarted: @escaping () -> Void, onFailure: @escaping () -> Void) {
            self.onStarted = onStarted; self.onFailure = onFailure
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { onStarted() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure() }
    }
}
#endif

/// System-browser / app hand-off for the trailer fallback, the cross-platform twin of ExternalPlayer's
/// open helper (UIApplication on iOS, NSWorkspace on macOS).
enum TrailerOpener {
    @MainActor static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
