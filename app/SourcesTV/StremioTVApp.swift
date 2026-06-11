import SwiftUI

@main
struct StremioTVApp: App {
    @StateObject private var account = StremioAccount()
    @StateObject private var core = CoreBridge.shared
    @StateObject private var presenter = PlayerPresenter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Embed Stremio's streaming server on :11470 (nodejs-mobile retargeted to tvOS), so
        // torrent / non-web-ready streams the server must fetch & remux can play on Apple TV.
        // On by default; -stremiox-no-server disables it for isolation testing.
        #if !STREMIOX_NO_EMBEDDED_SERVER
        if !PlaybackSettings.torrentsDisabled,
           !ProcessInfo.processInfo.arguments.contains("-stremiox-no-server") {
            NodeServer.startIfNeeded()
            // Once the server is up, cap its torrent cache to a TV-safe size (the 2 GB default
            // can get the whole app jetsam-killed mid-torrent). Detached so it never blocks launch.
            Task.detached(priority: .utility) { await StremioServer.applyServerConfig() }
        }
        #endif
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
                    RootView()   // player OR shell, never both, the only reliable tvOS focus isolation
                }
            }
            .environmentObject(account)
            .environmentObject(core)
            .environmentObject(presenter)
            .environmentObject(ThemeManager.shared)
            .environmentObject(ProfileStore.shared)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                // Distinguishes "the system suspended us" (an unhandled menu press)
                // from "we crashed" when a device report says the app vanished.
                DiagnosticsLog.log("app", "scenePhase → \(String(describing: phase))")
                if phase == .active { UpdateChecker.shared.checkIfStale() }
            }
            .onAppear {
                // Profile housekeeping (the library repair scan + sync probe) is background work;
                // delay it so it never competes with the engine boot and the node server's
                // cold start for the first seconds on device.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    ProfileStore.shared.bootstrapSync()
                }
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
