#if CINEMA_UI_SMOKE_RENDERER && os(iOS)
import SwiftUI

/// Test-only iPhone/iPad entry point. The regular `VortXiOSApp` is excluded by the same compilation
/// condition, so this scene never initializes CoreBridge, an account, node/engine server, a player, or
/// the installed VortX bundle. `CinemaUISmokeFixtureRoot` supplies static presentation inputs only.
@main
@MainActor
struct CinemaUISmokeIOSRendererApp: App {
    private let surface = CinemaUISmokeSurface.requestedFromEnvironment

    var body: some Scene {
        WindowGroup {
            GeometryReader { proxy in
                CinemaUISmokeFixtureRoot(
                    name: "Native iOS",
                    width: max(1, proxy.size.width),
                    height: max(1, proxy.size.height),
                    surface: surface
                )
            }
            .ignoresSafeArea()
        }
    }
}
#endif
