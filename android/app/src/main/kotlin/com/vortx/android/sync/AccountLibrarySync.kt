package com.vortx.android.sync

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.vortx.android.account.AccountSyncGate
import com.vortx.android.account.AccountWatchlistClient
import com.vortx.android.account.TitleRef
import com.vortx.android.integrations.SIMKLAuth
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.model.MediaType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * The WRITE half of two-way account<->Trakt/SIMKL WATCHLIST sync: it mirrors an account-library add/remove
 * out to the connected providers. The READ half (remote watchlist -> home rails) already ships in
 * [com.vortx.android.home.ExternalWatchlistModels]; together they are the two directions.
 *
 * WIRED at the account-library chokepoints only. The hook lives inside the `HistoryRoute.Engine` branch of
 * [com.vortx.android.engine.EngineStremioRepository]'s add/removeFromLibrary, which is the exact place an
 * ACCOUNT library mutation happens - an overlay profile takes the `HistoryRoute.Overlay` branch and never
 * reaches here. So this leg is already main-profile-only by construction; [AccountSyncGate] re-checks it
 * anyway (belt-and-suspenders, and it also guards [drainPending] which runs off a profile-change effect).
 * This mirrors the Apple `ScrobbleCoordinator.addedToLibrary` / `removedFromLibrary` (gated on
 * `passesOwnerGate` = `activeUsesEngineHistory`).
 *
 * FIRE-AND-FORGET: the public entry points are non-suspend and launch on a process-lifetime scope, so an
 * add fired from inside the engine's mutation fence never blocks it and completes on its own.
 *
 * FAIL-SOFT with an OFFLINE RETRY QUEUE (the Apple `TraktSyncEngine.PendingPush` analogue): a push that
 * fails while offline is persisted to a small, bounded, SESSION-TAGGED queue and retried on the next mirror
 * or on [drainPending]. Each queued entry carries the provider session epoch it was created under; a drain
 * drops any entry whose epoch no longer matches (a disconnect / account switch), so a queued push can never
 * drain into the NEXT account that signs in on this device.
 *
 * TOGGLES + KEYS: reuses [ScrobbleService]'s toggle store on the SAME keys the Apple + web clients use
 * ([ScrobbleService.KEY_TRAKT_WATCHLIST] / [ScrobbleService.KEY_SIMKL_WATCHLIST], both default ON), so the
 * choice rides the same cross-device carriage. No token is ever logged and no secret ever enters a URL.
 *
 * SIMKL asymmetry: SIMKL has no watchlist-remove endpoint, so a library REMOVE mirrors to Trakt only
 * (matching the Apple `SIMKLProvider.removeFromWatchlist` no-op); it is never routed to `/sync/history`.
 */
object AccountLibrarySync {

    private const val TAG = "AccountLibrarySync"
    private const val QUEUE_PREFS_FILE = "vortx_account_sync_queue"
    private const val QUEUE_KEY = "queue"
    private const val QUEUE_CAP = 200

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val queueMutex = Mutex()

    // MARK: - Public entry points (called from the engine library chokepoints)

    /** An account-library ADD was dispatched to the engine: mirror it to the connected watchlists. */
    fun onLibraryAdded(context: Context, type: MediaType, id: String) =
        mirror(context, add = true, TitleRef.from(id, type))

    /**
     * An account-library REMOVE was dispatched to the engine: mirror it to Trakt (SIMKL has no
     * watchlist-remove). [type] is null on the bare-id remove path; the Trakt remove then targets both
     * arrays (see [TitleRef]).
     */
    fun onLibraryRemoved(context: Context, id: String, type: MediaType?) =
        mirror(context, add = false, TitleRef.from(id, type))

    /**
     * Retry any queued offline pushes now. Safe to call freely (e.g. on the active-profile change effect at
     * launch); it no-ops for an overlay profile and when the queue is empty.
     */
    fun drainPending(context: Context) {
        if (!AccountSyncGate.activeProfileSyncsAccount()) return
        val appContext = context.applicationContext
        scope.launch { drain(queuePrefs(appContext)) }
    }

    // MARK: - Mirror

    private fun mirror(context: Context, add: Boolean, ref: TitleRef) {
        // Only the gate + a pure id parse run on the caller's thread (the engine mutation fence); every
        // prefs/token read and the network happen on the launched coroutine so the fence is never held for I/O.
        if (!AccountSyncGate.activeProfileSyncsAccount()) return
        if (!ref.hasUsableId) return
        val appContext = context.applicationContext
        scope.launch {
            // Idempotent: wires the toggle store + both auth token stores so the reads below are live.
            ScrobbleService.init(appContext)
            val prefs = queuePrefs(appContext)
            // Opportunistically retry earlier offline failures before pushing the new change.
            drain(prefs)
            pushTrakt(prefs, add, ref)
            if (add) pushSimkl(prefs, ref) // SIMKL has no watchlist-remove: a remove mirrors to Trakt only.
        }
    }

