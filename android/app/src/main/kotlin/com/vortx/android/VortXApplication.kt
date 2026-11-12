package com.vortx.android

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
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
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.downloads.DownloadManager
import com.vortx.android.downloads.DownloadStore
import com.vortx.android.config.RemoteConfig
import com.vortx.android.debrid.DebridAccountOwnerState
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.diagnostics.CrashReporter
import com.vortx.android.engine.NativeCatalogRepository
import com.vortx.android.engine.AndroidNativePlaybackResolver
import com.vortx.android.engine.NativeAccountCoordinator
import com.vortx.android.engine.NativeAccountBinding
import com.vortx.android.engine.runNativeRetirementAttempt
import com.vortx.android.engine.NativeProfileAccess
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.engine.VortxAndroidCheckpointKey
import com.vortx.android.engine.VortxEncryptedCheckpointStore
import com.vortx.android.engine.VortxJniBindings
import com.vortx.android.engine.VortxJniResourceTransport
import com.vortx.android.engine.VortxNativeSession
import com.vortx.android.iptv.IPTVCleanupCoordinator
import com.vortx.android.iptv.IPTVPlaylists
import com.vortx.android.iptv.iptvCleanupActions
import com.vortx.android.iptv.launchIPTVStartupCleanup
import com.vortx.android.mediaserver.MediaServerRepository
import com.vortx.android.moat.MoatToken
import com.vortx.android.notifications.NewEpisodeNotifications
import com.vortx.android.singularity.SourceIndexClient
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.PlaylistScopeTransition
import com.vortx.android.player.PlaybackOwnerEpoch
import com.vortx.android.player.PlaybackOwnerToken
import com.vortx.android.update.UpdateChecker
import com.vortx.android.sync.AccountFileRestoreExternalExclusion
import com.vortx.android.sync.AccountSyncForeground
import com.vortx.android.sync.ApplicationAccountFileRestoreExclusion
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.tv.WatchNextOwnerIdentity
import com.vortx.android.tv.WatchNextPublisher
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/// Owns the process-lifetime VortX engine session ([NativeAccountCoordinator]) and the repositories built on
/// it. An `Activity` can be torn down and recreated within the same process, so every `MainActivity.onCreate`
/// reads the same instances from here instead of building its own; a genuine process death restarts this
/// class, and the engine re-hydrates its encrypted checkpoint from disk.
class VortXApplication : Application(), SingletonImageLoader.Factory {

    /** All app-context settings writers share the prospective-account commit fence. */
    override fun getSharedPreferences(name: String, mode: Int): android.content.SharedPreferences =
        com.vortx.android.sync.NativeSettingsFence.open(this, name, mode) { super.getSharedPreferences(name, mode) }

    /// Process-owned recovery work. A failed cleanup cannot cancel another startup child, and IO keeps
    /// encrypted preference reads, engine add-on inspection, and Worker revocation off the main thread.
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val playbackQueueDelegate = lazy {
        com.vortx.android.player.queue.PlaybackQueueStore(this, applicationScope) {
            catalogRepository.continueWatchingOwner()
        }
    }
    internal val playbackQueue: com.vortx.android.player.queue.PlaybackQueueStore
        get() = playbackQueueDelegate.value
    private val savedPlaylistStoreDelegate = lazy {
        com.vortx.android.playlists.SavedPlaylistStore(
            gateway = nativeAccounts,
            queue = playbackQueue,
            scope = applicationScope,
            currentQueueOwner = { catalogRepository.continueWatchingOwner() },
        )
    }
    internal val savedPlaylistStore: com.vortx.android.playlists.SavedPlaylistStore
        get() = savedPlaylistStoreDelegate.value

