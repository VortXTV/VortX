import SwiftUI

/// The clip the built-in playback selftests play (`-tv-selftest` mounts the player directly,
/// `-tv-playertest` exercises the root-replacement path). Both read it from here so a dead default
/// can never rot in two places again, which is exactly what happened: the previous default,
/// Blender's `BigBuckBunny_320x180.mp4`, started returning 404 and every selftest run landed on the
/// "source never started" screen instead of playing, making the smoke check useless.
///
/// Override it to point a run at a local HTTP server (an offline machine, or to exercise a specific
/// container) with either:
///   -tv-selftest-url https://host/clip.mp4     launch argument, wins
///   defaults write <bundle-id> tv.selftest.url https://host/clip.mp4
/// A malformed or non-http(s) override is ignored in favour of the default, so a typo degrades to a
/// working selftest rather than the failure screen the override was meant to diagnose.
enum SelftestSource {
    /// Verified 2026-07-25: HTTP 200, no redirects, H.264 640x360, 10s, 0.94 MB. Kept deliberately
    /// small so a cold simulator start reaches first frame quickly.
    static let defaultURLString = "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4"
    static let argumentName = "-tv-selftest-url"
    static let defaultsKey = "tv.selftest.url"

    static var url: URL { resolve(override: overrideString) ?? URL(string: defaultURLString)! }

