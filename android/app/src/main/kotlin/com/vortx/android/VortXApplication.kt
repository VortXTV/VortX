package com.vortx.android

import android.app.Activity
import android.app.Application
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.util.Log
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.memory.MemoryCache
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Path.Companion.toOkioPath
import com.vortx.android.metadata.ArtworkPreferences
import com.vortx.android.metadata.LocalizedMetadataStore
import com.vortx.android.metadata.PosterImageNegativeCache
import com.vortx.android.net.VortXEdgeAuth
import com.vortx.android.ui.prefs.PosterStylePreferences
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.downloads.DownloadManager
import com.vortx.android.downloads.DownloadStore
import com.vortx.android.config.RemoteConfig
import com.vortx.android.debrid.DebridAccountOwnerState
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.engine.EngineStremioRepository
import com.vortx.android.iptv.IPTVCleanupCoordinator
import com.vortx.android.iptv.IPTVPlaylists
import com.vortx.android.iptv.iptvCleanupActions
import com.vortx.android.iptv.launchIPTVStartupCleanup
import com.vortx.android.mediaserver.MediaServerRepository
import com.vortx.android.moat.MoatToken
import com.vortx.android.notifications.NewEpisodeNotifications
import com.vortx.android.singularity.SourceIndexClient
import com.vortx.android.profile.ProfileStore
import com.vortx.android.update.UpdateChecker
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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

    /// Process-owned recovery work. A failed cleanup cannot cancel another startup child, and IO keeps
    /// encrypted preference reads, engine add-on inspection, and Worker revocation off the main thread.
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

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
        // An isolated service still receives this Application callback. Its broker is deliberately supplied
        // only bounded IPC input, so do not initialize any process-wide repositories, encrypted stores,
        // filesystem caches, or network clients in that process.
        if (isIsolatedBrokerProcess()) return
        // Fail closed until the encrypted session store has produced a definitive account or sign-out.
        // This process-wide binding precedes every lazy repository, resolver, and settings consumer.
        DebridKeys.bindAccountOwnerSource { DebridAccountOwnerState.UnknownOrUnavailable }
        // Stand up the multi-profile core once, before anything touches the engine (the engine is built
        // lazily on first catalog/auth access, after this). ProfileStore.init hydrates the roster, heals
        // the owner singleton, and makes ProfileStore.shared/activeProfileId available to the source-pin
        // per-profile key and the switch-listener reload hook wired in EngineStremioRepository.
        runCatching { ProfileStore.init(this) }
            .onFailure { Log.w(TAG, "Profile store init failed; profiles stay at defaults", it) }
        // Bootstrap the RemoteConfig snapshot (baked defaults, signed config.vortx.tv fetch with ETag/304).
        // Loads the last-good cached config synchronously, then refreshes once in the background. Fail-soft:
        // every feature flag + typed value reads its baked (== shipping) default until a remote value lands.
        runCatching { RemoteConfig.bootstrap(this, applicationScope) }
            .onFailure { Log.w(TAG, "RemoteConfig bootstrap failed; features stay at baked defaults", it) }
        // Poster artwork (XRDB/ERDB/fanart) reads its flat settings + the secure fanart key through this
        // context; the poster-style presentation prefs seed their live StateFlow; the localized-metadata pool
        // store hydrates its disk cache. All fail-soft and off the critical launch path (XRDB defaults on,
        // ERDB/fanart/localized default off / English-gated), so a miss just leaves the shipping behavior.
        runCatching {
            ArtworkPreferences.init(this)
            PosterStylePreferences.init(this)
            LocalizedMetadataStore.init(this)
        }.onFailure { Log.w(TAG, "Poster-artwork stores init failed; art stays at add-on/default behavior", it) }
        // Activate the (until-now dormant) VortX account sync engine now that the roster + watch overlay it
        // folds into are stood up: construct VortXSyncManager, wire its push seams, and add the foreground
        // pull. Fail-soft inside; a no-op when signed out, and never on the critical launch path.
        wireAccountSync()
        // Connect the give-to-get MOAT groundwork now that the session manager (read below) exists. This only
        // makes the moat-token client available + wires the reserved SourceIndexClient hook; the Singularity
        // SERVE it feeds stays DORMANT behind its own compile-time gate. Fail-soft + off the critical path.
        wireMoatGroundwork()
        runCatching { MediaServerRepository.init(this) }
            .onFailure { Log.w(TAG, "Media-server store init failed; the feature stays dormant", it) }
        startIPTVCleanupReplay()
        initDownloads()
        // New-episode alerts (F5): (re)arm the WorkManager library sweep if the user has alerts on (default
        // ON), so a followed show pings even with no UI opened. Fail-soft: never break app start.
        runCatching { NewEpisodeNotifications.scheduleSweepIfEnabled(this) }
            .onFailure { Log.w(TAG, "New-episode sweep scheduling failed; alerts stay dormant this launch", it) }
        // In-app update checker: poll vortx.tv/appcast.json for a newer sideload build, driving the Settings
        // banner and the once-per-launch popup. Idempotent + off the critical path.
        runCatching { UpdateChecker.start(this) }
            .onFailure { Log.w(TAG, "Update check could not start this launch", it) }
    }

    private fun isIsolatedBrokerProcess(): Boolean {
        // Android assigns isolated services an ephemeral UID and does not guarantee a stable process name.
        // UID identity is therefore the only trustworthy boundary before any app-owned state is initialized.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return Process.isIsolated()
        val appId = Process.myUid() % APP_ID_RANGE
        return appId in FIRST_ISOLATED_APP_ID..LAST_ISOLATED_APP_ID
    }

    private fun startIPTVCleanupReplay() {
        launchIPTVStartupCleanup(
            scope = applicationScope,
            initialize = { IPTVPlaylists.init(this) },
            resumeAll = {
                val repo = catalogRepository
                IPTVCleanupCoordinator(
                    store = IPTVPlaylists.cleanupStore(),
                    actions = iptvCleanupActions(repo),
                ).resumeAll()
            },
            onFailure = {
                Log.w(TAG, "IPTV cleanup replay failed; its durable journal remains retryable")
            },
        )
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
     * Wire the give-to-get MOAT groundwork, kept DORMANT exactly like Apple ships it gated. The Singularity
     * SERVE consumer ([SourceIndexClient]) stays behind its own compile-time `isEnabled = false` gate pending a
     * separately security-signed-off lane; this only makes the moat-token client ([MoatToken]) available and
     * connects the reserved `moatTokenProvider` hook, so the token flows the same way Apple wires
     * `MoatToken.shared` into `SourceIndexClient.fetchPooled` once SERVE re-enables. Because that gate is
     * closed, the provider is never invoked at runtime today: nothing here mints or reaches the network.
     *
     * [MoatToken] reads the VortX account session bearer live through [sessionProvider], sourced from the
     * already-built [syncManager] (the api.vortx.tv identity, NOT the Stremio authKey). A null manager (sync
     * unavailable this launch) or a signed-out / opted-out device yields no credential, so the client stays
     * fully dormant and fail-soft.
     */
    private fun wireMoatGroundwork() {
        MoatToken.appContext = applicationContext
        MoatToken.sessionProvider = {
            syncManager?.currentSession()?.let { session ->
                MoatToken.SessionCredential(bearer = session.token, accountId = session.account.id)
            }
        }
        // The reserved hook is invoked only after the login-only SERVE gate has already passed, so isSignedIn is
        // known true at that point (SourceIndexClient re-checks the flag before calling the provider).
        SourceIndexClient.moatTokenProvider = { MoatToken.current(isSignedIn = true) }
    }

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
     * matching Apple's scenePhase == .active; [VortXSyncManager.startRealtime] is the manager's foreground
     * entry point (Apple's scene-.active startRealtime): it opens the SyncRoom WebSocket + fallback poll AND
     * runs the same catch-up pull the old syncDownSoon hook did. The 1 -> 0 stopped transition mirrors
     * Apple's scene-.background [VortXSyncManager.stopRealtime], so no socket or poll outlives the
     * foreground. Rotation does not recreate the launcher activities (they declare configChanges), and a
     * pull is version-guarded and defers to any queued local push, so even a rare spurious foreground tick
     * (an uncovered config-change recreation) is a cheap, safe no-op rather than a wipe risk.
     */
    private fun wireAccountSync() {
        val store = ProfileStore.sharedOrNull() ?: return   // ProfileStore init failed: leave sync dormant
        val manager = runCatching {
            VortXSyncManager(this).also { manager ->
                // Bind account ownership before either launcher can create a repository, resolver, settings
                // screen, or view model. The snapshot distinguishes an unreadable session store from a
                // definitive sign-out, so local legacy keys are never adopted while restore identity is unknown.
                DebridKeys.bindAccountOwnerSource {
                    when (val owner = manager.sessionOwnerSnapshot()) {
                        is SessionOwnerSnapshot.Account ->
                            DebridAccountOwnerState.Account(owner.id, owner.generation)
                        is SessionOwnerSnapshot.SignedOutLocal ->
                            DebridAccountOwnerState.SignedOutLocal(owner.generation)
                        is SessionOwnerSnapshot.UnknownOrUnavailable ->
                            DebridAccountOwnerState.UnknownOrUnavailable
                    }
                }
                manager.attachSyncSeams(store)
            }
        }
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
                // 0 -> 1: the app is now in the foreground. Open the realtime channel (SyncRoom WebSocket +
                // fallback poll) AND run the catch-up pull, mirroring Apple's scenePhase == .active
                // startRealtime. Fail-soft + a no-op when signed out or already live, and every pull it
                // triggers is version-guarded (applies only a strictly-newer remote and defers while a
                // local push is queued), so it never clobbers local state.
                if (startedActivities == 0) manager.startRealtime()
                startedActivities++
            }

            override fun onActivityStopped(activity: Activity) {
                if (startedActivities > 0) startedActivities--
                // 1 -> 0: the app left the foreground. Close the socket + poll (Apple's scene-.background
                // stopRealtime); the next foreground re-opens them. Safe to call repeatedly.
                if (startedActivities == 0) manager.stopRealtime()
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
            // Give Coil a dedicated OkHttp client whose interceptor edge-signs requests to OUR gated art
            // hosts (poster.vortx.tv / erdb.vortx.tv). The signature rides X-VX-* HEADERS, which are NOT part
            // of Coil's cache key, so the disk cache stays warm (a query-signed URL would carry a per-second
            // `vts` and bust the cache every second). Fail-open for every other host (tmdb / metahub / add-on
            // art) and for an unprovisioned build, matching Apple's `PosterImageLoader` header-sign contract.
            .components {
                add(OkHttpNetworkFetcherFactory(callFactory = { edgeSignedImageClient }))
            }
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

    /**
     * The OkHttp client Coil uses for image bytes, with the edge-signing interceptor installed. Built once,
     * lazily; a plain client (no signing) for every non-gated host.
     */
    private val edgeSignedImageClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            // Order matters: the negative-cache interceptor is OUTERMOST so it can short-circuit a
            // recently-failed art URL before signing or a network hit; the edge signer runs only for
            // requests that actually go out.
            .addInterceptor(negativeCacheInterceptor)
            .addInterceptor(edgeSigningInterceptor)
            .build()
    }

    /**
     * Poster loader hardening (item 7) over Coil: a status-classified negative cache so a card that just
     * failed does not re-hammer the network on every scroll, with the suppression window chosen by WHY it
     * failed (terminal 4xx that cannot become an image get the long expiry; auth/throttle/timeout/5xx retry
     * after a short backoff). Diagnostics are HOST-ONLY (a poster URL can carry a title id or signed query
     * value), matching Apple's `PosterImageLoader` probe discipline. A 2xx clears any prior negative.
     */
    private val negativeCacheInterceptor = Interceptor { chain ->
        val request = chain.request()
        val key = PosterImageNegativeCache.key(request.url.host, request.url.encodedPath)
        if (PosterImageNegativeCache.shouldSuppress(key)) {
            // Suppressed: return a synthetic gateway-timeout so Coil treats it as a miss with NO network hit.
            // A miss is retried on the next appear, so a transient failure never latches a permanently blank
            // card (Coil re-requests when the card recomposes after the TTL).
            return@Interceptor Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(504)
                .message("VortX poster negative-cache suppressed")
                .body(ByteArray(0).toResponseBody(null))
                .build()
        }
        val response = chain.proceed(request)
        when (val failure = PosterImageNegativeCache.classify(response.code)) {
            null -> PosterImageNegativeCache.clear(key)
            else -> {
                PosterImageNegativeCache.record(key, failure)
                Log.d(TAG, "poster fetch host=${request.url.host} status=${response.code} -> negative-cache")
            }
        }
        response
    }

    /**
     * Stamp `X-VX-Ts` / `X-VX-Kid` / `X-VX-Sig` on an outgoing image GET IFF its host is one of VortX's gated
     * services ([VortXEdgeAuth.signingHeaders] returns null otherwise, so this is a no-op for tmdb / metahub /
     * add-on hosts). Never throws: a signing failure falls through to the unsigned request (observe-safe).
     */
    private val edgeSigningInterceptor = Interceptor { chain ->
        val request = chain.request()
        val headers = runCatching {
            VortXEdgeAuth.signingHeaders(request.method, request.url.toUrl())
        }.getOrNull()
        if (headers == null) {
            chain.proceed(request)
        } else {
            chain.proceed(
                request.newBuilder()
                    .header(VortXEdgeAuth.tsHeaderName(), headers.ts)
                    .header(VortXEdgeAuth.kidHeaderName(), headers.kid)
                    .header(VortXEdgeAuth.sigHeaderName(), headers.sig)
                    .build(),
            )
        }
    }

    private companion object {
        const val TAG = "VortXApplication"
        const val FIRST_ISOLATED_APP_ID = 99_000
        const val LAST_ISOLATED_APP_ID = 99_999
        const val APP_ID_RANGE = 100_000
    }
}
