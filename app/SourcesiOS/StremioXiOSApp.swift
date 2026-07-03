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
        // Safety sweep: clear any leftover libmpv on-disk streaming cache from a previous run. The
        // player wipes it on a genuine exit, but a crash mid-playback could leave bytes behind — this
        // guarantees a fresh, bounded start so the configurable cache can never accumulate unbounded.
        DiskCacheSetting.clearCache()
        CoreBridge.shared.start()
        NSLog("[StremioX-iOS] stremio-core schema version = \(CoreBridge.shared.schemaVersion)")
    }

    var body: some Scene {
        WindowGroup {
            iOSRootView()
                .onChange(of: scenePhase) { phase in   // iOS 16 single-parameter form
                    if phase == .active {
                        UpdateChecker.shared.checkIfStale()
                        Task {
                            await VortXSyncManager.shared.syncDown()      // pull other devices' changes on foreground
                            // Account-owns-everything: if the engine is degraded (no stream add-on),
                            // hydrate the VortX account's owned add-ons + library so the lists never read
                            // zero on foreground. Idempotent + never-zero guarded inside the sync manager.
                            if CoreBridge.shared.hasNoUserStreamAddon {
                                await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                            }
                            VortXSyncManager.shared.requestSyncSoon()     // then push THIS device's state (incl. the library + add-ons mirror) so the web dashboard repopulates on open, not only on background
                        }
                        VortXSyncManager.shared.startRealtime()   // SyncRoom WebSocket + while-active poll (real-time pull)
                    }
                    if phase == .background {
                        VortXSyncManager.shared.stopRealtime()   // drop the socket + poll while suspended
                        Task { await VortXSyncManager.shared.syncUp() }   // push profiles + settings
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        ProfileStore.shared.bootstrapSync()
                    }
                    // Reconnect any offline download still running from a previous launch: a background
                    // AVAssetDownloadURLSession / .background byte session keeps its tasks alive after the
                    // app is killed, but the new process has empty task<->record maps, so pause/cancel would
                    // silently no-op until we re-adopt them. Idempotent + fail-soft; a no-op when there are
                    // no in-flight downloads. (The background-relaunch path also calls this via
                    // adoptBackgroundEvents, but that only fires when iOS wakes us to deliver FINISHED events,
                    // not on an ordinary user-tapped launch.)
                    DownloadManager.shared.reconnectInFlightDownloads()
                    if core.library == nil { core.loadLibrary() }   // so the F5 sweep below has data to work with
                    // Account-owns-everything launch wiring (additive, fail-soft):
                    //  - hydrate the engine from the VortX account's owned add-ons when it boots degraded
                    //    (no stream add-on), so a logged-out / post-update device never shows zero;
                    //  - snapshot-on-import ONCE on an already-synced device that has add-ons but has never
                    //    anchored ownership (addonsOwnedAt unset), so existing users get auto-migrated.
                    // Both are no-ops when signed out / unreachable (never-zero guarded inside the manager).
                    Task { @MainActor in
                        if CoreBridge.shared.hasNoUserStreamAddon {
                            await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                        }
                        if !CoreBridge.shared.addons.isEmpty,
                           await VortXSyncManager.shared.ownedAddonsNeverSnapshotted() {
                            await VortXSyncManager.shared.snapshotOwnedFromEngine()
                        }
                    }
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
                // Resolve the single shared NSToolbar as hidden so updateLocations has nothing to
                // insert into. Combined with .windowStyle(.hiddenTitleBar) below this removes the
                // toolbar OBJECT the NSToolbar-insert crash requires, not just each item source.
                .toolbar(.hidden, for: .windowToolbar)
                // Traffic lights: hiddenTitleBar + the hidden window toolbar can leave the close /
                // minimize / zoom buttons hidden with the collapsed titlebar host. This accessor keeps
                // `.titled` in the styleMask and explicitly unhides the three standard buttons (and
                // their container) so they float over the top-left of the full-size content, with NO
                // NSToolbar ever attached.
                .background(MacWindowChrome())
                #endif
        }
        // macOS opens the window at a real default size (the deployment target is macOS 14, so
        // .defaultSize / .windowResizability — macOS 13+ — are available), and .contentMinSize lets
        // the user shrink it only down to the root's min frame above, never to nothing.
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        // `.hiddenTitleBar` is LOAD-BEARING for the NSToolbar crash: AppKit never stands up the
        // titlebar/toolbar host at window creation, so `_insertNewItemWithItemIdentifier` has nothing
        // to insert into even when SwiftUI's toolbar bridge (e.g. a NavigationStack back button across
        // the seven simultaneously-mounted stacks) publishes items. Build 145 switched this to
        // `.titleBar` to restore the traffic lights and the crash came straight back; the buttons are
        // instead restored by MacWindowChrome below, which keeps `.titled` in the styleMask and unhides
        // the standard window buttons over the full-size content. Never switch back to `.titleBar`.
        .windowStyle(.hiddenTitleBar)
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

#if os(macOS)
import AppKit

/// Hands a query typed in the persistent macOS top bar (iOSRootView.macTopBar) to whichever screen
/// hosts the engine search (the Search tab, or Discover in merged mode). A `@Published` value, not a
/// notification, because the target screen may be LAZILY mounted on its first visit: the mount happens
/// a render after the tab switch, and `onReceive` of a published value still delivers the pending query
/// to the newly-mounted screen, where a notification posted pre-mount would be lost.
@MainActor
final class MacSearchBridge: ObservableObject {
    static let shared = MacSearchBridge()
    private init() {}
    /// The query awaiting consumption; the consuming screen runs it and resets this to nil.
    @Published var pending: String?
}

/// Restores the traffic-light buttons on the `.hiddenTitleBar` window. The hiddenTitleBar style (plus
/// the hidden window toolbar) is what keeps the NSToolbar-insert crash dead, but it can leave the
/// close/minimize/zoom buttons hidden along with the collapsed titlebar host, the owner's "no window
/// buttons" report. This keeps `.titled` in the styleMask and unhides the three standard buttons (and
/// their container view) so they float over the full-size content, without ever attaching an NSToolbar.
private struct MacWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window isn't attached yet; defer one runloop turn to find + configure it.
        DispatchQueue.main.async { [weak view, coordinator = context.coordinator] in
            coordinator.attach(to: view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-assert on SwiftUI passes so a late chrome update (player overlay up/down, scene phase
        // churn) can never leave the buttons hidden again.
        DispatchQueue.main.async { [weak nsView, coordinator = context.coordinator] in
            coordinator.attach(to: nsView?.window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// One-shot asyncs lose the race: SwiftUI's toolbar bridge re-collapses the titlebar host on later
    /// preference passes (every NavigationStack push), so the buttons vanished again after the initial
    /// unhide. The coordinator owns a long-lived `didUpdate` observer that re-asserts with a cheap
    /// early-exit, so any re-hide self-heals within one window update cycle.
    final class Coordinator {
        private var observed: NSWindow?
        private var token: NSObjectProtocol?

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            Self.apply(to: window)
            Self.probe(window)
            guard observed !== window else { return }
            if let token { NotificationCenter.default.removeObserver(token) }
            observed = window
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { note in
                Self.apply(to: note.object as? NSWindow)
            }
            // Belt and braces for the first seconds while SwiftUI settles its toolbar/titlebar state.
            for delay in [0.2, 1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    Self.apply(to: window)
                    Self.probe(window)
                }
            }
        }

        /// Temporary field diagnostic for the owner's "no traffic lights" report: dumps the true AppKit
        /// state of the three standard buttons + their titlebar chain to the unified log.
        private static func probe(_ window: NSWindow?) {
            guard let window else { return }
            var lines = ["styleMask=\(window.styleMask.rawValue) titleVis=\(window.titleVisibility.rawValue) transparent=\(window.titlebarAppearsTransparent)"]
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                guard let b = window.standardWindowButton(kind) else {
                    lines.append("btn \(kind.rawValue): NIL"); continue
                }
                var chain = "btn \(kind.rawValue): hidden=\(b.isHidden) alpha=\(b.alphaValue) frame=\(NSStringFromRect(b.frame))"
                var v: NSView? = b.superview
                var depth = 0
                while let s = v, depth < 3 {
                    chain += " | sup\(depth)[\(type(of: s))] hidden=\(s.isHidden) alpha=\(s.alphaValue) frame=\(NSStringFromRect(s.frame))"
                    v = s.superview; depth += 1
                }
                lines.append(chain)
            }
            NSLog("[macchrome] %@", lines.joined(separator: "\n"))
        }

        private static func apply(to window: NSWindow?) {
            guard let window else { return }
            // Cheap early-exit so the didUpdate observer costs nothing once the chrome is right.
            if let close = window.standardWindowButton(.closeButton),
               !close.isHidden, close.alphaValue >= 1,
               close.superview?.isHidden == false, (close.superview?.alphaValue ?? 0) >= 1,
               close.superview?.superview?.isHidden == false,
               (close.superview?.superview?.alphaValue ?? 0) >= 1,
               window.styleMask.contains(.titled) { return }
            // Guarded union: reassigning styleMask when nothing is missing once collapsed the window to
            // its minimum size (see MacPlayerChromeHider's note), so only touch it when a flag is absent.
            let needed: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            if !window.styleMask.isSuperset(of: needed) { window.styleMask.formUnion(needed) }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind) else { continue }
                button.isHidden = false
                // Unhide the WHOLE titlebar chain: NSTitlebarView and NSTitlebarContainerView can each
                // be the hidden/collapsed node when the window toolbar resolves hidden. A zero-height
                // container never draws either, so give a collapsed node a real titlebar height back.
                var node: NSView? = button.superview
                while let v = node, v !== window.contentView?.superview {
                    v.isHidden = false
                    // SwiftUI's hidden-toolbar resolution FADES NSTitlebarContainerView to alpha 0
                    // rather than hiding it (field-verified: hidden=false, alpha=0.0) — restore alpha
                    // or the unhidden buttons still never draw.
                    if v.alphaValue < 1 { v.alphaValue = 1 }
                    if v.frame.height < 1 {
                        var f = v.frame
                        f.size.height = 28
                        v.frame = f
                    }
                    node = v.superview
                }
            }
        }
    }
}
#endif

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

    /// iOS relaunches the app in the background to deliver finished background downloads, handing us a
    /// completion handler we must call once the session drains. Stash it on DownloadManager (touching
    /// `.shared` also re-creates the background URLSession + re-attaches its delegate, so the queued
    /// `didFinishDownloadingTo` events actually fire and the saved file lands). Without this the download
    /// that finished while suspended never moved its temp file -> the owner's "cannot create file" / 0-byte
    /// save. We only adopt OUR session id; anything else is completed immediately so iOS isn't left waiting.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == "tv.vortx.downloads.background" else { completionHandler(); return }
        Task { @MainActor in
            DownloadManager.shared.adoptBackgroundEvents(completionHandler: completionHandler)
        }
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
