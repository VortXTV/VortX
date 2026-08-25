package com.vortx.android.integrations

import android.util.Log
import com.vortx.android.account.AccountSyncGate
import com.vortx.android.model.MediaRef
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

/** WHY check-in audit row: advertise the active Trakt playback, then clear it on stop or title switch. */
internal object TraktCheckIn {
    private const val TAG = "TraktCheckIn"
    private val lock = Mutex()
    private var activeKey: String? = null
    @Volatile private var desiredKey: String? = null

    fun prepareStart(ref: MediaRef) {
        desiredKey = key(ref)
    }

    fun prepareStop(ref: MediaRef) {
        if (desiredKey == key(ref)) desiredKey = null
    }

    suspend fun started(ref: MediaRef) = lock.withLock {
        if (!AccountSyncGate.activeProfileSyncsAccount() || !TraktAuth.isSignedIn) return@withLock
        if (ref.isSeries && (ref.season == null || ref.episode == null)) return@withLock
        val enabled = ScrobbleService.isToggleOn(ScrobbleService.KEY_TRAKT_CHECKIN, false)
        val key = key(ref)
        if (desiredKey != key) return@withLock
        if (!enabled) {
            deleteLocked()
            return@withLock
        }
        if (activeKey == key) return@withLock
        deleteLocked()
        val response = TraktSyncSupport.request("POST", "/checkin", payload(ref).toString())
        if (response.isSuccess || response.status == 409) {
            activeKey = key
            if (desiredKey != key) deleteLocked()
        } else Log.d(TAG, "trakt checkin skipped: HTTP ${response.status}")
    }

    suspend fun stopped(ref: MediaRef) = lock.withLock {
        val key = key(ref)
        if (activeKey == key && desiredKey != key) deleteLocked()
    }

    private suspend fun deleteLocked() {
        if (activeKey == null) return
        if (TraktAuth.isSignedIn) {
            val response = TraktSyncSupport.request("POST", "/checkin/delete")
            if (!response.isSuccess) {
                Log.d(TAG, "trakt checkin/delete skipped: HTTP ${response.status}")
                return
            }
        }
        activeKey = null
    }

    private fun payload(ref: MediaRef): JSONObject = JSONObject().apply {
        if (ref.isSeries) {
            put("show", JSONObject().put("ids", ids(ref)))
            put("episode", JSONObject().put("season", ref.season).put("number", ref.episode))
        } else {
            put("movie", JSONObject().put("ids", ids(ref)))
        }
    }

    private fun ids(ref: MediaRef) = JSONObject().apply {
        ref.imdb?.takeIf { it.isNotBlank() }?.let { put("imdb", it) }
        ref.tmdb?.let { put("tmdb", it) }
    }

    private fun key(ref: MediaRef): String =
        "${if (ref.isSeries) "episode" else "movie"}:${ref.imdb ?: ref.tmdb}:${ref.season}:${ref.episode}"
}
