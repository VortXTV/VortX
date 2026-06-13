import SwiftUI

/// Native iPhone / iPad entry point. Boots the SAME stremio-core engine + embedded server as the
/// Apple TV app (no web host), then hands off to the native SwiftUI UI. Mirrors StremioTVApp's
/// engine/server/profile wiring; the UI layer (SourcesiOS) is touch-native instead of focus-driven.
///
/// 0.3.0 Track 1, built incrementally: this scaffold proves the shared engine layer compiles and
/// the Rust⇄Swift FFI links on iOS (the schema-version log is the smoke check). Screens land one
/// by one on top of this shell.
@main
struct StremioXiOSApp: App {
    @StateObject private var account = StremioAccount()
    @StateObject private var core = CoreBridge.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if !STREMIOX_NO_EMBEDDED_SERVER
        if !PlaybackSettings.torrentsDisabled,
           !ProcessInfo.processInfo.arguments.contains("-stremiox-no-server") {
            NodeServer.startIfNeeded()
            Task.detached(priority: .utility) { await StremioServer.applyServerConfig() }
        }
        #endif
        CoreBridge.shared.start()
        NSLog("[StremioX-iOS] stremio-core schema version = \(CoreBridge.shared.schemaVersion)")
    }

    var body: some Scene {
        WindowGroup {
            iOSRootView()
                .environmentObject(account)
                .environmentObject(core)
                .environmentObject(ThemeManager.shared)
                .environmentObject(ProfileStore.shared)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { phase in   // iOS 16 single-parameter form
                    if phase == .active { UpdateChecker.shared.checkIfStale() }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        ProfileStore.shared.bootstrapSync()
                    }
                }
        }
    }
}
