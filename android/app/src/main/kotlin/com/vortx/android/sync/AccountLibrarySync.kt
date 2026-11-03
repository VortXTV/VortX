package com.vortx.android.sync

import android.content.Context
import android.os.Build
import android.util.Log
import com.vortx.android.VortXApplication
import com.vortx.android.account.AccountSyncGate
import com.vortx.android.account.AccountWatchlistClient
import com.vortx.android.account.TitleRef
import com.vortx.android.engine.NativeLibraryMirrorOrigin
import com.vortx.android.integrations.DurableProviderMirrorCredential
import com.vortx.android.integrations.SIMKLAuth
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.model.MediaType
import com.vortx.android.security.AccountFileProviderWriters
import com.vortx.android.sync.ProviderRetryOutbox.Provider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** Mirrors committed native library changes under the original account. The old unowned
 * preferences are preserved for existing-only Restore inspection and are never replayed. */
object AccountLibrarySync {
    private const val TAG = "AccountLibrarySync"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val handoffLock = Any()
    private val committedTail = mutableMapOf<SessionOwnerSnapshot.Account, CompletableDeferred<Unit>>()

    @Volatile private var installed: Installed? = null

    internal fun bind(application: VortXApplication, manager: VortXSyncManager) {
        installed = Installed(application, manager)
    }

    internal fun onLibraryAdded(context: Context, origin: NativeLibraryMirrorOrigin, type: MediaType, id: String) =
        mirror(context, origin, add = true, type, id)

    internal fun onLibraryRemoved(context: Context, origin: NativeLibraryMirrorOrigin, id: String, type: MediaType) =
        mirror(context, origin, add = false, type, id)

    fun drainPending(context: Context) {
        if (!supportsExistingVault() || !AccountSyncGate.activeProfileSyncsAccount()) return
        val current = installed?.takeIf { it.isAttached(context) } ?: return
        // Capture before scheduling. The worker may only open this original Session.
        val open = current.captureForeground() ?: return
        AccountFileProviderWriters.launchWriter(scope) {
            optional {
                val session = open() ?: return@optional
                session.use {
                    for (provider in Provider.entries) optional { current.coordinator.drain(session, provider) }
                }
            }
        }
    }

    private fun mirror(context: Context, origin: NativeLibraryMirrorOrigin, add: Boolean, type: MediaType, id: String) {
        if (!AccountSyncGate.activeProfileSyncsAccount() || (type != MediaType.MOVIE && type != MediaType.SERIES)) return
        val ref = TitleRef.from(id, type)
        if (!ref.hasUsableId) return
        val current = installed?.takeIf { it.isAttached(context) } ?: return
        // The native producer enrolls this handoff in the same monitor interval as its checkpoint.
        launchCommittedInOrder(origin.expectedAccount) {
            optional {
                if (!origin.admit { current.isAttached(context) && AccountSyncGate.activeProfileSyncsAccount() })
                    return@optional
                if (!supportsExistingVault()) {
                    // Keep the original online mirror on devices without authenticated existing-vault reads.
                    current.sendUnqueued(origin, Provider.TRAKT, add, ref)
                    if (add) current.sendUnqueued(origin, Provider.SIMKL, true, ref)
                    return@optional
                }
                val session = current.captureCommitted(origin) ?: return@optional
                session.use {
                    optional { current.submit(session, origin, Provider.TRAKT, add, ref) }
                    if (add) optional { current.submit(session, origin, Provider.SIMKL, true, ref) }
                }
            }
        }
    }

    private fun launchCommittedInOrder(owner: SessionOwnerSnapshot.Account, work: suspend () -> Unit) {
        val done = CompletableDeferred<Unit>()
        val predecessor = synchronized(handoffLock) { committedTail.put(owner, done) }
        fun release() {
            fun finish() {
                synchronized(handoffLock) {
                    if (committedTail[owner] === done) committedTail.remove(owner)
                }
                done.complete(Unit)
            }
            // A canceled waiting child still occupies its place until the original predecessor drains.
            if (predecessor == null) finish() else predecessor.invokeOnCompletion { finish() }
        }
        val child = try {
            AccountFileProviderWriters.launchWriter(scope) {
                predecessor?.await()
                work()
            }
        } catch (failure: Throwable) {
            release()
            throw failure
        }
        if (child == null) release() else child.invokeOnCompletion { release() }
    }

    private suspend fun optional(work: suspend () -> Unit) {
        try { work() }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { Log.d(TAG, "Provider watchlist mirror unavailable") }
    }

