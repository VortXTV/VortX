package com.vortx.android.sync

import android.content.SharedPreferences
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

/** Website roster receipt storage for the application's existing private sync-state preferences.
 * Callers still own the current account, request, storage, and transport admission. */
internal class NativeWebsiteRosterReceiptStore(private val prefs: SharedPreferences) {
    sealed interface State {
        data object Absent : State
        data class Present(val receipt: NativeWebsiteRosterDenialReceipt, val newlyReserved: Boolean = false) : State
        data object Unavailable : State
    }

    fun load(accountId: String, dataKey: ByteArray): State = guarded(accountId, dataKey) { name ->
        readCurrent(name, accountId, dataKey)
    }

    /** Same-value unresolved replay performs no write. A rejected value allows only a new base
     * at or above its durable readback floor; the caller must still authenticate that base. */
    fun retainFirst(accountId: String, dataKey: ByteArray, receipt: NativeWebsiteRosterDenialReceipt): State =
        guarded(accountId, dataKey) { name ->
            val encoded = receipt.encode()
            val pending = NativeWebsiteRosterDenialReceipt.decode(encoded, accountId, dataKey)
            if (pending.isDefinitivelyRejected || pending.minimumReadbackRevision != pending.targetRevision)
                return@guarded State.Unavailable
            when (val current = readCurrent(name, accountId, dataKey)) {
                is State.Present -> when {
                    current.receipt.encode() == encoded -> current
                    current.receipt.isDefinitivelyRejected &&
                        pending.originalRevision >= current.receipt.minimumReadbackRevision ->
                        writeConfirmed(name, accountId, dataKey, encoded, newlyReserved = true)
                    else -> State.Unavailable
                }
                State.Unavailable -> State.Unavailable
                State.Absent -> writeConfirmed(name, accountId, dataKey, encoded, newlyReserved = true)
            }
        }

    fun recordRejectedResponse(accountId: String, dataKey: ByteArray, expected: State.Present, readbackFloor: Long): State =
        guarded(accountId, dataKey) { name ->
            val current = readCurrent(name, accountId, dataKey) as? State.Present ?: return@guarded State.Unavailable
            if (current.receipt.encode() != expected.receipt.encode()) return@guarded State.Unavailable
            val updated = current.receipt.recordingRejectedResponse(accountId, dataKey, readbackFloor,
                resolvesSubmission = expected.newlyReserved)
            if (updated.encode() == current.receipt.encode()) current
            else writeConfirmed(name, accountId, dataKey, updated.encode(), newlyReserved = false)
        }

    private fun writeConfirmed(name: String, accountId: String, dataKey: ByteArray, encoded: String, newlyReserved: Boolean): State {
        // commit(false) may already have changed the cache. Hide that value from other readers,
        // including a synchronous preference listener, until the durable write is confirmed.
        unverifiedWrites.add(name)
        if (!prefs.edit().putString(name, encoded).commit()) return State.Unavailable
        val confirmed = readCurrent(name, accountId, dataKey) as? State.Present ?: return State.Unavailable
        if (confirmed.receipt.encode() != encoded) return State.Unavailable
        unverifiedWrites.remove(name)
        return confirmed.copy(newlyReserved = newlyReserved)
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
                val name = storageKey(accountId, dataKey)
                if (name in unverifiedWrites) State.Unavailable else block(name)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                State.Unavailable
            }
        }

    companion object {
        private const val KEY_PREFIX = "websiteRosterDenialReceipt."
        fun storageKey(accountId: String, dataKey: ByteArray): String =
            "$KEY_PREFIX$accountId.${NativeWebsiteRosterDenialReceipt.storageScope(accountId, dataKey)}"

        // SharedPreferences and its cached reads are process-local. Every manager in the main app
        // process uses this same reservation and an uncertain account stays blocked until restart.
        private val processLock = Any()
        private val unverifiedWrites = mutableSetOf<String>()
    }
}
