package com.vortx.android.sync

import android.content.Context
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

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
        return published(account, native, item) != null
    }

    @Synchronized fun published(account: String, native: NativeLibraryOwner, item: VortXSyncDoc.OwnerLibraryItem): VortXSyncDoc.OwnerLibraryItem? {
        val proof = load(account)?.optJSONObject(entryKey(native, item)) ?: return null
        if (proof.optString("raw") != fingerprint(item)) return null
        return proof.optJSONObject("outbound")?.let(::decode)
    }

    @Synchronized fun grant(account: String, native: NativeLibraryOwner, items: List<VortXSyncDoc.OwnerLibraryItem>): Boolean =
        grantProjected(account, native, items.map { it to it })

    @Synchronized fun grantProjected(account: String, native: NativeLibraryOwner, items: List<Pair<VortXSyncDoc.OwnerLibraryItem, VortXSyncDoc.OwnerLibraryItem>>): Boolean {
        if (items.isEmpty()) return true
        val ledger = load(account) ?: return false
        for ((raw, outbound) in items) {
            if (raw.identity != outbound.identity) return false
            ledger.put(entryKey(native, raw), JSONObject().put("raw", fingerprint(raw)).put("outbound", encode(outbound)))
        }
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

    @Synchronized fun pending(account: String, generation: String, identity: String, value: JSONObject?): Boolean {
        val key = accountKey(account) + ".pending"
        val prior = persistence.read(key)
        if (prior.isFailure) return false
        val root = prior.getOrNull()?.let { runCatching { JSONObject(it) }.getOrNull() ?: return false } ?: JSONObject()
        val operationKey = generation + '\u001f' + identity
        if (value == null) root.remove(operationKey) else root.put(operationKey, value)
        // Bounded diagnostic/recovery evidence. A new process never resumes an old lease generation.
        while (root.length() > 64) root.keys().asSequence().firstOrNull { it != operationKey }?.let(root::remove) ?: break
        val raw = root.toString()
        return persistence.write(key, raw) && persistence.read(key).getOrNull() == raw
    }

    private fun accountKey(account: String) = "owner." + digest(account)
    private fun entryKey(native: NativeLibraryOwner, item: VortXSyncDoc.OwnerLibraryItem) =
        digest(JSONArray().put(native.uid ?: JSONObject.NULL).put(item.type).put(item.metaId).toString())

    companion object {
        internal fun encode(item: VortXSyncDoc.OwnerLibraryItem): JSONObject = OwnerLibraryHistoryPolicy.encode(item, JSONObject())
            .put("v", item.videoId ?: JSONObject.NULL).put("lastWatched", item.lastWatched ?: JSONObject.NULL)
            .put("watched", item.watched ?: JSONObject.NULL).put("currentVideoWatched", item.currentVideoWatched ?: JSONObject.NULL)
            .put("timesWatched", item.timesWatched ?: JSONObject.NULL).put("wholeTitleWatched", item.wholeTitleWatched ?: JSONObject.NULL)
            .put("offsetMs", item.timeOffsetMs).put("durationMs", item.durationMs)
            .put("nativeEpoch", item.nativeEventEpochMs ?: JSONObject.NULL).put("historyOnly", item.historyOnly)
            .put("watchAuthority", item.declaredWatchFields?.let { JSONArray(it.sorted()) } ?: JSONObject.NULL)
            .put("removed", item.removed)

        internal fun decode(row: JSONObject): VortXSyncDoc.OwnerLibraryItem? {
            if (!row.has("watchAuthority") || row.opt("historyOnly") !is Boolean) return null
            val authority = if (row.isNull("watchAuthority")) null else {
                val array = row.optJSONArray("watchAuthority") ?: return null
                val fields = (0 until array.length()).map { array.opt(it) as? String ?: return null }
                if (fields.distinct().size != fields.size || fields.any { it !in setOf("watched", "currentVideoWatched", "timesWatched", "wholeTitleWatched") }) return null
                fields.toSet()
            }
            return VortXSyncDoc.ownerLibraryItem(row)?.copy(
            timeOffsetMs = OwnerLibraryHistoryPolicy.unsignedInteger(row.opt("offsetMs")) ?: return null,
            durationMs = OwnerLibraryHistoryPolicy.unsignedInteger(row.opt("durationMs")) ?: return null,
            nativeEventEpochMs = OwnerLibraryHistoryPolicy.unsignedInteger(row.opt("nativeEpoch")),
            historyOnly = row.optBoolean("historyOnly"),
            declaredWatchFields = authority,
            )
        }
        internal fun matchesRestored(request: VortXSyncDoc.OwnerLibraryItem, actual: VortXSyncDoc.OwnerLibraryItem): Boolean {
            val movieWatched = request.type == "movie" && request.wholeTitleWatched == true
            val count = request.timesWatched ?: if (movieWatched) 1L else 0L
            val flag = request.currentVideoWatched ?: movieWatched
            val expectedCurrentWatched = flag && request.videoId != null
            val expectedMovieWatched = request.wholeTitleWatched ?: (count > 0)
            return actual.identity == request.identity && actual.name == request.name && actual.poster == request.poster &&
                actual.videoId == request.videoId && actual.timeOffsetMs == request.timeOffsetMs && actual.durationMs == request.durationMs &&
                actual.nativeEventEpochMs == (request.conditionalHistory?.expected?.nativeEventEpochMs ?: OwnerLibraryHistoryPolicy.clock(request)) &&
                OwnerLibraryHistoryPolicy.watchClock(actual) == OwnerLibraryHistoryPolicy.watchClock(request) &&
                actual.watched == request.watched && actual.timesWatched == count && actual.removed == request.removed &&
                ((actual.currentVideoWatched == true) == expectedCurrentWatched) &&
                (request.type != "movie" || actual.wholeTitleWatched == expectedMovieWatched)
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
    @Volatile private var valid = true
    fun invalidate() {
        // Linearize replacement with a pending grant; never take a native lock from this callback.
        if (!admit { valid = false; true }) valid = false
    }
    fun isCurrent(): Boolean = valid && admit { true }
    private val generation = UUID.randomUUID().toString()
    private data class Pending(val native: NativeLibraryOwner, val previous: VortXSyncDoc.OwnerLibraryItem?,
        val owned: VortXSyncDoc.OwnerLibraryItem?, val operation: OwnerLibraryOperation,
        val candidate: () -> VortXSyncDoc.OwnerLibraryItem?, var expected: VortXSyncDoc.OwnerLibraryItem? = null)
    private val pending = mutableMapOf<String, Pending>()

    /** Persist the captured operation, not ownership. Restart creates a new generation and cannot adopt it. */
    fun mutateObserved(native: NativeLibraryOwner, identity: String, read: () -> List<VortXSyncDoc.OwnerLibraryItem>?,
        operation: OwnerLibraryOperation, candidate: () -> VortXSyncDoc.OwnerLibraryItem?, action: () -> Unit): Boolean = admit {
        if (!valid) return@admit false
        completePending(identity, read)
        val rows = read()?.filter { it.identity == identity }
        val previous = rows?.singleOrNull()
        val owned = previous?.let { proofs.published(account, native, it) }
        pending.remove(identity)
        val eligible = rows != null && (rows.isEmpty() || (previous != null && owned != null)) &&
            (operation.kind != OwnerLibraryOperation.Kind.MANUAL || owned != null || operation.manualInitial)
        val durable = eligible && proofs.pending(account, generation, identity, JSONObject()
            .put("nativeUid", native.uid ?: JSONObject.NULL).put("operation", operation.kind.name)
            .put("video", operation.video ?: JSONObject.NULL).put("position", operation.position).put("duration", operation.duration)
            .put("name", operation.name ?: JSONObject.NULL).put("poster", operation.poster ?: JSONObject.NULL)
            .put("manualWatched", operation.manualWatched ?: JSONObject.NULL).put("manualWhole", operation.manualWhole)
            .put("manualDirect", operation.manualDirect).put("manualInitial", operation.manualInitial)
            .put("progressInitial", operation.progressInitial)
            .put("manualInventory", JSONArray(operation.manualInventory)).put("manualVideos", JSONArray(operation.manualVideos.sorted()))
            .put("before", previous?.let(OwnerLibraryPublicationProofs::fingerprint) ?: JSONObject.NULL))
        action()
        if (!admit { true }) return@admit false
        if (durable) {
            pending[identity] = Pending(native, previous, owned, operation, candidate)
            completePending(identity, read)
        }
        true
    }

    fun completePending(identity: String, read: () -> List<VortXSyncDoc.OwnerLibraryItem>?): Boolean = admit {
        if (!valid) return@admit false
        val attempt = pending[identity] ?: return@admit true
        // Ctx may stamp mtime after the model first emits. Accept a refreshed model only if the
        // original operation's exact postcondition still holds; never substitute a disk-only row.
        val refreshed = attempt.candidate()?.takeIf { it.identity == identity &&
            attempt.operation.projection(attempt.previous, attempt.owned, it) != null &&
            (attempt.operation.kind != OwnerLibraryOperation.Kind.PROGRESS || attempt.expected == null ||
                OwnerLibraryHistoryPolicy.watchClock(it) == OwnerLibraryHistoryPolicy.watchClock(attempt.expected!!)) &&
            (it.nativeEventEpochMs ?: 0) >= (attempt.expected?.nativeEventEpochMs ?: 0) }
        val candidate = refreshed ?: attempt.expected ?: return@admit false
        if ((candidate.nativeEventEpochMs ?: 0) <= (attempt.previous?.nativeEventEpochMs ?: 0)) return@admit false
        val outbound = attempt.operation.projection(attempt.previous, attempt.owned, candidate) ?: return@admit false
        if (attempt.expected != candidate) {
            if (!proofs.pending(account, generation, identity, JSONObject().put("nativeUid", attempt.native.uid ?: JSONObject.NULL)
                    .put("candidate", OwnerLibraryPublicationProofs.encode(candidate)).put("outbound", OwnerLibraryPublicationProofs.encode(outbound)))) return@admit false
            attempt.expected = candidate
        }
        val disk = read()?.singleOrNull { it.identity == identity } ?: return@admit false
        if (OwnerLibraryPublicationProofs.fingerprint(disk) != OwnerLibraryPublicationProofs.fingerprint(candidate)) return@admit false
        if (!proofs.grantProjected(account, attempt.native, listOf(disk to outbound))) return@admit false
        pending.remove(identity)
        proofs.pending(account, generation, identity, null)
        true
    }
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
        if (canOwn && after != null && changed && validate(previous, after)) {
            val authorized = previous?.let { proofs.published(account, native, it) }
            val outgoing = if (authorized != null && after.removed != previous.removed)
                authorized.copy(removed = after.removed, eventEpochMs = after.nativeEventEpochMs)
            else after
            proofs.grantProjected(account, native, listOf(after to outgoing))
        }
        true
    }
}

/** Bridges separate UI invocation leases without recapturing an older operation's account/native owner. */
internal class OwnerLibraryPendingTransitions {
    private data class Capture(val owner: Any, val lease: OwnerLibraryPublicationLease)
    private val captures = ConcurrentHashMap<String, Capture>()

    fun record(identity: String, owner: Any, lease: OwnerLibraryPublicationLease) {
        captures[identity] = Capture(owner, lease)
        if (captures.size > 256) captures.keys.firstOrNull { it != identity }?.let(captures::remove)
    }

    /** Caller holds the native history fence; owner includes its exact profile/native revision. */
    fun completePrior(identity: String, owner: Any, read: () -> List<VortXSyncDoc.OwnerLibraryItem>?): Boolean {
        val captured = captures[identity] ?: return true
        if (captured.owner != owner || !captured.lease.isCurrent()) {
            captures.remove(identity, captured)
            return false
        }
        val complete = captured.lease.completePending(identity, read)
        if (complete) captures.remove(identity, captured)
        return complete
    }

    fun completed(identity: String, lease: OwnerLibraryPublicationLease) {
        captures[identity]?.takeIf { it.lease === lease }?.let { captures.remove(identity, it) }
    }
}
