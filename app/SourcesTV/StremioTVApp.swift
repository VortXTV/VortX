import SwiftUI

@main
struct StremioTVApp: App {
    @StateObject private var account = StremioAccount()
    @StateObject private var core = CoreBridge.shared
    @StateObject private var presenter = PlayerPresenter()

    init() {
        // Embed Stremio's streaming server on :11470 (nodejs-mobile retargeted to tvOS), so
        // torrent / non-web-ready streams the server must fetch & remux can play on Apple TV.
        // On by default; -stremiox-no-server disables it for isolation testing.
        if !ProcessInfo.processInfo.arguments.contains("-stremiox-no-server") {
            NodeServer.startIfNeeded()
        }
        // Boot the native stremio-core engine (hydrates library/profile from storage, starts the
        // event loop). The schema-version log is an end-to-end smoke check of the Rust⇄Swift FFI.
        CoreBridge.shared.start()
        NSLog("[StremioX] stremio-core schema version = \(CoreBridge.shared.schemaVersion)")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("-tv-selftest") {
                    TVPlayerView(url: URL(string: "https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4")!, title: "Player Test, Oceans")
                } else {
                    RootView()   // player OR shell, never both — the only reliable tvOS focus isolation
                }
            }
            .environmentObject(account)
            .environmentObject(core)
            .environmentObject(presenter)
            .preferredColorScheme(.dark)
            .onAppear {
                // DIAGNOSTIC (-tv-playertest): exercise the real root-replacement path without an account.
                guard ProcessInfo.processInfo.arguments.contains("-tv-playertest") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    presenter.request = PlaybackRequest(
                        url: URL(string: "https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4")!, title: "Player Test")
                }
            }
        }
    }
}
