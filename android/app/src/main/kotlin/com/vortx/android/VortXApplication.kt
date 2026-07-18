package com.vortx.android

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.util.Log
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.memory.MemoryCache
import coil3.request.crossfade
import okio.Path.Companion.toOkioPath
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.downloads.DownloadManager
import com.vortx.android.downloads.DownloadStore
import com.vortx.android.engine.EngineStremioRepository
import com.vortx.android.mediaserver.MediaServerRepository
import com.vortx.android.profile.ProfileStore
import com.vortx.android.sync.VortXSyncManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/// Owns the ONE [EngineStremioRepository] instance for the process's lifetime.
///
/// This matters for engine lifecycle correctness (ANDROID-PLAN.md S03: "init once at app start...
/// safe against double-init"): [MainActivity] does not construct the engine repository itself,
/// because an `Activity` can be torn down and recreated WITHIN THE SAME PROCESS (a config change
/// `MainActivity`'s manifest entry doesn't cover -- e.g. a system locale/night-mode change, or "Don't
/// keep activities" on some OEM skins) without the process (and so the JVM statics backing
/// [com.vortx.android.engine.StremioCoreNative]) ever restarting. If each `onCreate` built its own
/// `EngineStremioRepository`, the process-wide [com.vortx.android.engine.StremioCoreNative] object's
/// `initialized` guard would make every [com.vortx.android.engine.StremioCoreNative.init] after the
/// first return early WITHOUT re-registering the caller's listener -- so only the FIRST repository's
/// event listener is ever wired to native, and every subsequent Activity instance would hold a
/// repository whose engine event flow silently never fires again. (The native `nativeInit` itself does
/// not orphan a re-init: reached a second time it REPLACES the stored listener global ref,
/// last-writer-wins, and its runtime build is idempotent -- but the Kotlin-side guard means native
/// never even sees the second call.) Building it once here, keyed to [Application] (which really does
/// live for the process), makes that impossible: every `MainActivity.onCreate` reads the SAME
/// instance, whether it's the first launch or the fifth recreation.
///
/// A genuine process death (the OS reclaiming the whole app in the background) restarts this class
/// from scratch in a fresh process, which is the correct/expected reset: [EngineStremioRepository]
/// re-inits the native engine, which re-hydrates its own persisted state from disk, so Home/Continue
/// Watching/sign-in restore themselves with no extra code (see `EngineStremioRepository.start`).
class VortXApplication : Application(), SingletonImageLoader.Factory {

    /// Null only if native init genuinely failed (missing/incompatible `libstremiox_core.so`, an
    /// engine-side throw). Built once, lazily, on first access (not `onCreate`) so a
    /// [android.content.ContentProvider] or test harness that never touches the engine never pays the
    /// native-load cost.
    private val engine: EngineStremioRepository? by lazy {
        runCatching { EngineStremioRepository(this) }
            .getOrElse { error ->
                Log.e(TAG, "Engine repository unavailable; app falls back to offline preview data", error)
                null
            }
    }

    private val fallbackCatalogRepository by lazy { PreviewCatalogRepository() }
    private val fallbackAuthRepository by lazy { PreviewAuthRepository() }

    /// Warm the media-server store from disk at process start (idempotent), so a Plex/Jellyfin/Emby server
    /// connected in a previous run is queryable for direct-play sources on the very first detail page WITHOUT
    /// the user opening Settings. Dormant + cheap when no server is connected (an empty prefs read); it never
    /// touches the network here. The settings screen calls the same idempotent init defensively.
    override fun onCreate() {
        super.onCreate()
        // Stand up the multi-profile core once, before anything touches the engine (the engine is built
        // lazily on first catalog/auth access, after this). ProfileStore.init hydrates the roster, heals
        // the owner singleton, and makes ProfileStore.shared/activeProfileId available to the source-pin
        // per-profile key and the switch-listener reload hook wired in EngineStremioRepository.
        runCatching { ProfileStore.init(this) }
            .onFailure { Log.w(TAG, "Profile store init failed; profiles stay at defaults", it) }
        // Activate the (until-now dormant) VortX account sync engine now that the roster + watch overlay it
        // folds into are stood up: construct VortXSyncManager, wire its push seams, and add the foreground
        // pull. Fail-soft inside; a no-op when signed out, and never on the critical launch path.
        wireAccountSync()
        runCatching { MediaServerRepository.init(this) }
            .onFailure { Log.w(TAG, "Media-server store init failed; the feature stays dormant", it) }
        initDownloads()
    }