    /// The raw override from the launch argument (preferred) or the defaults key, whichever is present.
    static var overrideString: String? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: argumentName), i + 1 < args.count { return args[i + 1] }
        return UserDefaults.standard.string(forKey: defaultsKey)
    }

    /// Accept only a well-formed http(s) URL; anything else falls back to the default. Pure, so the
    /// rule is testable without launching the app.
    static func resolve(override: String?) -> URL? {
        guard let raw = override?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

@main
struct VortXTVApp: App {
    private static let runsPlayerSelftest = ProcessInfo.processInfo.arguments.contains("-tv-selftest")
    @State private var splashFinished = false
    @State private var shellReady = VortXTVApp.runsPlayerSelftest
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Self-capture crashes into the exportable diagnostic log FIRST, before anything else can fault.
        // A sideloaded Apple TV cannot hand its .ips reports to the owner, so the app writes its own: a
        // crash records a marker, the next launch folds it into the exportable log. See VortXCrashReporter.
        VortXCrashReporter.install()
        // Prior-launch termination evidence: folds how the PREVIOUS run ended into the probe log,
        // then keeps this session's receipt fresh (phase + 60 s heartbeat + memory warnings).
        TerminationReceipt.install()
        // Gated diagnostic logging: starts the once-a-second heartbeat only when VORTX_PROBE=1 or the
        // Settings toggle is on, then narrates the boot. No-op (and no cost) otherwise. tvOS was the ONE
        // target that never armed it (iOS/macOS both did), so a tvOS probe log had no per-second record of
        // screen / player / memory at all: the Settings toggle started the heartbeat only from the moment it
        // was flipped, and an already-running session that later showed a memory spike could not say whether
        // the app was sitting on Home or holding a live mount. That is the line the FAIL-260804-10 review
        // wanted and did not have.
        VXProbeHeartbeat.start()
        VXProbe.log("boot", "VortX launched probe=\(VXProbe.enabled)")
        // Offline mode (#120): start the process-wide connectivity monitor before the shell mounts, so
        // its FIRST verdict (launchOffline) is ready to land an offline launch on the Library tab (where
        // Downloads live) and the shell's "You're offline" chip tracks the live (debounced) state.
        ConnectivityMonitor.shared.start()
        // Embed Stremio's streaming server on :11470 (nodejs-mobile retargeted to tvOS), so
        // torrent / non-web-ready streams the server must fetch & remux can play on Apple TV.
        // On by default; -stremiox-no-server disables it for isolation testing.
        #if !VORTX_NO_EMBEDDED_SERVER
        if !PlaybackSettings.torrentsDisabled,
           !ProcessInfo.processInfo.arguments.contains("-stremiox-no-server") {
            NodeServer.startIfNeeded()
            // The lifecycle entry point starts exactly the selected transport.
            // Once the server is up, cap its torrent cache to a TV-safe size (the 2 GB default
            // can get the whole app jetsam-killed mid-torrent). Detached so it never blocks launch.
            Task.detached(priority: .utility) { await StremioServer.applyServerConfig() }
        }
        #endif
        // Install the dedicated, large image URLCache BEFORE any poster loads (parity with iOS/Mac). The
        // default shared cache cannot hold a catalog page of posters, so posters re-fetch on every scroll.
        PosterImageLoader.configureSharedCache()
        // Safety sweep: clear any leftover libmpv on-disk streaming cache from a previous run. The
        // player wipes it on a genuine exit, but a crash mid-playback could leave bytes behind; this
        // guarantees a fresh, bounded start so the configurable cache can never accumulate unbounded.
        // Detached so the directory scan + delete (multi-GB after a crash) never blocks launch.
        Task.detached(priority: .utility) { DiskCacheSetting.clearCache() }
        // Publish whether the user has their own usenet provider configured, so bare-NZB rows are tappable
        // from launch (before the Settings screen is ever opened). One Keychain read; no-op if unset.
        UsenetProviderStore.refreshAvailability()
        if Self.runsPlayerSelftest { Self.startCore() }
    }

    private static func startCore() {
        // Arm auto-delete of watched downloads before the shell opens, even if Downloads is never shown.
        _ = DownloadManager.shared
        // Boot the native stremio-core engine (hydrates library/profile from storage, starts the
        // event loop). The schema-version log is an end-to-end smoke check of the Rust⇄Swift FFI.
        CoreBridge.shared.start()
        NSLog("%@", "[StremioX] stremio-core schema version = \(CoreBridge.shared.schemaVersion)")
    }

    private func startShellIfReady(_ phase: ScenePhase) {
        guard splashFinished, !shellReady, phase == .active else { return }
        Self.startCore()
        shellReady = true
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if shellReady {
                    WindowShell(scenePhase: scenePhase, runsPlayerSelftest: Self.runsPlayerSelftest)
                } else if splashFinished {
                    SplashView.canvas.ignoresSafeArea()
                } else {
                    SplashView {
                        splashFinished = true
                    }
                }
            }
            .preferredColorScheme(.dark)
            .visualEffectsRoot()
            // Keep parking Top Shelf destinations during cold launch. Infuse progress is saved
            // here too, then applied when the account-backed shell appears.
            .onOpenURL { DeepLinkRouter.shared.handle($0, applyInfuseImmediately: shellReady) }
            .onChange(of: splashFinished) { _, _ in startShellIfReady(scenePhase) }
            .onChange(of: scenePhase) { _, phase in
                DiagnosticsLog.log("app", "scenePhase → \(String(describing: phase))")
                switch phase {
                case .active: TerminationReceipt.note(phase: TerminationReceiptPolicy.phaseActive)
                case .inactive: TerminationReceipt.note(phase: TerminationReceiptPolicy.phaseInactive)
                case .background: TerminationReceipt.note(phase: TerminationReceiptPolicy.phaseBackground)
                @unknown default: break
                }
                #if !VORTX_NO_EMBEDDED_SERVER
                // The in-process server starts before the shell, so handle suspension here as well.
                if phase == .active { VortxNativeServer.startIfNeeded() }
                if phase == .background { VortxNativeServer.stopOnBackground() }
                #endif
                startShellIfReady(phase)
            }
        }
    }

    private struct WindowShell: View {
        let scenePhase: ScenePhase
        let runsPlayerSelftest: Bool
        @StateObject private var account = StremioAccount()
        @StateObject private var core = CoreBridge.shared
        @StateObject private var sync = VortXSyncManager.shared
        @StateObject private var presenter = PlayerPresenter()

        var body: some View {
            Group {
                if runsPlayerSelftest {
                    TVPlayerView(url: SelftestSource.url, title: "Player Test, Oceans")
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
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    InfuseReturnCoordinator.applyReturned()   // a position Infuse reported before VortX was ready
                    UpdateChecker.shared.checkIfStale()
                    // RemoteConfig had NO foreground pull: `refreshIfForegroundDue` existed with zero call
                    // sites anywhere in the repo, so the only refreshes were the cold-launch fetch and the
                    // 6-hourly periodic Task. That Task's sleep does not advance while tvOS has the process
                    // suspended, and an Apple TV app is often never fully quit, so a device could hold a
                    // stale config (and therefore a stale KILL SWITCH) for a very long time. Throttled to
                    // once per 30 minutes inside the actor, detached so it cannot delay this hook, and
                    // fail-soft by construction (refresh never throws and keeps last-good on any error).
                    Task.detached(priority: .utility) { await RemoteConfig.shared.refreshIfForegroundDue() }
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
                    // TV Home does not close the mounted player, so RootTabView's playback-exit
                    // callback may not run. Publish the latest acknowledged queue before suspension;
                    // this does not invent a final progress ACK or bypass the writer's owner gates.
                    TopShelfSnapshotWriter.publishCurrent()
                    // Drop the memoized YouTube-trailer range-proxy listener: tvOS can reclaim its bound
                    // loopback port across a suspension, and the proxy caches the port once, so every Home
                    // hero-preview trailer fails after a resume until it rebinds. proxied() rebinds lazily on
                    // the next preview, so this just clears the stale listener/port.
                    VXTrailerProxy.shared.invalidate()
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
                InfuseReturnCoordinator.applyReturned()
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
                    presenter.request = PlaybackRequest(url: SelftestSource.url, title: "Player Test")
                }
            }
        }
    }
}
