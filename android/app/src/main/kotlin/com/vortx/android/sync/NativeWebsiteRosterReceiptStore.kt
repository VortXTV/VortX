package com.vortx.android.sync

import android.content.SharedPreferences
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

/** First-receipt storage for the application's existing private sync-state preferences.
 * Callers still own the current account, request, storage, and transport admission. */
internal class NativeWebsiteRosterReceiptStore(private val prefs: SharedPreferences) {
    sealed interface State {
        data object Absent : State
        data class Present(val receipt: NativeWebsiteRosterDenialReceipt) : State
        data object Unavailable : State
    }

    fun load(accountId: String, dataKey: ByteArray): State = guarded(accountId, dataKey) { name ->
        readCurrent(name, accountId, dataKey)
    }

    /** A verified same-value retry performs no write. A different first value stays in place. */
    fun retainFirst(accountId: String, dataKey: ByteArray, receipt: NativeWebsiteRosterDenialReceipt): State =
        guarded(accountId, dataKey) { name ->
            val encoded = receipt.encode()
            when (val current = readCurrent(name, accountId, dataKey)) {
                is State.Present -> if (current.receipt.encode() == encoded) current else State.Unavailable
                State.Unavailable -> State.Unavailable
                State.Absent -> {
                    NativeWebsiteRosterDenialReceipt.decode(encoded, accountId, dataKey)
                    // commit(false) can already have changed the cache. Mark before invoking it so
                    // even a synchronous preference listener cannot see that value as confirmed.
                    unverifiedWrites.add(name)
                    if (!prefs.edit().putString(name, encoded).commit()) State.Unavailable
                    else {
                        val confirmed = readCurrent(name, accountId, dataKey)
                        if (confirmed is State.Present && confirmed.receipt.encode() == encoded) {
                            unverifiedWrites.remove(name)
                            confirmed
                        } else State.Unavailable
                    }
                }
            }
        }

    private fun readCurrent(name: String, accountId: String, dataKey: ByteArray): State {
        val values = prefs.all
        if (!values.containsKey(name)) return State.Absent
        val encoded = values[name] as? String ?: return State.Unavailable
        return State.Present(NativeWebsiteRosterDenialReceipt.decode(encoded, accountId, dataKey))
    }

    private inline fun guarded(accountId: String, dataKey: ByteArray, block: (String) -> State): State =
        synchronized(processLock) {
            try {
                if (dataKey.size != 32 || accountId.length != 36 || UUID.fromString(accountId).toString() != accountId) {
                    return@synchronized State.Unavailable
                }
                val name = KEY_PREFIX + accountId
                if (name in unverifiedWrites) State.Unavailable else block(name)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                State.Unavailable
            }
        }

    companion object {
        private const val KEY_PREFIX = "websiteRosterDenialReceipt."
        // SharedPreferences and its cached reads are process-local. Every manager in the main app
        // process uses this same reservation and an uncertain account stays blocked until restart.
        private val processLock = Any()
        private val unverifiedWrites = mutableSetOf<String>()
    }
}