    /**
     * Stand up the offline-downloads subsystem: hydrate the local index, restore the queue-manager settings, then do
     * the two things that need the process to be alive.
     *
     * The store + manager init are synchronous because everything downstream (the Settings row's live count, a
     * [com.vortx.android.downloads.DownloadWorker] WorkManager revives into this process) reads them, and they cost
     * one small file read plus one prefs read. The two follow-ups are moved OFF the main thread because they are not:
     *
     *  1. [com.vortx.android.downloads.DownloadManager.reconcileInFlight] blocks on WorkManager's future to ask which
     *     transfers are genuinely still live, and demotes any record that only CLAIMS to be downloading to paused.
     *     This is Apple's `reconnectInFlightDownloads`, which it must run at launch for the same reason.
     *  2. [com.vortx.android.downloads.DownloadManager.retryDownloadsAwaitingUnlock] is the app-foreground leg of the
     *     #132 recovery. Apple wires three triggers for this (`protectedDataDidBecomeAvailable`, `didBecomeActive`,
     *     `willEnterForeground`); [com.vortx.android.downloads.DownloadUnlockReceiver] covers the unlock/boot legs,
     *     and this covers the "unlocked while the app was dead, so the broadcast was missed" case. It no-ops when
     *     nothing is parked, so an ordinary launch pays nothing.
     */
    private fun initDownloads() {
        runCatching {
            DownloadStore.init(this)
            DownloadManager.init(this)
        }.onFailure {
            Log.w(TAG, "Download store init failed; downloads stay dormant this launch", it)
            return
        }
        CoroutineScope(Dispatchers.IO).launch {
            runCatching {
                DownloadManager.reconcileInFlight()
                DownloadManager.retryDownloadsAwaitingUnlock()
            }.onFailure {
                // Fail-soft: a record that could not be reconciled stays as it is and remains resumable by hand,
                // which is exactly Apple's fallback. Never let download bookkeeping break app start.
                Log.w(TAG, "Download reconcile failed; in-flight rows stay as they are and remain resumable", it)
            }
        }
    }

    /// The process-lifetime VortX account sync engine, or null when it could not be stood up (a
    /// [ProfileStore] init failure, or a keystore problem building its session store). Held here for the same
    /// reason [EngineStremioRepository] is -- one instance keyed to the [Application], never per Activity --
    /// so its debounced auto-push scope and the roster/overlay seams it installed on [ProfileStore] live for
    /// the whole process. Nullable + fail-soft: sync is OFF the critical launch path (VortX works fully
    /// signed out), so a null here degrades to "no cross-device sync this launch", never a crash.
    var syncManager: VortXSyncManager? = null
        private set

