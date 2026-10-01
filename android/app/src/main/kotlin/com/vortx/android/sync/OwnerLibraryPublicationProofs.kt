package com.vortx.android.sync

import android.content.Context
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** Unknown owner is represented by absence of this object; uid=null is a positively settled native owner. */
data class NativeLibraryOwner(val uid: String?)

data class AccountLibraryRestoreResult(val accepted: Boolean, val restored: List<VortXSyncDoc.OwnerLibraryItem> = emptyList())

internal interface LibraryProofPersistence {
    /** Failure is unavailable storage, success(null) is positively absent data. */
    fun read(key: String): Result<String?>
    fun write(key: String, value: String): Boolean
}

/** Encrypted, durable exact-event ownership. No account IDs, native IDs, or title IDs are logged. */
internal class OwnerLibraryPublicationProofs(private val persistence: LibraryProofPersistence) {
    constructor(context: Context) : this(object : LibraryProofPersistence {
        private val store = FailClosedCredentialStore(context, "vortx_library_publication", tag = "LibraryPublication")
        override fun read(key: String): Result<String?> {
            val snapshot = store.confirmedSnapshot(key)
            return if (snapshot.availability == PersistentCredentialAvailability.AVAILABLE) Result.success(snapshot.values[key])
            else Result.failure(IllegalStateException("Publication proof storage unavailable"))
        }
        override fun write(key: String, value: String): Boolean = store.set(key, value)
    })

    @Synchronized fun owns(account: String, native: NativeLibraryOwner, item: VortXSyncDoc.OwnerLibraryItem): Boolean {
        val ledger = load(account) ?: return false
        return ledger.opt(entryKey(native, item)) == fingerprint(item)
    }

    @Synchronized fun grant(account: String, native: NativeLibraryOwner, items: List<VortXSyncDoc.OwnerLibraryItem>): Boolean {
        if (items.isEmpty()) return true
        val ledger = load(account) ?: return false
        for (item in items) ledger.put(entryKey(native, item), fingerprint(item))
        val key = accountKey(account)
        val encoded = ledger.toString()
        if (!persistence.write(key, encoded)) return false
        return persistence.read(key).getOrNull() == encoded
    }

    private fun load(account: String): JSONObject? {
        val result = persistence.read(accountKey(account))
        if (result.isFailure) return null
        val encoded = result.getOrNull() ?: return JSONObject()
        return runCatching { JSONObject(encoded) }.getOrNull()
    }

    private fun accountKey(account: String) = "owner." + digest(account)
    private fun entryKey(native: NativeLibraryOwner, item: VortXSyncDoc.OwnerLibraryItem) =
        digest(JSONArray().put(native.uid ?: JSONObject.NULL).put(item.type).put(item.metaId).toString())

    companion object {
        internal fun matchesRestored(request: VortXSyncDoc.OwnerLibraryItem, actual: VortXSyncDoc.OwnerLibraryItem): Boolean {
            val movieWatched = request.type == "movie" && request.wholeTitleWatched == true
            val count = request.timesWatched ?: if (movieWatched) 1L else 0L
            val flag = request.currentVideoWatched ?: movieWatched
            return actual.identity == request.identity && actual.name == request.name && actual.poster == request.poster &&
                actual.videoId == request.videoId && actual.timeOffsetMs == request.timeOffsetMs && actual.durationMs == request.durationMs &&
                actual.nativeEventEpochMs == OwnerLibraryHistoryPolicy.clock(request) &&
                OwnerLibraryHistoryPolicy.watchClock(actual) == OwnerLibraryHistoryPolicy.watchClock(request) &&
                actual.watched == request.watched && actual.timesWatched == count && actual.removed == request.removed &&
                (actual.currentVideoWatched == true) == (flag && request.videoId != null) &&
                (request.type != "movie" || actual.wholeTitleWatched == (request.wholeTitleWatched ?: (count > 0)))
        }

        /** Ordered, zero/null-safe canonical payload. An epoch alone never proves the resident contents. */
        internal fun fingerprint(item: VortXSyncDoc.OwnerLibraryItem): String = digest(JSONArray()
            .put(item.type).put(item.metaId).put(item.name).put(item.poster ?: JSONObject.NULL)
            .put(item.videoId ?: JSONObject.NULL).put(item.timeOffsetMs).put(item.durationMs)
            .put(item.nativeEventEpochMs ?: OwnerLibraryHistoryPolicy.clock(item) ?: JSONObject.NULL)
            .put(OwnerLibraryHistoryPolicy.watchClock(item) ?: JSONObject.NULL)
            .put(item.watched ?: JSONObject.NULL).put(item.currentVideoWatched ?: JSONObject.NULL)
            .put(item.timesWatched ?: JSONObject.NULL).put(item.removed)
            .put(item.wholeTitleWatched ?: JSONObject.NULL).toString())

        private fun digest(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}

/** Captured before entering HistoryOwnerFence. The caller supplies a raw native reader under that fence. */
internal class OwnerLibraryPublicationLease(
    private val account: String,
    private val proofs: OwnerLibraryPublicationProofs,
    private val admit: ((() -> Boolean) -> Boolean),
) {
    fun mutate(
        native: NativeLibraryOwner, identity: String, read: () -> List<VortXSyncDoc.OwnerLibraryItem>?,
        validate: (VortXSyncDoc.OwnerLibraryItem?, VortXSyncDoc.OwnerLibraryItem) -> Boolean,
        action: () -> Unit,
    ): Boolean = admit {
        val before = read()
        val matches = before?.filter { it.identity == identity }
        val previous = matches?.singleOrNull()
        val canOwn = matches != null && (matches.isEmpty() || (previous != null && proofs.owns(account, native, previous)))
        action()
        if (!admit { true }) return@admit false
        val after = read()?.singleOrNull { it.identity == identity }
        // Unknown/colliding rows remain local. A partial operation cannot claim inherited fields.
        val changed = after != null && (after.nativeEventEpochMs ?: 0) > (previous?.nativeEventEpochMs ?: 0)
        if (canOwn && after != null && changed && validate(previous, after)) proofs.grant(account, native, listOf(after))
        true
    }
}