    private fun supportsExistingVault(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE

    private class Installed(private val app: VortXApplication, private val manager: VortXSyncManager) : ProviderRetryHost {
        private val outbox = manager.providerRetryOutbox
        val coordinator = ProviderRetryCoordinator(outbox, outbox)

        fun isAttached(context: Context): Boolean = context.applicationContext === app && app.syncManager === manager

        override fun captureCommitted(origin: NativeLibraryMirrorOrigin): ProviderRetrySession? {
            var open: (() -> VortXSyncManager.ProviderRetryOwner?)? = null
            if (!origin.admit {
                    if (!isAttached(app)) false
                    else manager.captureProviderRetryOwnerOpener(origin.expectedAccount).also { open = it } != null
                }) return null
            return open?.invoke()?.takeIf { isAttached(app) }?.let { Session(it, origin) }
        }

        override fun captureForeground(): (() -> ProviderRetrySession?)? {
            if (!isAttached(app)) return null
            val open = manager.captureProviderRetryOwnerOpener() ?: return null
            return { if (isAttached(app)) open()?.let { Session(it, null) } else null }
        }

        suspend fun submit(
            session: ProviderRetrySession, origin: NativeLibraryMirrorOrigin, provider: Provider, add: Boolean, ref: TitleRef,
        ) {
            if (!session.isEnabled(provider)) return
            val result = coordinator.submit(session, provider, add, ref)
            Log.d(TAG, "Provider watchlist mirror: ${result.name}")
            if (result == ProviderRetryCoordinator.Submit.Unavailable) {
                // An unreceipted credential may still send the fresh online intent. First prove this
                // exact lane is empty, so a fallback never overtakes retained or uncertain work.
                val lane = ProviderRetryOutbox.Lane(session.owner, provider)
                val missing = session.withDataKey { key ->
                    outbox.readHead(lane, key, session::requireCurrent) == ProviderRetryOutbox.Read.Missing
                }
                if (missing) sendUnqueued(origin, provider, add, ref)
            }
        }

        suspend fun sendUnqueued(origin: NativeLibraryMirrorOrigin, provider: Provider, add: Boolean, ref: TitleRef) {
            if (!origin.admit { isAttached(app) && AccountSyncGate.activeProfileSyncsAccount() } || !enabled(provider)) return
            when (provider) {
                Provider.TRAKT -> {
                    TraktAuth.init(app)
                    val epoch = TraktAuth.watchlistEpoch(origin.expectedAccount) ?: return
                    AccountWatchlistClient.traktWatchlist(add, ref, epoch, origin)
                }
                Provider.SIMKL -> if (add) {
                    SIMKLAuth.init(app)
                    val epoch = SIMKLAuth.watchlistEpoch(origin.expectedAccount) ?: return
                    AccountWatchlistClient.simklWatchlistAdd(ref, epoch, origin)
                }
            }
        }

        private fun enabled(provider: Provider): Boolean = ScrobbleService.watchlistEnabled(app, when (provider) {
            Provider.TRAKT -> ScrobbleService.KEY_TRAKT_WATCHLIST
            Provider.SIMKL -> ScrobbleService.KEY_SIMKL_WATCHLIST
        })

        private inner class Session(private val lease: VortXSyncManager.ProviderRetryOwner,
            private val origin: NativeLibraryMirrorOrigin?) : ProviderRetrySession {
            override val owner = lease.owner
            @Volatile private var closed = false

            override fun requireCurrent() {
                check(!closed && isAttached(app) && AccountSyncGate.activeProfileSyncsAccount())
                lease.requireCurrent()
            }

            override fun <T> withDataKey(block: (ByteArray) -> T): T {
                requireCurrent()
                return lease.withDataKey(block)
            }

            override fun isEnabled(provider: Provider): Boolean {
                requireCurrent()
                return enabled(provider)
            }

            override suspend fun prepareCredential(provider: Provider): ProviderRetryCredential? {
                val captured = withDataKey { key ->
                    when (provider) {
                        Provider.TRAKT -> TraktAuth.captureDurableWatchlistCredential(owner, owner.generation, key)
                        Provider.SIMKL -> SIMKLAuth.captureDurableWatchlistCredential(owner, owner.generation, key)
                    }
                } ?: return null
                return try {
                    requireCurrent()
                    Credential(captured)
                } catch (failure: Throwable) {
                    captured.close()
                    throw failure
                }
            }

            private inner class Credential(private val captured: DurableProviderMirrorCredential) : ProviderRetryCredential {
                override fun copyProof(): ByteArray = captured.copyProof() ?: ByteArray(0)

                override suspend fun dispatch(lane: ProviderRetryOutbox.Lane, row: ProviderRetryOutbox.Row,
                    start: ProviderRetryStart): ProviderRetryDispatchOutcome {
                    requireCurrent()
                    return AccountWatchlistClient.dispatchDurable(lane, row, start, lease, origin, captured)
                }

                override fun close() { captured.close() }
            }

            override fun close() { closed = true }
        }
    }
}
