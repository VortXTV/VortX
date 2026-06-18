import SwiftUI
#if os(iOS)
import UIKit
#endif

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
    /// Launch splash gate (the brand pinwheel animation), matching Apple TV. Cleared when it finishes;
    /// it covers the engine + embedded-server boot moment on iPhone, iPad, and Mac too.
    @State private var splashDone = false

    // macOS only: the embedded streaming server runs as a `node` CHILD PROCESS (MacNodeServer),
    // and Foundation does NOT kill that child when the app quits — it would be reparented to
    // launchd and keep holding port 11470, accumulating orphans across launches. An app-delegate
    // gives us the one reliable "the app is really quitting" hook (applicationWillTerminate),
    // which scenePhase .background/.inactive does NOT provide on macOS — those fire on ordinary
    // window/focus changes, so killing the server there would wrongly stop it mid-use.
    #if os(macOS) && !STREMIOX_NO_EMBEDDED_SERVER
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    // iOS / iPadOS: an app delegate that reports the current allowed-orientation mask, so the player can
    // force landscape (rotating even when the user has rotation lock on) and the rest of the app rotates
    // freely again on exit. See OrientationAppDelegate / PlayerOrientation at the bottom of this file.
    #if os(iOS)
    @UIApplicationDelegateAdaptor(OrientationAppDelegate.self) private var orientationDelegate
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
                .onChange(of: scenePhase) { phase in   // iOS 16 single-parameter form
                    if phase == .active {
                        UpdateChecker.shared.checkIfStale()
                        Task { await VortXSyncManager.shared.syncDown() }   // pull other devices' changes on foreground
                    }
                    if phase == .background { Task { await VortXSyncManager.shared.syncUp() } }   // push profiles + settings
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        ProfileStore.shared.bootstrapSync()
                    }
                    if core.library == nil { core.loadLibrary() }   // so the F5 sweep below has data to work with
                }
                .task(id: core.library?.catalog.count ?? 0) {
                    // F5 library-wide sweep: once the library is loaded, schedule the next-episode alert for
                    // EVERY series in it, not just the ones the user opens (alerts are on by default). Re-runs
                    // when the library count changes; each series holds a single pending request, so the whole
                    // sweep stays under iOS's 64 pending-notification cap.
                    let series = (core.library?.catalog ?? []).filter { $0.type == "series" }
                    guard NewEpisodeNotifications.isEnabled, !series.isEmpty else { return }
                    let names = Dictionary(series.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                    let bases = account.addons.filter { $0.providesMeta }.map(\.baseUrl)
                    await NewEpisodeNotifications.sweepLibrary(seriesIDs: series.map(\.id), seriesNames: names, metaBases: bases)
                }
                // macOS: present the player full-window at the scene ROOT (above the dimmed app), not as a
                // separate floating window. The overlay is applied HERE — INSIDE the environmentObjects
                // below — so those objects wrap the overlay's ZStack and the hoisted player (a sibling of
                // the root content, fed through MacPlayerHost) inherits CoreBridge / StremioAccount /
                // ThemeManager. Injecting them deeper than the overlay crashed the player the instant it
                // launched: the hoisted AnyView read an @EnvironmentObject that was not one of its
                // ancestors, so SwiftUI hit EnvironmentObject.error() (a fatal assertion, SIGTRAP). See
                // MacRootPlayerOverlay / MacPlayerHost in PlatformModifiers.
                #if os(macOS)
                .modifier(MacRootPlayerOverlay())
                #endif
                // Brand launch splash on top of everything (incl. the macOS player overlay) until its
                // animation finishes — the iPhone/iPad/Mac twin of the tvOS RootTabView splash.
                .overlay {
                    if !splashDone {
                        SplashView { splashDone = true }
                            .ignoresSafeArea()
                            .zIndex(100)
                    }
                }
                .environmentObject(account)
                .environmentObject(core)
                .environmentObject(ThemeManager.shared)
                .environmentObject(ProfileStore.shared)
                .environmentObject(VortXSyncManager.shared)
                .preferredColorScheme(.dark)
                // Tint the whole scene so system chrome inside separately-presented sheets (SignIn /
                // OpenLink) and the ProfileEditor cover renders the app accent, not system blue.
                .tint(Theme.Palette.accent)
                // Without a min frame the macOS WindowGroup adopts the root's tiny intrinsic size and
                // opens as a postage-stamp window; pin a sensible minimum so it can't collapse. (iOS /
                // iPadOS ignore this — their windows are managed by the system, not content size.)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
        }
        // macOS opens the window at a real default size (the deployment target is macOS 14, so
        // .defaultSize / .windowResizability — macOS 13+ — are available), and .contentMinSize lets
        // the user shrink it only down to the root's min frame above, never to nothing.
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            // Single-window media app: the document-style File ▸ New does nothing here, so drop it.
            CommandGroup(replacing: .newItem) { }
            // Conventional macOS Preferences slot (app menu, ⌘,) → the Settings tab.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { MacCommands.go(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateChecker.shared.checkIfStale(maxAge: 0) }
            }
            // Tab navigation, the menu-bar twin of the bottom tab bar (commands live at the Scene
            // level, so they post to MacCommands and iOSRootView maps it to its tab selection).
            CommandMenu("Go") {
                Button("Home")     { MacCommands.go(.home) }.keyboardShortcut("1", modifiers: .command)
                Button("Discover") { MacCommands.go(.discover) }.keyboardShortcut("2", modifiers: .command)
                Button("Live TV")  { MacCommands.go(.live) }.keyboardShortcut("3", modifiers: .command)
                Button("Library")  { MacCommands.go(.library) }.keyboardShortcut("4", modifiers: .command)
                Button("Add-ons")  { MacCommands.go(.addons) }.keyboardShortcut("5", modifiers: .command)
                Divider()
                Button("Search")   { MacCommands.go(.search) }.keyboardShortcut("f", modifiers: .command)
            }
        }
        #endif
    }
}

