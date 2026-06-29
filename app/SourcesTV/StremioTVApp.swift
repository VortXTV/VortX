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
        // Safety sweep: clear any leftover libmpv on-disk streaming cache from a previous run. The
        // player wipes it on a genuine exit, but a crash mid-playback could leave bytes behind — this
        // guarantees a fresh, bounded start so the configurable cache can never accumulate unbounded.
        DiskCacheSetting.clearCache()
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
            .environmentObject(VortXSyncManager.shared)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                // Distinguishes "the system suspended us" (an unhandled menu press)
                // from "we crashed" when a device report says the app vanished.
                DiagnosticsLog.log("app", "scenePhase → \(String(describing: phase))")
                if phase == .active {
                    UpdateChecker.shared.checkIfStale()
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
                    Task { await VortXSyncManager.shared.syncUp() }   // push profiles + settings
                }
            }
            .onAppear {
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