    /**
     * Activate the account sync engine: construct the (dormant-until-now) [VortXSyncManager], wire its push
     * seams onto the profile roster + watch overlay via [VortXSyncManager.attachSyncSeams], and register a
     * process-wide foreground hook that PULLS the account doc on every foreground.
     *
     * This is the Android analogue of Apple building `VortXSyncManager.shared` and its
     * `.onChange(of: scenePhase) { if .active { syncDown() } }` root hook (VortXiOSApp.swift:88 /
     * VortXTVApp.swift:94): a change made on another device pulls DOWN when this device comes forward. The
     * engine itself is UNCHANGED -- this only WIRES the already-reviewed manager, whose #145 guards
     * (tri-state pull, never-shrink / never-zero, tombstone-first fold, per-account version-wins) all live
     * inside [VortXSyncManager] + [com.vortx.android.sync.VortXSyncDoc]. No merge logic is added here.
     *
     * The foreground hook uses [registerActivityLifecycleCallbacks] (not ProcessLifecycleOwner) so it needs
     * no new dependency and covers BOTH launcher activities from the one process -- the phone [MainActivity]
     * and the TV [com.vortx.android.ui.tv.TvActivity] -- with a single started-activity counter. The 0 -> 1
     * started transition IS "the app came to the foreground" (cold launch OR return from background),
     * matching Apple's scenePhase == .active; [VortXSyncManager.syncDownSoon] is the manager's own documented
     * foreground / "Sync now" pull entry point (the realtime WebSocket channel is a later Android round).
     * Rotation does not recreate the launcher activities (they declare configChanges), and a pull is
     * version-guarded and defers to any queued local push, so even a rare spurious foreground tick (an
     * uncovered config-change recreation) is a cheap, safe no-op rather than a wipe risk.
     */
    private fun wireAccountSync() {
        val store = ProfileStore.sharedOrNull() ?: return   // ProfileStore init failed: leave sync dormant
        val manager = runCatching { VortXSyncManager(this).also { it.attachSyncSeams(store) } }
            .getOrElse {
                Log.w(TAG, "Account sync unavailable; cross-device sync stays dormant this launch", it)
                return
            }
        syncManager = manager
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            /// Count of currently-started activities. Touched only from the main thread (every
            /// ActivityLifecycleCallbacks callback is delivered on the main looper), so a plain Int is safe.
            private var startedActivities = 0

            override fun onActivityStarted(activity: Activity) {
                // 0 -> 1: the app is now in the foreground. Pull the account doc so a remote edit applies,
                // mirroring Apple's scenePhase == .active syncDown. syncDownSoon() is fail-soft + a no-op
                // when signed out, and the pull is version-guarded (applies only a strictly-newer remote and
                // defers while a local push is queued), so it never clobbers local state.
                if (startedActivities == 0) manager.syncDownSoon()
                startedActivities++
            }

            override fun onActivityStopped(activity: Activity) {
                if (startedActivities > 0) startedActivities--
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    /// The one [CatalogRepository] the whole app shares. Falls back to the offline preview data (same
    /// fail-soft boundary [MainActivity] used to own directly) so a native-side problem degrades the
    /// UI instead of crashing it.
    val catalogRepository: CatalogRepository get() = engine ?: fallbackCatalogRepository

    /// The one [AuthRepository] the whole app shares -- the SAME underlying engine instance as
    /// [catalogRepository] when the engine is up (one repository class implements both contracts), so
    /// a sign-in immediately shows up in every catalog call that reads `ctx`-derived state.
    val authRepository: AuthRepository get() = engine ?: fallbackAuthRepository

    /// Coil3's app-wide [ImageLoader] (S03: real poster/backdrop art in [com.vortx.android.ui.
    /// components.PosterArt]). `crossfade(true)` matches DESIGN-SYSTEM.md's motion spec for image
    /// reveals; the memory cache is capped as a PERCENT of available RAM (not a flat byte count) so it
    /// scales sanely from a low-RAM Android TV stick to a flagship phone, and the disk cache is a
    /// bounded slice of free space under this app's own cache dir (OS-purgeable, matches the engine's
    /// own cacheDir choice in `EngineStremioRepository.start`). The OkHttp network fetcher
    /// (`coil-network-okhttp`) needs no manual registration -- Coil3 wires it in automatically once the
    /// dependency is on the classpath.
    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .crossfade(true)
            .memoryCache {
                MemoryCache.Builder()
                    .maxSizePercent(context, 0.25)
                    .build()
            }
            .diskCache {
                DiskCache.Builder()
                    .directory(cacheDir.resolve("image_cache").toOkioPath())
                    .maxSizePercent(0.02)
                    .build()
            }
            .build()

    private companion object {
        const val TAG = "VortXApplication"
    }
}