    private val nativeAccounts: NativeAccountCoordinator by lazy { NativeAccountCoordinator(VortxJniBindings,
        VortxEncryptedCheckpointStore(java.io.File(noBackupFilesDir, "native-state"), VortxAndroidCheckpointKey::get),
        ::VortxJniResourceTransport, { syncManager?.sessionOwnerSnapshot() == it },
        { close -> applicationScope.launch {
            runNativeRetirementAttempt(close) {
                Log.w(TAG, "Native retirement could not finish; the previous writer remains reserved")
            }
        } },
        { candidate -> ProfileStore.sharedOrNull()?.attachNativeGateway(nativeProfiles, candidate) },
        { origin -> applicationScope.launch { syncManager?.onLocalNativeMutation(origin) } },
        { applicationScope.launch(Dispatchers.Main) {
            if (runCatching { nativeAccounts.session() }.isFailure) {
                ProfileStore.sharedOrNull()?.clearNativeProjection()
            }
        } },
        ownCredentials = com.vortx.android.engine.NativeOwnAccountCredentials.shared(this),
        captureOwnAccountAdmission = { captured -> syncManager?.let { manager ->
            val admission = manager.captureLocalLibraryMutationAdmission() ?: return@let null
            val gate: (() -> Boolean) -> Boolean = { action -> admission {
                syncManager === manager && manager.sessionOwnerSnapshot() == captured && action()
            } }
            gate
        } }, captureForYouAccountAuthority = { captured -> syncManager?.let { manager ->
            val authority = manager.captureLocalLibraryMutationAuthority() ?: return@let null
            if (manager.sessionOwnerSnapshot() != captured) return@let null
            com.vortx.android.sync.LocalLibraryMutationAuthority(authority.identity) { action -> authority.admit {
                syncManager === manager && manager.sessionOwnerSnapshot() == captured && authority.admit(action)
            } }
        } }, onAuthorityChanged = {
            if (xperienceCatalogDelegate.isInitialized()) xperienceCatalogDelegate.value.invalidateDeferred()
            com.vortx.android.singularity.SourceIndexLifecycle.invalidateDeferred()
            com.vortx.android.library.WatchlistStore.shared(this).invalidateNativeAuthority()
            com.vortx.android.foryou.ForYouStore.shared(this).invalidateNativeAuthority()
            if (playbackQueueDelegate.isInitialized()) playbackQueue.invalidate()
            if (savedPlaylistStoreDelegate.isInitialized()) savedPlaylistStore.nativeProjectionWillChange()
        },
        onProgressMutation = { origin -> applicationScope.launch { syncManager?.onLocalNativeMutation(origin, progressOnly = true) } },
        captureProfilePresentationAdmission = { captured -> syncManager?.let { manager ->
            // Read-only UI capability only. Persistent identity is verified on IO at capture;
            // admission retains the exact authenticated session, owner epoch and operation generation.
            val admission = manager.captureLocalLibraryMutationAdmission() ?: return@let null
            if (manager.sessionOwnerSnapshot() != captured) return@let null
            val gate: (() -> Boolean) -> Boolean = { action -> admission {
                syncManager === manager && manager.sessionUiState.value is VortXSyncManager.SessionUiState.SignedIn && action()
            } }
            gate
        } }) }
    internal fun nativeStreamingAccounts(): NativeAccountCoordinator = nativeAccounts

    internal fun clearWatchNextIfDisabled() {
        applicationScope.launch { WatchNextPublisher.clearWhenDisabled(this@VortXApplication) }
    }

    /** IO only. Unavailable encrypted state is never allowed to retire launcher rows. */
    private fun retireWatchNextAfterSignOut(manager: VortXSyncManager, owner: SessionOwnerSnapshot.SignedOutLocal) {
        if (!hasWatchNextLauncher()) return
        val admit = manager.captureLocalLibraryMutationAdmission() ?: return
        WatchNextPublisher.clearAfterSignOut(this) { delete ->
            admit { syncManager === manager && manager.sessionOwnerSnapshot() == owner && delete() }
        }
    }

