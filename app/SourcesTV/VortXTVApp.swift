import SwiftUI

@main
struct VortXTVApp: App {
    @StateObject private var account = StremioAccount()
    @StateObject private var core = CoreBridge.shared
    @StateObject private var sync = VortXSyncManager.shared
    @StateObject private var presenter = PlayerPresenter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Self-capture crashes into the exportable diagnostic log FIRST, before anything else can fault.
        // A sideloaded Apple TV cannot hand its .ips reports to the owner, so the app writes its own: a
        // crash records a marker, the next launch folds it into the exportable log. See VortXCrashReporter.
        VortXCrashReporter.install()
        // Offline mode (#120): start the process-wide connectivity monitor before the shell mounts, so
        // its FIRST verdict (launchOffline) is ready to land an offline launch on the Library tab (where
        // Downloads live) and the shell's "You're offline" chip tracks the live (debounced) state.
        ConnectivityMonitor.shared.start()
        // Bring DownloadManager up at launch so its "auto-delete watched downloads" subscription (it
        // observes WatchedIndex and prunes finished downloads when the opt-in setting is ON) is live from
        // the start on tvOS. Without touching the singleton here, nothing on tvOS instantiates it at launch,
        // so the subscription would only arm once a Downloads screen happened to be opened.
        _ = DownloadManager.shared
        // Embed Stremio's streaming server on :11470 (nodejs-mobile retargeted to tvOS), so
        // torrent / non-web-ready streams the server must fetch & remux can play on Apple TV.
        // On by default; -stremiox-no-server disables it for isolation testing.
        #if !VORTX_NO_EMBEDDED_SERVER
        if !PlaybackSettings.torrentsDisabled,
           !ProcessInfo.processInfo.arguments.contains("-stremiox-no-server") {
            NodeServer.startIfNeeded()
            // Once the server is up, cap its torrent cache to a TV-safe size (the 2 GB default
            // can get the whole app jetsam-killed mid-torrent). Detached so it never blocks launch.
            Task.detached(priority: .utility) { await StremioServer.applyServerConfig() }
        }
        #endif
        // Install the dedicated, large image URLCache BEFORE any poster loads (parity with iOS/Mac). The
        // default shared cache cannot hold a catalog page of posters, so posters re-fetch on every scroll.
        PosterImageLoader.configureSharedCache()
        // Safety sweep: clear any leftover libmpv on-disk streaming cache from a previous run. The
        // player wipes it on a genuine exit, but a crash mid-playback could leave bytes behind — this
        // guarantees a fresh, bounded start so the configurable cache can never accumulate unbounded.
        // Detached so the directory scan + delete (multi-GB after a crash) never blocks launch.
        Task.detached(priority: .utility) { DiskCacheSetting.clearCache() }
        // Boot the native stremio-core engine (hydrates library/profile from storage, starts the
        // event loop). The schema-version log is an end-to-end smoke check of the Rust⇄Swift FFI.
        CoreBridge.shared.start()
        NSLog("%@", "[StremioX] stremio-core schema version = \(CoreBridge.shared.schemaVersion)")
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
            .environmentObject(VortXSyncManager.shared)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                // Distinguishes "the system suspended us" (an unhandled menu press)
                // from "we crashed" when a device report says the app vanished.
                DiagnosticsLog.log("app", "scenePhase → \(String(describing: phase))")
                if phase == .active {
                    UpdateChecker.shared.checkIfStale()
                    #if !VORTX_NO_EMBEDDED_SERVER
                    // #130: after a suspension (Home, app switch, screensaver exit) tvOS can tear down the
                    // server's bound listener while node keeps ticking, so the server reads Offline until a
                    // manual restart. recoverIfSuspended subsumes the old drift-latch probe (isOnline) and,
                    // on a CONNECTION-REFUSED result while the process is alive, signals the in-node rebind.
                    // A timeout is left alone (busy-but-alive), so it never touches a mid-stream listener.
                    Task.detached(priority: .utility) { await NodeServer.recoverIfSuspended() }
                    #endif
                    Task {
                        await VortXSyncManager.shared.syncDown()      // pull other devices' changes on foreground
                        // Account-owns-everything: if the engine is degraded (no stream add-on), hydrate the
                        // VortX account's owned add-ons + library so the lists never read zero on foreground.
                        // Idempotent + never-zero guarded inside the sync manager.
                        if CoreBridge.shared.hasNoUserStreamAddon {
                            await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                        }
                        VortXSyncManager.shared.requestSyncSoon()     // then push THIS device's state (incl. the library + add-ons mirror) so the web dashboard repopulates on open
                    }
                    VortXSyncManager.shared.startRealtime()   // SyncRoom WebSocket + while-active poll (real-time pull)
                    // The top tab bar can desync (park offscreen) across a background/foreground cycle,
                    // the same "vanishing tab bar" the player-close heal fixes. Re-assert it on return so
                    // the menu never stays gone after the Home button (issue #75). Two shots: the desync
                    // can surface only after the first layout settles.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { TabBarHealer.heal("foreground") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { TabBarHealer.heal("foreground+1.5s") }
                }
                if phase == .background {
                    VortXSyncManager.shared.stopRealtime()   // drop the socket + poll while suspended
                    // push profiles + settings under a background-task grace window so a just-made library
                    // removal / rewind survives a sideload-update process kill (CW resurrection fix).
                    VortXSyncManager.shared.syncUpOnBackground()
                }
            }
            .onChange(of: sync.isSignedIn) { _, signedIn in
                // A VortX sign-in from ANY entry point (password sheet, QR joiner) must restore add-ons +
                // owner library WITHOUT waiting for a background/foreground cycle: adopt() hydrates at the
                // sign-in chokepoint, and this root-level hook re-runs the degraded-engine check once the
                // signed-in flag flips, catching an adopt-time pass that raced the engine still booting.
                // Never-zero guarded inside the manager (a .failed/.empty pull does nothing; install-only
                // union; library recovery only when the engine POSITIVELY reports an empty account library).
                guard signedIn else { return }
                Task {
                    if CoreBridge.shared.hasNoUserStreamAddon {
                        await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                    }
                }
            }
            .onAppear {
                // Cold-launch pull: on a fresh process the initial scenePhase == .active does NOT fire
                // .onChange(of: scenePhase), so nothing opens the sync channel on launch. On Apple TV the
                // first real foreground transition is the screensaver dismissal (minutes away), so a reinstall
                // would sit on the un-hydrated default "Main" profile until then. Open the channel now so a
                // Keychain-restored session pulls the account's real profile immediately. Idempotent (guards
                // isSignedIn + !realtimeActive) and it already performs an immediate syncDown().
                VortXSyncManager.shared.startRealtime()
                // Profile housekeeping (the library repair scan + sync probe) is background work;
                // delay it so it never competes with the engine boot and the node server's
                // cold start for the first seconds on device.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    ProfileStore.shared.bootstrapSync()
                }
                // Account-owns-everything launch wiring (additive, fail-soft): hydrate the engine from the
                // VortX account's owned add-ons when it boots degraded (no stream add-on) so a logged-out /
                // post-update Apple TV never shows zero, and snapshot-on-import ONCE on an already-synced
                // device that has add-ons but never anchored ownership (addonsOwnedAt unset). Both no-op
                // when signed out / unreachable (never-zero guarded inside the manager).
                Task { @MainActor in
                    if CoreBridge.shared.hasNoUserStreamAddon {
                        await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                    }
                    if !CoreBridge.shared.addons.isEmpty,
                       await VortXSyncManager.shared.ownedAddonsNeverSnapshotted() {
                        await VortXSyncManager.shared.snapshotOwnedFromEngine()
                    }
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