/// macOS menu-bar command bridge. The menu commands live at the SwiftUI `Scene` level, outside the
/// view tree, so they cannot touch iOSRootView's `@State tab` directly — they post a notification the
/// root view observes and maps to its tab selection. Tiny and platform-neutral so it compiles on every
/// SourcesiOS target even though only macOS builds a menu bar.
enum MacCommands {
    /// Posted with a `tab` userInfo `Int` matching `iOSRootView.Tab.rawValue`.
    static let tabRequest = Notification.Name("stremiox.macCommands.tabRequest")

    /// Menu destinations. Raw values MUST mirror iOSRootView.Tab's order
    /// (home, discover, live, library, search, addons, settings).
    enum Destination: Int { case home, discover, live, library, search, addons, settings }

    static func go(_ destination: Destination) {
        NotificationCenter.default.post(name: tabRequest, object: nil, userInfo: ["tab": destination.rawValue])
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

#if os(iOS)
/// Reports the app's currently-allowed interface orientations to UIKit. The player flips `lock` to
/// landscape while it is open, so the video rotates to landscape even when the user has rotation lock on,
/// then back to `.all` on exit so the rest of the app rotates per the user's preference again.
final class OrientationAppDelegate: NSObject, UIApplicationDelegate {
    static var lock: UIInterfaceOrientationMask = .allButUpsideDown
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.lock
    }
}

/// Force / release landscape for the player on iPhone and iPad. `requestGeometryUpdate` actually rotates
/// the window and overrides the user's rotation lock for the orientations we report as supported, so a
/// stream opens landscape even when the device is locked to portrait. No-op outside iOS.
enum PlayerOrientation {
    /// AppStorage flag (default on): users who prefer the player to follow rotation lock can turn it off.
    static let autoLandscapeKey = "stremiox.autoLandscapeInPlayer"
    static var autoLandscapeEnabled: Bool {
        UserDefaults.standard.object(forKey: autoLandscapeKey) == nil ? true : UserDefaults.standard.bool(forKey: autoLandscapeKey)
    }

    @MainActor static func forceLandscape() {
        guard autoLandscapeEnabled else { return }
        OrientationAppDelegate.lock = .landscape
        guard let scene = activeScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    @MainActor static func release() {
        OrientationAppDelegate.lock = .allButUpsideDown
        activeScene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    @MainActor private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
    }
}
#endif