    private fun hasWatchNextLauncher(): Boolean =
        runCatching { packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) }.getOrDefault(false)

    /** Retire attributable old-account rows without waiting for the next native mount. */
    private fun retireWatchNextOtherAccounts(manager: VortXSyncManager, owner: SessionOwnerSnapshot.Account): Boolean {
        if (!hasWatchNextLauncher()) return true
        val admit = manager.captureLocalLibraryMutationAdmission() ?: return false
        return WatchNextPublisher.retireOtherAccounts(this, owner.id) { delete ->
            admit { syncManager === manager && manager.sessionOwnerSnapshot() == owner && delete() }
        }
    }

    internal class WatchNextMount(
        val owner: ContinueWatchingOwner,
        val identity: WatchNextOwnerIdentity,
        val admit: (() -> Boolean) -> Boolean,
    )

    /** Capture the one exact Session, authenticated account, native binding and playback epoch. */
    internal fun captureWatchNextMount(epoch: PlaybackOwnerToken): WatchNextMount? = runCatching {
        val session = nativeAccounts.session()
        session.withCurrentRead { read ->
            val native = read.owner
            val manager = syncManager ?: return@withCurrentRead null
            val account = nativeAccounts.accountFor(session) ?: return@withCurrentRead null
            val accountAdmission = manager.captureLocalLibraryMutationAdmission() ?: return@withCurrentRead null
            fun admitCurrentMount(write: () -> Boolean): Boolean = accountAdmission {
                syncManager === manager && manager.sessionOwnerSnapshot() == account &&
                    nativeAccounts.withCompletedPickerMount(session, account) {
                        PlaybackOwnerEpoch.isCurrent(epoch) && write()
                    }
            }
            if (!admitCurrentMount { true }) return@withCurrentRead null
            val binding = NativeAccountBinding.read(read.state, native.profileID)
            val scope = native.scope.digest
            val identity = WatchNextOwnerIdentity(account.id, scope, native.profileID, binding.kind,
                binding.json().getJSONObject("account").opt("value") as? String, binding.revision, binding.transactionID)
            val owner = ContinueWatchingOwner(native.profileID, scope, native.scope.accountID, true, native.revision)
            WatchNextMount(owner, identity) { write ->
                runCatching {
                    session.withCurrentRead { current ->
                        current.owner == native && binding.matches(NativeAccountBinding.read(current.state, native.profileID)) &&
                            admitCurrentMount(write)
                    }
                }.getOrDefault(false)
            }
        }
    }.getOrNull()

    private val xperienceCatalogDelegate = lazy {
        com.vortx.android.engine.NativeXperienceCatalogAccess(nativeAccounts, nativeRepository, applicationScope)
    }
    internal fun xperienceCatalogGateway(): com.vortx.android.engine.NativeXperienceCatalogGateway = xperienceCatalogDelegate.value
    private val nativeProfiles: NativeProfileAccess by lazy { NativeProfileAccess(
        publicationAdmission = { runtime, action ->
            val account = nativeAccounts.accountFor(runtime)
            account != null && nativeAccounts.withProfileMutation(runtime, account, action)
        },
        capturePreparedPublication = nativeAccounts::captureProfilePresentation,
        session = { nativeAccounts.session() },
    ) }
    private val nativeWatchlist by lazy { com.vortx.android.engine.NativeWatchlistAccess(nativeAccounts) }
    private val nativeForYou by lazy { com.vortx.android.engine.NativeForYouAccess(nativeAccounts) }
    private val nativeStreamingAuth by lazy { com.vortx.android.engine.NativeStreamingAuthRepository(nativeAccounts, applicationScope) }
    private val nativeRepository: NativeCatalogRepository by lazy { NativeCatalogRepository(AndroidNativePlaybackResolver(this), nativeAccounts.changes.map { Unit },
        { check(syncManager?.signOut() == true) { "Account sign-out could not be stored securely" } },
        captureReclaimAdmission = { session, owner ->
            syncManager?.let { manager -> com.vortx.android.engine.captureNativeReclaimAdmission(nativeAccounts, session, owner,
                { if (syncManager === manager) manager.sessionOwnerSnapshot() else com.vortx.android.sync.SessionOwnerSnapshot.UnknownOrUnavailable(0) },
                manager::captureLocalLibraryMutationAdmission) }
        },
        withReclaimLifecycle = { action -> DownloadManager.withWatchedReclaimAdmission(this, action) },
        sourceIndexSource = com.vortx.android.engine.NativeSourceIndexSource(applicationScope,
            ::captureNativeSourceIndexAuthorization),
        captureAddonPublication = { session, update ->
            nativeAccounts.accountFor(session)?.let { account ->
                { action: () -> Unit ->
                    nativeAccounts.withProfileMutation(session, account) {
                        if (session.updates.value == update) { action(); true } else false
                    }
                }
            }
        },
        captureLibraryMirrorOrigin = ::captureNativeLibraryMirrorOrigin,
        mirrorLibrary = { origin, added, type, id ->
            if (added) com.vortx.android.sync.AccountLibrarySync.onLibraryAdded(this, origin, type, id)
            else com.vortx.android.sync.AccountLibrarySync.onLibraryRemoved(this, origin, id, type)
        },
        nzbSourceAggregator = run {
            val keys = DebridKeys(this)
            com.vortx.android.engine.NzbSourceAggregator(
                com.vortx.android.nzb.NzbIndexerStore(
                    this,
                    keys::ownerToken,
                    { ProfileStore.sharedOrNull()?.active?.id },
                    keys::mutateCurrentOwner,
                ),
            )
        }) {
        nativeAccounts.session()
    } }


    /// Warm the media-server store from disk at process start (idempotent), so a Plex/Jellyfin/Emby server
    /// connected in a previous run is queryable for direct-play sources on the very first detail page WITHOUT
    /// the user opening Settings. Dormant + cheap when no server is connected (an empty prefs read); it never
    /// touches the network here. The settings screen calls the same idempotent init defensively.
    override fun onCreate() {
        super.onCreate()
        CrashReporter.install(this) // Audit 12.5: capture before any process initialization can fail.
        // An isolated service still receives this Application callback. Its broker is deliberately supplied
        // only bounded IPC input, so do not initialize any process-wide repositories, encrypted stores,
        // filesystem caches, or network clients in that process.
        if (isCommunityJsBrokerProcess()) return
        // Durable, scrubbed diagnostics (always-on breadcrumb + the opt-in exportable log). Main process only.
        com.vortx.android.diagnostics.DiagnosticsLog.install(this)
        // This existing-only provenance starts before any normal provider retry work.
        runCatching {
            com.vortx.android.security.AccountFileProviderWriters.withWriter(Unit) {
                val backing = com.vortx.android.sync.NativeSettingsFence.RestoreAuxiliaryBacking.PROVIDER_RETRY_QUEUE
                com.vortx.android.sync.NativeSettingsFence.preparePristineRestoreBacking(this, backing) {
                    super.getSharedPreferences(backing.fileName, Context.MODE_PRIVATE)
                }
            }
        }.onFailure { Log.w(TAG, "Provider retry backing unavailable for account Restore") }
        // Fail closed until the encrypted session store has produced a definitive account or sign-out.
        // This process-wide binding precedes every lazy repository, resolver, and settings consumer.
        DebridKeys.bindAccountOwnerSource { DebridAccountOwnerState.UnknownOrUnavailable }
        DebridKeys.bindUsenetOwnerAdmission(null)
        // Stand up the multi-profile core once, before anything touches the engine (the engine session is
        // built lazily on first catalog/auth access, after this). ProfileStore.init makes
        // ProfileStore.shared/activeProfileId available to the source-pin per-profile key.
        runCatching { ProfileStore.init(this) }
            .onFailure { Log.w(TAG, "Profile store init failed; profiles stay at defaults", it) }
        // Playlist receipts survive same-owner native metadata/settings refreshes, but not an
        // admitted profile/account/credential boundary. This callback is local-only on ProfileStore's lane.
        ProfileStore.sharedOrNull()?.addPlaylistScopeTransitionListener { transition ->
            if (transition == PlaylistScopeTransition.AUTHORITY_BOUNDARY && xperienceCatalogDelegate.isInitialized())
                xperienceCatalogDelegate.value.invalidateDeferred()
            if (!savedPlaylistStoreDelegate.isInitialized()) return@addPlaylistScopeTransitionListener
            when (transition) {
                PlaylistScopeTransition.PROJECTION_REFRESH -> savedPlaylistStore.nativeProjectionWillChange()
                PlaylistScopeTransition.AUTHORITY_BOUNDARY -> savedPlaylistStore.invalidateAuthority()
            }
        }
        com.vortx.android.library.WatchlistStore.shared(this).installNativeGateway(nativeWatchlist) { true }
        com.vortx.android.foryou.ForYouStore.shared(this).installNativeGateway(nativeForYou)
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
        // Connect the issuer and live consent observer. The repository's typed owner authorization is the
        // only Source Index network entrance; the old Boolean/frontend entrance remains closed.
        wireMoatGroundwork()
        runCatching { MediaServerRepository.init(this) }
            .onFailure { Log.w(TAG, "Media-server store init failed; the feature stays dormant", it) }
        startIPTVCleanupReplay()
        initDownloads()
        wireAccountSync()
        // New-episode alerts (F5): (re)arm the WorkManager library sweep if the user has alerts on (default
        // ON), so a followed show pings even with no UI opened. Fail-soft: never break app start.
        runCatching { NewEpisodeNotifications.scheduleSweepIfEnabled(this) }
            .onFailure { Log.w(TAG, "New-episode sweep scheduling failed; alerts stay dormant this launch", it) }
        // In-app update checker: poll vortx.tv/appcast.json for a newer sideload build, driving the Settings
        // banner and the once-per-launch popup. Idempotent + off the critical path.
        runCatching { UpdateChecker.start(this) }
            .onFailure { Log.w(TAG, "Update check could not start this launch", it) }
    }

    private fun isCommunityJsBrokerProcess(): Boolean {
        val name = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            Application.getProcessName()
        } else {
            val manager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            manager?.runningAppProcesses?.firstOrNull { it.pid == Process.myPid() }?.processName
        }
        return name == "$packageName:communityjs"
    }

    private fun startIPTVCleanupReplay() {
        launchIPTVStartupCleanup(
            scope = applicationScope,
            initialize = { IPTVPlaylists.init(this) },
            resumeAll = {
                awaitAccountSyncStartup()
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

    private val downloadStoresReady = CompletableDeferred<Boolean>()
    private val downloadRecoveryMutex = Mutex()

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
     *     and this covers the "unlocked while the app was dead, so the broadcast was missed" case.
     */
    private fun initDownloads() {
        runCatching {
            DownloadStore.init(this)
            DownloadManager.init(this)
        }.onFailure {
            downloadStoresReady.complete(false)
            Log.w(TAG, "Download store init failed; downloads stay dormant this launch", it)
            return
        }
        downloadStoresReady.complete(true)
        applicationScope.launch {
            retryDownloadRecovery()
        }
    }

    /** Both callers run on the application IO scope after releasing the session owner locks. */
    private suspend fun retryDownloadRecovery(expectedManager: VortXSyncManager? = null) {
        if (!downloadStoresReady.await()) return

        try {
            downloadRecoveryMutex.withLock {
                if (expectedManager != null && syncManager !== expectedManager) return@withLock
                DownloadManager.retryDownloadsAfterOwnerReady()
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            Log.w(TAG, "Download recovery deferred; pending transfers remain retryable")
        }
    }

    /** One process-owned publication for the attached manager and its picker Restore binding. */
    internal sealed interface AccountSyncStartup {
        data object Preparing : AccountSyncStartup
        data object Unavailable : AccountSyncStartup
        class Ready(
            val manager: VortXSyncManager,
            val pickerFileRestore: AccountFileRestoreExternalExclusion,
        ) : AccountSyncStartup
    }

    private val _accountSyncStartup = MutableStateFlow<AccountSyncStartup>(AccountSyncStartup.Preparing)
    internal val accountSyncStartup = _accountSyncStartup.asStateFlow()
    private val accountForeground = MutableStateFlow(AccountSyncForeground(active = false))
    private var sourceIndexConsentObserver: android.content.SharedPreferences.OnSharedPreferenceChangeListener? = null

    val syncManager: VortXSyncManager?
        get() = (_accountSyncStartup.value as? AccountSyncStartup.Ready)?.manager

    internal suspend fun awaitAccountSyncStartup() {
        accountSyncStartup.first { it !== AccountSyncStartup.Preparing }
    }

    internal fun pickerAccountFileRestoreExclusion(expected: VortXSyncManager?): AccountFileRestoreExternalExclusion? =
        (_accountSyncStartup.value as? AccountSyncStartup.Ready)
            ?.takeIf { it.manager === expected }
            ?.pickerFileRestore

    private fun publishAccountSync(
        manager: VortXSyncManager,
        pickerRestore: AccountFileRestoreExternalExclusion,
        confirmedOwner: SessionOwnerSnapshot,
    ) {
        check(_accountSyncStartup.value === AccountSyncStartup.Preparing)
        com.vortx.android.singularity.SourceIndexLifecycle.invalidateDeferred()
        val ready = AccountSyncStartup.Ready(manager, pickerRestore)
        com.vortx.android.player.PlaybackOwnerEpoch.transition {
            _accountSyncStartup.value = ready
            com.vortx.android.singularity.SourceIndexLifecycle.invalidateDeferred()
        }
        applicationScope.launch {
            var observed: SessionOwnerSnapshot? = confirmedOwner
            var recoveredDownloadOwner: SessionOwnerSnapshot? = null
            var checkedWatchNextAccount: SessionOwnerSnapshot.Account? = null
            manager.sessionUiState.combine(manager.pickerAccountRevision) { state, _ ->
                state
            }.collect { state ->
                if (syncManager !== manager) return@collect
                val current = runCatching { manager.sessionOwnerSnapshot() }.getOrNull()
                if (current is SessionOwnerSnapshot.SignedOutLocal) retireWatchNextAfterSignOut(manager, current)
                val watchNextAccount = current as? SessionOwnerSnapshot.Account
                if (watchNextAccount == null) {
                    checkedWatchNextAccount = null
                } else if (watchNextAccount != checkedWatchNextAccount && retireWatchNextOtherAccounts(manager, watchNextAccount)) {
                    checkedWatchNextAccount = watchNextAccount
                }
                if (current != observed || state !is VortXSyncManager.SessionUiState.SignedIn) {
                    com.vortx.android.singularity.SourceIndexLifecycle.invalidateDeferred()
                }
                observed = current

                if (state === VortXSyncManager.SessionUiState.UnknownOrUnavailable) {
                    recoveredDownloadOwner = null
                }
                val confirmedOwner = current?.takeIf {
                    it is SessionOwnerSnapshot.Account || it is SessionOwnerSnapshot.SignedOutLocal
                }
                if (confirmedOwner != recoveredDownloadOwner) {
                    recoveredDownloadOwner = confirmedOwner
                    if (confirmedOwner != null) applicationScope.launch { retryDownloadRecovery(manager) }
                }
            }
        }
    }

    /**
     * Wire the VortX-account issuer and live consent invalidation. Legacy Source Index Boolean methods
     * remain closed; the repository-owned path supplies a captured native/account authorization.
     *
     * [MoatToken] reads the VortX account session bearer live through [sessionProvider], sourced from the
     * already-built [syncManager] (the api.vortx.tv identity, NOT the Stremio authKey). A null manager (sync
     * unavailable this launch) or a signed-out / opted-out device yields no credential, so the client stays
     * fail-closed and fail-soft.
     */
    private fun wireMoatGroundwork() {
        MoatToken.appContext = applicationContext
        MoatToken.sessionProvider = {
            syncManager?.currentSession()?.let { session ->
                MoatToken.SessionCredential(bearer = session.currentBearer, accountId = session.account.id)
            }
        }
        // Compatibility hook for the closed legacy API. The typed path uses its captured account admission.
        SourceIndexClient.moatTokenProvider = { MoatToken.current(isSignedIn = true) }
        com.vortx.android.player.subtitles.SubtitlePoolClient.moatTokenProvider = { MoatToken.current(it) }
        val preferences = getSharedPreferences("vortx_settings", Context.MODE_PRIVATE)
        sourceIndexConsentObserver = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == com.vortx.android.moat.MoatConsent.KEY) {
                com.vortx.android.singularity.SourceIndexLifecycle.invalidateDeferred()
            }
        }.also(preferences::registerOnSharedPreferenceChangeListener)
    }

    /** Issue provenance before the actual repository checkpoint, with no provider credential call. */
    private fun captureNativeLibraryMirrorOrigin(session: VortxNativeSession,
        owner: com.vortx.android.engine.VortxNativeOwner): com.vortx.android.engine.NativeLibraryMirrorOrigin? {
        val manager = syncManager ?: return null
        val mounted = nativeAccounts.captureLibraryMirrorMount(session) ?: return null
        if (com.vortx.android.integrations.NativeProviderVault.scope(mounted.account) != owner.scope.accountID) return null
        val original = manager.captureProviderMirrorCallAuthority() ?: return null
        // Verify persistence with the captured generation held, before the library dispatch.
        if (!original.admit { syncManager === manager && manager.sessionOwnerSnapshot() == mounted.account }) return null
        return com.vortx.android.engine.NativeLibraryMirrorOrigin(session, owner, mounted.account,
            { action -> original.admit { syncManager === manager && action() } }, mounted::admit, original.acquire)
    }

    /** Typed native mount plus persistence-backed VortX credential epoch, captured before any query. */
    private fun captureNativeSourceIndexAuthorization(session: VortxNativeSession,
        owner: com.vortx.android.engine.VortxNativeOwner): com.vortx.android.singularity.SourceIndexAuthorization? = runCatching {
        val manager = syncManager ?: return@runCatching null
        session.owned(owner) {
            val account = nativeAccounts.accountFor(session) ?: return@owned null
            if (manager.sessionOwnerSnapshot() != account ||
                com.vortx.android.integrations.NativeProviderVault.scope(account) != owner.scope.accountID) return@owned null
            val admission = manager.captureLocalLibraryMutationAdmission() ?: return@owned null
            com.vortx.android.singularity.SourceIndexLifecycle.issue(
                isCurrent = {
                    runCatching {
                        // Existing lock order: Session -> captured authenticated account -> mounted lifecycle.
                        session.owned(owner) {
                            admission {
                                syncManager === manager && manager.sessionOwnerSnapshot() == account &&
                                    nativeAccounts.withMountedSession(session, account) {
                                        com.vortx.android.moat.MoatConsent.contributeAndConsume(this) &&
                                            SourceIndexClient.serveEnabled && RemoteConfig.isFeatureOn("sourceIndex", true)
                                    }
                            }
                        }
                    }.getOrDefault(false)
                },
                moatProvider = { MoatToken.current(isSignedIn = true) },
            )
        }
    }.getOrNull()

    /** Both launchers can enter or leave foreground while encrypted account state is opening. */
    private fun wireAccountSync() {
        if (ProfileStore.sharedOrNull() == null) {
            _accountSyncStartup.value = AccountSyncStartup.Unavailable
            return
        }
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            // ActivityLifecycleCallbacks arrive on Main. The worker observes only the latest intent.
            private var startedActivities = 0

            override fun onActivityStarted(activity: Activity) {
                if (startedActivities++ == 0) accountForeground.value = AccountSyncForeground(active = true)
            }

            override fun onActivityStopped(activity: Activity) {
                if (startedActivities > 0 && --startedActivities == 0) {
                    accountForeground.value = AccountSyncForeground(active = false)
                }
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })

        applicationScope.launch {
            try {
                val manager = VortXSyncManager(this@VortXApplication) { syncManager === it }
                // The old Debrid binding performed this second secure read before exposing its owner.
                val confirmedOwner = manager.sessionOwnerSnapshot()
                DebridKeys.bindAccountOwnerSource {
                    if (syncManager !== manager) return@bindAccountOwnerSource DebridAccountOwnerState.UnknownOrUnavailable
                    when (val owner = manager.sessionOwnerSnapshot()) {
                        is SessionOwnerSnapshot.Account ->
                            DebridAccountOwnerState.Account(owner.id, owner.generation)
                        is SessionOwnerSnapshot.SignedOutLocal ->
                            DebridAccountOwnerState.SignedOutLocal(owner.generation)
                        is SessionOwnerSnapshot.UnknownOrUnavailable ->
                            DebridAccountOwnerState.UnknownOrUnavailable
                    }
                }
                DebridKeys.bindUsenetOwnerAdmission { owner, mutation ->
                    syncManager === manager && manager.mutateCurrentUsenetOwner(owner, mutation)
                }
                com.vortx.android.sync.AccountLibrarySync.bind(this@VortXApplication, manager)
                val startNativeWork = checkNotNull(manager.prepareNativeGateway(nativeAccounts, accountForeground, confirmedOwner))
                val pickerRestore = ApplicationAccountFileRestoreExclusion(this@VortXApplication, manager)
                ensureActive()
                publishAccountSync(manager, pickerRestore, confirmedOwner)
                startNativeWork()
                // For You switches between account fields and the signed-out local copy on sign-in.
                applicationScope.launch {
                    manager.account.collect {
                        com.vortx.android.foryou.ForYouStore.shared(this@VortXApplication).reload(invalidate = true)
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                Log.w(TAG, "Account sync setup failed this launch")
            } finally {
                _accountSyncStartup.compareAndSet(AccountSyncStartup.Preparing, AccountSyncStartup.Unavailable)
            }
        }
    }

    /// The one [CatalogRepository] the whole app shares, backed by the VortX engine session.
    val catalogRepository: CatalogRepository get() = nativeRepository

    /// The one [AuthRepository] the whole app shares, backed by the same engine session.
    val authRepository: AuthRepository get() = nativeStreamingAuth

    /// Coil3's app-wide [ImageLoader] (S03: real poster/backdrop art in [com.vortx.android.ui.
    /// components.PosterArt]). `crossfade(true)` matches DESIGN-SYSTEM.md's motion spec for image
    /// reveals; the memory cache is capped as a PERCENT of available RAM (not a flat byte count) so it
    /// scales sanely from a low-RAM Android TV stick to a flagship phone, and the disk cache is a
    /// bounded slice of free space under this app's own cache dir (OS-purgeable). The OkHttp network fetcher
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
    }
}
