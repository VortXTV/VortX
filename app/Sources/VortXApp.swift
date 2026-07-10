import SwiftUI

@main
struct StremioXApp: App {
    init() {
        // Gated diagnostic logging: starts the once-a-second heartbeat only when VORTX_PROBE=1 or the
        // Settings toggle is on, then narrates the boot. No-op (and no cost) otherwise.
        VXProbeHeartbeat.start()
        VXProbe.log("boot", "VortX launched probe=\(VXProbe.enabled)")
        #if os(iOS)
        // Embed Stremio's streaming server (server.js on :11470) like the official app, so
        // torrent / non-web-ready streams the server must fetch & remux can play. Direct debrid
        // streams play without it (native libmpv + UA), but the server is needed for full parity.
        // On by default; -stremiox-no-server disables it for isolation testing.
        if !PlaybackSettings.torrentsDisabled,
           !ProcessInfo.processInfo.arguments.contains("-stremiox-no-server") {
            NodeServer.startIfNeeded()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
