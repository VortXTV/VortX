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

    // macOS only: the embedded streaming server runs as a `node` CHILD PROCESS (MacNodeServer),
    // and Foundation does NOT kill that child when the app quits — it would be reparented to
    // launchd and keep holding port 11470, accumulating orphans across launches. An app-delegate
    // gives us the one reliable "the app is really quitting" hook (applicationWillTerminate),
    // which scenePhase .background/.inactive does NOT provide on macOS — those fire on ordinary
    // window/focus changes, so killing the server there would wrongly stop it mid-use.
    #if os(macOS) && !STREMIOX_NO_EMBEDDED_SERVER
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

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
                // Without a min frame the macOS WindowGroup adopts the root's tiny intrinsic size and
                // opens as a postage-stamp window; pin a sensible minimum so it can't collapse. (iOS /
                // iPadOS ignore this — their windows are managed by the system, not content size.)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
                .onChange(of: scenePhase) { phase in   // iOS 16 single-parameter form
                    if phase == .active { UpdateChecker.shared.checkIfStale() }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        ProfileStore.shared.bootstrapSync()
                    }
                }
        }
        // macOS opens the window at a real default size (the deployment target is macOS 14, so
        // .defaultSize / .windowResizability — macOS 13+ — are available), and .contentMinSize lets
        // the user shrink it only down to the root's min frame above, never to nothing.
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        #endif
    }
}

#if os(macOS) && !STREMIOX_NO_EMBEDDED_SERVER
import AppKit

/// macOS app delegate whose sole job is to kill the embedded node streaming server when the app
/// actually quits. `applicationWillTerminate(_:)` is the reliable "app is exiting" signal on macOS
/// (Cmd-Q, menu Quit, logout/shutdown) — unlike scenePhase `.background`/`.inactive`, which fire on
/// routine window/focus changes and must NOT tear the server down. Without this the `node` child is
/// reparented to launchd and keeps holding port 11470 (the orphaned-process leak this fixes).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        NodeServer.stop()
    }

    /// Closing the only window must QUIT the app (a single-window media app, not a document app).
    /// Without this, the red close button / Cmd-W left the app running headless with the node server
    /// still holding port 11470 and no way to get the window back — and applicationWillTerminate above
    /// never fired, so the server was only reaped on an explicit Quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