    /** Push one change to Trakt when connected + enabled; queue it on a network failure. */
    private suspend fun pushTrakt(prefs: SharedPreferences, add: Boolean, ref: TitleRef) {
        if (!TraktAuth.isSignedIn) return
        if (!ScrobbleService.isToggleOn(ScrobbleService.KEY_TRAKT_WATCHLIST, true)) return
        val epoch = TraktAuth.currentSessionEpoch ?: return
        val ok = AccountWatchlistClient.traktWatchlist(add, ref, epoch)
        if (!ok) {
            enqueue(prefs, QueuedPush(Provider.TRAKT, add, ref, epoch))
            Log.d(TAG, "trakt watchlist ${if (add) "add" else "remove"} queued for retry")
        }
    }

    /** Push one ADD to SIMKL when connected + enabled; queue it on a network failure. */
    private suspend fun pushSimkl(prefs: SharedPreferences, ref: TitleRef) {
        if (!SIMKLAuth.isSignedIn) return
        if (!ScrobbleService.isToggleOn(ScrobbleService.KEY_SIMKL_WATCHLIST, true)) return
        val epoch = SIMKLAuth.currentSessionEpoch ?: return
        val ok = AccountWatchlistClient.simklWatchlistAdd(ref, epoch)
        if (!ok) {
            enqueue(prefs, QueuedPush(Provider.SIMKL, add = true, ref, epoch))
            Log.d(TAG, "simkl watchlist add queued for retry")
        }
    }

    // MARK: - Offline retry queue

    private suspend fun enqueue(prefs: SharedPreferences, push: QueuedPush) = queueMutex.withLock {
        withContext(Dispatchers.IO) {
            val current = readQueue(prefs).toMutableList()
            // Idempotent adds: a queued duplicate (same provider/op/title/epoch) is not appended twice.
            if (current.none { it == push }) current += push
            writeQueue(prefs, current.takeLast(QUEUE_CAP))
        }
    }

    /**
     * Retry every queued push; keep only the ones that still fail with a live, matching session. Entries
     * whose provider is disconnected or whose epoch no longer matches are DROPPED (terminal), so a stale
     * push can never move one account's watchlist through another's credentials.
     */
    private suspend fun drain(prefs: SharedPreferences) = queueMutex.withLock {
        val queue = withContext(Dispatchers.IO) { readQueue(prefs) }
        if (queue.isEmpty()) return@withLock
        val survivors = ArrayList<QueuedPush>(queue.size)
        for (push in queue) {
            if (!attempt(push)) survivors.add(push)
        }
        withContext(Dispatchers.IO) { writeQueue(prefs, survivors.takeLast(QUEUE_CAP)) }
    }

    /** True when the push is HANDLED (drop from the queue): a success, or a terminal stale-session drop. */
    private suspend fun attempt(push: QueuedPush): Boolean {
        val ref = push.ref
        return when (push.provider) {
            Provider.TRAKT -> {
                val epoch = TraktAuth.currentSessionEpoch
                if (epoch == null || epoch != push.epoch) true // account changed/disconnected: terminal drop
                else AccountWatchlistClient.traktWatchlist(push.add, ref, epoch) // 2xx drops, failure keeps
            }
            Provider.SIMKL -> {
                if (!push.add) true // SIMKL has no watchlist-remove: nothing to do, drop
                else {
                    val epoch = SIMKLAuth.currentSessionEpoch
                    if (epoch == null || epoch != push.epoch) true
                    else AccountWatchlistClient.simklWatchlistAdd(ref, epoch)
                }
            }
        }
    }

    private fun queuePrefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(QUEUE_PREFS_FILE, Context.MODE_PRIVATE)

    private fun readQueue(prefs: SharedPreferences): List<QueuedPush> {
        val raw = prefs.getString(QUEUE_KEY, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val row = array.optJSONObject(index) ?: continue
                    QueuedPush.fromJson(row)?.let(::add)
                }
            }
        }.getOrDefault(emptyList())
    }

    private fun writeQueue(prefs: SharedPreferences, pushes: List<QueuedPush>) {
        val array = JSONArray().apply { pushes.forEach { put(it.toJson()) } }
        // commit(): the caller holds the mutex and is already on Dispatchers.IO; the write must reach the
        // backing store before the lock admits the next read-modify-write.
        prefs.edit().putString(QUEUE_KEY, array.toString()).commit()
    }

    private enum class Provider { TRAKT, SIMKL }

    private data class QueuedPush(
        val provider: Provider,
        val add: Boolean,
        val ref: TitleRef,
        val epoch: Long,
    ) {
        fun toJson(): JSONObject = JSONObject().apply {
            put("p", provider.name)
            put("add", add)
            ref.imdb?.let { put("imdb", it) }
            ref.tmdb?.let { put("tmdb", it) }
            ref.isSeries?.let { put("series", it) }
            put("epoch", epoch)
        }

        companion object {
            fun fromJson(row: JSONObject): QueuedPush? {
                val provider = runCatching { Provider.valueOf(row.optString("p")) }.getOrNull() ?: return null
                val ref = TitleRef(
                    imdb = row.optString("imdb").takeIf(String::isNotBlank),
                    tmdb = if (row.has("tmdb")) row.optInt("tmdb").takeIf { it != 0 } else null,
                    isSeries = if (row.has("series")) row.optBoolean("series") else null,
                )
                if (!ref.hasUsableId) return null
                return QueuedPush(
                    provider = provider,
                    add = row.optBoolean("add", true),
                    ref = ref,
                    epoch = row.optLong("epoch", -1L),
                )
            }
        }
    }
}
