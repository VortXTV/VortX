package com.vortx.android.sync

import com.vortx.android.diagnostics.DiagnosticsLog
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.vortx.android.backup.SettingsBackup
import com.vortx.android.data.AddonPrefsStore
import com.vortx.android.data.AddonTombstones
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridService
import com.vortx.android.engine.VortxJniBindings
import com.vortx.android.engine.AccountFileLocalPresence
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.metadata.MetadataProviderKeys
import com.vortx.android.security.AccountFileProviderWriters
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.DashboardProfileEdits
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URLEncoder
import java.net.URL
import java.util.Collections
import java.util.IdentityHashMap
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.ContinuationInterceptor
import okhttp3.Authenticator
import okhttp3.CookieJar
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okio.BufferedSink

/**
 * Publish the app-owned effective add-on removal set and its LWW stamps without replacing any other `vortx`
 * member. The timestamp map retains `addedAt` entries even when a URL is currently present: that is how a
 * later explicit reinstall beats an older removal on every peer instead of being re-tombstoned on the next pull.
 */
internal fun applyAddonTombstonesToVortx(
    vortx: JSONObject,
    tombstones: AddonTombstones,
): JSONObject {
    val removed = tombstones.all()
    if (removed.isNotEmpty()) {
        vortx.put("deletedAddons", JSONArray(removed.sorted()))
    } else {
        vortx.remove("deletedAddons")
    }
    val stamps = tombstones.timestampsForSync()
    if (stamps.isNotEmpty()) {
        val encoded = JSONObject()
        for (url in stamps.keys.sorted()) {
            val entry = JSONObject()
            stamps[url]?.get("removedAt")?.let { entry.put("removedAt", it) }
            stamps[url]?.get("addedAt")?.let { entry.put("addedAt", it) }
            if (entry.length() > 0) encoded.put(url, entry)
        }
        vortx.put("deletedAddonsTs", encoded)
    } else {
        vortx.remove("deletedAddonsTs")
    }
    return vortx
}

/**
 * The add-on portion of `syncDown`: a successfully authenticated and decrypted account doc always advances its
 * monotone LWW tombstone state before `syncDown` decides whether its versioned payload is safe to apply. An
 * older document is deliberately scoped to this fold alone, preserving the H-2 rollback barrier for every other
 * account field. Keeping this as a production seam makes that boundary directly testable.
 */
internal data class AddonTombstoneSyncDownFold(
    val changed: Boolean,
    val shouldFoldLibraryTombstones: Boolean,
    val shouldApplyVersionedPayload: Boolean,
)

internal fun foldAddonTombstonesForSyncDown(
    tombstones: AddonTombstones,
    parsed: VortXSyncDoc.Parsed,
    pulledVersion: Long,
    lastSyncedVersion: Long,
    force: Boolean,
): AddonTombstoneSyncDownFold {
    val appChanged = if (parsed.deletedAddons.isEmpty() && parsed.deletedAddonsTs.isEmpty()) {
        false
    } else {
        tombstones.merge(parsed.deletedAddons, parsed.deletedAddonsTs)
    }
    val webChanged = if (parsed.webAddonRemovals.isEmpty()) {
        false
    } else {
        tombstones.merge(
            legacyIds = emptyList(),
            stamps = emptyMap(),
            webIds = parsed.webAddonRemovals,
        )
    }
    return AddonTombstoneSyncDownFold(
        changed = appChanged || webChanged,
        shouldFoldLibraryTombstones = pulledVersion >= lastSyncedVersion,
        shouldApplyVersionedPayload =
            pulledVersion > lastSyncedVersion || (force && pulledVersion == lastSyncedVersion),
    )
}

internal const val INITIAL_SESSION_OWNER_EPOCH = 1L

/** Injectable transport used only by local production-path sync tests. */
internal typealias SyncRequestTestSeam = suspend (
    method: String,
    path: String,
    body: JSONObject?,
    bearerToken: String?,
) -> Pair<Int, JSONObject?>

/** Header-aware local transport seam; the normal production transport remains below. */
internal typealias ConditionalSyncRequestTestSeam = suspend (
    method: String, path: String, body: JSONObject?, bearerToken: String?, ifNoneMatch: String?,
) -> Triple<Int, JSONObject?, String?>

/** Opaque native-owner fence. A gateway may only use a lease it captured for the current engine account. */
interface AccountAddonGatewayLease

/** Native engine boundary: sync owns account semantics; the repository owns descriptors and native actions. */
interface AccountAddonSyncGateway {
    /** Captures the native account UID/profile generation which must still own every later dispatch. */
    fun captureAccountAddonLease(): AccountAddonGatewayLease?
    fun nativeAddonOwner(nativeLease: AccountAddonGatewayLease): NativeLibraryOwner? = null
    suspend fun accountAddonSnapshot(nativeLease: AccountAddonGatewayLease): List<VortXSyncDoc.AddonDescriptor>
    suspend fun installAccountAddon(
        nativeLease: AccountAddonGatewayLease,
        descriptor: VortXSyncDoc.AddonDescriptor,
        admit: ((() -> Boolean) -> Boolean),
    ): Boolean
    suspend fun removeAccountAddon(
        nativeLease: AccountAddonGatewayLease,
        normalizedTransportUrl: String,
        admit: ((() -> Boolean) -> Boolean),
    ): Boolean
    suspend fun applyRemoteAddonOrder(nativeLease: AccountAddonGatewayLease, order: List<String>, admit: ((() -> Boolean) -> Boolean)): Boolean
}

/** Owner-library boundary: positive reads and receipt-validated restores share the account admission lock. */
interface AccountLibrarySyncGateway {
    fun captureAccountLibraryLease(): AccountAddonGatewayLease?
    fun nativeLibraryOwner(nativeLease: AccountAddonGatewayLease): NativeLibraryOwner? = null
    suspend fun ownerWatchedChanged(nativeLease: AccountAddonGatewayLease, admit: ((() -> Boolean) -> Boolean)): Boolean = admit { true }
    /** Null means native state is not positively ready; an empty list means a confirmed empty library. */
    suspend fun accountLibrarySnapshot(nativeLease: AccountAddonGatewayLease, admit: ((() -> Boolean) -> Boolean)): List<VortXSyncDoc.OwnerLibraryItem>?
    suspend fun addAccountLibraryItems(
        nativeLease: AccountAddonGatewayLease,
        items: List<VortXSyncDoc.OwnerLibraryItem>,
        admit: ((() -> Boolean) -> Boolean),
    ): Boolean
    suspend fun restoreAccountLibraryItems(nativeLease: AccountAddonGatewayLease, items: List<VortXSyncDoc.OwnerLibraryItem>, admit: ((() -> Boolean) -> Boolean)): AccountLibraryRestoreResult =
        AccountLibraryRestoreResult(addAccountLibraryItems(nativeLease, items, admit))
}

/**
 * Publishes a session value only after its encrypted persistence mutation succeeds. Failed replacement
 * and clear operations leave [value] unchanged, so live state and restart state cannot disagree.
 */
internal class DurableSessionState<T>(
    initialValue: T?,
    initialOwnerEpoch: Long,
    private val persist: (T, Long) -> Boolean,
    clear: (Long) -> Boolean,
    private val ownerTransition: ((() -> Boolean) -> Boolean) = { mutation -> mutation() },
) {
    private val clearDurably = clear

    @Volatile
    var value: T? = initialValue
        private set

    @Volatile
    var ownerEpoch: Long = initialOwnerEpoch
        private set

    constructor(
        initialValue: T?,
        persist: (T) -> Boolean,
        clear: () -> Boolean,
        ownerTransition: ((() -> Boolean) -> Boolean) = { mutation -> mutation() },
    ) : this(
        initialValue = initialValue,
        initialOwnerEpoch = INITIAL_OWNER_EPOCH,
        persist = { candidate, _ -> persist(candidate) },
        clear = { _ -> clear() },
        ownerTransition = ownerTransition,
    )

    fun replace(candidate: T, publish: () -> Unit = {}): Boolean {
        check(!Thread.holdsLock(this)) {
            "replace must acquire the owner transition before the session monitor"
        }
        return ownerTransition {
            com.vortx.android.player.PlaybackOwnerEpoch.transition {
                synchronized(this) {
                    val nextOwnerEpoch = nextOwnerEpoch() ?: return@synchronized false
                    if (!persist(candidate, nextOwnerEpoch)) {
                        false
                    } else {
                        value = candidate
                        ownerEpoch = nextOwnerEpoch
                        publish()
                        true
                    }
                }
            }
        }
    }

    fun clear(publish: () -> Unit = {}): Boolean {
        check(!Thread.holdsLock(this)) {
            "clear must acquire the owner transition before the session monitor"
        }
        return ownerTransition {
            com.vortx.android.player.PlaybackOwnerEpoch.transition {
                synchronized(this) {
                    val nextOwnerEpoch = nextOwnerEpoch() ?: return@synchronized false
                    if (!clearDurably(nextOwnerEpoch)) {
                        false
                    } else {
                        value = null
                        ownerEpoch = nextOwnerEpoch
                        publish()
                        true
                    }
                }
            }
        }
    }

    @Synchronized
    fun restore(candidate: T?, restoredOwnerEpoch: Long = ownerEpoch) {
        value = candidate
        ownerEpoch = restoredOwnerEpoch
    }

    /**
     * Serialize a persistence read/reconcile with [replace] and [clear]. Mutations acquire their owner-transition
     * transaction before this monitor and must not be called from [block]. This closes the stale-load race where a
     * restore loaded account A, sign-out durably cleared A, and the delayed restore then published A back into memory.
     */
    @Synchronized
    fun <R> serialized(block: () -> R): R = block()

    @Synchronized
    fun matches(expectedOwnerEpoch: Long, predicate: (T?) -> Boolean): Boolean =
        ownerEpoch == expectedOwnerEpoch && predicate(value)

    private fun nextOwnerEpoch(): Long? =
        ownerEpoch.takeIf { it in 0 until Long.MAX_VALUE }?.plus(1L)

    private companion object {
        const val INITIAL_OWNER_EPOCH = INITIAL_SESSION_OWNER_EPOCH
    }
}

internal sealed interface SessionOwnerSnapshot {
    val generation: Long

    data class UnknownOrUnavailable(override val generation: Long) : SessionOwnerSnapshot
    data class SignedOutLocal(override val generation: Long) : SessionOwnerSnapshot
    data class Account(val id: String, override val generation: Long) : SessionOwnerSnapshot
}

/** Stable identity of the exact captured command scope; deliberately has no value-bearing toString. */
internal class LocalLibraryMutationIdentity(
    private val manager: Any,
    private val session: Any?,
    private val operationGeneration: Long,
    private val ownerEpoch: Long,
) {
    override fun equals(other: Any?): Boolean = other is LocalLibraryMutationIdentity &&
        manager === other.manager && session === other.session &&
        operationGeneration == other.operationGeneration && ownerEpoch == other.ownerEpoch
    override fun hashCode(): Int = (((System.identityHashCode(manager) * 31 + System.identityHashCode(session)) * 31 +
        operationGeneration.hashCode()) * 31 + ownerEpoch.hashCode())
}

/** A command gate and its independently comparable original identity; neither can be refreshed in place. */
internal class LocalLibraryMutationAuthority internal constructor(
    internal val identity: Any,
    private val admission: (() -> Boolean) -> Boolean,
) {
    fun admit(action: () -> Boolean): Boolean = admission(action)
}

internal sealed interface SessionMutationResult<out T> {
    data object Stale : SessionMutationResult<Nothing>
    data class Applied<T>(val value: T) : SessionMutationResult<T>
}

/**
 * One lock guards distinct auth-response and session-work generations. Starting a later auth invalidates only
 * older auth responses, while a committed owner mutation invalidates session work. Sign-out advances both before
 * its clear, even when secure storage rejects the clear and the durable owner must remain unchanged.
 */
internal class SessionOperationCoordinator {
    private val lock = Any()
    private var authGeneration = 0L
    @Volatile
    private var sessionGeneration = 0L
    private val _accountRevision = MutableStateFlow(0L)
    val accountRevision: StateFlow<Long> = _accountRevision.asStateFlow()
    private val _pickerAuthorityRevision = MutableStateFlow(0L)
    val pickerAuthorityRevision: StateFlow<Long> = _pickerAuthorityRevision.asStateFlow()
    private fun notifyPickerAuthorityChangedLocked() {
        _pickerAuthorityRevision.value = nextGeneration(_pickerAuthorityRevision.value)
    }
    private val activeCalls: MutableSet<OutboundCallPermit> =
        Collections.newSetFromMap(IdentityHashMap())

    fun beginAuth(): AuthOperation = checkNotNull(beginAuthIf { true })

    fun beginAuthIf(admitted: () -> Boolean): AuthOperation? {
        var cancellations = emptyList<() -> Unit>()
        val operation = synchronized(lock) {
            if (!admitted()) return@synchronized null
            authGeneration = nextGeneration(authGeneration)
            notifyPickerAuthorityChangedLocked()
            cancellations = retireCallsLocked { it.owner == OutboundCallOwner.AUTH }
            AuthOperation(authGeneration)
        }
        cancelCalls(cancellations)
        return operation
    }

    fun <T> invalidate(mutation: () -> T): T {
        var cancellations = emptyList<() -> Unit>()
        return com.vortx.android.player.PlaybackOwnerEpoch.transition {
            try {
                synchronized(lock) {
                    authGeneration = nextGeneration(authGeneration)
                    sessionGeneration = nextGeneration(sessionGeneration)
                    cancellations = retireCallsLocked { true }
                    try { mutation() } finally { _accountRevision.value = sessionGeneration; notifyPickerAuthorityChangedLocked() }
                }
            } finally {
                cancelCalls(cancellations)
            }
        }
    }

    /** Guard BEFORE retiring playback/auth/session work; stale confirmation changes no authority.
     * Cancellation callbacks still run after releasing the operations monitor, as in invalidate. */
    fun <T> invalidateIfAuthorityCurrent(
        expectedAuth: Long,
        expectedSession: Long,
        validate: () -> Boolean,
        mutation: () -> T,
    ): SessionMutationResult<T> {
        var cancellations = emptyList<() -> Unit>()
        return try {
            synchronized(lock) {
                if (authGeneration != expectedAuth || sessionGeneration != expectedSession || !validate()) {
                    SessionMutationResult.Stale
                } else com.vortx.android.player.PlaybackOwnerEpoch.transition {
                    authGeneration = nextGeneration(authGeneration)
                    sessionGeneration = nextGeneration(sessionGeneration)
                    cancellations = retireCallsLocked { true }
                    try { SessionMutationResult.Applied(mutation()) }
                    finally { _accountRevision.value = sessionGeneration; notifyPickerAuthorityChangedLocked() }
                }
            }
        } finally { cancelCalls(cancellations) }
    }

    fun <T> snapshot(read: (Long) -> T): T = synchronized(lock) {
        read(sessionGeneration)
    }

    /** Capture both authorities without changing auth or durable-session transition semantics. */
    fun <T> snapshotAuthority(read: (authGeneration: Long, sessionGeneration: Long) -> T): T =
        synchronized(lock) { read(authGeneration, sessionGeneration) }

    fun isCurrent(expectedGeneration: Long): Boolean = synchronized(lock) {
        sessionGeneration == expectedGeneration
    }

    fun isCurrentSnapshot(expectedGeneration: Long): Boolean =
        sessionGeneration == expectedGeneration

    fun <T> mutateIfCurrent(
        expectedGeneration: Long,
        mutation: () -> T,
    ): SessionMutationResult<T> = synchronized(lock) {
        if (sessionGeneration != expectedGeneration) {
            SessionMutationResult.Stale
        } else {
            SessionMutationResult.Applied(mutation())
        }
    }

    fun acquireSessionCallPermit(
        expectedGeneration: Long,
        validate: () -> Boolean,
    ): OutboundCallPermit? = synchronized(lock) {
        if (sessionGeneration != expectedGeneration || !validate()) {
            null
        } else {
            registerCallLocked(OutboundCallOwner.SESSION, expectedGeneration)
        }
    }

    internal inner class AuthOperation internal constructor(
        private val expectedAuthGeneration: Long,
    ) {
        fun isCurrent(): Boolean = synchronized(lock) {
            authGeneration == expectedAuthGeneration
        }

        fun acquireCallPermit(): OutboundCallPermit? = synchronized(lock) {
            if (authGeneration != expectedAuthGeneration) {
                null
            } else {
                registerCallLocked(OutboundCallOwner.AUTH, expectedAuthGeneration)
            }
        }

        fun commitSessionMutation(
            onCommitted: () -> Unit = {},
            mutation: () -> Boolean,
        ): SessionMutationResult<Boolean> {
            var cancellations = emptyList<() -> Unit>()
            return try {
                synchronized(lock) {
                    if (authGeneration != expectedAuthGeneration) {
                        SessionMutationResult.Stale
                    } else {
                        com.vortx.android.player.PlaybackOwnerEpoch.transition {
                            val nextSessionGeneration = nextGeneration(sessionGeneration)
                            val committed = mutation()
                            if (committed) {
                                sessionGeneration = nextSessionGeneration
                                cancellations = retireCallsLocked {
                                    it.owner == OutboundCallOwner.SESSION
                                }
                                onCommitted()
                                _accountRevision.value = sessionGeneration
                                notifyPickerAuthorityChangedLocked()
                            }
                            SessionMutationResult.Applied(committed)
                        }
                    }
                }
            } finally {
                cancelCalls(cancellations)
            }
        }
    }

    internal inner class OutboundCallPermit internal constructor(
        internal val owner: OutboundCallOwner,
        private val expectedGeneration: Long,
    ) {
        internal var cancellation: (() -> Unit)? = null

        fun isCurrent(): Boolean = synchronized(lock) {
            isPermitCurrentLocked(this)
        }

        fun attachCancellation(cancellation: () -> Unit): Boolean = synchronized(lock) {
            if (!isPermitCurrentLocked(this)) {
                false
            } else {
                this.cancellation = cancellation
                true
            }
        }

        fun close() {
            synchronized(lock) {
                activeCalls.remove(this)
                cancellation = null
            }
        }

        internal fun matchesGeneration(): Boolean = when (owner) {
            OutboundCallOwner.AUTH -> authGeneration == expectedGeneration
            OutboundCallOwner.SESSION -> sessionGeneration == expectedGeneration
        }
    }

    internal enum class OutboundCallOwner {
        AUTH,
        SESSION,
    }

    private fun registerCallLocked(
        owner: OutboundCallOwner,
        generation: Long,
    ): OutboundCallPermit =
        OutboundCallPermit(owner, generation).also(activeCalls::add)

    private fun isPermitCurrentLocked(permit: OutboundCallPermit): Boolean =
        permit in activeCalls && permit.matchesGeneration()

    private fun retireCallsLocked(
        shouldRetire: (OutboundCallPermit) -> Boolean,
    ): List<() -> Unit> = buildList {
        val iterator = activeCalls.iterator()
        while (iterator.hasNext()) {
            val permit = iterator.next()
            if (shouldRetire(permit)) {
                permit.cancellation?.let(::add)
                permit.cancellation = null
                iterator.remove()
            }
        }
    }

    private fun cancelCalls(cancellations: List<() -> Unit>) {
        cancellations.forEach { cancellation -> runCatching(cancellation) }
    }

    private fun nextGeneration(current: Long): Long =
        checkNotNull(current.takeIf { it < Long.MAX_VALUE }?.plus(1L)) {
            "Session operation generation exhausted"
        }
}

internal class SyncSessionLease(
    val operationGeneration: Long,
    val ownerEpoch: Long,
    val accountId: String,
    val token: String,
    dataKey: ByteArray,
    private val transportBearer: () -> String = { token },
) {
    /** Bound to the original Session; callers retain their existing owner/epoch admission. */
    fun currentBearer(): String = transportBearer()

    private val immutableDataKey = dataKey.copyOf()

    fun dataKeyCopy(): ByteArray = immutableDataKey.copyOf()

    fun matchesDataKey(candidate: ByteArray): Boolean =
        java.security.MessageDigest.isEqual(immutableDataKey, candidate)
}

internal fun sessionTruthMatches(
    left: VortXSyncManager.Session?,
    right: VortXSyncManager.Session?,
): Boolean {
    if (left == null || right == null) return left == null && right == null
    return left.currentBearer == right.currentBearer &&
        left.account == right.account &&
        left.dataKey.contentEquals(right.dataKey)
}

internal suspend fun runPendingSyncRetryLoop(
    initialDelayMs: Long,
    maxDelayMs: Long,
    shouldContinue: () -> Boolean,
    wait: suspend (Long) -> Unit,
    attempt: suspend () -> Boolean,
    resetDelay: () -> Boolean = { false },
): Boolean {
    require(initialDelayMs > 0 && maxDelayMs >= initialDelayMs)
    var retryDelayMs = initialDelayMs
    while (shouldContinue()) {
        wait(retryDelayMs)
        if (!shouldContinue()) return false
        val succeeded = attempt()
        if (succeeded) return true
        if (!shouldContinue()) return false
        retryDelayMs = if (resetDelay()) initialDelayMs else
            if (retryDelayMs > maxDelayMs / 2) maxDelayMs else retryDelayMs * 2
    }
    return false
}

internal fun shouldResumeRetainedRealtime(
    hadActiveRealtime: Boolean,
    retainedSessionIsCurrent: Boolean,
): Boolean = hadActiveRealtime && retainedSessionIsCurrent

internal data class PendingSyncOwner(
    val operationGeneration: Long,
    val ownerEpoch: Long,
    val accountId: String,
    val token: String,
)

internal class PendingSyncAttempt internal constructor(
    val owner: PendingSyncOwner,
) {
    @Volatile
    internal var job: Job? = null
    internal var editGeneration = 1L
    /** Guarded by [DurablePendingSyncState]'s lock, like [editGeneration]. */
    internal val window = ProgressUploadWindow()
    /** Wakes a worker that is only sitting out a playback-progress window when a real edit arrives. */
    internal val urgentWake = Channel<Unit>(Channel.CONFLATED)
}

internal data class PendingSyncClaim(
    val blockPull: Boolean,
    val attemptToStart: PendingSyncAttempt? = null,
    val replacedJob: Job? = null,
)

internal enum class PendingMarkerTruth {
    CLEAN_CONFIRMED,
    DIRTY_CONFIRMED,
    DIRTY_UNCONFIRMED,
    READ_UNKNOWN,
}

/**
 * Serializes the per-account durable dirty bit with ownership of the one pending coroutine. Persistence
 * callbacks run under this dedicated lock, never under the auth/session coordinator.
 */
internal class DurablePendingSyncState(
    private val readDirty: (String) -> Boolean,
    private val writeDirty: (String, Boolean) -> Boolean,
) {
    private val lock = Any()
    private val truthByAccount = mutableMapOf<String, PendingMarkerTruth>()
    private var owner: PendingSyncOwner? = null
    private var attempt: PendingSyncAttempt? = null

    fun recordEdit(
        nextOwner: PendingSyncOwner,
        nextAttempt: PendingSyncAttempt,
        progressOnly: Boolean = false,
        nowMs: Long = System.nanoTime() / 1_000_000L,
    ): PendingSyncClaim = synchronized(lock) {
        // Synchronous durable write precedes creation and start of the debounce coroutine.
        truthByAccount[nextOwner.accountId] = if (writeMarker(nextOwner.accountId, true)) {
            PendingMarkerTruth.DIRTY_CONFIRMED
        } else {
            // A failed SharedPreferences commit may still mutate its process-local cache. Remember the
            // uncertainty and never trust a same-process read as proof of restart durability.
            PendingMarkerTruth.DIRTY_UNCONFIRMED
        }
        val current = attempt
        if (owner == nextOwner && current?.job?.let { !it.isCancelled && !it.isCompleted } == true) {
            check(current.editGeneration < Long.MAX_VALUE) { "Pending edit generation exhausted" }
            current.editGeneration++
            current.window.record(current.editGeneration, progressOnly, nowMs)
            // A continuing stream of edits must not postpone the first upload forever, and a real edit
            // must not wait behind a playback-progress window. Do not cancel a PUT either: its exact
            // snapshot will be acknowledged independently.
            if (!progressOnly) current.urgentWake.trySend(Unit)
            return@synchronized PendingSyncClaim(blockPull = true)
        }
        val replaced = attempt?.job
        owner = nextOwner
        attempt = nextAttempt
        nextAttempt.window.record(nextAttempt.editGeneration, progressOnly, nowMs)
        PendingSyncClaim(blockPull = true, attemptToStart = nextAttempt, replacedJob = replaced)
    }

    /** The wait before this attempt's next upload; null once it no longer owns the pending state. */
    fun uploadWait(
        expectedAttempt: PendingSyncAttempt,
        job: Job,
        nowMs: Long,
        urgentDelayMs: Long,
        failureBackoffMs: Long?,
    ): UploadWait? = synchronized(lock) {
        if (owner == expectedAttempt.owner && attempt === expectedAttempt && expectedAttempt.job === job) {
            expectedAttempt.window.nextDelayMs(nowMs, urgentDelayMs, failureBackoffMs)
        } else {
            null
        }
    }

    /** An accepted upload covered edits up to [uploadedGeneration]; later progress opens a fresh window. */
    fun acknowledgeUpload(expectedAttempt: PendingSyncAttempt, job: Job, uploadedGeneration: Long) {
        synchronized(lock) {
            if (owner == expectedAttempt.owner && attempt === expectedAttempt && expectedAttempt.job === job) {
                expectedAttempt.window.acknowledge(uploadedGeneration, expectedAttempt.editGeneration)
            }
        }
    }

    fun claimRestored(
        nextOwner: PendingSyncOwner,
        nextAttempt: PendingSyncAttempt,
    ): PendingSyncClaim = synchronized(lock) {
        when (resolveTruth(nextOwner.accountId)) {
            PendingMarkerTruth.CLEAN_CONFIRMED ->
                return@synchronized PendingSyncClaim(blockPull = false)
            PendingMarkerTruth.READ_UNKNOWN ->
                return@synchronized PendingSyncClaim(blockPull = true)
            PendingMarkerTruth.DIRTY_CONFIRMED,
            PendingMarkerTruth.DIRTY_UNCONFIRMED,
            -> Unit
        }
        val current = attempt
        if (
            owner == nextOwner &&
            current?.job?.let { !it.isCancelled && !it.isCompleted } == true
        ) {
            PendingSyncClaim(blockPull = true)
        } else {
            val replaced = current?.job
            owner = nextOwner
            attempt = nextAttempt
            PendingSyncClaim(blockPull = true, attemptToStart = nextAttempt, replacedJob = replaced)
        }
    }

    fun attachJob(
        expectedAttempt: PendingSyncAttempt,
        job: Job,
    ): Boolean = synchronized(lock) {
        if (attempt !== expectedAttempt || owner != expectedAttempt.owner) {
            false
        } else {
            expectedAttempt.job = job
            true
        }
    }

    fun owns(
        expectedAttempt: PendingSyncAttempt,
        job: Job,
    ): Boolean = synchronized(lock) {
        truthByAccount[expectedAttempt.owner.accountId].isDirty() &&
            owner == expectedAttempt.owner &&
            attempt === expectedAttempt &&
            expectedAttempt.job === job
    }

    fun ensureMarker(
        expectedAttempt: PendingSyncAttempt,
        job: Job,
    ): Boolean = synchronized(lock) {
        if (
            owner != expectedAttempt.owner ||
            attempt !== expectedAttempt ||
            expectedAttempt.job !== job
        ) {
            false
        } else {
            when (truthByAccount[expectedAttempt.owner.accountId]) {
                PendingMarkerTruth.DIRTY_CONFIRMED -> true
                PendingMarkerTruth.DIRTY_UNCONFIRMED -> {
                    val confirmed = writeMarker(expectedAttempt.owner.accountId, true)
                    if (confirmed) {
                        truthByAccount[expectedAttempt.owner.accountId] =
                            PendingMarkerTruth.DIRTY_CONFIRMED
                    }
                    confirmed
                }
                PendingMarkerTruth.CLEAN_CONFIRMED,
                PendingMarkerTruth.READ_UNKNOWN,
                null,
                -> false
            }
        }
    }

    fun completeAccepted(
        expectedAttempt: PendingSyncAttempt,
        job: Job,
        expectedEditGeneration: Long = expectedAttempt.editGeneration,
        isCurrentSnapshot: () -> Boolean,
    ): Boolean = synchronized(lock) {
        val accountId = expectedAttempt.owner.accountId
        if (
            owner != expectedAttempt.owner ||
            attempt !== expectedAttempt ||
            expectedAttempt.job !== job ||
            expectedAttempt.editGeneration != expectedEditGeneration ||
            truthByAccount[accountId] != PendingMarkerTruth.DIRTY_CONFIRMED ||
            !isCurrentSnapshot()
        ) {
            false
        } else if (!writeMarker(accountId, false)) {
            truthByAccount[accountId] = PendingMarkerTruth.DIRTY_UNCONFIRMED
            false
        } else {
            truthByAccount[accountId] = PendingMarkerTruth.CLEAN_CONFIRMED
            owner = null
            attempt = null
            true
        }
    }

    fun captureEditGeneration(expectedAttempt: PendingSyncAttempt, job: Job): Long? = synchronized(lock) {
        if (owner == expectedAttempt.owner && attempt === expectedAttempt && expectedAttempt.job === job)
            expectedAttempt.editGeneration else null
    }

    fun abandon(
        expectedAttempt: PendingSyncAttempt,
        job: Job,
    ) {
        synchronized(lock) {
            if (attempt === expectedAttempt && expectedAttempt.job === job) {
                owner = null
                attempt = null
            }
        }
    }

    fun resetTransient(): Job? = synchronized(lock) {
        val cancelled = attempt?.job
        owner = null
        attempt = null
        cancelled
    }

    fun inspectFileRestorePending(accountId: String): AccountFileLocalPresence = synchronized(lock) {
        val observed = truthByAccount[accountId]
        when {
            owner?.accountId == accountId && attempt != null -> AccountFileLocalPresence.PRESENT
            observed.isDirty() -> AccountFileLocalPresence.PRESENT
            observed == PendingMarkerTruth.READ_UNKNOWN -> AccountFileLocalPresence.UNAVAILABLE
            else -> try {
                if (readDirty(accountId)) AccountFileLocalPresence.PRESENT else AccountFileLocalPresence.ABSENT
            } catch (_: Exception) { AccountFileLocalPresence.UNAVAILABLE }
        }
    }

    private fun resolveTruth(accountId: String): PendingMarkerTruth {
        val known = truthByAccount[accountId]
        if (known != null && known != PendingMarkerTruth.READ_UNKNOWN) return known
        val observed = try {
            if (readDirty(accountId)) {
                PendingMarkerTruth.DIRTY_CONFIRMED
            } else {
                PendingMarkerTruth.CLEAN_CONFIRMED
            }
        } catch (_: Exception) {
            PendingMarkerTruth.READ_UNKNOWN
        }
        truthByAccount[accountId] = observed
        return observed
    }

    private fun writeMarker(accountId: String, pending: Boolean): Boolean =
        runCatching { writeDirty(accountId, pending) }.getOrDefault(false)

    private fun PendingMarkerTruth?.isDirty(): Boolean =
        this == PendingMarkerTruth.DIRTY_CONFIRMED ||
            this == PendingMarkerTruth.DIRTY_UNCONFIRMED
}

/**
 * Required cross-subsystem writer reservation. Only a real application composition that holds
 * these gates may supply it. It is deliberately not installed by the manager or any picker.
 */
internal fun interface AccountFileRestoreExternalExclusion {
    /** Run the callback at most once, only while the actual issuer-owned gates are held. */
    suspend fun withReservation(original: Owner, requireOriginal: () -> Unit,
        operation: suspend (Reservation) -> Unit)

    class Owner internal constructor(
        val account: SessionOwnerSnapshot.Account,
        val operationGeneration: Long,
    ) {
        override fun toString() = "AccountFileRestoreExternalExclusion.Owner"
    }

    interface Reservation {
        /** Recheck original native/direct-writer reservation, including undrained work. */
        fun requireCurrent(original: Owner)
        /** Existing-only proof for external stores and for the exact physical prefs backing. */
        fun requireLocalAbsence(original: Owner, scope: VortxAccountScope)
    }
}

/** Manager writer slots are held through actual coroutine return, without holding this monitor. */
internal class AccountFileRestoreManagerExclusion {
    class Reservation internal constructor()
    private val lock = Any()
    private var writers = 0
    private var reservation: Reservation? = null
    private var invalidated = false

    fun tryReserve(): Reservation? = synchronized(lock) {
        if (writers != 0 || reservation != null) return@synchronized null
        invalidated = false
        Reservation().also { reservation = it }
    }

    fun isCurrent(original: Reservation): Boolean = synchronized(lock) {
        reservation === original && !invalidated && writers == 0
    }

    fun release(original: Reservation) {
        synchronized(lock) { if (reservation === original) reservation = null }
    }

    fun enterWriter(observedEdit: Boolean): Boolean = synchronized(lock) {
        if (reservation != null) {
            if (!observedEdit) return@synchronized false
            // The direct writer already changed data. Preserve its real marker and retire
            // Restore admission, while holding its reservation until the call drains.
            invalidated = true
        }
        writers++
        true
    }

    fun exitWriter() = synchronized(lock) {
        check(writers > 0)
        writers--
    }
}

/**
 * The VortX end-to-end-encrypted account on Android: create (register), sign in, and recover, plus the
 * on-device session (token + account + data key). Kotlin port of the AUTH portion of the Apple
 * `app/SourcesShared/VortXSyncManager.swift`, using [VortXCrypto] for the byte-for-byte crypto contract
 * shared with the website (`webapp/src/lib/vault.ts`) and the Cloudflare Worker. Every request body and
 * every derived value matches Apple + web + the worker, so an account created on ANY surface signs in here
 * and vice-versa.
 *
 * SCOPE: the auth surface (`register` / `signIn` / `recover`, session persistence, `adopt` / `signOut`)
 * AND the sync engine (`syncUp` / `syncDown`, the [VortXSyncDoc] `vortx` doc-merge, tombstone folds, and
 * the never-shrink / never-zero / decrypt-miss / version guards), built on [VortXCrypto]'s
 * `sealDocument` / `openDocument`. The sync engine covers the PROFILE + WATCH-OVERLAY + PROFILE-TOMBSTONE
 * legs, plus the realtime WebSocket pull channel ([VortXSyncRealtime], via [startRealtime] /
 * [stopRealtime]); the add-on / library / apiKeys / searches legs (which depend on
 * stores not yet ported) are later rounds — this engine PRESERVES those foreign doc keys on the
 * read-merge-write so it never drops what another surface wrote. VortX works fully signed out; this only
 * adds cross-device sync, backup, and recovery, so nothing here is on the critical launch path.
 *
 * The session (token, account, and the sensitive 32-byte data key) is persisted in
 * EncryptedSharedPreferences — the Android analogue of the Keychain the Apple session lives in
 * ([SecureTokenStore] / [com.vortx.android.auth.AuthIdentityStore] use the same fail-soft pattern). The
 * data key decrypts the WHOLE account, so it never sits in plain SharedPreferences.
 */
class VortXSyncManager internal constructor(context: Context, private val scope: CoroutineScope) {
    constructor(context: Context) : this(context, CoroutineScope(SupervisorJob() + Dispatchers.IO))

    // Preserve the caller Job while running synchronous native/checkpoint work on the manager worker.
    // The production worker is IO; injected test scopes keep their deterministic dispatcher.
    private val nativeWorkDispatcher =
        scope.coroutineContext[ContinuationInterceptor] as? CoroutineDispatcher ?: Dispatchers.IO

    /** The account fields the server returns (mirrors Apple `VortXSyncManager.Account`). */
    data class Account(
        val id: String,
        val email: String,
        val username: String,
        val twoFactorEnabled: Boolean,
    )

    /** Persistence-truthful session state for account UI. Unknown is never rendered as signed out. */
    sealed interface SessionUiState {
        data object UnknownOrUnavailable : SessionUiState
        data object SignedOut : SessionUiState
        data class SignedIn(val account: Account) : SessionUiState
    }

    /** Result of an auth flow. `TotpRequired` asks the UI to reveal the 6-digit field and retry with a code. */
    sealed interface AuthResult {
        data object Ok : AuthResult
        data object TotpRequired : AuthResult
        data class Failed(val message: String) : AuthResult
    }

    /** In-memory QR pairing session. The private key and auth generation never leave this process. */
    class QrJoinSession internal constructor(
        val pairingID: String,
        val code: String,
        val devicePublicKey: String,
        internal val ephemeralPrivateKey: ByteArray,
        internal val operation: SessionOperationCoordinator.AuthOperation,
    )

    sealed interface QrJoinResult {
        data object Pending : QrJoinResult
        data object TransportError : QrJoinResult
        data object Expired : QrJoinResult
        data object Failed : QrJoinResult
        data class SignedIn(val email: String) : QrJoinResult
    }

    enum class QrPollDisposition { READY, PENDING, EXPIRED, RETRIABLE_ERROR }

    /** [result] plus the one-time [recoveryCode] minted by a successful server-side registration. */
    data class RegisterResult(val result: AuthResult, val recoveryCode: String?) {
        companion object {
            internal fun secureStorageFailure(recoveryCode: String): RegisterResult = RegisterResult(
                result = AuthResult.Failed(
                    "Your account was created, but this device could not securely save the session. " +
                        "Save your recovery code, then sign in again.",
                ),
                recoveryCode = recoveryCode,
            )

            internal fun superseded(recoveryCode: String): RegisterResult = RegisterResult(
                result = AuthResult.Failed(
                    "Your account was created, but this sign-in was superseded. " +
                        "Save your recovery code, then sign in again.",
                ),
                recoveryCode = recoveryCode,
            )
        }
    }

    /** A live signed-in session: bearer token + account + the decrypted 32-byte data key. */
    data class Session(val token: String, val account: Account, val dataKey: ByteArray) {
        // token remains the immutable owner/lease identity for this process. Only confirmed
        // same-session renewal advances the network carrier; no Session/epoch is replaced.
        @Volatile internal var currentBearer: String = token
            private set
        internal fun publishConfirmedRenewal(expected: String, candidate: String): Boolean {
            if (currentBearer != expected) return false
            currentBearer = candidate
            return true
        }
        override fun toString(): String = "Session(redacted)"
        override fun equals(other: Any?): Boolean =
            other is Session && token == other.token && account == other.account && dataKey.contentEquals(other.dataKey)
        override fun hashCode(): Int = 31 * (31 * token.hashCode() + account.hashCode()) + dataKey.contentHashCode()
    }

    private val appContext = context.applicationContext
    private val settingsBundleId = appContext.packageName

    /**
     * The `vortx_settings` [SharedPreferences] domain, Android's analogue of Apple's `UserDefaults`: the shared
     * file the settings stores (theme, subtitle style, player toggles, home/discover layout, ...) read and write.
     * The device app-settings sync leg (gap 1) reads its syncable keys into `doc.settings` on push and writes an
     * incoming account blob back here on pull. NOT the credential store: the account token and every secret live
     * only in the encrypted session/credential stores, never in this file.
     */
    private val settingsPrefs: SharedPreferences =
        NativeSettingsFence.wrap(SETTINGS_PREFS_FILE, appContext.getSharedPreferences(SETTINGS_PREFS_FILE, Context.MODE_PRIVATE))

    // ---- LOCAL-WINS settings bookkeeping (audit 09 S-04, the Android port of Apple SettingsDirtyKeys) ----

    /**
     * Durable per-account dirty map for the settings sync: syncable `vortx_settings` keys the user changed on
     * THIS device that have NOT been confirmed onto the account yet, as `key -> dirtyAt` epoch stamps. The
     * PULL path skips these keys (a just-made local edit survives until its own push lands, across relaunch),
     * and a CONFIRMED push clears exactly the stamps it carried up. Keyed PER ACCOUNT so switching accounts
     * never carries another account's dirty set. Stored as a JSON object string in its own tiny prefs file.
     */
    private val dirtyPrefs: SharedPreferences =
        NativeSettingsFence.wrap("vortx_sync_dirty", appContext.getSharedPreferences("vortx_sync_dirty", Context.MODE_PRIVATE))

    /** Strong ref: Android holds preference listeners WEAKLY, so an inline lambda would be collected. */
    private val settingsChangeListener =
        SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> noteLocalSettingsChange() }

    /**
     * The differ shadow: the last-seen snapshot of the syncable settings domain. A local write diffs against
     * this; remote/housekeeping writes RE-BASELINE it instead of marking, so they never become a future
     * user edit's phantom diff (Apple `refreshSettingsShadow`).
     */
    @Volatile private var settingsShadow: Map<String, Any> = emptyMap()

    private fun currentSyncableDomain(): Map<String, Any> =
        SettingsBackup.plistSettingsFrom(settingsPrefs.all)
    private fun nativeGlobalDomain(values: Map<String, Any>): Map<String, Any> = values.filterKeys {
        it in SettingsBackup.SYNCABLE_SETTING_TYPES && it !in NATIVE_PROFILE_SETTING_KEYS
    }.toMap()
    private fun nativeGlobalsChanged(before: Map<String, Any>, after: Map<String, Any>): Boolean =
        SettingsDirtyKeys.changedSyncableKeys(before, after) {
            it in SettingsBackup.SYNCABLE_SETTING_TYPES && it !in NATIVE_PROFILE_SETTING_KEYS
        }.isNotEmpty()

    private val dirtyAccountId: String? get() = session?.account?.id

    private fun dirtySettingsStorageKey(forAccount: String?): String =
        "vortx.sync.dirtySettings." + (forAccount ?: "")

    private fun readDirtySettings(): MutableMap<String, Double> {
        val raw = dirtyPrefs.getString(dirtySettingsStorageKey(forAccount = dirtyAccountId), null)
            ?: return mutableMapOf()
        return runCatching {
            val obj = JSONObject(raw)
            val map = linkedMapOf<String, Double>()
            for (key in obj.keys()) map[key] = obj.getDouble(key)
            map
        }.getOrDefault(mutableMapOf())
    }

    private fun writeDirtySettings(map: Map<String, Double>) {
        val accountId = dirtyAccountId ?: return
        if (map.isEmpty()) {
            dirtyPrefs.edit().remove(dirtySettingsStorageKey(forAccount = accountId)).apply()
        } else {
            dirtyPrefs.edit().putString(dirtySettingsStorageKey(forAccount = accountId), JSONObject(map).toString()).apply()
        }
    }

    /** Re-baseline the differ shadow to the live domain (after a remote apply / suppressed window). */
    private fun refreshSettingsShadow() { NativeSettingsFence.mutateBookkeeping { settingsShadow = currentSyncableDomain() } }

    /**
     * A preferences write landed. Under [applyingRemote] it is a remote/housekeeping write: re-baseline only.
     * Otherwise diff the live domain against the shadow, mark any changed SYNCABLE key dirty (per account,
     * durable), and re-baseline. No-op marking while signed out (nothing to protect).
     */
    private fun noteLocalSettingsChange() = accountFileManagedWriter(Unit, observedEdit = true) {
        val lease = captureSyncLease()
        if (lease == null) { refreshSettingsShadow(); return@accountFileManagedWriter }
        var changed = emptySet<String>()
        if (!publishIfSyncLeaseCurrent(lease, preserveObservedEdit = true) {
            NativeSettingsFence.mutateBookkeeping {
                val current = currentSyncableDomain()
                changed = if (!applyingRemote) SettingsDirtyKeys.changedSyncableKeys(settingsShadow, current) {
                    SettingsBackup.isSyncable(it)
                } else emptySet()
                settingsShadow = current
                if (changed.isNotEmpty()) {
                    val dirty = readDirtySettings()
                    SettingsDirtyKeys.mark(changed, at = System.currentTimeMillis() / 1000.0, into = dirty)
                    writeDirtySettings(dirty)
                }
            }
        }) return@accountFileManagedWriter
        // Native receives can remain bodyless indefinitely. Exportable global edits must own
        // their own durable retry instead of waiting for an unrelated library/profile mutation.
        // Profile mirrors and remote application do not create a second upload intent.
        if (changed.any {
            it in SettingsBackup.SYNCABLE_SETTING_TYPES && it !in NATIVE_PROFILE_SETTING_KEYS
        }) armPendingSync(lease, recordEdit = true)
    }

    /**
     * Clear the keys a CONFIRMED push carried up, guarded by the stamp [snapshot] taken when that push began,
     * so a key re-edited mid-push stays protected (`SettingsDirtyKeys.clearPushed`). Runs under the remote-
     * apply suppression because it is a durable-sync write that must not arm a self-echo push.
     */
    private fun clearPushedDirtySettings(snapshot: Map<String, Double>) {
        if (snapshot.isEmpty()) return
        applyingRemote = true
        try {
            val dirty = readDirtySettings()
            SettingsDirtyKeys.clearPushed(snapshot, from = dirty)
            writeDirtySettings(dirty)
        } finally {
            applyingRemote = false
        }
        refreshSettingsShadow()
    }
    /** Keep a queued newer local preference difference intact. This does not manufacture dirty
     * stamps; it only refuses to clear/rebaseline after the admitted own-apply domain changed. */
    private fun clearNativePushedDirtySettings(snapshot: Map<String, Double>, applied: Map<String, Any>): Boolean =
        NativeSettingsFence.mutateBookkeeping {
            if (applyingRemote || nativeGlobalsChanged(applied, nativeGlobalDomain(currentSyncableDomain()))) false
            else { clearPushedDirtySettings(snapshot); true }
        }

    init {
        NativeSettingsFence.mutateBookkeeping { settingsShadow = currentSyncableDomain() }
        settingsPrefs.registerOnSharedPreferenceChangeListener(settingsChangeListener)
    }

    private val debridKeys = DebridKeys(appContext)
    private val metadataKeys = MetadataProviderKeys(appContext)
    @Volatile private var libraryTombstones = LibraryTombstones(appContext)
    private var libraryPublicationProofs = OwnerLibraryPublicationProofs(appContext)
    private var addonPublicationProofs = AddonPublicationProofs(appContext)
    private var ownerWatchedIntents = OwnerWatchedIntentStore(appContext)

    internal fun installOwnerWatchedIntentTestSeam(store: OwnerWatchedIntentStore) { ownerWatchedIntents = store }
    internal fun captureOwnerWatchedIntentLease(): OwnerWatchedIntentLease? {
        val lease = captureSyncLease() ?: return null
        return OwnerWatchedIntentLease(lease.accountId, ownerWatchedIntents, syncLeaseAdmission(lease))
    }

    internal fun installAddonPublicationProofTestSeam(proofs: AddonPublicationProofs) { addonPublicationProofs = proofs }

    internal fun captureAddonPublicationLease(): AddonPublicationLease? {
        val lease = captureSyncLease() ?: return null
        return AddonPublicationLease(lease.accountId, addonPublicationProofs, syncLeaseAdmission(lease))
    }

    internal fun installLibraryPublicationProofTestSeam(proofs: OwnerLibraryPublicationProofs) { libraryPublicationProofs = proofs }

    internal fun captureLibraryPublicationLease(): OwnerLibraryPublicationLease? {
        val lease = captureSyncLease() ?: return null
        return OwnerLibraryPublicationLease(lease.accountId, libraryPublicationProofs, syncLeaseAdmission(lease))
    }

    private fun bindLibraryAccount(accountId: String?) {
        LibraryTombstones.activateAccount(accountId)
        libraryTombstones = LibraryTombstones(appContext)
    }
    private val addonTombstones = AddonTombstones(appContext)
    private val addonPrefs = AddonPrefsStore(appContext)
    private val store = SessionStore(appContext)
    private val initialSessionLoad = store.load()
    @Volatile private var sessionClearTestSeam: ((Long) -> Boolean)? = null
    internal fun installSessionClearTestSeam(clear: (Long) -> Boolean) { sessionClearTestSeam = clear }
    private val sessionState = DurableSessionState(
        initialValue = (initialSessionLoad as? SessionLoad.Available)?.session,
        initialOwnerEpoch = initialSessionLoad.ownerEpochOrInitial(),
        persist = store::persist,
        clear = { epoch -> sessionClearTestSeam?.invoke(epoch) ?: store.clear(epoch) },
        ownerTransition = { mutation -> mutation() },
    )
    private val operations = SessionOperationCoordinator()

    /**
     * Per-account version + downgrade-ratchet state for the sync engine (the analogue of Apple's
     * UserDefaults `lastSyncedVersion` / `sawDocV2`). Plain SharedPreferences on purpose: a version int and
     * a bool are NOT sensitive (only the data key is), and Apple keeps them in UserDefaults, not the Keychain.
     */
    private val syncState = SyncStateStore(appContext)
    private val pendingState = DurablePendingSyncState(
        readDirty = syncState::hasPendingPush,
        writeDirty = syncState::setPendingPush,
    )

    private val _syncProblem = MutableStateFlow<String?>(null)
    /** Writer/engine incompatibility, surfaced by the existing account status line. */
    val syncProblem: StateFlow<String?> = _syncProblem.asStateFlow()
    @Volatile private var upgradeRequiredLease: SyncSessionLease? = null

    private fun requiresUpgrade(lease: SyncSessionLease): Boolean {
        val blocked = upgradeRequiredLease ?: return false
        return isSyncLeaseCurrent(blocked) && blocked.accountId == lease.accountId &&
            blocked.ownerEpoch == lease.ownerEpoch && blocked.operationGeneration == lease.operationGeneration
    }

    private fun markUpgradeRequired(lease: SyncSessionLease) {
        publishIfSyncLeaseCurrent(lease) {
            upgradeRequiredLease = lease
            _syncProblem.value = "Update VortX to keep syncing. Your changes are still on this device."
        }
    }

    private fun markNativeAccountUnavailable(lease: SyncSessionLease, gateway: NativeAccountGateway) {
        var firstNotice = false
        publishIfSyncLeaseCurrent(lease) {
            if (nativeGateway === gateway && !requiresUpgrade(lease)) {
                firstNotice = _syncProblem.value != NATIVE_ACCOUNT_UNAVAILABLE
                _syncProblem.value = NATIVE_ACCOUNT_UNAVAILABLE
            }
        }
        if (firstNotice) DiagnosticsLog.log("native-account", "sync result=failed reason=native_linkage_unavailable")
    }

    private fun clearNativeAccountUnavailable(lease: SyncSessionLease, gateway: NativeAccountGateway) {
        publishIfSyncLeaseCurrent(lease) {
            if (nativeGateway === gateway && _syncProblem.value == NATIVE_ACCOUNT_UNAVAILABLE) _syncProblem.value = null
        }
    }

    /** IO scope for the debounced auto-push (requestSyncSoon) and background catch-up pulls. */
    // Native joins and their host/credential/stamp receipts form one transaction. A broadcast,
    // foreground catch-up, and a queued local push must not interleave those receipts.
    private val nativeSyncMutex = Mutex()
    private val fileRestoreExclusion = AccountFileRestoreManagerExclusion()

    private inline fun <T> accountFileManagedWriter(refused: T, observedEdit: Boolean = false, work: () -> T): T {
        if (!fileRestoreExclusion.enterWriter(observedEdit)) return refused
        return try { work() } finally { fileRestoreExclusion.exitWriter() }
    }
    // Auth completion is not foreground intent. Only the process lifecycle may enable the
    // socket/poll; a late sign-in/reconcile result must not reopen it after background stop.
    private var realtimeForeground = false

    @Volatile private var requestTestSeam: SyncRequestTestSeam? = null
    @Volatile private var conditionalRequestTestSeam: ConditionalSyncRequestTestSeam? = null
    private data class NativeReceiveReceipt(val lease: SyncSessionLease, val mount: NativeAccountMountToken, val version: Long)
    private var nativeReceiveReceipt: NativeReceiveReceipt? = null // guarded by nativeSyncMutex

    private fun conditionalReceiveVersion(lease: SyncSessionLease, gateway: NativeAccountGateway): Long? {
        val receipt = nativeReceiveReceipt ?: return null
        val account = SessionOwnerSnapshot.Account(lease.accountId, lease.ownerEpoch)
        if (!isSyncLeaseCurrent(lease) || !isSyncLeaseCurrent(receipt.lease) ||
            receipt.lease.operationGeneration != lease.operationGeneration || receipt.lease.ownerEpoch != lease.ownerEpoch ||
            receipt.lease.accountId != lease.accountId || receipt.version != lastSyncedVersion(lease) ||
            gateway.currentMountToken(account) != receipt.mount) {
            nativeReceiveReceipt = null
            return null
        }
        return receipt.version
    }
    @Volatile private var versionedPayloadTestObserver: (() -> Unit)? = null
    @Volatile private var sessionRestoreTestSeam: SessionLoad? = null

    /** The roster/overlay store the sync engine reads + folds into. Set by [attachSyncSeams]. */
    @Volatile private var profileStore: ProfileStore? = null
    /** Bound by the application after the single native repository is available. */
    @Volatile private var addonGateway: AccountAddonSyncGateway? = null
    @Volatile private var libraryGateway: AccountLibrarySyncGateway? = null
    @Volatile private var nativeGateway: NativeAccountGateway? = null
    private var nativeProviderStore: com.vortx.android.integrations.CredentialStoreAccess? = null
    @Volatile private var fileRestoreProviderVault: com.vortx.android.integrations.NativeProviderVault? = null
    private var nativeProviderTestStore = false

    private fun bindNativeProviders() {
        val credentials = nativeProviderStore ?: com.vortx.android.integrations.SecureTokenStore(appContext, "vortx_native_provider_credentials")
            .also { nativeProviderStore = it }
        val vault = com.vortx.android.integrations.NativeProviderVault(credentials, if (nativeProviderTestStore) null else { owner ->
            // Only explicitly account-qualified old slots can migrate. The legacy global
            // debrid/metadata slots and unscoped OAuth tuples are never attributed here.
            val debrid = com.vortx.android.integrations.SecureTokenStore(appContext, DebridKeys.ENCRYPTED_FILE)
            val metadata = com.vortx.android.integrations.SecureTokenStore(appContext, "vortx_metadata_credentials")
            val debridNames = DebridService.entries.associate { "vortx.debrid.${it.id}.account.${owner.id}" to it.id }
            val metadataNames = MetadataProviderKeys.Slot.entries.associate { "${it.key}.account.${owner.id}" to it.syncKey }
            val api = JSONObject()
            for ((store, names) in listOf(debrid to debridNames, metadata to metadataNames)) {
                val values = store.confirmedSnapshot(*names.keys.toTypedArray())
                check(values.availability == com.vortx.android.security.PersistentCredentialAvailability.AVAILABLE)
                names.forEach { (key, wire) -> values.values[key]?.takeIf(String::isNotEmpty)?.let { api.put(wire, it) } }
            }
            JSONObject().put("apiKeys", api)
        })
        com.vortx.android.integrations.NativeProviderAccess.bind(
            vault,
            object : com.vortx.android.integrations.NativeProviderAdmission {
                override fun <T> withCurrent(expected: SessionOwnerSnapshot.Account?, action: (SessionOwnerSnapshot.Account) -> T): T? =
                    operations.snapshot { sessionState.serialized {
                        val owner = sessionOwnerSnapshot() as? SessionOwnerSnapshot.Account
                        if (owner == null || (expected != null && expected != owner)) null else action(owner)
                    } }
            },
            changed = { owner ->
                val lease = captureSyncLease()
                if (lease != null && lease.accountId == owner.id && lease.ownerEpoch == owner.generation) armPendingSync(lease, recordEdit = true)
            },
        )
        fileRestoreProviderVault = vault
    }

    internal fun attachNativeGateway(gateway: NativeAccountGateway) =
        AccountFileProviderWriters.withWriter(Unit) {
            nativeGateway = gateway
            bindNativeProviders()
            gateway.installPlaylistAccountProducer(NativePlaylistAccountProducer(::capturePlaylistAccountWrite))
            captureSyncLease()?.let { lease -> scope.launch { syncDown(lease, force = true) } }
            scope.launch { sessionUiState.collect { state ->
                com.vortx.android.integrations.NativeProviderAccess.accountChanged()
                if (state !is SessionUiState.SignedIn) gateway.retire()
            } }
            Unit
        }

    internal fun installNativeGatewayTestSeam(gateway: NativeAccountGateway,
        credentials: com.vortx.android.integrations.CredentialStoreAccess? = null) =
        AccountFileProviderWriters.withWriter(Unit) {
            nativeGateway = gateway
            if (credentials != null) { nativeProviderStore = credentials; nativeProviderTestStore = true }
            bindNativeProviders()
            gateway.installPlaylistAccountProducer(NativePlaylistAccountProducer(::capturePlaylistAccountWrite))
        }

    /** Capture once before the edit suspends. GET operation generation is intentionally absent:
     * this edit owns a new current authenticated admission, plus the coordinator's original raw GET.
     */
    private fun capturePlaylistAccountWrite(account: SessionOwnerSnapshot.Account): NativePlaylistAccountWrite? {
        if (sessionOwnerSnapshot() != account) return null
        val lease = captureSyncLease()?.takeIf { it.accountId == account.id && it.ownerEpoch == account.generation } ?: return null
        var result: NativePlaylistAccountWrite? = null
        if (!publishIfSyncLeaseCurrent(lease) {
            val providers = checkNotNull(com.vortx.android.integrations.NativeProviderAccess.captureProspective(account))
            try {
                val (hostWitness, capturedGlobals) = NativeSettingsFence.capture {
                    val rawDirty = dirtyPrefs.getString(dirtySettingsStorageKey(account.id), null)
                    val dirty = rawDirty?.let(::JSONObject) ?: JSONObject()
                    dirty.keys().forEach { key -> require(dirty.getDouble(key).let { it.isFinite() && it >= 0 }) }
                    val values = currentSyncableDomain()
                    // Writer notification is deliberately asynchronous. Its not-yet-stamped edits
                    // are included from the same fenced domain/shadow observation, never omitted.
                    val unstamped = SettingsDirtyKeys.changedSyncableKeys(settingsShadow, values) {
                        SettingsBackup.isSyncable(it)
                    }
                    val fields = dirty.keys().asSequence().toSet() + unstamped
                    val exportable = fields.filter { it in SettingsBackup.SYNCABLE_SETTING_TYPES && it !in NATIVE_PROFILE_SETTING_KEYS }
                    require(exportable.all { !settingsPrefs.contains(it) || values.containsKey(it) }) {
                        "Pending global setting cannot be exported"
                    }
                    JSONObject().also { changes -> exportable.forEach { field ->
                        changes.put(field, values[field]?.let(JSONObject::wrap) ?: JSONObject.NULL)
                    } }.toString()
                }
                result = object : NativePlaylistAccountWrite {
                    private var active = true
                    override fun pendingGlobalValues(): JSONObject { check(active); return JSONObject(capturedGlobals) }
                    override fun commitCandidate(raw: ByteArray, originalNativeProjection: ByteArray,
                        candidateNative: ByteArray, candidateHost: ByteArray, commit: () -> Unit) {
                        check(active)
                        check(publishIfSyncLeaseCurrent(lease) {
                            providers.withCurrent(com.vortx.android.engine.NativeProfileOverlayWitness.parseAccountDocument(raw)) { full ->
                                NativeSettingsFence.withCurrent(hostWitness) {
                                    val prospective = com.vortx.android.engine.NativePlaylistAccountComposer.compose(
                                        raw, originalNativeProjection, candidateNative, candidateHost, full)
                                    try { commit() } finally { prospective.fill(0) }
                                }
                            }
                        }) { "Original playlist account admission changed" }
                    }
                    override fun commitPreparedCandidate(raw: ByteArray, prospectiveHost: ByteArray, commit: () -> Unit) {
                        check(active)
                        check(publishIfSyncLeaseCurrent(lease) {
                            providers.withCurrent(com.vortx.android.engine.NativeProfileOverlayWitness.parseAccountDocument(raw)) { full ->
                                NativeSettingsFence.withCurrent(hostWitness) {
                                    val prospective = com.vortx.android.engine.NativePlaylistAccountComposer.composePrepared(raw, prospectiveHost, full)
                                    try { commit() } finally { prospective.fill(0) }
                                }
                            }
                        }) { "Original prepared-account admission changed" }
                    }
                    override fun commitXperienceCandidate(raw: ByteArray, originalNativeProjection: ByteArray,
                        candidateNative: ByteArray, host: com.vortx.android.engine.VortxNativeSession.XperienceHostPreview,
                        commit: () -> Unit) {
                        check(active)
                        check(publishIfSyncLeaseCurrent(lease) {
                            providers.withCurrent(com.vortx.android.engine.NativeProfileOverlayWitness.parseAccountDocument(raw)) { full ->
                                NativeSettingsFence.withCurrent(hostWitness) {
                                    val prospective = com.vortx.android.engine.NativePlaylistAccountComposer.composeXperience(
                                        raw, originalNativeProjection, candidateNative, host, full)
                                    try { commit() } finally { prospective.fill(0) }
                                }
                            }
                        }) { "Original Xperience account admission changed" }
                    }
                    override fun close() { active = false; providers.close() }
                }
            } catch (failure: Throwable) { providers.close(); throw failure }
        }) return null
        return result
    }

    /**
     * Set while syncDown is applying a remote pull. The writes it makes (roster fold, overlay hydrate) must
     * NOT arm an auto-push, or the receiving device re-pushes the peer values and starves its own pull guard
     * (Apple's Beta 8/9 settings-sync self-echo). The Android foundation already avoids most self-echo by
     * folding through `persist(touch = false)` and a non-scheduling `applyRemoteOverlay`, but the seams could
     * still fire, so [requestSyncSoon] hard-gates on this flag exactly like Apple's `isApplyingRemote`.
     */
    @Volatile private var applyingRemote = false

    private val session: Session? get() = sessionState.value

    private val _account = MutableStateFlow(session?.account)
    /** The signed-in account, or null without one. Use [sessionUiState] to distinguish sign-out from unavailable. */
    val account: StateFlow<Account?> = _account.asStateFlow()

    private val _sessionUiState = MutableStateFlow(initialSessionLoad.uiState())
    /** Tri-state persistence truth for account surfaces, including an explicit unavailable/retry state. */
    val sessionUiState: StateFlow<SessionUiState> = _sessionUiState.asStateFlow()

    /** True whenever a session is present (a token + data key were adopted and persisted). */
    val isSignedIn: Boolean get() = session != null

    /**
     * An in-memory bearer bound to the account, selected profile and current auth intent. The original
     * owner token is captured BEFORE reading any state. No encrypted-store read or data-key copy occurs.
     * A transition in flight, unknown session truth, or an unbound profile fails closed.
     */
    internal fun captureWatchPartyAuth(): WatchPartyAuthSnapshot? {
        val owner = com.vortx.android.player.PlaybackOwnerEpoch.capture() ?: return null
        val captured = operations.snapshotAuthority { authGeneration, sessionGeneration ->
            sessionState.serialized {
                val current = sessionState.value ?: return@serialized null
                val published = _sessionUiState.value as? SessionUiState.SignedIn
                    ?: return@serialized null
                if (published.account != current.account || _account.value != current.account) {
                    return@serialized null
                }
                // activeProfileId has an Owner fallback while a roster is absent. A party must bind
                // to an actual selected profile rather than adopting that temporary fallback.
                val selected = profileStore?.active ?: return@serialized null
                WatchPartyAuthSnapshot.capture(
                    bearer = current.token,
                    currentBearer = { current.currentBearer },
                    accountId = current.account.id,
                    profileId = selected.id,
                    authGeneration = authGeneration,
                    sessionGeneration = sessionGeneration,
                    ownerEpoch = sessionState.ownerEpoch,
                    ownerToken = owner,
                )
            }
        }
        return captured?.takeIf { com.vortx.android.player.PlaybackOwnerEpoch.isCurrent(owner) }
    }

    /** Revalidate after EVERY suspension; this is proof of authority, not a player-mutation lock. */
    internal fun isCurrentWatchPartyAuth(snapshot: WatchPartyAuthSnapshot): Boolean {
        if (!com.vortx.android.player.PlaybackOwnerEpoch.isCurrent(snapshot.ownerToken)) return false
        return captureWatchPartyAuth()?.let(snapshot::sameAuthorityAs) == true
    }

    init {
        operations.snapshot { bindLibraryAccount(session?.account?.id) }
        AddonTombstones.activateAccount(session?.account?.id)
        AddonPrefsStore.activateAccount(session?.account?.id)
    }

    /**
     * A persistence-backed owner snapshot for account-scoped device credentials. `null account` is only
     * published as a definitive signed-out state after the encrypted session store was read successfully.
     * Keystore unavailability, a partial/corrupt session tuple, or any disagreement between the live and
     * persisted session stays unknown so another subsystem cannot adopt signed-out local data by mistake.
     */
    internal fun sessionOwnerSnapshot(): SessionOwnerSnapshot = operations.snapshot { sessionState.serialized {
        val loaded = sessionRestoreTestSeam ?: store.load()
        val available = loaded as? SessionLoad.Available
        if (available == null) {
            if (_sessionUiState.value != SessionUiState.UnknownOrUnavailable) {
                com.vortx.android.player.PlaybackOwnerEpoch.transition {
                    _sessionUiState.value = SessionUiState.UnknownOrUnavailable
                }
            }
            return@serialized SessionOwnerSnapshot.UnknownOrUnavailable(sessionState.ownerEpoch)
        }
        val persisted = available.session
        val live = sessionState.value
        val persistedOwnerEpoch = available.ownerEpoch
        if (_sessionUiState.value == SessionUiState.UnknownOrUnavailable) {
            // Repeated reads of the same secure tuple are not ownership changes. The session
            // monitor still covers the original truth/epoch comparison and restore publication.
            if (!sessionTruthMatches(live, persisted) || sessionState.ownerEpoch != persistedOwnerEpoch) {
                com.vortx.android.player.PlaybackOwnerEpoch.transition {
                    sessionState.restore(persisted, persistedOwnerEpoch)
                }
            } // Equal confirmed truth retains the ORIGINAL Session and immutable lease token.
            if (pickerFileRecoverySession != null && pickerFileRecoverySession !== sessionState.value)
                publishPickerFileRecoverySession(null)
            bindLibraryAccount(persisted?.account?.id)
            AddonTombstones.activateAccount(persisted?.account?.id)
            AddonPrefsStore.activateAccount(persisted?.account?.id)
            _account.value = persisted?.account
        } else if (
            !sessionTruthMatches(live, persisted) ||
            sessionState.ownerEpoch != persistedOwnerEpoch
        ) {
            com.vortx.android.player.PlaybackOwnerEpoch.transition {
                _sessionUiState.value = SessionUiState.UnknownOrUnavailable
            }
            return@serialized SessionOwnerSnapshot.UnknownOrUnavailable(sessionState.ownerEpoch)
        }
        val current = sessionState.value
        if (current == null) {
            _account.value = null
            _sessionUiState.value = SessionUiState.SignedOut
            SessionOwnerSnapshot.SignedOutLocal(sessionState.ownerEpoch)
        } else {
            _account.value = current.account
            _sessionUiState.value = SessionUiState.SignedIn(current.account)
            SessionOwnerSnapshot.Account(current.account.id, sessionState.ownerEpoch)
        }
    } }

    /** Retry an unavailable/corrupt secure-session read without misclassifying it as sign-out. */
    fun retrySessionRestore() {
        if (sessionOwnerSnapshot() is SessionOwnerSnapshot.Account) {
            startRealtime()
        }
    }

    /** Supplies a persisted session read for local recovery-path tests without weakening secure storage. */
    internal fun installSessionRestoreTestSeam(
        testSession: Session?,
        ownerEpoch: Long = INITIAL_SESSION_OWNER_EPOCH,
    ) {
        require(ownerEpoch >= INITIAL_SESSION_OWNER_EPOCH)
        require(testSession == null || testSession.account.id.isNotBlank())
        sessionRestoreTestSeam = SessionLoad.Available(testSession, ownerEpoch)
    }

    /** Forces the retryable secure-storage-unavailable branch for local recovery-path tests. */
    internal fun installUnavailableSessionRestoreTestSeam() {
        sessionRestoreTestSeam = SessionLoad.UnknownOrUnavailable
    }

    /** One explicit signed-out picker intent; a TOTP retry uses it without recapturing the owner. */
    internal class PickerFileRecoverySignIn internal constructor(internal val original: PickerAccountSnapshot) {
        override fun toString() = "PickerFileRecoverySignIn"
    }
    // Both fields are guarded by operations, with the same lock order as session publication.
    private var pickerFileRecoveryIntent: PickerFileRecoverySignIn? = null
    private var pickerFileRecoverySession: Session? = null
    private val _pickerFileRecoveryPaused = MutableStateFlow(false)
    internal val pickerFileRecoveryPaused: StateFlow<Boolean> = _pickerFileRecoveryPaused.asStateFlow()

    internal fun beginPickerFileRecoverySignIn(original: PickerAccountSnapshot): PickerFileRecoverySignIn? =
        operations.snapshot {
            if (original.account != null || !isPickerAccountCurrent(original) || pickerFileRecoveryIntent != null) null
            else PickerFileRecoverySignIn(original).also { pickerFileRecoveryIntent = it }
        }

    internal fun abandonPickerFileRecoverySignIn(intent: PickerFileRecoverySignIn) {
        operations.snapshot { if (pickerFileRecoveryIntent === intent) pickerFileRecoveryIntent = null }
    }

    private fun pickerFileRecoveryIntentCurrent(intent: PickerFileRecoverySignIn): Boolean =
        pickerFileRecoveryIntent === intent && pickerAccountMatches(intent.original)

    /** Scalar check for the app Restore reservation. Do not load secure storage or recapture an owner. */
    internal fun isPickerFileRecoveryOwnerCurrent(
        original: AccountFileRestoreExternalExclusion.Owner,
        gateway: NativeAccountGateway,
    ): Boolean = operations.snapshot { generation ->
        if (generation != original.operationGeneration || nativeGateway !== gateway) return@snapshot false
        sessionState.serialized {
            val paused = pickerFileRecoverySession ?: return@serialized false
            paused === sessionState.value && sessionState.ownerEpoch == original.account.generation &&
                paused.account.id == original.account.id && _account.value == paused.account &&
                _sessionUiState.value == SessionUiState.SignedIn(paused.account)
        }
    }

    private fun publishPickerFileRecoverySession(owner: Session?) {
        pickerFileRecoveryIntent = null
        pickerFileRecoverySession = owner
        _pickerFileRecoveryPaused.value = owner != null
    }

    private fun beginAuthOperation(): SessionOperationCoordinator.AuthOperation =
        checkNotNull(operations.beginAuthIf { pickerFileRecoveryIntent = null; true })

    private fun cancelSessionWork() {
        stopRealtime()
        pendingState.resetTransient()?.cancel()
        applyingRemote = false
        upgradeRequiredLease = null
        _syncProblem.value = null
    }

    private data class RetainedSessionWork(
        val operationGeneration: Long,
        val ownerEpoch: Long,
        val accountId: String,
        val token: String,
        val hadActiveRealtime: Boolean,
    )

    private fun resumeRetainedSessionWork(retained: RetainedSessionWork?) {
        retained ?: return
        captureSyncLease()
            ?.takeIf {
                it.operationGeneration == retained.operationGeneration &&
                    it.ownerEpoch == retained.ownerEpoch &&
                    it.accountId == retained.accountId &&
                    it.token == retained.token
            }
            ?.let { armPendingSync(it, recordEdit = false) }
        operations.mutateIfCurrent(retained.operationGeneration) {
            val retainedSessionIsCurrent =
                sessionState.matches(retained.ownerEpoch) { current ->
                    current?.account?.id == retained.accountId &&
                        current.token == retained.token
                }
            if (shouldResumeRetainedRealtime(retained.hadActiveRealtime, retainedSessionIsCurrent)) {
                startRealtime()
            }
        }
    }

    private fun captureSyncLease(): SyncSessionLease? =
        operations.snapshot { operationGeneration ->
            sessionState.serialized {
                val current = sessionState.value ?: return@serialized null
                SyncSessionLease(
                    operationGeneration = operationGeneration,
                    ownerEpoch = sessionState.ownerEpoch,
                    accountId = current.account.id,
                    token = current.token,
                    dataKey = current.dataKey,
                    transportBearer = { current.currentBearer },
                )
            }
        }

    private fun routineSyncAllowed(lease: SyncSessionLease): Boolean = operations.snapshot { generation ->
        generation == lease.operationGeneration && sessionState.serialized {
            sessionMatchesLease(lease) && pickerFileRecoverySession !== sessionState.value
        }
    }

    /** Called after the original picker controller revokes and drains its file operation. */
    internal suspend fun resumePickerFileRecovery(expected: PickerAccountSnapshot): Boolean =
        withContext(nativeWorkDispatcher) {
            val lease = accountFileRepairSlot.withLock {
                currentCoroutineContext().ensureActive()
                operations.snapshot {
                    val held = pickerFileRecoverySession
                    if (held == null || !isPickerAccountCurrent(expected) || sessionState.value !== held)
                        return@snapshot null
                    val original = captureSyncLease() ?: return@snapshot null
                    publishPickerFileRecoverySession(null)
                    original
                }
            } ?: return@withContext false
            // Keep durable local work. Never seed from the device or submit a file automatically.
            armPendingSync(lease, recordEdit = false)
            operations.snapshot {
                if (routineSyncAllowed(lease) && isPickerAccountCurrent(expected)) {
                    startRealtime() // Its existing foreground catch-up owns the resumed pull.
                    true
                } else false
            }
        }

    private fun isSyncLeaseCurrent(lease: SyncSessionLease): Boolean =
        operations.snapshot { operationGeneration ->
            operationGeneration == lease.operationGeneration &&
                sessionState.serialized { sessionMatchesLease(lease) }
        }

    private fun acquireSyncCallPermit(
        lease: SyncSessionLease,
    ): SessionOperationCoordinator.OutboundCallPermit? =
        operations.acquireSessionCallPermit(lease.operationGeneration) {
            sessionState.serialized { sessionMatchesLease(lease) }
        }

    private fun publishIfSyncLeaseCurrent(
        lease: SyncSessionLease,
        preserveObservedEdit: Boolean = false,
        publication: () -> Unit,
    ): Boolean = accountFileManagedWriter(false, observedEdit = preserveObservedEdit) {
        val result = operations.mutateIfCurrent(lease.operationGeneration) {
            sessionState.serialized {
                if (!sessionMatchesLease(lease) ||
                    (!preserveObservedEdit && pickerFileRecoverySession === sessionState.value)) {
                    false
                } else {
                    publication()
                    true
                }
            }
        }
        return@accountFileManagedWriter when (result) {
            is SessionMutationResult.Applied -> result.value
            SessionMutationResult.Stale -> false
        }
    }

    private fun sessionMatchesLease(lease: SyncSessionLease): Boolean {
        val current = sessionState.value ?: return false
        return sessionState.ownerEpoch == lease.ownerEpoch &&
            current.account.id == lease.accountId &&
            current.token == lease.token &&
            lease.matchesDataKey(current.dataKey)
    }

    /**
     * Lock-free, fail-closed fence used only while the pending-state lock is held. Owner fields and the
     * coordinator generation are volatile, so invalidation or replacement becomes visible without a
     * pending-lock to coordinator-lock edge.
     */
    private fun isSyncLeaseCurrentSnapshot(lease: SyncSessionLease): Boolean =
        operations.isCurrentSnapshot(lease.operationGeneration) &&
            sessionMatchesLease(lease)

    private fun pendingOwner(lease: SyncSessionLease): PendingSyncOwner =
        PendingSyncOwner(
            operationGeneration = lease.operationGeneration,
            ownerEpoch = lease.ownerEpoch,
            accountId = lease.accountId,
            token = lease.token,
        )

    // MARK: - Flows

    /** The holder owns the worker result until the caller has resumed without prompt cancellation. */
    private suspend fun deriveAuthKey(derive: () -> ByteArray): ByteArray {
        val pending = AtomicReference<ByteArray?>()
        try {
            // Return Unit across the dispatcher boundary; a raw key cannot be lost during cancellation.
            withContext(Dispatchers.Default) { pending.set(derive()) }
            return checkNotNull(pending.getAndSet(null))
        } finally {
            pending.getAndSet(null)?.fill(0)
        }
    }

    /**
     * Create an account. Generates the kdf salt, derives the master key, mints a random data key + a
     * recovery code, wraps the data key under BOTH the master key and the recovery key, and posts the
     * verifiers + wrapped keys. On success adopts the session and returns the one-time recovery code (the
     * UI must show it once and tell the user to store it offline). Mirrors Apple `register`.
     */
    suspend fun register(email: String, username: String, password: String, completion: PickerAuthCompletion? = null): RegisterResult {
        val operation = beginAuthOperation()
        val kdfSalt = VortXCrypto.randomBytes(16)
        val iters = VortXCrypto.DEFAULT_ITERS
        val masterKey = deriveAuthKey { VortXCrypto.masterKey(password, kdfSalt, iters) }
        try {
            val dataKey = VortXCrypto.randomBytes(32)
            val recoveryCode = VortXCrypto.makeRecoveryCode()
            val recoveryKey = deriveAuthKey { VortXCrypto.recoveryKey(recoveryCode, kdfSalt, iters) }
            try {
                val wrappedPw = VortXCrypto.seal(masterKey, dataKey)
                val wrappedRec = VortXCrypto.seal(recoveryKey, dataKey)
                if (wrappedPw == null || wrappedRec == null) {
                    return RegisterResult(AuthResult.Failed("Could not set up encryption."), null)
                }
                val body = JSONObject().apply {
                    put("email", email)
                    put("username", username)
                    put("kdfSalt", VortXCrypto.b64(kdfSalt))
                    put("kdfIters", iters)
                    put("authVerifier", VortXCrypto.authVerifier(masterKey, password))
                    put("wrappedKeyPassword", wrappedPw)
                    put("wrappedKeyRecovery", wrappedRec)
                    put("recVerifier", VortXCrypto.recVerifier(recoveryKey, recoveryCode))
                    // Sent ONLY so the worker can put it in the welcome email; it is never stored server-side (the
                    // worker marks it "NEVER written to the DB"), matching Apple's register body. Without it the
                    // welcome email falls back to a generic "save your code" note.
                    put("recoveryCode", recoveryCode)
                }
                if (!operation.isCurrent()) {
                    return RegisterResult(AuthResult.Failed(AUTH_SUPERSEDED), null)
                }
                val callPermit = operation.acquireCallPermit()
                    ?: return RegisterResult(AuthResult.Failed(AUTH_SUPERSEDED), null)
                val (code, json) = request(
                    "POST",
                    "/v1/auth/register",
                    body,
                    callPermit = callPermit,
                )
                if (!operation.isCurrent()) {
                    val created = code == 200 && !json?.optString("token").isNullOrEmpty()
                    return if (created) {
                        RegisterResult.superseded(recoveryCode)
                    } else {
                        RegisterResult(AuthResult.Failed(AUTH_SUPERSEDED), null)
                    }
                }
                val token = json?.optString("token").takeUnless { it.isNullOrEmpty() }
                val acct = json?.optJSONObject("account")
                if (code == 200 && token != null && acct != null) {
                    return when (adopt(operation, token, acct, dataKey, completion)) {
                        SessionAdoption.ADOPTED -> RegisterResult(AuthResult.Ok, recoveryCode)
                        SessionAdoption.STALE -> RegisterResult.superseded(recoveryCode)
                        SessionAdoption.STORAGE_FAILURE -> RegisterResult.secureStorageFailure(recoveryCode)
                    }
                }
                val message = when (json?.optString("error")) {
                    "email_taken" -> "That email is already registered."
                    "username_taken" -> "That username is taken."
                    else -> "Could not create the account."
                }
                return RegisterResult(AuthResult.Failed(message), null)
            } finally {
                recoveryKey.fill(0)
            }
        } finally {
            masterKey.fill(0)
        }
    }

    /**
     * Sign in with email-or-username + password (+ optional TOTP). Pre-login fetches the account's kdf salt
     * + iterations; the master key is derived locally and only the auth verifier crosses the wire. On
     * success the password-wrapped data key is unwrapped on-device. Mirrors Apple `signIn`.
     */
    suspend fun signIn(login: String, password: String, totp: String? = null, completion: PickerAuthCompletion? = null): AuthResult =
        signIn(beginAuthOperation(), login, password, totp, completion)

    /** Attempt currency must be a synchronous scalar. The same presentation owns later retries. */
    internal suspend fun signInForPickerFileRecovery(intent: PickerFileRecoverySignIn, login: String, password: String,
        totp: String?, completion: PickerAuthCompletion, attemptCurrent: () -> Boolean): AuthResult {
        val caller = currentCoroutineContext()[Job]
        caller?.ensureActive()
        val operation = operations.beginAuthIf { attemptCurrent() && pickerFileRecoveryIntentCurrent(intent) }
            ?: return AuthResult.Failed(AUTH_SUPERSEDED)
        return signIn(operation, login, password, totp, completion, intent, caller, attemptCurrent)
    }

    private suspend fun signIn(operation: SessionOperationCoordinator.AuthOperation, login: String, password: String,
        totp: String?, completion: PickerAuthCompletion?, recoveryIntent: PickerFileRecoverySignIn? = null,
        recoveryCaller: Job? = null, recoveryAttemptCurrent: (() -> Boolean)? = null): AuthResult {
        fun current(): Boolean = operation.isCurrent() && (recoveryIntent == null ||
            (recoveryCaller?.isActive != false && recoveryAttemptCurrent?.invoke() == true &&
                operations.snapshot { pickerFileRecoveryIntentCurrent(recoveryIntent) }))
        val transportCurrent: () -> Boolean = if (recoveryIntent == null) ({ true }) else ::current
        val preloginPermit = operation.acquireCallPermit()
            ?: return AuthResult.Failed(AUTH_SUPERSEDED)
        val (_, pre) = request(
            "POST",
            "/v1/auth/prelogin",
            JSONObject().put("login", login),
            callPermit = preloginPermit,
            candidateCurrent = transportCurrent,
        )
        if (!current()) return AuthResult.Failed(AUTH_SUPERSEDED)
        val salt = pre?.optString("kdfSalt").takeUnless { it.isNullOrEmpty() }?.let { VortXCrypto.unb64(it) }
        val iters = pre?.optInt("kdfIters", -1)?.takeIf { it > 0 }
        if (salt == null || iters == null) return AuthResult.Failed("Could not reach VortX. Try again.")
        // Reject a downgraded work factor from the UNAUTHENTICATED prelogin response before deriving the key.
        if (iters < VortXCrypto.MIN_ITERS) return AuthResult.Failed("Could not verify VortX security parameters. Try again.")

        val masterKey = deriveAuthKey { VortXCrypto.masterKey(password, salt, iters) }
        try {
            val body = JSONObject().apply {
                put("login", login)
                put("authVerifier", VortXCrypto.authVerifier(masterKey, password))
                if (!totp.isNullOrEmpty()) put("totp", totp)
            }
            if (!current()) return AuthResult.Failed(AUTH_SUPERSEDED)
            val loginPermit = operation.acquireCallPermit()
                ?: return AuthResult.Failed(AUTH_SUPERSEDED)
            val (code, json) = request(
                "POST",
                "/v1/auth/login",
                body,
                callPermit = loginPermit,
                candidateCurrent = transportCurrent,
            )
            if (!current()) return AuthResult.Failed(AUTH_SUPERSEDED)
            if (code == 401 && json?.optString("error") == "totp_required") return AuthResult.TotpRequired

            val token = json?.optString("token").takeUnless { it.isNullOrEmpty() }
            val acct = json?.optJSONObject("account")
            val wrappedPw = json?.optString("wrappedKeyPassword").takeUnless { it.isNullOrEmpty() }
            val dataKey = wrappedPw?.let { VortXCrypto.open(masterKey, it) }
            if (code == 200 && token != null && acct != null && dataKey != null) {
                return when (adopt(operation, token, acct, dataKey, completion, recoveryIntent, recoveryCaller, recoveryAttemptCurrent)) {
                    SessionAdoption.ADOPTED -> AuthResult.Ok
                    SessionAdoption.STALE -> AuthResult.Failed(AUTH_SUPERSEDED)
                    SessionAdoption.STORAGE_FAILURE -> AuthResult.Failed(SESSION_STORAGE_FAILURE)
                }
            }
            return AuthResult.Failed(if (code == 401) "Wrong login or password." else "Could not sign in.")
        } finally {
            masterKey.fill(0)
        }
    }

    /** Start the joiner side of VortX account device pairing. */
    suspend fun qrStart(): QrJoinSession? {
        val operation = beginAuthOperation()
        val ephemeral = VortXPairingCrypto.newEphemeral()
        val permit = operation.acquireCallPermit() ?: return null
        val (status, json) = request(
            method = "POST",
            path = "/v1/qr/start",
            body = JSONObject().put("devicePublicKey", ephemeral.publicKeyBase64URL),
            callPermit = permit,
        )
        if (!operation.isCurrent() || status != 200) return null
        val pairingID = json?.optString("pairingID")?.takeIf { it.isNotBlank() } ?: return null
        val code = json.optString("code").takeIf { it.isNotBlank() } ?: return null
        return QrJoinSession(
            pairingID = pairingID,
            code = code.uppercase(),
            devicePublicKey = ephemeral.publicKeyBase64URL,
            ephemeralPrivateKey = ephemeral.privateKey,
            operation = operation,
        )
    }

    /** Poll once, adopting only after the approved payload decrypts to a valid 32-byte data key. */
    suspend fun qrPoll(session: QrJoinSession, completion: PickerAuthCompletion? = null): QrJoinResult {
        val statusPermit = session.operation.acquireCallPermit() ?: return QrJoinResult.Failed
        val encodedID = URLEncoder.encode(session.pairingID, Charsets.UTF_8.name())
        val (status, json) = request(
            method = "GET",
            path = "/v1/qr/status?id=$encodedID",
            body = null,
            callPermit = statusPermit,
        )
        if (!session.operation.isCurrent()) return QrJoinResult.Failed
        val token = json?.optString("token")?.takeIf { it.isNotBlank() }
        val payload = json?.optString("payload")?.takeIf { it.isNotBlank() }
        val approved = token != null && payload != null && !json.optBoolean("pending", false)
        when (qrPollDisposition(status, approved)) {
            QrPollDisposition.EXPIRED -> return QrJoinResult.Expired
            QrPollDisposition.RETRIABLE_ERROR -> return QrJoinResult.TransportError
            QrPollDisposition.PENDING -> return QrJoinResult.Pending
            QrPollDisposition.READY -> Unit
        }

        val dataKey = unwrapQrPayload(payload.orEmpty(), session.ephemeralPrivateKey)
            ?: return QrJoinResult.Failed
        val mePermit = session.operation.acquireCallPermit() ?: return QrJoinResult.Failed
        val (meStatus, meJson) = request(
            method = "GET",
            path = "/v1/auth/me",
            body = null,
            bearerToken = token,
            callPermit = mePermit,
        )
        if (!session.operation.isCurrent()) return QrJoinResult.Failed
        val account = meJson?.optJSONObject("account")
        if (meStatus != 200 || account == null) return QrJoinResult.Failed
        return when (adopt(session.operation, token.orEmpty(), account, dataKey, completion)) {
            SessionAdoption.ADOPTED -> QrJoinResult.SignedIn(account.optString("email"))
            SessionAdoption.STALE,
            SessionAdoption.STORAGE_FAILURE,
            -> QrJoinResult.Failed
        }
    }

    /**
     * Forgot-password recovery (DATA-PRESERVING): the user still has the recovery code. Unwrap the data key
     * with the recovery key, then re-derive a new master key from the SAME kdf salt the account already uses
     * (so the recovery key stays valid afterwards) and re-wrap the data key under it. Mirrors Apple `recover`.
     */
    suspend fun recover(email: String, recoveryCode: String, newPassword: String, completion: PickerAuthCompletion? = null): AuthResult {
        val operation = beginAuthOperation()
        val trimmed = recoveryCode.trim()
        val startPermit = operation.acquireCallPermit()
            ?: return AuthResult.Failed(AUTH_SUPERSEDED)
        val (_, start) = request(
            "POST",
            "/v1/auth/recover-start",
            JSONObject().put("email", email),
            callPermit = startPermit,
        )
        if (!operation.isCurrent()) return AuthResult.Failed(AUTH_SUPERSEDED)
        val salt = start?.optString("kdfSalt").takeUnless { it.isNullOrEmpty() }?.let { VortXCrypto.unb64(it) }
        val iters = start?.optInt("kdfIters", -1)?.takeIf { it > 0 }
        val wrappedRec = start?.optString("wrappedKeyRecovery").takeUnless { it.isNullOrEmpty() }
        if (salt == null || iters == null || wrappedRec == null) {
            return AuthResult.Failed("No recovery is set up for that email.")
        }
        // Same downgrade guard as signIn: recover-start is unauthenticated too.
        if (iters < VortXCrypto.MIN_ITERS) return AuthResult.Failed("Could not verify VortX security parameters. Try again.")

        val recoveryKey = deriveAuthKey { VortXCrypto.recoveryKey(trimmed, salt, iters) }
        try {
            val dataKey = VortXCrypto.open(recoveryKey, wrappedRec) ?: return AuthResult.Failed("That recovery code is not correct.")
            // Keep the existing kdfSalt (it also derives the recovery key); derive the new master from it.
            val newMaster = deriveAuthKey { VortXCrypto.masterKey(newPassword, salt, iters) }
            try {
                val wrappedPw = VortXCrypto.seal(newMaster, dataKey) ?: return AuthResult.Failed("Could not re-encrypt.")
                val body = JSONObject().apply {
                    put("email", email)
                    put("recVerifier", VortXCrypto.recVerifier(recoveryKey, trimmed))
                    put("newAuthVerifier", VortXCrypto.authVerifier(newMaster, newPassword))
                    put("newWrappedKeyPassword", wrappedPw)
                }
                if (!operation.isCurrent()) return AuthResult.Failed(AUTH_SUPERSEDED)
                val completePermit = operation.acquireCallPermit()
                    ?: return AuthResult.Failed(AUTH_SUPERSEDED)
                val (code, json) = request(
                    "POST",
                    "/v1/auth/recover-complete",
                    body,
                    callPermit = completePermit,
                )
                if (!operation.isCurrent()) return AuthResult.Failed(AUTH_SUPERSEDED)
                val token = json?.optString("token").takeUnless { it.isNullOrEmpty() }
                val acct = json?.optJSONObject("account")
                if (code == 200 && token != null && acct != null) {
                    return when (adopt(operation, token, acct, dataKey, completion)) {
                        SessionAdoption.ADOPTED -> AuthResult.Ok
                        SessionAdoption.STALE -> AuthResult.Failed(AUTH_SUPERSEDED)
                        SessionAdoption.STORAGE_FAILURE -> AuthResult.Failed(SESSION_STORAGE_FAILURE)
                    }
                }
                return AuthResult.Failed("Recovery failed.")
            } finally {
                newMaster.fill(0)
            }
        } finally {
            recoveryKey.fill(0)
        }
    }

    internal val pickerAccountRevision: StateFlow<Long> get() = operations.accountRevision
    /** Ephemeral Tools cancellation, including auth start; it does not mutate session/owner epochs. */
    internal val pickerAuthorityRevision: StateFlow<Long> get() = operations.pickerAuthorityRevision
    /** Read-only completion lifetime, not sign-out/write authority. Unavailable persistence must not
     * erase an unsaved recovery code while the same original live owner is retained. */
    internal fun capturePickerCompletionOwner(): PickerAccountSnapshot =
        operations.snapshotAuthority { auth, generation -> sessionState.serialized {
            PickerAccountSnapshot(this, auth, generation, sessionState.ownerEpoch, sessionState.value, sessionState.value?.account)
        } }
    internal fun isPickerCompletionOwnerCurrent(expected: PickerAccountSnapshot): Boolean = operations.snapshot {
        sessionState.serialized { expected.matchesOwner(this, sessionState.ownerEpoch, sessionState.value) }
    }
    internal fun publishIfPickerCompletionOwnerCurrent(expected: PickerAccountSnapshot, publication: () -> Unit): Boolean =
        operations.snapshot {
            if (!isPickerCompletionOwnerCurrent(expected)) false else { publication(); true }
        }

    /** Account controls do not require a selected profile or a healthy native mount. */
    internal fun capturePickerAccountSnapshot(): PickerAccountSnapshot? =
        operations.snapshotAuthority { auth, sessionGeneration -> sessionState.serialized {
            val current = sessionState.value
            val published = _sessionUiState.value
            if (published == SessionUiState.UnknownOrUnavailable ||
                (current == null && published != SessionUiState.SignedOut) ||
                (current != null && (published !is SessionUiState.SignedIn || published.account != current.account)) ||
                _account.value != current?.account) return@serialized null
            PickerAccountSnapshot(this, auth, sessionGeneration, sessionState.ownerEpoch, current, current?.account)
        } }

    private fun pickerAccountMatches(expected: PickerAccountSnapshot): Boolean = sessionState.serialized {
        expected.matchesOwner(this, sessionState.ownerEpoch, sessionState.value) && _account.value == expected.account &&
            when (val state = _sessionUiState.value) {
                is SessionUiState.SignedIn -> state.account == expected.account
                SessionUiState.SignedOut -> expected.account == null
                SessionUiState.UnknownOrUnavailable -> false
            }
    }

    internal fun isPickerAccountCurrent(expected: PickerAccountSnapshot): Boolean =
        operations.snapshotAuthority { auth, sessionGeneration ->
            expected.matchesAuthority(this, auth, sessionGeneration) && pickerAccountMatches(expected)
        }

    internal fun signOut(expected: PickerAccountSnapshot): PickerSignOutResult {
        if (expected.account == null) return PickerSignOutResult.STALE
        var admitted = false
        val cleared = signOutUsing { mutation ->
            when (val result = expected.invalidate(operations, this,
                validate = { pickerAccountMatches(expected) }, mutation = mutation)) {
                SessionMutationResult.Stale -> false
                is SessionMutationResult.Applied -> { admitted = true; result.value }
            }
        }
        return if (!admitted) PickerSignOutResult.STALE else if (cleared) PickerSignOutResult.SIGNED_OUT
            else PickerSignOutResult.STORAGE_UNAVAILABLE
    }

    /** Sign out only after the encrypted session clear succeeds. */
    fun signOut(): Boolean {
        return signOutUsing { mutation -> operations.invalidate { mutation() } }
    }

    private fun signOutUsing(invalidate: (() -> Boolean) -> Boolean): Boolean {
        var retained: RetainedSessionWork? = null
        val cleared = invalidate {
            retained = operations.snapshot { operationGeneration ->
                sessionState.serialized {
                    sessionState.value?.let { current ->
                        RetainedSessionWork(
                            operationGeneration = operationGeneration,
                            ownerEpoch = sessionState.ownerEpoch,
                            accountId = current.account.id,
                            token = current.token,
                            hadActiveRealtime = realtime.isActive(),
                        )
                    }
                }
            }
            pickerFileRecoveryIntent = null
            cancelSessionWork()
            sessionState.clear {
                publishPickerFileRecoverySession(null)
                bindLibraryAccount(null)
                AddonTombstones.activateAccount(null)
                AddonPrefsStore.activateAccount(null)
                _account.value = null
                _sessionUiState.value = SessionUiState.SignedOut
                nativeGateway?.retire()
            }
        }
        if (!cleared) {
            resumeRetainedSessionWork(retained)
            return false
        }
        // The per-account version / sawDocV2 keys are deliberately NOT reset (they are keyed by account id,
        // so a re-login for the SAME account keeps its high-water mark), mirroring Apple's signOut.
        return true
    }

    /**
     * The current session snapshot (token + account + data key), or null when signed out. `internal` so the
     * next-wave sync engine (same package) can seal/pull the encrypted document under the data key; not part
     * of the public API (the data key never leaves this package).
     */
    internal fun currentSession(): Session? = session

    /**
     * Installs an in-memory signed-in state and transport for a local test. It bypasses encrypted session
     * persistence only for setup; [syncDown] and every H-1/H-2 pull, decrypt, and apply guard remain live.
     */
    internal fun installSyncTestSeam(
        testSession: Session,
        highWaterVersion: Long,
        transport: SyncRequestTestSeam,
        onVersionedPayloadApply: () -> Unit = {},
    ) {
        require(testSession.account.id.isNotBlank())
        operations.invalidate {
        sessionState.restore(testSession)
        bindLibraryAccount(testSession.account.id)
        AddonTombstones.activateAccount(testSession.account.id)
        AddonPrefsStore.activateAccount(testSession.account.id)
        _account.value = testSession.account
        _sessionUiState.value = SessionUiState.SignedIn(testSession.account)
        syncState.setLastVersion(testSession.account.id, highWaterVersion)
        requestTestSeam = transport
        versionedPayloadTestObserver = onVersionedPayloadApply
        refreshSettingsShadow()
        }
    }

    internal fun installConditionalTransportTestSeam(transport: ConditionalSyncRequestTestSeam) {
        conditionalRequestTestSeam = transport
    }

    /** Narrow regression seam for final native-dispatch admission; production replacements use the same coordinator. */
    internal fun captureSyncLeaseAdmissionTestSeam(): ((() -> Boolean) -> Boolean)? =
        captureSyncLease()?.let(::syncLeaseAdmission)
    /** Exercise an expired transient sync operation without changing the authenticated account. */
    internal fun expireSyncOperationTestSeam() { operations.invalidate {} }

    /** Capture invocation ownership even while signed out; a queued action cannot adopt a later session. */
    internal fun captureLocalLibraryMutationAdmission(): ((() -> Boolean) -> Boolean)? =
        operations.snapshot { generation ->
            sessionState.serialized {
                if (_sessionUiState.value == SessionUiState.UnknownOrUnavailable) return@serialized null
                val expected = sessionState.value
                val epoch = sessionState.ownerEpoch
                val admission: ((() -> Boolean) -> Boolean) = { dispatch ->
                    operations.snapshot { currentGeneration ->
                        sessionState.serialized {
                            currentGeneration == generation && sessionState.ownerEpoch == epoch &&
                                sessionState.value === expected && dispatch()
                        }
                    }
                }
                admission
            }
        }

    /** Same gate semantics as captureLocalLibraryMutationAdmission, with a comparable original scope. */
    internal fun captureLocalLibraryMutationAuthority(): LocalLibraryMutationAuthority? =
        operations.snapshot { generation ->
            sessionState.serialized {
                if (_sessionUiState.value == SessionUiState.UnknownOrUnavailable) return@serialized null
                val expected = sessionState.value
                val epoch = sessionState.ownerEpoch
                val identity = LocalLibraryMutationIdentity(this, expected, generation, epoch)
                LocalLibraryMutationAuthority(identity) { dispatch ->
                    operations.snapshot { currentGeneration ->
                        sessionState.serialized {
                            currentGeneration == generation && sessionState.ownerEpoch == epoch &&
                                sessionState.value === expected && dispatch()
                        }
                    }
                }
            }
        }

    internal fun replaceSyncSessionTestSeam(session: Session) {
        operations.invalidate {
            upgradeRequiredLease = null
            _syncProblem.value = null
            sessionState.restore(session)
            bindLibraryAccount(session.account.id)
            _account.value = session.account
            AddonTombstones.activateAccount(session.account.id)
            AddonPrefsStore.activateAccount(session.account.id)
        }
    }

    internal suspend fun cancelSyncTestWork() {
        cancelSessionWork()
        scope.coroutineContext[Job]?.cancelAndJoin()
    }

    // MARK: - Encrypted sync document: the engine (syncUp / syncDown)
    //
    // Kotlin port of the sync-engine half of Apple `VortXSyncManager` (`syncUp` / `syncDown`, the
    // `vortxSummary` doc-merge, tombstone folds, and the never-shrink / never-zero / decrypt-miss / version
    // guards). The document seal/open crypto lives in [VortXCrypto]; the roster<->doc.vortx codec in
    // [VortXSyncDoc]; this class owns the transport, the guards, and the optimistic-concurrency loop.
    //
    // ANDROID SCOPE (this round): the PROFILE + WATCH-OVERLAY + PROFILE-TOMBSTONE legs. The add-on /
    // library / apiKeys / searches legs Apple also merges depend on stores not yet ported (AddonTombstones,
    // LibraryTombstones, the CoreBridge library, ApiKeys), so this engine PRESERVES those foreign keys on
    // the read-merge-write (never dropping what another surface wrote) and merges only what it owns.

    /**
     * MIGRATION flip for the version-bound sync-document format (see [VortXCrypto.sealDocument]). STAYS
     * FALSE until dual-read is broadly adopted on EVERY client — a v2 doc is unreadable by any client that
     * predates `openDocument`, so writing v2 before then breaks sync for a user whose other device/surface
     * is on an older build. `openDocument` always reads BOTH formats regardless of this flag; only WRITE is
     * gated. Named to match Apple `VortXSyncManager.writeSyncDocV2` and web `vault.ts` WRITE_SYNC_DOC_V2. DO
     * NOT flip to true until all clients ship dual-read (see the Apple doc-comment's hard gates H-1 / H-2).
     */
    private val writeSyncDocV2 = WRITE_SYNC_DOC_V2

    /**
     * Wire the profile + overlay push seams to a debounced [syncUp], and keep the [store] the engine folds
     * into. Called once after [ProfileStore.init] (e.g. from `VortXApplication.onCreate`). A genuine roster
     * edit (`touch = true`) or a debounced overlay write fires [onRosterPush] / [onRequestSync] /
     * [onPushWatch]; a syncDown fold uses `touch = false` + a non-scheduling `applyRemoteOverlay`, so it
     * never self-arms a push (and [requestSyncSoon] hard-gates on [applyingRemote] as a belt-and-braces).
     */
    fun attachSyncSeams(store: ProfileStore) {
        profileStore = store
        store.onRosterPush = { requestSyncSoon() }
        store.watchOverlay.onRequestSync = { requestSyncSoon() }
        store.watchOverlay.onPushWatch = { _, _ -> requestSyncSoon() }
    }

    /** Separate because native-engine startup and ProfileStore startup are independently fail-soft. */
    fun attachAccountAddonGateway(gateway: AccountAddonSyncGateway) {
        addonGateway = gateway
    }

    fun attachAccountLibraryGateway(gateway: AccountLibrarySyncGateway) {
        libraryGateway = gateway
    }

    /** Called after a local drag has persisted an account-scoped dirty order overlay. */
    fun onLocalAddonOrderChanged() = requestSyncSoon()
    /** Real local library mutations arm the existing durable/debounced account push. */
    fun onLocalOwnerLibraryChanged() = requestSyncSoon()

    /** Origin must be captured by the mounted native transaction, not after an async queue hop. */
    /** [progressOnly]: a periodic playback-progress report, whose upload may wait for playback to go quiet. */
    internal fun onLocalNativeMutation(origin: SessionOwnerSnapshot.Account, progressOnly: Boolean = false) {
        val lease = captureSyncLease()?.takeIf { it.accountId == origin.id && it.ownerEpoch == origin.generation } ?: return
        armPendingSync(lease, recordEdit = true, progressOnly = progressOnly)
    }

    private fun resolveStore(): ProfileStore? = profileStore ?: ProfileStore.sharedOrNull()

    // ---- Per-account version guards (H-1 downgrade ratchet, H-2 high-water floor) ----

    /**
     * Newest doc revision this device has pushed or applied FOR THE SIGNED-IN ACCOUNT (a safe integer
     * represented as [Long], including historical epoch-ms values). Per-account so a switch never
     * treats B's pulls as stale. A fresh account key starts at 0, so the first pull is applied once.
     */
    private fun lastSyncedVersion(lease: SyncSessionLease): Long =
        syncState.lastVersion(lease.accountId)

    private fun advanceVersion(lease: SyncSessionLease, version: Long, publicationCurrent: () -> Boolean = { true }): Boolean {
        var persisted = false
        return publishIfSyncLeaseCurrent(lease) {
            if (publicationCurrent()) persisted = syncState.setLastVersion(
                    lease.accountId,
                    maxOf(version, syncState.lastVersion(lease.accountId)),
                )
            if (persisted && writeSyncDocV2) markSawDocV2(lease.accountId)
        } && persisted
    }

    // H-1 downgrade ratchet (per account): once this account's doc has opened as v2, a bare-legacy blob is
    // treated as tamper and never opened (a legacy blob authenticates at ANY version, so a backend could
    // replay an archived pre-flip ciphertext under a forged higher version). Dormant until v2 docs exist.
    private fun sawDocV2(accountId: String): Boolean = accountId.isNotEmpty() && syncState.sawV2(accountId)
    private fun markSawDocV2(accountId: String) { if (accountId.isNotEmpty()) syncState.setSawV2(accountId) }

    /**
     * Open a pulled sync document, enforcing the H-1 ratchet. Returns null (tamper / undecryptable / refused)
     * rather than ever surfacing an empty doc, so a caller never clobbers the account from a refused open.
     * [version] is a 64-bit epoch-ms value threaded as a [Long] straight into [VortXCrypto.openDocument]'s
     * AAD — reading it as an Int would truncate it and fail GCM auth on every Apple/web-authored v2 document.
     */
    private fun openSyncDocument(
        lease: SyncSessionLease,
        stored: String,
        version: Long,
    ): ByteArray? {
        if (!isSyncLeaseCurrent(lease)) return null
        val isV2 = stored.startsWith(VortXCrypto.DOC_V2_PREFIX)
        if (!isV2 && sawDocV2(lease.accountId)) return null       // legacy after v2 seen -> tamper
        val plaintext = VortXCrypto.openDocument(
            lease.dataKeyCopy(),
            stored,
            lease.accountId,
            version,
        )
        if (!isSyncLeaseCurrent(lease)) return null
        if (
            plaintext != null &&
            isV2 &&
            !publishIfSyncLeaseCurrent(lease) { markSawDocV2(lease.accountId) }
        ) {
            return null
        }
        return plaintext
    }

    private class AccountFileDownload(val lease: SyncSessionLease, val owner: Session, val pickerOwner: PickerAccountSnapshot?) {
        var response: ByteArray? = null
    }
    private fun captureAccountFileDownload(pickerOwner: PickerAccountSnapshot?): AccountFileDownload? = operations.snapshot {
        if (pickerOwner != null && !isPickerAccountCurrent(pickerOwner)) return@snapshot null
        if (sessionOwnerSnapshot() !is SessionOwnerSnapshot.Account) return@snapshot null
        sessionState.serialized {
            val owner = sessionState.value ?: return@serialized null
            val lease = captureSyncLease() ?: return@serialized null
            AccountFileDownload(lease, owner, pickerOwner)
        }
    }
    private fun isAccountFileDownloadCurrent(capture: AccountFileDownload): Boolean = operations.snapshot {
        (capture.pickerOwner?.let(::isPickerAccountCurrent) ?: true) &&
        isSyncLeaseCurrent(capture.lease) && sessionState.serialized {
            sessionState.value === capture.owner && _sessionUiState.value is SessionUiState.SignedIn
        }
    }

    /** Full encrypted account export; independent of profile/native readiness and sync side effects. */
    suspend fun downloadAccountBackupFile(): ByteArray = downloadAccountBackupFileOwned(null)

    /** Picker exports cannot recapture another Session between the UI check and owned raw GET. */
    internal suspend fun downloadAccountBackupFile(expected: PickerAccountSnapshot): ByteArray =
        downloadAccountBackupFileOwned(expected)

    private suspend fun downloadAccountBackupFileOwned(expected: PickerAccountSnapshot?): ByteArray {
        val capture = captureAccountFileDownload(expected)
            ?: throw AccountBackupFile.Failure(AccountBackupFile.Reason.SESSION_CHANGED)
        val response = fetchOwnedAccountFileResponse(capture)
        try {
            val file = AccountBackupFile.encodeServerResponse(response, capture.owner.account.username)
            if (!isAccountFileDownloadCurrent(capture)) {
                file.fill(0)
                throw AccountBackupFile.Failure(AccountBackupFile.Reason.SESSION_CHANGED)
            }
            return file
        } finally { response.fill(0) }
    }

    /** Owned authenticated raw GET, without conditional cache, application, backup upload or floor writes. */
    private suspend fun fetchOwnedAccountFileResponse(capture: AccountFileDownload,
        candidateCurrent: () -> Boolean = { true }): ByteArray {
        fun current() = candidateCurrent() && isAccountFileDownloadCurrent(capture)
        if (!current()) throw AccountBackupFile.Failure(AccountBackupFile.Reason.SESSION_CHANGED)
        val permit = acquireSyncCallPermit(capture.lease)
            ?: throw AccountBackupFile.Failure(AccountBackupFile.Reason.SESSION_CHANGED)
        try {
            val (status, _) = request("GET", "/v1/backup", null, bearerToken = capture.lease.token,
                callPermit = permit, candidateCurrent = ::current, accountFileDownload = capture)
            currentCoroutineContext().ensureActive()
            if (!current()) throw AccountBackupFile.Failure(AccountBackupFile.Reason.SESSION_CHANGED)
            if (status == 404) throw AccountBackupFile.Failure(AccountBackupFile.Reason.NO_BACKUP)
            if (status != 200) throw AccountBackupFile.Failure(AccountBackupFile.Reason.UNAVAILABLE)
            val raw = capture.response ?: throw AccountBackupFile.Failure(AccountBackupFile.Reason.DAMAGED)
            capture.response = null // Transfer these exact HTTP bytes to the operation that requested them.
            return raw
        } finally {
            capture.response?.fill(0)
            capture.response = null
        }
    }

    private val accountFileRepairSlot = Mutex()

    /** Only this manager mints the checked owner witness. The worker owns disposable native handles. */
    internal suspend fun prepareAccountBackupRepair(expected: PickerAccountSnapshot, selected: ByteArray,
        routeCurrent: () -> Boolean): AccountFileRepairExport {
        if (selected.size !in 1..AccountBackupFile.MAXIMUM_FILE_BYTES)
            throw AccountFileRepairFailure(AccountFileRepairReason.INVALID_FILE)
        val job = currentCoroutineContext()[Job]
        if (job?.isActive == false || !routeCurrent()) throw kotlinx.coroutines.CancellationException("Account file route retired")
        val capture = captureAccountFileDownload(expected)
            ?: throw kotlinx.coroutines.CancellationException("Account file owner retired")
        val lease = capture.lease
        val started = System.nanoTime()
        fun remainingMillis(): Long = accountFileRepairRemainingMillis(started, System.nanoTime())
        fun current(): Boolean = job?.isActive != false && routeCurrent() && isAccountFileDownloadCurrent(capture)
        fun requireCurrent() {
            if (!current()) throw kotlinx.coroutines.CancellationException("Account file repair retired")
            if (remainingMillis() == 0L) throw AccountFileRepairFailure(AccountFileRepairReason.EXPIRED)
        }
        if (!accountFileRepairSlot.tryLock()) throw AccountFileRepairFailure(AccountFileRepairReason.BUSY)
        val pending = AtomicReference<AccountFileRepairExport?>()
        var handedOff = false
        try {
            requireCurrent()
            val raw = try {
                fetchOwnedAccountFileResponse(capture) { job?.isActive != false && routeCurrent() && remainingMillis() > 0L }
            } catch (_: AccountBackupFile.Failure) {
                requireCurrent()
                throw AccountFileRepairFailure(AccountFileRepairReason.OWNER_UNAVAILABLE)
            }
            try {
                requireCurrent()
                withContext(Dispatchers.Default) {
                    val key = lease.dataKeyCopy()
                    try {
                        val prepared = prepareAccountFileRepair(selected, raw, lease.accountId, key,
                            lease.operationGeneration, lease.ownerEpoch, { sawDocV2(lease.accountId) },
                            VortxJniBindings, ::requireCurrent)
                        pending.set(AccountFileRepairExport(prepared, ::remainingMillis, checkCurrent = {
                            requireCurrent()
                            if (!prepared.headWasVersionBound && sawDocV2(lease.accountId))
                                throw AccountFileRepairFailure(AccountFileRepairReason.OWNER_UNAVAILABLE)
                        }, saveCurrent = {
                            current() && (prepared.headWasVersionBound || !sawDocV2(lease.accountId))
                        }, onClose = { accountFileRepairSlot.unlock() }))
                    } finally { key.fill(0) }
                } // Return Unit across dispatcher handoff, so prompt cancellation can clear pending bytes.
                requireCurrent()
                val export = checkNotNull(pending.getAndSet(null))
                handedOff = true
                return export
            } finally { raw.fill(0) }
        } finally {
            if (!handedOff) {
                val abandoned = pending.getAndSet(null)
                if (abandoned == null) accountFileRepairSlot.unlock() else abandoned.close()
            }
        }
    }

    internal sealed interface FileRestoreStatus {
        data object Missing : FileRestoreStatus
        data object Unavailable : FileRestoreStatus
        data class Retained(val operationId: UUID, val revision: Long, val state: AccountFileRestoreJournal.State) : FileRestoreStatus
    }

    // Existing-only status/Verify never build an alternate owner from a selected profile,
    // never reopen a secure store for a second Session, and never run Restore's PUT path.
    private fun captureFileRestoreOwner(expected: PickerAccountSnapshot): AccountFileDownload? = operations.snapshot {
        if (expected.account == null || !isPickerAccountCurrent(expected)) return@snapshot null
        sessionState.serialized {
            val owner = sessionState.value ?: return@serialized null
            if (owner.dataKey.size != 32) return@serialized null
            val lease = captureSyncLease() ?: return@serialized null
            AccountFileDownload(lease, owner, expected)
        }
    }

    private fun requireFileRestoreOwner(capture: AccountFileDownload, original: SyncSessionLease,
        caller: Job?, routeCurrent: () -> Boolean) {
        caller?.ensureActive()
        if (capture.lease !== original || !routeCurrent() || !isAccountFileDownloadCurrent(capture))
            throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
    }

    private val fileRestoreJournal by lazy { AccountFileRestoreJournal(appContext) }
    private val fileRestoreTransaction by lazy {
        AccountFileRestoreTransaction(fileRestoreJournal, VortxJniBindings, AccountFileHostAdmission::requireCandidate)
    }

    internal suspend fun readAccountBackupFileRestoreStatus(expected: PickerAccountSnapshot,
        routeCurrent: () -> Boolean): FileRestoreStatus = withContext(nativeWorkDispatcher) {
        val caller = currentCoroutineContext()[Job]
        val capture = captureFileRestoreOwner(expected) ?: return@withContext FileRestoreStatus.Unavailable
        val lease = capture.lease
        val key = lease.dataKeyCopy()
        try {
            requireFileRestoreOwner(capture, lease, caller, routeCurrent)
            val result = when (val stored = fileRestoreJournal.readExisting(lease.accountId, key)) {
                AccountFileRestoreJournal.Read.Missing -> FileRestoreStatus.Missing
                AccountFileRestoreJournal.Read.Unavailable -> FileRestoreStatus.Unavailable
                is AccountFileRestoreJournal.Read.Present -> stored.snapshot.let {
                    FileRestoreStatus.Retained(it.intent.operationId, it.intent.revision, it.state)
                }
            }
            requireFileRestoreOwner(capture, lease, caller, routeCurrent)
            result
        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (_: Exception) { FileRestoreStatus.Unavailable }
        finally { key.fill(0) }
    }

    /** Historical journal facts survive retirement, but their result must stay with the original route. */
    private suspend fun withFileRestoreResult(expected: PickerAccountSnapshot, routeCurrent: () -> Boolean,
        operation: suspend (AccountFileDownload, Job?) -> AccountFileRestoreTransaction.Result): AccountFileRestoreTransaction.Result {
        val capture = captureFileRestoreOwner(expected)
            ?: return fileRestoreNotSubmitted(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
        val lease = capture.lease
        val caller = currentCoroutineContext()[Job]
        try { requireFileRestoreOwner(capture, lease, caller, routeCurrent) }
        catch (refusal: AccountFileRestoreTransaction.Refusal) { return fileRestoreNotSubmitted(refusal.reason) }

        return try {
            withContext(nativeWorkDispatcher) {
                requireFileRestoreOwner(capture, lease, caller, routeCurrent)
                operation(capture, caller)
            }
        } finally {
            // This runs on the original caller after the worker and all reservation cleanup drain.
            // A retired result may describe an actual prior send. It cannot become NotSubmitted.
            try { requireFileRestoreOwner(capture, lease, caller, routeCurrent) }
            catch (_: AccountFileRestoreTransaction.Refusal) {
                throw kotlinx.coroutines.CancellationException("Account file restore result retired")
            }
        }
    }

    internal suspend fun verifyAccountBackupFileRestore(expected: PickerAccountSnapshot, operationId: UUID,
        routeCurrent: () -> Boolean): AccountFileRestoreTransaction.Result = withFileRestoreResult(expected, routeCurrent) { capture, caller ->
        if (!accountFileRepairSlot.tryLock()) return@withFileRestoreResult fileRestoreNotSubmitted(AccountFileRestoreTransaction.Reason.BUSY)
        try {
            val access = FileRestoreReads(capture, caller, routeCurrent)
            try { access.requireCurrent(capture.lease) }
            catch (refusal: AccountFileRestoreTransaction.Refusal) { return@withFileRestoreResult fileRestoreNotSubmitted(refusal.reason) }
            fileRestoreTransaction.verify(capture.lease, operationId, access)
        } finally { accountFileRepairSlot.unlock() }
    }

    /** Only an independently installed actual cross-subsystem exclusion may activate this entry. */
    internal suspend fun restoreAccountBackupFile(expected: PickerAccountSnapshot, selected: ByteArray,
        routeCurrent: () -> Boolean, external: AccountFileRestoreExternalExclusion): AccountFileRestoreTransaction.Result =
        withFileRestoreResult(expected, routeCurrent) { capture, caller ->
            val lease = capture.lease
            if (!accountFileRepairSlot.tryLock())
                return@withFileRestoreResult fileRestoreNotSubmitted(AccountFileRestoreTransaction.Reason.BUSY)
            try {
                val managed = fileRestoreExclusion.tryReserve()
                    ?: return@withFileRestoreResult fileRestoreNotSubmitted(AccountFileRestoreTransaction.Reason.BUSY)
                val providerWriters = AccountFileProviderWriters.tryReserve()
                if (providerWriters == null) {
                    fileRestoreExclusion.release(managed)
                    return@withFileRestoreResult fileRestoreNotSubmitted(AccountFileRestoreTransaction.Reason.BUSY)
                }
                try {
                    val capturedNativeGateway = nativeGateway
                    val externalOwner = AccountFileRestoreExternalExclusion.Owner(
                        SessionOwnerSnapshot.Account(lease.accountId, lease.ownerEpoch), lease.operationGeneration)
                    val addonWriter = addonPrefs.tryReserveRestoreWriter(externalOwner.account)
                        ?: return@withFileRestoreResult fileRestoreNotSubmitted(AccountFileRestoreTransaction.Reason.BUSY)
                    addonWriter.use {
                        val auxiliaryBackings = AtomicReference<List<() -> Boolean>?>(null)
                        fun requireManagedIdle() {
                            requireFileRestoreOwner(capture, lease, caller, routeCurrent)
                            if (!fileRestoreExclusion.isCurrent(managed) || !AccountFileProviderWriters.isCurrent(providerWriters) ||
                                nativeSyncMutex.isLocked || nativeGateway !== capturedNativeGateway || applyingRemote)
                                throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.BUSY)
                            addonWriter.requireCurrent(externalOwner.account)
                            auxiliaryBackings.get()?.let(::requireAuxiliaryRestoreBackings)
                        }
                        val entered = AtomicBoolean(false)
                        var outcome: AccountFileRestoreTransaction.Result? = null
                        try {
                            requireManagedIdle()
                            external.withReservation(externalOwner, ::requireManagedIdle) { reservation ->
                                check(entered.compareAndSet(false, true))
                                requireManagedIdle()
                                val reads = FileRestoreReads(capture, caller, routeCurrent)
                                val access = object : AccountFileRestoreTransaction.ExclusiveRestore, AccountFileRestoreTransaction.AuthenticatedReads by reads {
                                    override fun requireIdle(original: SyncSessionLease) {
                                        reads.requireCurrent(original)
                                        requireManagedIdle()
                                        reservation.requireCurrent(externalOwner)
                                        requireManagedIdle()
                                    }
                                    override fun requireCurrent(original: SyncSessionLease) = requireIdle(original)
                                    override suspend fun getHead(original: SyncSessionLease): AccountFileRestoreTransaction.RawResponse =
                                        requestFileRestoreRaw(capture, original, null) { requireIdle(original) }

                                    override fun requireLocalAbsence(original: SyncSessionLease, scope: VortxAccountScope) {
                                        requireIdle(original)
                                        if (scope.accountID != "account.${lease.accountId}")
                                            throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
                                        requireManagedFileRestoreAbsence(externalOwner.account) { requireIdle(original) }
                                        val currentBackings = captureAuxiliaryRestoreBackings(externalOwner.account, addonWriter)
                                        auxiliaryBackings.compareAndSet(null, currentBackings)
                                        requireAuxiliaryRestoreBackings(currentBackings)
                                        reservation.requireLocalAbsence(externalOwner, scope)
                                        requireIdle(original)
                                    }
                                    override suspend fun putOnce(original: SyncSessionLease,
                                        grant: AccountFileRestoreTransaction.PutGrant): AccountFileRestoreTransaction.RawResponse {
                                        requireIdle(original)
                                        return requestFileRestoreRaw(capture, original, grant) { requireIdle(original) }
                                    }
                                }
                                outcome = fileRestoreTransaction.restore(lease, selected, access)
                            }
                        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                        catch (refusal: AccountFileRestoreTransaction.Refusal) {
                            return@withFileRestoreResult outcome ?: fileRestoreNotSubmitted(refusal.reason)
                        } catch (_: Exception) {
                            return@withFileRestoreResult outcome
                                ?: fileRestoreNotSubmitted(AccountFileRestoreTransaction.Reason.LOCAL_STATE_UNVERIFIABLE)
                        }
                        outcome ?: fileRestoreNotSubmitted(AccountFileRestoreTransaction.Reason.BUSY)
                    }
                } finally {
                    AccountFileProviderWriters.release(providerWriters)
                    fileRestoreExclusion.release(managed)
                }
            } finally { accountFileRepairSlot.unlock() }
        }

    private fun fileRestoreNotSubmitted(reason: AccountFileRestoreTransaction.Reason) =
        AccountFileRestoreTransaction.Result.NotSubmitted(reason)

    private inner class FileRestoreReads(private val capture: AccountFileDownload, private val caller: Job?,
        private val routeCurrent: () -> Boolean) : AccountFileRestoreTransaction.AuthenticatedReads {
        override fun requireCurrent(original: SyncSessionLease) = requireFileRestoreOwner(capture, original, caller, routeCurrent)

        override fun policy(original: SyncSessionLease): AccountFileRestoreTransaction.HeadPolicy {
            requireCurrent(original)
            val result = try {
                AccountFileRestoreTransaction.HeadPolicy(lastSyncedVersion(original), sawDocV2(original.accountId), writeSyncDocV2)
            } catch (_: Exception) {
                throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.LOCAL_STATE_UNVERIFIABLE)
            }
            requireCurrent(original)
            return result
        }

        override suspend fun getHead(original: SyncSessionLease): AccountFileRestoreTransaction.RawResponse =
            requestFileRestoreRaw(capture, original, null) { requireCurrent(original) }
    }

    /** Physical probes run only on the owned transaction worker. Dispatch uses their retained scalars. */
    private fun captureAuxiliaryRestoreBackings(owner: SessionOwnerSnapshot.Account,
        addonWriter: AddonPrefsStore.RestoreWriteExclusion): List<() -> Boolean> {
        fun verified(backing: (() -> Boolean)?): () -> Boolean = backing
            ?: throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.LOCAL_STATE_UNVERIFIABLE)
        return listOf(
            verified(syncState.captureRestoreBacking()),
            verified(NativeSettingsFence.capturePristineRestoreBacking(dirtyPrefs, NativeSettingsFence.RestoreAuxiliaryBacking.DIRTY_SETTINGS)),
            verified(addonPrefs.captureRestoreBacking(owner, addonWriter)),
        )
    }

    private fun requireAuxiliaryRestoreBackings(backings: List<() -> Boolean>) {
        if (backings.any { !it() })
            throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.LOCAL_STATE_UNVERIFIABLE)
    }

    private fun requireManagedFileRestoreAbsence(owner: SessionOwnerSnapshot.Account, checkCurrent: () -> Unit) {
        fun witness(inspect: () -> AccountFileLocalPresence) {
            checkCurrent()
            val result = try { inspect() }
            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) { AccountFileLocalPresence.UNAVAILABLE }
            checkCurrent()
            when (result) {
                AccountFileLocalPresence.ABSENT -> Unit
                AccountFileLocalPresence.PRESENT ->
                    throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.PENDING_LOCAL_CHANGES)
                AccountFileLocalPresence.UNAVAILABLE ->
                    throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.LOCAL_STATE_UNVERIFIABLE)
            }
        }
        witness { if (nativeReceiveReceipt == null) AccountFileLocalPresence.ABSENT else AccountFileLocalPresence.PRESENT }
        witness { pendingState.inspectFileRestorePending(owner.id) }
        witness {
            NativeSettingsFence.capture {
                val raw = dirtyPrefs.all
                if (raw.containsKey(dirtySettingsStorageKey(owner.id))) {
                    // A present malformed, empty or unstamped marker cannot prove clean absence.
                    AccountFileLocalPresence.PRESENT
                } else {
                    val values = currentSyncableDomain()
                    val keys = settingsPrefs.all.keys.filter(SettingsBackup::isSyncable)
                    if (keys.any { it !in values }) AccountFileLocalPresence.UNAVAILABLE
                    else if (SettingsDirtyKeys.changedSyncableKeys(settingsShadow, values, SettingsBackup::isSyncable).isNotEmpty())
                        AccountFileLocalPresence.PRESENT else AccountFileLocalPresence.ABSENT
                }
            }.second
        }
        witness { libraryPublicationProofs.inspectRestorePresence(owner.id) }
        witness { addonPublicationProofs.inspectRestorePresence(owner.id) }
        witness { ownerWatchedIntents.inspectRestorePresence(owner.id) }
        witness {
            val vault = fileRestoreProviderVault ?: return@witness AccountFileLocalPresence.UNAVAILABLE
            val result = com.vortx.android.integrations.NativeProviderAccess.inspectRestoreVaultPresence(owner, vault)
            if (fileRestoreProviderVault === vault) result else AccountFileLocalPresence.UNAVAILABLE
        }
        witness { debridKeys.inspectQualifiedRestorePresence(owner.id) }
        witness { metadataKeys.inspectQualifiedRestorePresence(owner.id) }
    }

    // The network interceptor admits one request attempt, including any HTTP follow-up
    // internally considered by the client. The PUT body itself additionally refuses replay.
    private class FileRestoreNetworkAttempt(private val checkCurrent: () -> Unit) {
        private val entered = AtomicBoolean(false)
        fun enter() {
            if (!entered.compareAndSet(false, true)) throw IOException("Repeated account file request")
            checkCurrent()
        }
    }
    private val fileRestoreHttp by lazy {
        OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
            .cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
            .retryOnConnectionFailure(false).callTimeout(TIMEOUT_MS.toLong(), TimeUnit.MILLISECONDS)
            .addNetworkInterceptor { chain ->
                checkNotNull(chain.request().tag(FileRestoreNetworkAttempt::class.java)).enter()
                chain.proceed(chain.request())
            }.build()
    }

    /** Blocking structured I/O on the transaction's owned worker. No detached callback can use
     * the grant after the operation returns. Account retirement disconnects through the permit. */
    private fun requestFileRestoreRaw(capture: AccountFileDownload, original: SyncSessionLease,
        grant: AccountFileRestoreTransaction.PutGrant?, checkCurrent: () -> Unit): AccountFileRestoreTransaction.RawResponse {
        checkCurrent()
        val permit = acquireSyncCallPermit(original)
            ?: throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
        var renewal: SessionRenewalCapture? = null
        var bodyBytes: ByteArray? = null
        var pendingRaw: ByteArray? = null
        try {
            val captured = captureSessionRenewal(original.token, permit)
                ?: throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
            renewal = captured
            fun requireDispatch() {
                checkCurrent()
                if (!permit.isCurrent() || captured.owner !== capture.owner ||
                    capture.owner.currentBearer != captured.sentToken)
                    throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
            }
            val method = if (grant == null) "GET" else "PUT"
            requireDispatch()
            val bytes = grant?.take(original)
            bodyBytes = bytes
            val request = Request.Builder().url("$BASE/v1/backup").header("Authorization", "Bearer ${captured.sentToken}")
                .header("Cache-Control", "no-cache, no-store")
                .tag(FileRestoreNetworkAttempt::class.java, FileRestoreNetworkAttempt(::requireDispatch)).apply {
                    if (bytes == null) get()
                    else put(object : RequestBody() {
                        private val wrote = AtomicBoolean(false)
                        override fun contentType() = "application/json; charset=utf-8".toMediaType()
                        override fun contentLength() = bytes.size.toLong()
                        override fun isOneShot() = true
                        override fun writeTo(sink: BufferedSink) {
                            if (!wrote.compareAndSet(false, true)) throw IOException("Repeated account file body")
                            requireDispatch()
                            sink.write(bytes)
                        }
                    })
                }.build()
            val call = fileRestoreHttp.newCall(request)
            if (!permit.attachCancellation(call::cancel))
                throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
            requireDispatch()
            val result = call.execute().use { response ->
                checkCurrent()
                if (!permit.isCurrent() || response.request.url != request.url || response.request.method != method ||
                    response.priorResponse != null || response.cacheResponse != null)
                    throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.HEAD_UNAVAILABLE)
                if (response.code == 200) response.body.byteStream().use { input ->
                    pendingRaw = if (grant == null) AccountBackupFile.readBoundedResponse(input) else readFileRestoreControl(input)
                }
                checkCurrent()
                if (!permit.isCurrent())
                    throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
                storeSessionRenewal(response.headers.values("X-VortX-Session").singleOrNull(), captured, permit,
                    method, "/v1/backup", response.code, null, response.header("ETag"), pendingRaw?.isEmpty() != false)
                checkCurrent()
                if (!permit.isCurrent())
                    throw AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
                AccountFileRestoreTransaction.RawResponse(response.code, pendingRaw)
            }
            pendingRaw = null
            return result
        } finally {
            permit.close()
            bodyBytes?.fill(0)
            pendingRaw?.fill(0)
            renewal?.dataKey?.fill(0)
        }
    }

    private fun readFileRestoreControl(input: InputStream): ByteArray {
        val limit = AccountFileRestoreTransaction.CONTROL_RESPONSE_LIMIT
        val storage = ByteArray(limit + 1)
        try {
            var used = 0
            while (used < storage.size) {
                val count = input.read(storage, used, storage.size - used)
                if (count < 0) return storage.copyOf(used)
                if (count == 0) throw IOException("Invalid account control response")
                used += count
            }
            throw IOException("Account control response exceeded its bound")
        } finally { storage.fill(0) }
    }

    /** Raw-body collaborator is restricted to this owned download mode; normal sync/auth is unchanged. */
    @Volatile private var accountFileTransportTestSeam: (suspend (String, String, String?) -> Pair<Int, ByteArray?>)? = null
    internal fun installAccountFileTransportTestSeam(transport: suspend (String, String, String?) -> Pair<Int, ByteArray?>) {
        accountFileTransportTestSeam = transport
    }

    // ---- Tri-state pull (never conflate "no backup yet" with "the pull failed") ----

    /** Constructed only by this account's authenticated GET, never a poll/high-water/reject echo. */
    private class BackupReadWitness(val lease: SyncSessionLease, val baseRevision: Long?)

    private sealed interface SyncDocPull {
        data class Doc(val doc: JSONObject, val witness: BackupReadWitness, val raw: ByteArray) : SyncDocPull {
            val version: Long get() = requireNotNull(witness.baseRevision)
        }
        data class Unchanged(val version: Long) : SyncDocPull
        data class Empty(val witness: BackupReadWitness) : SyncDocPull
        data object Failed : SyncDocPull
    }

    /** Issue read provenance only from this operation's authenticated Doc; payload remains sensitive. */
    private fun capturedAccountRead(
        lease: SyncSessionLease,
        account: SessionOwnerSnapshot.Account,
        pulled: SyncDocPull.Doc,
    ): NativeAccountReadCapture? {
        val read = pulled.witness
        if (read.lease !== lease || read.baseRevision != pulled.version ||
            account.id != lease.accountId || account.generation != lease.ownerEpoch) return null
        return NativeAccountReadCapture.fromAuthenticatedPull(account, lease.operationGeneration,
            lease.accountId, lease.ownerEpoch, pulled.version, pulled.raw)
    }

    /**
     * Pull the account doc, distinguishing "no backup yet" (safe to seed) from "the pull failed" (must NOT
     * push, or it clobbers the account's existing doc). A non-200/non-404, an undecryptable doc, or a
     * version older than this account's high-water mark (H-2 rollback replay) is a FAILURE. A DECRYPT-MISS
     * throws no exception and yields Failed, never an empty `{}` that would wipe state.
     */
    private suspend fun pullSyncDocResult(lease: SyncSessionLease): SyncDocPull =
        pullSyncDocResult(lease, allowOlderAddonTombstones = false)

    /**
     * [syncDown] is the sole caller permitted to inspect a replayed envelope after cryptographic authentication.
     * It uses this strictly to max-fold add-on tombstones, then rejects all other payload paths. Every normal
     * pull remains H-2 protected before decryption, so it cannot merge, seed, or report stale account data.
     */
    private suspend fun pullSyncDocResult(
        lease: SyncSessionLease,
        allowOlderAddonTombstones: Boolean,
        ifNoneMatch: Long? = null,
        publicationCurrent: () -> Boolean = { true },
    ): SyncDocPull {
        if (!routineSyncAllowed(lease) || !publicationCurrent()) return SyncDocPull.Failed
        val callPermit = acquireSyncCallPermit(lease) ?: return SyncDocPull.Failed
        var etag: String? = null
        val (code, json) = request(
            "GET",
            "/v1/backup",
            null,
            bearerToken = lease.token,
            callPermit = callPermit,
            ifNoneMatch = ifNoneMatch?.let { "\"$it\"" },
            receiveETag = { etag = it },
            candidateCurrent = publicationCurrent,
        )
        if (!isSyncLeaseCurrent(lease) || !publicationCurrent()) return SyncDocPull.Failed
        if (code == 304) return if (ifNoneMatch != null && etag == "\"$ifNoneMatch\"")
            SyncDocPull.Unchanged(ifNoneMatch) else SyncDocPull.Failed
        if (code == 404) return if (lastSyncedVersion(lease) > 0 || syncState.nativeBackupSeen(lease.accountId)) SyncDocPull.Failed
            else SyncDocPull.Empty(BackupReadWitness(lease, null))
        if (code != 200) return SyncDocPull.Failed                // network/server error: do not clobber
        val body = json ?: return SyncDocPull.Failed
        val docStr = (body.opt("document") as? String)?.takeIf { it.isNotEmpty() } ?: return SyncDocPull.Failed
        // Never coerce strings/fractions, truncate to Int, or infer revision zero from malformed 200.
        val pulledVersion = BackupRevisionPolicy.parse(body.opt("version")) ?: return SyncDocPull.Failed
        // H-2: normal pulls refuse an honest-label replay of a doc OLDER than what this account already applied.
        // syncDown may authenticate and decrypt that envelope solely to max-fold add-on tombstones; it never
        // applies any other stale account data. A real server only returns a version >= our high-water mark.
        if (pulledVersion < lastSyncedVersion(lease) && !allowOlderAddonTombstones) return SyncDocPull.Failed
        val plaintext = openSyncDocument(lease, docStr, pulledVersion) ?: return SyncDocPull.Failed
        val obj = runCatching { com.vortx.android.engine.NativeProfileOverlayWitness.parseAccountDocument(plaintext) }.getOrNull()
            ?: return SyncDocPull.Failed                          // undecodable plaintext: do not clobber
        var remembered = false
        if (!publishIfSyncLeaseCurrent(lease) { if (publicationCurrent()) remembered = syncState.markNativeBackupSeen(lease.accountId) } || !remembered) return SyncDocPull.Failed
        return if (isSyncLeaseCurrent(lease) && publicationCurrent()) {
            SyncDocPull.Doc(obj, BackupReadWitness(lease, pulledVersion), plaintext.copyOf())
        } else {
            SyncDocPull.Failed
        }
    }

    // ---- Push with optimistic concurrency ----

    private sealed interface PushOutcome {
        data class Accepted(val version: Long) : PushOutcome
        data object Rejected : PushOutcome
        data object UpgradeRequired : PushOutcome
        data object Error : PushOutcome
    }

    /**
     * Seal + PUT the immutable candidate with its exact GET witness. Advances the per-account
     * high-water mark ONLY on accepted == true — advancing it on a rejected write would suppress the
     * recovery pull and silently drop a write that LOST the race. Only an explicit accepted Boolean
     * acknowledges either writer path; a missing/malformed/lost response preserves local intent.
     */
    private suspend fun pushSyncDocAt(
        lease: SyncSessionLease,
        candidate: DerivedBackup,
    ): PushOutcome {
        if (!candidateHealthIsCurrent(lease, candidate) || requiresUpgrade(lease)) return PushOutcome.Error
        val version = BackupRevisionPolicy.next(candidate.witness.baseRevision) ?: return PushOutcome.Error
        val plaintext = candidate.plaintext.toByteArray(Charsets.UTF_8)
        val ciphertext = VortXCrypto.sealDocument(
            lease.dataKeyCopy(),
            plaintext,
            lease.accountId,
            version,
            writeSyncDocV2,
        )
            ?: return PushOutcome.Error
        if (!candidateHealthIsCurrent(lease, candidate)) return PushOutcome.Error
        val body = JSONObject().put("document", ciphertext).put("version", version)
            .put("baseRevision", candidate.witness.baseRevision ?: JSONObject.NULL)
        val callPermit = acquireSyncCallPermit(lease) ?: return PushOutcome.Error
        val (code, json) = request(
            "PUT",
            "/v1/backup",
            body,
            bearerToken = lease.token,
            callPermit = callPermit,
            candidateCurrent = { candidateIsCurrent(lease, candidate) },
        )
        if (!candidateHealthIsCurrent(lease, candidate)) return PushOutcome.Error
        // The terminal status remains authoritative even if its error body was lost/malformed.
        // It never acknowledges this candidate and must not start an infinite conflict retry.
        if (code == 426) {
            markUpgradeRequired(lease)
            return PushOutcome.UpgradeRequired
        }
        if (code != 200) return PushOutcome.Error
        val accepted = json?.opt("accepted") as? Boolean ?: return PushOutcome.Error
        if (accepted) {
            var remembered = false
            if (withCandidateSession(candidate) { publishIfSyncLeaseCurrent(lease) {
                if (candidateIsCurrent(lease, candidate)) remembered = syncState.markNativeBackupSeen(lease.accountId)
            } } != true || !remembered) return PushOutcome.Error
            // Native acceptance is not yet a completed local transaction (seed apply, host and
            // credential receipts can still fail). Its caller stamps only after those all succeed.
            return PushOutcome.Accepted(version)
        }
        // A winner echo is not the base of our document. Only a fresh authenticated GET + merge
        // can grant the next candidate's revision. Do not advance the high-water mark on rejection.
        if (json?.has("version") == true && !json.isNull("version") && BackupRevisionPolicy.parse(json.get("version")) == null)
            return PushOutcome.Error
        return PushOutcome.Rejected
    }

    private class DerivedBackup(val plaintext: String, val witness: BackupReadWitness,
        val gateway: NativeAccountGateway?, val mount: NativeAccountMountToken?,
        val hostAcknowledgment: NativeHostUploadAcknowledgment? = null,
        val currency: NativeAccountUploadCurrency? = null) {
        val baseVersion: Long? get() = witness.baseRevision
        fun document(): JSONObject = JSONObject(plaintext)
    }

    private fun deriveBackup(lease: SyncSessionLease, document: JSONObject, pull: SyncDocPull,
        gateway: NativeAccountGateway?,
        mount: NativeAccountMountToken? = gateway?.currentMountToken(SessionOwnerSnapshot.Account(lease.accountId, lease.ownerEpoch)),
        rawAccount: ByteArray? = null, hostAcknowledgment: NativeHostUploadAcknowledgment? = null,
        currency: NativeAccountUploadCurrency? = null): DerivedBackup? {
        val witness = when (pull) {
            is SyncDocPull.Doc -> pull.witness
            is SyncDocPull.Empty -> pull.witness
            else -> return null
        }
        if (witness.lease !== lease || !isSyncLeaseCurrent(lease)) return null
        val plaintext = rawAccount?.let { com.vortx.android.engine.OHJson.utf8(it) } ?: document.toString()
        return DerivedBackup(plaintext, witness, gateway, mount, hostAcknowledgment, currency).takeIf { candidateIsCurrent(lease, it) }
    }

    private fun candidateIsCurrent(lease: SyncSessionLease, candidate: DerivedBackup): Boolean {
        if (candidate.witness.lease !== lease || !isSyncLeaseCurrent(lease)) return false
        if (candidate.gateway !== nativeGateway) return false
        // New edits on this same mount remain pending through exact carrier ACK. A replacement
        // installation can never send or acknowledge a candidate captured by the retired mount.
        return (candidate.gateway == null || candidate.currency?.isCurrent() == true) && candidate.hostAcknowledgment?.isCurrent() != false
    }

    private fun <T> withCandidateSession(candidate: DerivedBackup, action: () -> T): T? =
        if (candidate.gateway == null) action() else candidate.currency?.withCurrentSession(action)

    /** Only called OUTSIDE operations/request publication monitors. The request callback uses
     * candidateIsCurrent's scalar identity; health is checked Session-first before/after PUT. */
    private fun candidateHealthIsCurrent(lease: SyncSessionLease, candidate: DerivedBackup): Boolean =
        candidateIsCurrent(lease, candidate) && withCandidateSession(candidate) { candidateIsCurrent(lease, candidate) } == true

    /** Acceptance retains the exact candidate. Only successful seed application may replace its
     * absent mount with the resulting installation; every later local receipt uses that same mount. */
    private class AcceptedBackup(val candidate: DerivedBackup, val currency: NativeAccountUploadCurrency)

    private fun acceptanceIsCurrent(lease: SyncSessionLease, accepted: AcceptedBackup): Boolean =
        accepted.candidate.witness.lease === lease && isSyncLeaseCurrent(lease) && accepted.candidate.gateway === nativeGateway && accepted.currency.isCurrent() &&
            accepted.candidate.hostAcknowledgment?.isCurrent() != false

    /**
     * Push a doc DERIVED from a pulled base, with optimistic-concurrency recovery. On a lost race, [rebuild]
     * re-runs the caller's exact merge onto a freshly pulled base and retries at that base + 1.
     * A stale GET cannot be promoted using a newer rejection echo or wall-clock. On exhaustion or
     * a failed rebuild, the version is left unadvanced so the next natural pull reconciles. Mirrors Apple
     * `pushDerivedDoc`.
     */
    private suspend fun pushDerivedDoc(
        lease: SyncSessionLease,
        initial: DerivedBackup,
        onAccepted: (DerivedBackup, Long) -> Unit = { _, _ -> },
        rebuild: suspend () -> DerivedBackup?,
    ): Boolean {
        var candidate = initial
        repeat(PUSH_MAX_RETRIES) { attempt ->
            when (val outcome = pushSyncDocAt(lease, candidate)) {
                is PushOutcome.Accepted -> { onAccepted(candidate, outcome.version); return true }
                is PushOutcome.Error -> return false              // network/server/encode failure: reconcile later
                is PushOutcome.UpgradeRequired -> return false
                is PushOutcome.Rejected -> {
                    if (!isSyncLeaseCurrent(lease)) return false
                    if (attempt >= PUSH_MAX_RETRIES - 1) return false
                    val rebuilt = rebuild() ?: return false       // rebuild's pull now fails: abort, do not clobber
                    if (!isSyncLeaseCurrent(lease)) return false
                    candidate = rebuilt
                }
            }
        }
        return false
    }

    // ---- syncUp / syncDown ----

    /**
     * Push this device's roster + overlays + tombstones to the account. MERGES into the freshly-pulled doc
     * (preserving foreign keys other surfaces wrote) instead of replacing it, then pushes with
     * optimistic-concurrency recovery. Mirrors Apple `syncUp`.
     */
    suspend fun syncUp(): Boolean {
        val lease = captureSyncLease() ?: return false
        if (retryPendingPushBeforePull(lease)) return false
        val synced = syncUp(lease)
        return synced && isSyncLeaseCurrent(lease)
    }

    private suspend fun syncUp(lease: SyncSessionLease): Boolean = accountFileManagedWriter(false) {
        if (!routineSyncAllowed(lease) || requiresUpgrade(lease)) return@accountFileManagedWriter false
        return@accountFileManagedWriter try { withContext(nativeWorkDispatcher) {
            nativeSyncMutex.withLock {
                if (!routineSyncAllowed(lease)) return@withLock false
                val gateway = nativeGateway ?: return@withLock false
                runNativeAccountAttempt(onUnavailable = { markNativeAccountUnavailable(lease, gateway) }) {
                    nativeSyncUp(lease, gateway)
                }.also { if (it) clearNativeAccountUnavailable(lease, gateway) }
            }
        } }
            catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel }
            catch (_: Exception) { false }
    }

    private suspend fun nativeSyncDown(lease: SyncSessionLease, gateway: NativeAccountGateway, force: Boolean = false, routineReceive: Boolean = false): Boolean {
        if (gateway !== nativeGateway) return false
        val account = SessionOwnerSnapshot.Account(lease.accountId, lease.ownerEpoch)
        if (force) nativeReceiveReceipt = null
        val conditionalVersion = if (routineReceive && !force) conditionalReceiveVersion(lease, gateway) else null
        // Local availability is independent of network availability. The lease came from verified
        // secure session persistence; the encrypted locator supplies the historical owner, never
        // the unscoped device roster. Failed/corrupt recovery is not permission to create an account.
        val reopened = try { conditionalVersion != null || gateway.reopenCheckpoint(account) { isSyncLeaseCurrent(lease) } }
        catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel }
        catch (_: Exception) { return false }
        if (conditionalVersion == null && reopened && !applyNativeHostSettings(lease, gateway.exportDocument(account))) return false
        // The secure journal is authoritative even if the process died before the ordinary
        // debounce marker was written. Re-arm its exact account before permitting a pull.
        if (com.vortx.android.integrations.NativeProviderAccess.hasPending(account) == true) armPendingSync(lease, recordEdit = true)
        if (retryPendingPushBeforePull(lease)) return false
        val pulled = pullSyncDocResult(lease, allowOlderAddonTombstones = false, ifNoneMatch = conditionalVersion)
        if (pulled is SyncDocPull.Unchanged) {
            if (com.vortx.android.integrations.NativeProviderAccess.hasPending(account) == true) armPendingSync(lease, recordEdit = true)
            return conditionalVersion == pulled.version && conditionalReceiveVersion(lease, gateway) == pulled.version &&
                !retryPendingPushBeforePull(lease) && isSyncLeaseCurrent(lease)
        }
        nativeReceiveReceipt = null
        if (pulled is SyncDocPull.Empty) {
            return nativeSyncUp(lease, gateway)
        }
        val pull = pulled as? SyncDocPull.Doc ?: return false
        if (!isSyncLeaseCurrent(lease)) return false
        if (retryPendingPushBeforePull(lease)) return false
        // A confirmed mounted checkpoint already contains this acknowledged revision. Replaying
        // it on every active poll remounts/projections and can arm needless peer echo work.
        if (reopened && !force && !routineReceive && syncState.hasLastVersion(lease.accountId) && pull.version == lastSyncedVersion(lease)) {
            val exported = gateway.exportDocument(account) ?: return false
            val providers = mergeNativeProviders(lease, account, pull.doc) ?: return false
            if (NativeSyncPublicationPolicy.needsRepublish(pull.doc, exported, pull.raw) ||
                NativeSyncPublicationPolicy.needsProviderRepublish(pull.doc, providers)) armPendingSync(lease, recordEdit = true)
            return isSyncLeaseCurrent(lease)
        }
        val initialMount = gateway.currentMountToken(account)
        val capturedRead = capturedAccountRead(lease, account, pull) ?: return false
        val applied = try { gateway.applyRawDocument(account, capturedRead) { isSyncLeaseCurrent(lease) } }
            catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel }
            catch (_: Exception) { false }
            finally { capturedRead.retire() }
        if (!applied) return false
        val appliedMount = gateway.currentMountToken(account)
        if (initialMount != null && appliedMount?.installation !== initialMount.installation) return false
        val exported = gateway.exportDocument(account) ?: return false
        if (!applyNativeHostSettings(lease, exported)) return false
        if (appliedMount != null && gateway.currentMountToken(account) != appliedMount) return false
        // The same atomic secure record backs provider reads and register intent. No deferred
        // credential application can replay an older pull over a newer local edit after suspension.
        val providers = mergeNativeProviders(lease, account, pull.doc) ?: return false
        if (!advanceVersion(lease, pull.version)) return false
        // A higher envelope revision from an old client can carry an older causal document. The
        // authenticated native join retains our facts; publish only if that joined wire carrier
        // actually contributes facts missing from the server (never a projection or wall clock).
        if (NativeSyncPublicationPolicy.needsRepublish(pull.doc, exported, pull.raw) ||
            NativeSyncPublicationPolicy.needsProviderRepublish(pull.doc, providers)) armPendingSync(lease, recordEdit = true)
        if (isSyncLeaseCurrent(lease) && !retryPendingPushBeforePull(lease)) {
            if (initialMount != null && appliedMount != null && gateway.currentMountToken(account) == appliedMount) {
                nativeReceiveReceipt = NativeReceiveReceipt(lease, appliedMount, pull.version)
            }
        }
        return isSyncLeaseCurrent(lease)
    }

    private fun mergeNativeProviders(lease: SyncSessionLease, account: SessionOwnerSnapshot.Account,
        document: JSONObject): JSONObject? {
        var joined: JSONObject? = null
        if (!publishIfSyncLeaseCurrent(lease) {
            joined = com.vortx.android.integrations.NativeProviderAccess.merge(account, document)
        }) return null
        return joined
    }

    private suspend fun applyNativeHostSettings(lease: SyncSessionLease, exported: NativeAccountExport?,
        publicationCurrent: () -> Boolean = { true }, expectedLocalGlobals: Map<String, Any>? = null,
        onAppliedGlobals: ((Map<String, Any>) -> Unit)? = null,
        uploadCurrency: NativeAccountUploadCurrency? = null): Boolean {
        if (exported == null || !publicationCurrent()) return false
        return withContext(Dispatchers.Main) {
            val previousSettings = settingsPrefs.all
            var applied = false
            fun applyValues() {
                applyingRemote = true
                try {
                    applyDeviceSettings(exported.hostSettingsBaseline)
                    applyNativeGlobalPreferences(exported.hostPreferences)
                } finally { applyingRemote = false }
            }
            fun apply(): Boolean = publishIfSyncLeaseCurrent(lease) {
                if (publicationCurrent()) {
                    if (expectedLocalGlobals == null) { applyValues(); applied = publicationCurrent() }
                    else {
                        NativeSettingsFence.capture {
                            if (!applyingRemote && !nativeGlobalsChanged(expectedLocalGlobals, nativeGlobalDomain(currentSyncableDomain()))) {
                                applyValues()
                                onAppliedGlobals?.invoke(nativeGlobalDomain(currentSyncableDomain()))
                                applied = true
                            }
                        }
                        // Upload publication is scalar; the enclosing scope already owns Session.
                        if (applied) applied = publicationCurrent()
                    }
                }
            } && applied
            fun admittedApply(): Boolean = if (uploadCurrency == null) apply()
                else uploadCurrency.withCurrentSession { apply() } == true
            val profileStore = resolveStore()
            val result = if (profileStore != null) profileStore.withoutNativePreferenceCapture { admittedApply() } else admittedApply()
            // Re-project profile-owned flat keys only after releasing the auth lock. Remote global
            // settings must not mint local profile edits or introduce auth-lock/runtime-lock inversion.
            if (result && profileStore != null && previousSettings != settingsPrefs.all && isSyncLeaseCurrent(lease) && publicationCurrent()) profileStore.refreshNativeProjectionInBackground(forceSettings = true)
            result && publicationCurrent()
        }
    }

    private suspend fun nativeSyncUp(lease: SyncSessionLease, gateway: NativeAccountGateway): Boolean {
        if (gateway !== nativeGateway) return false
        val account = SessionOwnerSnapshot.Account(lease.accountId, lease.ownerEpoch)
        val operationJob = currentCoroutineContext()[Job]
        // Original AUTH precedes every GET/prepare/apply suspension and every conflict rebuild.
        // Installation binding follows the genuine merged checkpoint; it never recaptures auth.
        val original = gateway.captureUploadOrigin(account) {
            operationJob?.isActive != false && isSyncLeaseCurrent(lease) && nativeGateway === gateway
        } ?: return false
        val frozenPlaylistReceipts = gateway.freezePlaylistReceipts(account)
        var pushedHostAcknowledgment: NativeHostUploadAcknowledgment? = null
        var pushedStamps: Map<String, Double> = emptyMap()
        var pushedSettingsValues: Map<String, Any> = emptyMap()
        var pushedPreferences: JSONObject? = null
        var pushedProviders: JSONObject? = null
        var acceptedVersion: Long? = null
        var acceptedBackup: AcceptedBackup? = null
        try {
        fun recordAccepted(candidate: DerivedBackup, version: Long) {
            acceptedBackup = AcceptedBackup(candidate, checkNotNull(candidate.currency))
            acceptedVersion = version
        }
        suspend fun derived(): DerivedBackup? {
            operationJob?.ensureActive()
            if (!original.isCurrent()) return null
            // A conflict rebuild has its own fresh authenticated GET and issued export. The old
            // receipt is never rebound to the next read, version echo, checkpoint or installation.
            pushedHostAcknowledgment?.close(); pushedHostAcknowledgment = null
            var globals = JSONObject()
            if (!publishIfSyncLeaseCurrent(lease) {
                check(original.isCurrent()) { "Original upload authentication retired" }
                val (_, captured) = NativeSettingsFence.capture {
                    check(!applyingRemote) { "Native settings remote application in progress" }
                    val values = currentSyncableDomain()
                    // Match the actual producer's strict known dirty schema. Never turn malformed
                    // pending input into empty data or acknowledge it after a partial candidate.
                    val dirty = dirtyPrefs.getString(dirtySettingsStorageKey(account.id), null)?.let(::JSONObject) ?: JSONObject()
                    val stamps = linkedMapOf<String, Double>()
                    dirty.keys().forEach { field -> stamps[field] = dirty.getDouble(field).also { require(it.isFinite() && it >= 0) } }
                    val unstamped = SettingsDirtyKeys.changedSyncableKeys(settingsShadow, values) { SettingsBackup.isSyncable(it) }
                    val fields = (stamps.keys + unstamped).filter {
                        it in SettingsBackup.SYNCABLE_SETTING_TYPES && it !in NATIVE_PROFILE_SETTING_KEYS &&
                            (!settingsPrefs.contains(it) || values.containsKey(it))
                    }
                    // A present value with an unsupported local type is not a deletion. Leave its
                    // exact dirty stamp pending while independently exportable native edits upload;
                    // only the fields actually included below can receive a settings acknowledgement.
                    val changes = JSONObject().also { target -> fields.forEach { field ->
                        target.put(field, values[field]?.let(JSONObject::wrap) ?: JSONObject.NULL)
                    } }
                    // The immutable values cross GET; only REAL captured stamps may later clear.
                    Triple(stamps.filterKeys { it in fields }.toMap(), changes.toString(), nativeGlobalDomain(values))
                }
                pushedStamps = captured.first
                globals = JSONObject(captured.second)
                pushedSettingsValues = captured.third
            }) return null
            val pulled = pullSyncDocResult(lease, allowOlderAddonTombstones = false, publicationCurrent = original::isCurrent)
            if (!original.isCurrent()) return null
            val seed = pulled is SyncDocPull.Empty
            var seedCurrency: NativeAccountUploadCurrency? = null
            val document = when (pulled) {
                is SyncDocPull.Doc -> pulled.doc
                is SyncDocPull.Empty -> {
                    val prepared = gateway.prepareUploadSeed(account, original) {
                        original.isCurrent()
                    } ?: return null
                    seedCurrency = prepared.second
                    prepared.first
                }
                SyncDocPull.Failed, is SyncDocPull.Unchanged -> return null
            }
            if (seed) {
                // Fresh seed has no mounted writer or local actor. Preserve any queued local
                // setting intent for a subsequent normal transaction, never acknowledge it here.
                pushedPreferences = null
                pushedProviders = null
                return deriveBackup(lease, document, pulled, gateway, currency = checkNotNull(seedCurrency))
            }
            val originalRead = pulled as? SyncDocPull.Doc ?: return null
            val originalRaw = originalRead.raw
            val capturedRead = capturedAccountRead(lease, account, originalRead) ?: return null
            // Lease-scoped like the pull path: this predicate is also the lifetime of any session the apply
            // mounts, which must outlive this one upload. The upload's own authentication still fences
            // the export and PUT below (withUploadExport, original currency).
            val applied = try { gateway.applyRawDocument(account, capturedRead) { isSyncLeaseCurrent(lease) && nativeGateway === gateway } }
                finally { capturedRead.retire() }
            if (!applied) return null
            if (globals.length() > 0 && !gateway.recordGlobalPreferences(account, globals, original)) return null
            return gateway.withUploadExport(account, capturedRead, originalRaw, original, {
                original.isCurrent()
            }) { exported, exportMount, composeGeneric, acknowledgment, currency ->
            pushedHostAcknowledgment = acknowledgment
            try {
            com.vortx.android.engine.NativeRawHostPreferences.requireRawExport(exported.hostPreferences, exported.rawHostPreferences)
            if (exported.hostProfileSyncPending) return@withUploadExport null
            operationJob?.ensureActive()
            if (!isSyncLeaseCurrent(lease)) return@withUploadExport null
            // Preserve the exact legacy baseline. Rewriting the projected roster/settings here
            // changes the one-time import fingerprint and poisons our own next pull. Native profile,
            // library and watch edits travel only in nativeSync until explicit legacy reconciliation.
            val merged = JSONObject(document.toString())
            merged.put("nativeSync", exported.nativeSync)
            pushedPreferences = exported.hostPreferences
            exported.hostPreferences?.let { merged.put("nativeHostPreferences", it) }
            var providerCandidate: JSONObject? = null
            if (!publishIfSyncLeaseCurrent(lease) { providerCandidate = com.vortx.android.integrations.NativeProviderAccess.merge(account, merged) }) return@withUploadExport null
            val withProviders = providerCandidate ?: return@withUploadExport null
            pushedProviders = withProviders.getJSONObject("nativeProviderCredentials")
            // Replace only owned wire fields. Unknown raw siblings and numeric spelling survive
            // both a normal upload and every optimistic retry's fresh authenticated GET.
            val exactBase = com.vortx.android.engine.NativeOwnerHistoryAccount(exported.rawAccount ?: originalRaw)
            val replacements = linkedMapOf("nativeSync" to exported.nativeSync.toString().toByteArray(Charsets.UTF_8),
                "nativeProviderCredentials" to withProviders.getJSONObject("nativeProviderCredentials").toString().toByteArray(Charsets.UTF_8))
            exported.rawHostPreferences?.let { replacements["nativeHostPreferences"] = it }
                ?: exported.hostPreferences?.let { replacements["nativeHostPreferences"] = it.toString().toByteArray(Charsets.UTF_8) }
            withProviders.optJSONObject("apiKeys")?.let { replacements["apiKeys"] = it.toString().toByteArray(Charsets.UTF_8) }
            // A typed checkpoint already carries exact native/source slices: never replace that
            // native object with its presentation projection merely to add provider registers.
            if (exported.rawAccount != null) {
                replacements.remove("nativeSync")
                replacements.remove("nativeHostPreferences")
            }
            val rawCandidate = if (composeGeneric != null) {
                // This callback uses only the just-merged, Session-issued raw checkpoint plus
                // the original retained GET bytes/projection. Readonly rawHostPreferences alone
                // never enables whole-host replacement, including after a cold reopen.
                try { composeGeneric(withProviders) } finally { exported.genericSourceNativeProjection?.fill(0) }
            } else if (exported.rawAccount != null || exported.genericSourceNativeProjection == null) {
                // Preserve legacy bootstrap, but never downgrade a real generic native source
                // whose original lossless projection could not be retained.
                check(exported.rawAccount != null || (document.optJSONObject("nativeSync")?.optInt("schemaVersion") ?: 0) !in 1..5) {
                    "Original generic native source projection unavailable"
                }
                exactBase.replacingOwned(replacements).validateBudget(writeV2 = true)
            }
            else {
                val sourceProjection = exported.genericSourceNativeProjection ?: return@withUploadExport null
                try { com.vortx.android.engine.NativePlaylistAccountComposer.compose(originalRaw, sourceProjection,
                    exported.nativeSync.toString().toByteArray(Charsets.UTF_8),
                    exported.rawHostPreferences ?: checkNotNull(exported.hostPreferences).toString().toByteArray(Charsets.UTF_8), withProviders)
                } finally { sourceProjection.fill(0) }
            }
            try {
                operationJob?.ensureActive()
                deriveBackup(lease, withProviders, pulled, gateway, exportMount, rawCandidate, acknowledgment, currency)
            }
            finally { rawCandidate.fill(0) }
            } finally {
                exported.genericSourceNativeProjection?.fill(0)
                exported.rawHostPreferences?.fill(0)
                exported.rawAccount?.fill(0)
            }
            }
        }
        val first = derived() ?: return false
        val pushed = if (first.baseVersion == null) {
            // Null witnesses authenticated absence; only version zero can create this row.
            // A collision or unknown outcome must re-pull the winner before rebuilding.
            when (val outcome = pushSyncDocAt(lease, first)) {
                is PushOutcome.Accepted -> {
                    if (!candidateHealthIsCurrent(lease, first)) return false
                    val installed = gateway.applyUploadSeed(account, first.document(), checkNotNull(first.currency)) {
                        operationJob?.isActive != false && isSyncLeaseCurrent(lease) && nativeGateway === gateway
                    } ?: return false
                    acceptedBackup = AcceptedBackup(first, installed)
                    if (!acceptanceIsCurrent(lease, requireNotNull(acceptedBackup))) return false
                    if (pushedStamps.isNotEmpty() || com.vortx.android.integrations.NativeProviderAccess.hasPending(account) != false) return false
                    acceptedVersion = outcome.version
                    true
                }
                is PushOutcome.Error -> false
                is PushOutcome.UpgradeRequired -> false
                is PushOutcome.Rejected -> {
                    val merged = derived()
                    if (merged?.baseVersion == null) false else pushDerivedDoc(lease, merged,
                        onAccepted = ::recordAccepted) { derived()?.takeIf { it.baseVersion != null } }
                }
            }
        } else pushDerivedDoc(lease, first, onAccepted = ::recordAccepted) { derived()?.takeIf { it.baseVersion != null } }
        if (!pushed) return false
        val accepted = acceptedBackup ?: return false
        fun receiptCurrent() = acceptanceIsCurrent(lease, accepted)
        if (!receiptCurrent()) return false
        // A PUT ACK alone does not publish the joined host settings to this device. Complete
        // that application before acknowledging registers or retiring the durable dirty marker.
        var appliedSettingsValues: Map<String, Any>? = null
        val receiptExport = accepted.currency.withCurrentSession { gateway.exportDocument(account) } ?: return false
        if (!applyNativeHostSettings(lease, receiptExport, ::receiptCurrent, pushedSettingsValues,
                { appliedSettingsValues = it }, accepted.currency) || !receiptCurrent()) return false
        // Only acknowledge the exact carrier accepted by the server. A local edit during the PUT
        // has a different register event and remains pending, including after a cold restart.
        val rawAcknowledgment = accepted.candidate.hostAcknowledgment
        if (rawAcknowledgment != null) {
            if (accepted.currency.withCurrentSession { receiptCurrent() && rawAcknowledgment.acknowledge(::receiptCurrent) && receiptCurrent() } != true) return false
        } else pushedPreferences?.let {
            if (accepted.currency.withCurrentSession { receiptCurrent() && gateway.acknowledgeHostPreferences(account, it) && receiptCurrent() } != true) return false
        }
        pushedProviders?.let { sent ->
            var acknowledged = false
            if (accepted.currency.withCurrentSession { publishIfSyncLeaseCurrent(lease) {
                if (receiptCurrent()) acknowledged = com.vortx.android.integrations.NativeProviderAccess.acknowledge(account, sent)
            } } != true || !acknowledged || !receiptCurrent()) return false
        }
        var cleared = false
        if (accepted.currency.withCurrentSession { publishIfSyncLeaseCurrent(lease) {
            if (receiptCurrent()) cleared = clearNativePushedDirtySettings(pushedStamps, checkNotNull(appliedSettingsValues))
        } } != true || !cleared || !receiptCurrent()) return false
        val version = acceptedVersion ?: return false
        if (accepted.currency.withCurrentSession { advanceVersion(lease, version, ::receiptCurrent) } != true) return false
        accepted.currency.withCurrentSession {
            if (receiptCurrent()) runCatching {
                gateway.acceptPlaylistReceipts(account, frozenPlaylistReceipts, accepted.candidate.plaintext, version)
            }
        } ?: return false
        return accepted.currency.withCurrentSession { receiptCurrent() } == true
        } finally { pushedHostAcknowledgment?.close() }
    }

    private fun applyLibraryTombstonesToVortx(vortx: JSONObject): JSONObject {
        val removed = libraryTombstones.all()
        val source = vortx.optJSONArray("library")
        if (source != null) {
            val filtered = JSONArray()
            for (index in 0 until source.length()) {
                val raw = source.get(index)
                val item = raw as? JSONObject
                val id = item?.opt("id") as? String
                val type = item?.opt("type") as? String
                val isRemoved = id != null && VortXSyncDoc.isTypedCatalogIdentity(id) &&
                    type in setOf("movie", "series") && LibraryTombstones.normalize(id) in removed
                if (!isRemoved) filtered.put(raw)
            }
            if (filtered.length() > 0) vortx.put("library", filtered) else vortx.remove("library")
        }
        if (removed.isNotEmpty()) {
            vortx.put("deletedLibrary", JSONArray(removed.sorted()))
        } else {
            vortx.remove("deletedLibrary")
        }
        val stamps = libraryTombstones.timestampsForSync()
        if (stamps.isNotEmpty()) {
            vortx.put("deletedLibraryTs", JSONObject(stamps))
        } else {
            vortx.remove("deletedLibraryTs")
        }
        return vortx
    }

    /**
     * Build the doc to push by MERGING this device's state onto a freshly pulled base. Returns null on a
     * FAILED pull (network / undecryptable): a failed pull must NEVER overwrite the account's doc, or it
     * wipes keys other surfaces wrote. UNIONs the cloud roster into the local one BEFORE building the vortx
     * block, so a device with FEWER profiles never shrinks the cloud's set. Mirrors Apple `mergeLocalIntoDoc`.
     */
    private suspend fun mergeLocalIntoDoc(lease: SyncSessionLease): DerivedBackup? {
        if (!isSyncLeaseCurrent(lease)) return null
        val store = resolveStore() ?: return null
        val pull = pullSyncDocResult(lease)
        val doc: JSONObject = when (pull) {
            is SyncDocPull.Failed, is SyncDocPull.Unchanged -> return null
            is SyncDocPull.Empty -> JSONObject()
            is SyncDocPull.Doc -> pull.doc
        }
        if (!isSyncLeaseCurrent(lease)) return null
        // Reading local native state is deliberately outside the Main transaction. An unavailable/degraded
        // engine contributes an empty snapshot, which mergeLocalAddons treats as preserve-not-delete.
        val localAddons = addonGateway?.let { gateway ->
            gateway.captureAccountAddonLease()?.let { nativeLease ->
                val raw = gateway.accountAddonSnapshot(nativeLease)
                val native = gateway.nativeAddonOwner(nativeLease)
                if (native == null) emptyList() else raw.mapNotNull { addonPublicationProofs.published(lease.accountId, native, it) }
            }
        }.orEmpty()
        val localOwnerLibrary = libraryGateway?.let { gateway ->
            val nativeLease = gateway.captureAccountLibraryLease()
            if (nativeLease != null) {
                val raw = gateway.accountLibrarySnapshot(nativeLease, syncLeaseAdmission(lease))
                val native = gateway.nativeLibraryOwner(nativeLease)
                if (native == null) null else raw?.mapNotNull { libraryPublicationProofs.published(lease.accountId, native, it) }
            } else null
        }
        if (!isSyncLeaseCurrent(lease)) return null
        val parsed = VortXSyncDoc.parse(doc)
        val resolvedRoster = SettingsBackup.resolveRosterForPull(
            pulledBlob = doc.opt("settings"),
            fallbackRoster = parsed.roster,
            fallbackModifiedSeconds = parsed.rosterModifiedSeconds,
            fallbackIsLossless = parsed.rosterIsLossless,
        )
        // ProfileStore is a main-thread store (mirroring Apple's @MainActor); fold + build on Main.
        val published = withContext(Dispatchers.Main) {
            publishIfSyncLeaseCurrent(lease) {
                // UNION the cloud roster into the local one first (never shrinks local), so the block we push
                // already carries both sides; a cloud-only profile survives the round-trip. Fold under the
                // remote-apply flag so this union does not self-arm a push.
                applyingRemote = true
                try {
                    // TOMBSTONES FIRST (#145 M6), the same precedence syncDown already applies and the same
                    // order Apple `mergeLocalIntoDoc` folds in: mergeInRoster below SUBTRACTS deletedProfileIDs
                    // from the union, so without this fold the pulled cloud roster re-seeds a profile a peer
                    // deleted and the push sends it straight back up, resurrecting it on every device. The fold
                    // is a monotone, idempotent union that also prunes the live roster, so it needs no version
                    // gate; buildVortx then emits the folded set (and read-merges the pulled one again).
                    if (parsed.deletedProfiles.isNotEmpty()) store.mergeDeletedTombstones(parsed.deletedProfiles)
                    val libraryStamps = OwnerLibraryHistoryPolicy.canonicalLibraryTombstones(
                        parsed.copy(ownerLibrary = parsed.ownerLibrary.orEmpty() + localOwnerLibrary.orEmpty()),
                    )
                    if (parsed.deletedLibrary.isNotEmpty() || libraryStamps.isNotEmpty()) {
                        libraryTombstones.merge(parsed.deletedLibrary, libraryStamps)
                        refreshSettingsShadow()
                    }
                    // Fold app-authored add-on tombstones before publishing this read-merge. The max fold is
                    // monotone, so a peer deletion remains authoritative over a locally seeded add-on, while
                    // a newer explicit install's addedAt stamp is retained and wins on every later pull.
                    // Stamp-less web removals are deliberately minted only in syncDown (the single guarded
                    // mint chokepoint), never by a push-path read merge.
                    if (parsed.deletedAddons.isNotEmpty() || parsed.deletedAddonsTs.isNotEmpty()) {
                        addonTombstones.merge(parsed.deletedAddons, parsed.deletedAddonsTs)
                    }
                    resolvedRoster.roster?.let {
                        foldNativeProfileRoster(store, doc, it, resolvedRoster.modifiedSeconds, parsed.rosterIsLossless)
                    }
                    foldDashboardProfileEdits(store, doc)
                } finally {
                    applyingRemote = false
                }
                SettingsBackup.settingsBlobFor(
                    pulledBlob = doc.opt("settings"),
                    roster = store.profiles,
                    rosterModifiedSeconds = store.rosterModified,
                    bundleId = settingsBundleId,
                    // gap 1: carry this device's syncable GLOBAL app settings (theme, subtitle style, player
                    // toggles, home/discover layout, ...) on the SAME channel + keys Apple uses. Local-wins,
                    // never-delete: only keys this device holds are set; a key it lacks keeps the account's value.
                    deviceSettings = SettingsBackup.plistSettingsFrom(settingsPrefs.all),
                    rawRosterJson = VortXSyncDoc.preservedRoster(store.profiles,
                        doc.optJSONObject("vortx")?.optJSONArray("roster"), SettingsBackup.rawRosterFromBlob(doc.opt("settings"))).toString(),
                )?.let { doc.put("settings", it) }
                val vortx = VortXSyncDoc.buildVortx(store, doc.optJSONObject("vortx"))
                if (!vortx.has("ownerWatched") || vortx.optJSONObject("ownerWatched") != null) {
                    val watchedWire = ownerWatchedIntents.wire(lease.accountId, vortx.optJSONObject("ownerWatched"))
                    if (watchedWire.length() > 0) vortx.put("ownerWatched", watchedWire)
                }
                VortXSyncDoc.mergeLocalAddons(
                    vortx = vortx,
                    local = localAddons,
                    removed = addonTombstones.all(),
                )
                VortXSyncDoc.mergeLocalOwnerLibrary(vortx, localOwnerLibrary?.filterNot { it.historyOnly }, libraryTombstones.all())
                VortXSyncDoc.mergeLocalOwnerHistory(vortx, localOwnerLibrary.orEmpty())
                doc.put(
                    "vortx",
                    applyAddonTombstonesToVortx(applyLibraryTombstonesToVortx(vortx), addonTombstones),
                )
                // gap 2: mirror this device's connected-service (debrid) keys on doc.apiKeys, read-merge +
                // never-delete, so a key set on one device follows the account. Foreign apiKeys keys are preserved.
                mergeDebridKeysIntoDoc(doc)
                mergeMetadataKeysIntoDoc(doc)
                // Do not turn every routine push into a stale order write. Only an unacknowledged local
                // drag owns the top-level spine; accepted pushes clear exactly that dirty generation.
                if (addonPrefs.orderDirtyAt() != null) {
                    val order = addonPrefs.appliedOrder()
                    val authorized = (parsed.addons + localAddons).mapTo(HashSet()) { AddonTombstones.normalize(it.transportUrl) }
                    val publishableOrder = order.filter { AddonTombstones.normalize(it) in authorized }
                    if (order.isEmpty()) doc.remove("addonOrder")
                    else if (publishableOrder.isNotEmpty()) doc.put("addonOrder", JSONArray(publishableOrder))
                }
            }
        }
        return if (published && isSyncLeaseCurrent(lease)) deriveBackup(lease, doc, pull, gateway = null) else null
    }

    /**
     * Apply an incoming account `doc.settings` blob's GLOBAL device settings into `vortx_settings` (gap 1). Writes
     * ONLY the [SettingsBackup.SYNCABLE_SETTING_TYPES] keys the blob carries, each under the exact type its getter
     * expects, and NEVER clears a key the blob omits (a device missing a setting keeps its own value, mirroring
     * Apple's never-wipe restore). Must run inside syncDown's apply window (applyingRemote true) so these
     * SharedPreferences writes cannot arm a self-echo push. Returns true when at least one setting was applied.
     */
    private fun foldNativeProfileRoster(store: ProfileStore, doc: JSONObject,
        remote: List<com.vortx.android.profile.UserProfile>, modified: Double?, carrierIsLossless: Boolean) {
        val lossless = carrierIsLossless || SettingsBackup.rosterFromBlob(doc.opt("settings"))?.isNotEmpty() == true
        val safe = DashboardProfileEdits.safeIncoming(store.profiles, remote, lossless)
        if (safe.isNotEmpty()) store.mergeInRoster(safe, if (lossless) modified else null)
    }

    private fun foldDashboardProfileEdits(store: ProfileStore, doc: JSONObject): Boolean {
        val result = DashboardProfileEdits.apply(store.profiles, store.deletedProfileIDs,
            store.rosterModified, doc.optJSONObject("profileEdits"), doc.optJSONObject("vortx")?.opt("updatedAt"))
        val changed = result.profiles != store.profiles || result.deletedIDs.isNotEmpty()
        if (result.deletedIDs.isNotEmpty()) store.mergeDeletedTombstones(result.deletedIDs.toList())
        if (result.profiles.isNotEmpty()) store.mergeInRoster(result.profiles, result.modified)
        return changed
    }

    private fun applyDeviceSettings(blob: Any?): Boolean {
        val settings = SettingsBackup.settingsFromBlob(blob) ?: return false
        if (settings.isEmpty()) return false
        // LOCAL-WINS: a key the user changed on THIS device whose push has not confirmed yet keeps its local
        // value; the account's older copy must not clobber it across a relaunch (the "toggle would not stay"
        // bug). The mark clears only when this device's own confirmed push carries the value up.
        val dirty = readDirtySettings().keys
        val editor = settingsPrefs.edit()
        var applied = 0
        for ((key, value) in settings) {
            if (key in dirty) continue
            when (value) {
                is SettingsBackup.BackupValue.Bool -> editor.putBoolean(key, value.value)
                is SettingsBackup.BackupValue.IntValue -> editor.putInt(key, value.value)
                is SettingsBackup.BackupValue.LongValue -> editor.putLong(key, value.value)
                is SettingsBackup.BackupValue.FloatValue -> editor.putFloat(key, value.value)
                is SettingsBackup.BackupValue.Str -> editor.putString(key, value.value)
                is SettingsBackup.BackupValue.StrSet -> editor.putStringSet(key, value.value)
            }
            applied++
        }
        if (applied == 0) return false
        editor.apply()
        // The just-applied remote values become the differ baseline, so they are never mistaken for a
        // future LOCAL edit (Apple re-baselines its shadow before clearing the applyingRemote flag).
        refreshSettingsShadow()
        return true
    }

    /** Known global keys retain their exact Android storage type; unknown registers stay sealed
     * for other platforms. A malformed known value fails instead of a lossy/coercing application. */
    private fun applyNativeGlobalPreferences(document: JSONObject?) {
        val fields = document?.getJSONObject("globals")?.getJSONObject("fields") ?: return
        val dirty = readDirtySettings().keys
        val editor = settingsPrefs.edit()
        for (field in fields.keys()) {
            if (field in dirty || field in NATIVE_PROFILE_SETTING_KEYS) continue
            val type = SettingsBackup.SYNCABLE_SETTING_TYPES[field] ?: continue
            val value = fields.getJSONObject(field).get("value")
            if (value == JSONObject.NULL) { editor.remove(field); continue }
            when (type) {
                SettingsBackup.SettingType.BOOL -> editor.putBoolean(field, value as? Boolean ?: error("Invalid native boolean preference"))
                SettingsBackup.SettingType.STRING -> editor.putString(field, value as? String ?: error("Invalid native string preference"))
                SettingsBackup.SettingType.INT -> {
                    require(value is Number)
                    editor.putInt(field, java.math.BigDecimal(value.toString()).intValueExact())
                }
                SettingsBackup.SettingType.FLOAT -> {
                    require(value is Number && value.toDouble().isFinite() && value.toFloat().isFinite())
                    editor.putFloat(field, value.toFloat())
                }
                SettingsBackup.SettingType.STRING_SET, SettingsBackup.SettingType.JSON_STRING_ARRAY -> {
                    val array = value as? JSONArray ?: error("Invalid native array preference")
                    val values = (0 until array.length()).map { array.get(it) as? String ?: error("Invalid native string array") }
                    if (type == SettingsBackup.SettingType.STRING_SET) editor.putStringSet(field, values.toSet())
                    else editor.putString(field, JSONArray(values).toString())
                }
            }
        }
        check(editor.commit()) { "Could not persist native global preferences" }
        refreshSettingsShadow()
    }

    /**
     * Read-merge this device's configured debrid service keys into `doc.apiKeys` (gap 2), mirroring Apple's
     * apiKeys leg. START from the pulled `apiKeys` and SET only the slots this device holds; NEVER delete a key
     * this device did not author, so a TMDB / Trakt / SIMKL / media-server / IPTV key another surface wrote is
     * preserved (the asymmetric read-merge Apple uses). The keys are owner-scoped by [DebridKeys]' account
     * binding, so a signed-in device only ever emits its OWN account's keys. Key VALUES are never logged. An
     * empty result never creates an `apiKeys` object, so a fresh account does not gain an empty key.
     */
    private fun mergeDebridKeysIntoDoc(doc: JSONObject) {
        val keys = doc.optJSONObject("apiKeys")?.let { JSONObject(it.toString()) } ?: JSONObject()
        for (service in DebridService.entries) {
            if (debridKeys.isConfigured(service)) keys.put(service.id, debridKeys.key(service))
        }
        if (keys.length() > 0) doc.put("apiKeys", keys)
    }

    /**
     * WHY K-05: metadata credentials use their own `apiKeys.metadata` namespace. Read-merging both levels
     * preserves fields written by peers that do not understand this leg, while omission never deletes a key.
     */
    private fun mergeMetadataKeysIntoDoc(doc: JSONObject) {
        val apiKeys = doc.optJSONObject("apiKeys")?.let { JSONObject(it.toString()) } ?: JSONObject()
        val metadata = apiKeys.optJSONObject("metadata")?.let { JSONObject(it.toString()) } ?: JSONObject()
        for (slot in MetadataProviderKeys.Slot.entries) {
            val value = metadataKeys.value(slot)
            if (value.isNotEmpty()) metadata.put(slot.syncKey, value)
        }
        if (metadata.length() > 0) apiKeys.put("metadata", metadata)
        if (apiKeys.length() > 0) doc.put("apiKeys", apiKeys)
    }

    /**
     * Apply connected-service (debrid) keys from an incoming `doc.apiKeys` (gap 2). Sets ONLY the slots the blob
     * carries and NEVER clears a locally-configured key the blob omits (mirrors Apple's never-delete-on-absence
     * apiKeys guard). Owner-scoped via [DebridKeys]' account binding; a failed durable write is skipped
     * (fail-soft) rather than surfaced. Key VALUES are never logged. Returns true when at least one key applied.
     */
    private fun applyDebridKeys(apiKeys: JSONObject?): Boolean {
        apiKeys ?: return false
        var applied = false
        for (service in DebridService.entries) {
            val value = apiKeys.optString(service.id, "")
            if (value.isNotEmpty() && debridKeys.setKey(service, value)) applied = true
        }
        return applied
    }

    /** WHY K-05: apply only present, non-empty metadata slots, preserving every omitted local credential. */
    private fun applyMetadataKeys(apiKeys: JSONObject?): Boolean {
        val metadata = apiKeys?.optJSONObject("metadata") ?: return false
        var applied = false
        for (slot in MetadataProviderKeys.Slot.entries) {
            val value = metadata.optString(slot.syncKey, "")
            if (value.isNotEmpty() && metadataKeys.set(slot, value)) applied = true
        }
        return applied
    }

    /**
     * Pull the account doc and apply what is NEWER than this device holds. Deferred while a local push is
     * queued (so it never re-applies the account's pre-edit value over a fresh local edit) and version-gated
     * (applies only a strictly-newer remote). `force` ignores the version guard, but never the pending-edit
     * guard. A `.failed` / `.empty` pull applies NOTHING (never wipes local). Mirrors Apple `syncDown`.
     */
    suspend fun syncDown(force: Boolean = false): Boolean {
        val lease = captureSyncLease() ?: return false
        val synced = syncDown(lease, force)
        return synced && isSyncLeaseCurrent(lease)
    }

    private suspend fun syncDown(
        lease: SyncSessionLease,
        force: Boolean = false,
        routineReceive: Boolean = false,
    ): Boolean = accountFileManagedWriter(false) {
        if (!routineSyncAllowed(lease)) return@accountFileManagedWriter false
        return@accountFileManagedWriter try { withContext(nativeWorkDispatcher) {
            nativeSyncMutex.withLock {
                if (!routineSyncAllowed(lease)) return@withLock false
                val gateway = nativeGateway ?: return@withLock false
                runNativeAccountAttempt(onUnavailable = { markNativeAccountUnavailable(lease, gateway) }) {
                    nativeSyncDown(lease, gateway, force, routineReceive)
                }.also { if (it) clearNativeAccountUnavailable(lease, gateway) }
            }
        } }
            catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel }
            catch (_: Exception) { false }
    }

    /** Remove only add-ons with an effective tombstone; repository skips protected engine stubs. */
    private suspend fun enforceRemovedAccountAddons(lease: SyncSessionLease): Boolean {
        val gateway = addonGateway ?: return true
        val removed = addonTombstones.all()
        if (removed.isEmpty()) return true
        val nativeLease = gateway.captureAccountAddonLease() ?: return false
        if (!isSyncLeaseCurrent(lease)) return false
        val installed = gateway.accountAddonSnapshot(nativeLease)
        if (!isSyncLeaseCurrent(lease)) return false
        for (descriptor in installed) {
            val identity = AddonTombstones.normalize(descriptor.transportUrl)
            if (identity !in removed) continue
            if (!isSyncLeaseCurrent(lease)) return false
            gateway.removeAccountAddon(nativeLease, identity, syncLeaseAdmission(lease))
            if (!isSyncLeaseCurrent(lease)) return false
        }
        return true
    }

    /** Install only missing valid descriptors and converge the shared order without overwriting a local drag. */
    private suspend fun applyRemoteAccountAddons(
        lease: SyncSessionLease,
        parsed: VortXSyncDoc.Parsed,
    ): Boolean {
        val gateway = addonGateway ?: return false
        val removed = addonTombstones.all()
        val nativeLease = gateway.captureAccountAddonLease() ?: return false
        if (!isSyncLeaseCurrent(lease)) return false
        val installed = gateway.accountAddonSnapshot(nativeLease)
        if (!isSyncLeaseCurrent(lease)) return false
        val present = installed.mapTo(HashSet()) { AddonPublicationProofs.endpoint(it.transportUrl) }
        var changed = false
        for (descriptor in parsed.addons) {
            val identity = AddonTombstones.normalize(descriptor.transportUrl)
            if (identity.isEmpty() || identity in removed || AddonPublicationProofs.endpoint(descriptor.transportUrl) in present) continue
            if (!isSyncLeaseCurrent(lease)) return false
            if (gateway.installAccountAddon(nativeLease, descriptor, syncLeaseAdmission(lease))) changed = true
            if (!isSyncLeaseCurrent(lease)) return false
        }
        val native = gateway.nativeAddonOwner(nativeLease)
        if (native != null) {
            val post = gateway.accountAddonSnapshot(nativeLease)
            val authorized = parsed.addons.filter { AddonTombstones.normalize(it.transportUrl) !in removed }
            val witnessed = authorized.mapNotNull { expected ->
                post.singleOrNull { AddonPublicationProofs.matchesInstalled(expected, it) }?.let { it to expected }
            }
            if (!syncLeaseAdmission(lease).invoke { addonPublicationProofs.grant(lease.accountId, native, witnessed) }) return false
        }
        if (!enforceRemovedAccountAddons(lease)) return false
        // Dirty is persisted per account: a late remote order cannot erase an unacknowledged local reorder,
        // including after process death. Remote application is marked remote so it does not self-push.
        if (parsed.addonOrder != null) {
            val wroteOrder = syncLeaseAdmission(lease).invoke {
                addonPrefs.orderDirtyAt() == null && addonPrefs.setAppliedOrder(parsed.addonOrder, remote = true)
            }
            if (wroteOrder) {
                if (!isSyncLeaseCurrent(lease)) return false
                if (gateway.applyRemoteAddonOrder(nativeLease, parsed.addonOrder, syncLeaseAdmission(lease))) changed = true
                if (!isSyncLeaseCurrent(lease)) return false
            }
        }
        return changed
    }

    /** Executes the native dispatch while the VortX session identity remains serialized with adopt/sign-out. */
    private fun syncLeaseAdmission(lease: SyncSessionLease): ((() -> Boolean) -> Boolean) = { dispatch ->
        accountFileManagedWriter(false) {
            operations.snapshot { generation ->
                sessionState.serialized {
                    if (generation == lease.operationGeneration && sessionMatchesLease(lease) &&
                        pickerFileRecoverySession !== sessionState.value) dispatch() else false
                }
            }
        }
    }

    /** Restores newer history even for existing identities; native performs a fresh, fenced LWW check. */
    private suspend fun applyRemoteOwnerLibrary(lease: SyncSessionLease, parsed: VortXSyncDoc.Parsed): Boolean {
        val membership = parsed.ownerLibrary.orEmpty()
        val removed = libraryTombstones.all()
        val saved = membership.filter { !it.removed && LibraryTombstones.normalize(it.metaId) !in removed }.mapTo(hashSetOf()) { it.identity }
        if (membership.isEmpty() && parsed.ownerHistory.isEmpty() && removed.isEmpty()) return true
        val gateway = libraryGateway ?: return false
        val nativeLease = gateway.captureAccountLibraryLease() ?: return false
        if (!isSyncLeaseCurrent(lease)) return false
        val local = gateway.accountLibrarySnapshot(nativeLease, syncLeaseAdmission(lease)) ?: return false
        if (!isSyncLeaseCurrent(lease)) return false
        val native = gateway.nativeLibraryOwner(nativeLease)
        val stamps = libraryTombstones.timestampsForSync()
        if (native != null) local.mapNotNull { libraryPublicationProofs.published(lease.accountId, native, it) }
            .filter { !it.historyOnly && !it.removed && LibraryTombstones.normalize(it.metaId) !in removed }
            .forEach { saved.add(it.identity) }
        val history = parsed.ownerHistory.map { row ->
            val raw = local.singleOrNull { it.identity == row.identity }
            val prior = raw?.let { if (native != null) libraryPublicationProofs.published(lease.accountId, native, it) else null }
            OwnerLibraryHistoryPolicy.admitConditionalHistory(
                OwnerLibraryHistoryPolicy.preserveUndeclaredWatchFields(row, prior).copy(removed = row.identity !in saved), raw, prior)
        }
        val incoming = membership.map { row ->
            val raw = local.singleOrNull { it.identity == row.identity }
            val prior = raw?.let { if (native != null) libraryPublicationProofs.published(lease.accountId, native, it) else null }
            val stamp = stamps[LibraryTombstones.normalize(row.metaId)]
            val addedAt = stamp?.get("addedAt") ?: 0.0
            val readd = !row.removed && raw?.removed == true &&
                addedAt > (stamp?.get("removedAt") ?: 0.0) && addedAt > (raw.nativeEventEpochMs ?: 0).toDouble()
            OwnerLibraryHistoryPolicy.admitConditionalHistory(
                OwnerLibraryHistoryPolicy.preserveUndeclaredWatchFields(row, prior).copy(membershipAddedAt = addedAt.takeIf { readd }), raw, prior)
        } + history
        val eligible = incoming.filter {
            it.historyOnly || (LibraryTombstones.normalize(it.metaId) in removed) == it.removed
        }
        // A tombstone-only peer still carries a genuine membership event. Keep the local watch clock
        // and opaque watched field intact while applying that event's timestamp, never the receive time.
        val membershipRemovals = local.mapNotNull { item ->
            val id = LibraryTombstones.normalize(item.metaId)
            val epoch = stamps[id]?.get("removedAt")?.toLong()
            if (id in removed && !item.removed && epoch != null && epoch > 1L)
                item.copy(removed = true, eventEpochMs = epoch) else null
        }
        val candidates = OwnerLibraryHistoryPolicy.newerIncoming(eligible + membershipRemovals, local)
        if (candidates.isEmpty()) return isSyncLeaseCurrent(lease)
        val result = gateway.restoreAccountLibraryItems(nativeLease, candidates, syncLeaseAdmission(lease))
        if (!result.accepted || !isSyncLeaseCurrent(lease)) return false
        if (native != null) {
            // Only canonical account document rows can establish ownership. A synthetic membership
            // removal assembled from a resident foreign row must never claim its inherited history.
            val canonical = result.restored.mapNotNull { actual ->
                eligible.firstOrNull { OwnerLibraryPublicationProofs.matchesRestored(it, actual) }?.let { actual to it }
            }
            if (canonical.isNotEmpty() && !syncLeaseAdmission(lease).invoke { libraryPublicationProofs.grantProjected(lease.accountId, native, canonical) }) return false
        }
        return isSyncLeaseCurrent(lease)
    }

    /**
     * Auto-sync: a debounced push, armed whenever the roster or an overlay changes. Coalesces a burst of
     * edits into ONE push a couple of seconds later. Hard-gated on [applyingRemote] so a remote apply's own
     * writes never arm a push (the self-echo starvation). Mirrors Apple `requestSyncSoon`.
     */
    fun requestSyncSoon() {
        val lease = captureSyncLease() ?: return
        if (applyingRemote) return
        armPendingSync(lease, recordEdit = true)
    }

    /**
     * Restore a process-death dirty marker before a foreground pull. The caller's pull is deferred while
     * the exact account/session lease retries its merge-before-push.
     */
    private fun retryPendingPushBeforePull(lease: SyncSessionLease): Boolean =
        armPendingSync(lease, recordEdit = false)

    /**
     * Persist or restore dirty state before creating the lazy debounce job. Coordinator validation happens
     * before and after the dedicated pending-state transaction, never while its lock is held.
     */
    private fun armPendingSync(
        lease: SyncSessionLease,
        recordEdit: Boolean,
        progressOnly: Boolean = false,
    ): Boolean = accountFileManagedWriter(refused = true, observedEdit = recordEdit) {
        if (!isSyncLeaseCurrent(lease)) return@accountFileManagedWriter false
        if (!recordEdit && !routineSyncAllowed(lease)) return@accountFileManagedWriter true
        val owner = pendingOwner(lease)
        val proposedAttempt = PendingSyncAttempt(owner)
        val claim = if (recordEdit) {
            pendingState.recordEdit(owner, proposedAttempt, progressOnly, uploadClockMs())
        } else {
            pendingState.claimRestored(owner, proposedAttempt)
        }
        claim.replacedJob?.cancel()
        // Already-observed edits retain their marker. Only a resumed routine lease starts delivery.
        if (!routineSyncAllowed(lease) || requiresUpgrade(lease)) return@accountFileManagedWriter claim.blockPull
        val attempt = claim.attemptToStart ?: return@accountFileManagedWriter claim.blockPull

        val job = scope.launch(start = CoroutineStart.LAZY) {
            val runningJob = currentCoroutineContext()[Job] ?: return@launch
            var acceptedWithNewEdits = false
            runPendingSyncRetryLoop(
                initialDelayMs = SYNC_DEBOUNCE_MS,
                maxDelayMs = SYNC_RETRY_MAX_MS,
                shouldContinue = {
                    isActive &&
                        isSyncLeaseCurrent(lease) &&
                        !requiresUpgrade(lease) &&
                        pendingState.owns(attempt, runningJob)
                },
                // The loop's delay is the ordinary debounce until an upload fails, then its backoff.
                wait = { retryDelayMs ->
                    waitForUploadWindow(attempt, runningJob, retryDelayMs.takeIf { it > SYNC_DEBOUNCE_MS })
                },
                attempt = {
                    accountFileManagedWriter(false) writer@ {
                        if (!pendingState.ensureMarker(attempt, runningJob)) return@writer false
                        val editGeneration = pendingState.captureEditGeneration(attempt, runningJob)
                            ?: return@writer false
                        val synced = syncUp(lease)
                        DiagnosticsLog.log("sync", "upload result=${if (synced) "accepted" else "failed"}")
                        if (synced) pendingState.acknowledgeUpload(attempt, runningJob, editGeneration)
                        acceptedWithNewEdits = synced
                        synced &&
                            pendingState.completeAccepted(
                                expectedAttempt = attempt,
                                job = runningJob,
                                isCurrentSnapshot = { isSyncLeaseCurrentSnapshot(lease) },
                                expectedEditGeneration = editGeneration,
                            )
                    }
                },
                resetDelay = { acceptedWithNewEdits.also { acceptedWithNewEdits = false } },
            )
        }
        if (!pendingState.attachJob(attempt, job)) {
            job.cancel()
            return@accountFileManagedWriter claim.blockPull
        }
        if (!isSyncLeaseCurrent(lease)) {
            pendingState.abandon(attempt, job)
            job.cancel()
            return@accountFileManagedWriter claim.blockPull
        }
        job.start()
        return@accountFileManagedWriter claim.blockPull
    }

    /**
     * Sleep until [attempt] may upload: the ordinary cadence (or [failureBackoffMs]) for real edits, or until
     * playback goes quiet for progress-only work. A real edit wakes a worker sitting out a progress window,
     * and newer progress moves a quiet window later, so the wait is recomputed after each wake.
     */
    private suspend fun waitForUploadWindow(attempt: PendingSyncAttempt, job: Job, failureBackoffMs: Long?) {
        while (true) {
            val wait = pendingState.uploadWait(attempt, job, uploadClockMs(), SYNC_DEBOUNCE_MS, failureBackoffMs) ?: return
            if (!wait.progressWindow) {
                delay(wait.delayMs)
                return
            }
            if (wait.delayMs <= PROGRESS_WINDOW_SLACK_MS) return
            withTimeoutOrNull(wait.delayMs) { attempt.urgentWake.receive() }
        }
    }

    /** Monotonic clock for upload windows; tests point it at the virtual scheduler. */
    internal var uploadClockMs: () -> Long = { System.nanoTime() / 1_000_000L }

    /** Catch-up PULL entry point (manual "Sync now"); [startRealtime] is the foreground entry point. */
    fun syncDownSoon() {
        val lease = captureSyncLease() ?: return
        scope.launch { syncDown(lease) }
    }

    // ---- Real-time pull channel (WebSocket SyncRoom + while-active poll fallback) ----

    /**
     * The Android port of the Apple realtime leg ([VortXSyncRealtime]): the worker SyncRoom WebSocket
     * plus the 3s while-active fallback poll. Lazy so a signed-out launch never builds the OkHttp
     * client. The channel only ever calls the guarded [syncDown] -- the #145 pull guards (tri-state
     * pull, version-wins, pending-push defer) all still apply to every realtime-triggered apply.
     */
    private val defaultRealtime by lazy {
        VortXSyncRealtime(this, scope, BASE.replaceFirst("https://", "wss://") + "/v1/sync/connect")
    }
    private var realtimeTestSeam: VortXSyncRealtime? = null
    private val realtime: VortXSyncRealtime get() = realtimeTestSeam ?: defaultRealtime
    internal fun installRealtimeTestSeam(channel: VortXSyncRealtime) { realtimeTestSeam = channel }

    /**
     * Open the real-time channel + run one catch-up pull. Called on app-foreground (the
     * [com.vortx.android.VortXApplication] started-activity hook) and after a successful sign-in.
     * Idempotent and fail-soft: a no-op when signed out or already live, and a failed socket degrades
     * to the fallback poll, never breaking the pull+debounced-push engine underneath.
     */
    fun startRealtime() {
        operations.snapshot {
            if (realtimeForeground && pickerFileRecoverySession == null) {
                captureSyncLease()?.let(::retryPendingPushBeforePull)
                realtime.start()
            }
        }
    }

    /** Process activity-count transition; auth callers may request start but cannot create intent. */
    internal fun setRealtimeForeground(active: Boolean) {
        operations.snapshot {
            realtimeForeground = active
            if (active) startRealtime() else realtime.stop()
        }
    }

    /** Close the real-time channel. Called on app-background and inside [signOut]. Safe to repeat. */
    fun stopRealtime() {
        // Session retirement closes delivery but preserves the still-foreground lifecycle intent.
        realtime.stop()
    }

    /**
     * The signed-in account's applied-version high-water mark, for the realtime channel's up-front
     * broadcast filter (only a strictly-newer pushed version triggers a pull). Same-package internal,
     * like [currentSession]: not part of the public API.
     */
    internal fun lastAppliedVersion(): Long =
        captureSyncLease()?.let(::lastSyncedVersion) ?: 0L

    // Realtime work carries the session captured when its channel opened, never recaptures a
    // replacement session after a queued callback. Generation + ownerEpoch also fence A→B→A.
    internal fun captureRealtimeLease(): SyncSessionLease? =
        captureSyncLease()?.takeIf(::routineSyncAllowed)
    internal fun isRealtimeLeaseCurrent(lease: SyncSessionLease): Boolean = isSyncLeaseCurrent(lease)
    internal fun admitRealtimeLease(lease: SyncSessionLease, action: () -> Boolean): Boolean =
        syncLeaseAdmission(lease).invoke(action)
    internal fun lastAppliedVersion(lease: SyncSessionLease): Long =
        if (isSyncLeaseCurrent(lease)) lastSyncedVersion(lease) else Long.MAX_VALUE
    internal suspend fun syncDownForRealtime(lease: SyncSessionLease): Boolean = syncDown(lease, routineReceive = true)

    // ---- Sign-in reconciliation (no blind last-writer-wins) ----

    /** Does the account already hold synced data (so a sign-in is a merge), is it empty, or unreachable? */
    enum class AccountDataProbe { HAS_DATA, EMPTY, UNREACHABLE }

    suspend fun accountHasSyncData(): AccountDataProbe {
        val lease = captureSyncLease() ?: return AccountDataProbe.UNREACHABLE
        val result = accountHasSyncData(lease)
        return result.takeIf { isSyncLeaseCurrent(lease) } ?: AccountDataProbe.UNREACHABLE
    }

    private suspend fun accountHasSyncData(lease: SyncSessionLease): AccountDataProbe {
        if (retryPendingPushBeforePull(lease)) return AccountDataProbe.UNREACHABLE
        val pull = pullSyncDocResult(lease)
        if (retryPendingPushBeforePull(lease)) return AccountDataProbe.UNREACHABLE
        return when (pull) {
            is SyncDocPull.Doc ->
                if (pull.doc.has("vortx") || pull.doc.has("settings") || pull.doc.has("apiKeys"))
                    AccountDataProbe.HAS_DATA else AccountDataProbe.EMPTY
            is SyncDocPull.Empty -> AccountDataProbe.EMPTY       // genuinely no backup yet: safe to seed
            is SyncDocPull.Failed, is SyncDocPull.Unchanged -> AccountDataProbe.UNREACHABLE // blip / refused doc: retry, NEVER seed
        }
    }

    enum class SignInReconcile { SEEDED_FROM_DEVICE, HAS_ACCOUNT_DATA, UNREACHABLE }

    /**
     * Call right after a successful sign-in. A fresh (empty) account is seeded from this device; an account
     * with data returns [SignInReconcile.HAS_ACCOUNT_DATA] (the UI asks which side to keep); an unreachable
     * doc returns [SignInReconcile.UNREACHABLE] and pushes NOTHING (a blip is never treated as a fresh account).
     */
    suspend fun reconcileAfterSignIn(): SignInReconcile = reconcileAfterSignIn(captureSyncLease())
    internal suspend fun reconcileAfterSignIn(owner: PickerAccountSnapshot): SignInReconcile =
        reconcileAfterSignIn(captureCompletionLease(owner))
    private fun captureCompletionLease(owner: PickerAccountSnapshot): SyncSessionLease? = operations.snapshot {
        if (!isPickerCompletionOwnerCurrent(owner)) null else captureSyncLease()
    }
    private suspend fun reconcileAfterSignIn(captured: SyncSessionLease?): SignInReconcile {
        val lease = captured ?: return SignInReconcile.UNREACHABLE
        val probe = accountHasSyncData(lease)
        if (!isSyncLeaseCurrent(lease)) return SignInReconcile.UNREACHABLE
        return when (probe) {
            AccountDataProbe.HAS_DATA -> SignInReconcile.HAS_ACCOUNT_DATA
            AccountDataProbe.UNREACHABLE -> SignInReconcile.UNREACHABLE
            AccountDataProbe.EMPTY -> {
                if (syncUp(lease) && isSyncLeaseCurrent(lease)) {
                    SignInReconcile.SEEDED_FROM_DEVICE
                } else {
                    SignInReconcile.UNREACHABLE
                }
            }
        }
    }

    /** Conflict resolution: adopt the account's roster (forced). Still UNIONs, so no local-only profile is lost. */
    suspend fun useAccountData(): Boolean = useAccountData(captureSyncLease())
    internal suspend fun useAccountData(owner: PickerAccountSnapshot): Boolean = useAccountData(captureCompletionLease(owner))
    private suspend fun useAccountData(captured: SyncSessionLease?): Boolean {
        val lease = captured ?: return false
        val received = syncDown(lease, force = true)
        return received && isSyncLeaseCurrent(lease)
    }

    /** Conflict resolution / "Sync now": push this device's roster + overlays to the account. */
    suspend fun pushThisDevice(): Boolean {
        val lease = captureSyncLease() ?: return false
        if (retryPendingPushBeforePull(lease)) return false
        val pushed = syncUp(lease)
        return pushed && isSyncLeaseCurrent(lease)
    }

    /** Explicit Keep device choice only. Sync now, automatic empty seeding, and Merge both never grant. */
    suspend fun importThisDeviceLibraryAndPush(): Boolean = importThisDeviceLibraryAndPush(captureSyncLease())
    internal suspend fun importThisDeviceLibraryAndPush(owner: PickerAccountSnapshot): Boolean = importThisDeviceLibraryAndPush(captureCompletionLease(owner))
    private suspend fun importThisDeviceLibraryAndPush(captured: SyncSessionLease?): Boolean {
        val lease = captured?.takeIf(::routineSyncAllowed) ?: return false
        val gateway = libraryGateway ?: return false
        val nativeLease = gateway.captureAccountLibraryLease() ?: return false
        val native = gateway.nativeLibraryOwner(nativeLease) ?: return false
        val snapshot = gateway.accountLibrarySnapshot(nativeLease, syncLeaseAdmission(lease)) ?: return false
        val imported = snapshot.map { raw ->
            // Native removed also represents watch-only, not an explicit library-delete intent.
            val hasPlayback = raw.videoId != null && raw.durationMs > 0 && OwnerLibraryHistoryPolicy.watchClock(raw) != null
            val outbound = if (hasPlayback) raw.copy(historyOnly = raw.removed) else raw.copy(
                lastWatched = null, eventEpochMs = null, nativeEventEpochMs = null,
                videoId = null, timeOffsetMs = 0, durationMs = 0, historyOnly = raw.removed,
            )
            raw to outbound
        }
        if (!syncLeaseAdmission(lease).invoke { libraryPublicationProofs.grantProjected(lease.accountId, native, imported) }) return false
        val addons = addonGateway
        if (addons != null) {
            val addonLease = addons.captureAccountAddonLease() ?: return false
            val addonNative = addons.nativeAddonOwner(addonLease) ?: return false
            val addonSnapshot = addons.accountAddonSnapshot(addonLease)
            if (!syncLeaseAdmission(lease).invoke { addonPublicationProofs.grant(lease.accountId, addonNative, addonSnapshot.map { it to it }) }) return false
        }
        return syncUp(lease) && isSyncLeaseCurrent(lease)
    }

    /** "Sync now" recommended path: union both ways so EVERY profile from both sides survives, then push. */
    suspend fun mergeBoth(): Boolean = mergeBoth(captureSyncLease())
    internal suspend fun mergeBoth(owner: PickerAccountSnapshot): Boolean = mergeBoth(captureCompletionLease(owner))
    private suspend fun mergeBoth(captured: SyncSessionLease?): Boolean {
        val lease = captured ?: return false
        if (retryPendingPushBeforePull(lease)) return false
        val received = syncDown(lease, force = true)
        // Native receive reports admission/publication success. A later push cannot settle a failed
        // account restore.
        if (!received) return false
        if (!isSyncLeaseCurrent(lease)) return false
        if (retryPendingPushBeforePull(lease)) return false
        val pushed = syncUp(lease)
        return pushed && isSyncLeaseCurrent(lease)
    }

    // MARK: - Session adoption + persistence

    private enum class SessionAdoption {
        ADOPTED,
        STALE,
        STORAGE_FAILURE,
    }

    private fun adopt(
        operation: SessionOperationCoordinator.AuthOperation,
        token: String,
        acct: JSONObject,
        dataKey: ByteArray,
        completion: PickerAuthCompletion? = null,
        recoveryIntent: PickerFileRecoverySignIn? = null,
        recoveryCaller: Job? = null,
        recoveryAttemptCurrent: (() -> Boolean)? = null,
    ): SessionAdoption {
        val account = Account(
            id = acct.optString("id"),
            email = acct.optString("email"),
            username = acct.optString("username"),
            twoFactorEnabled = acct.optBoolean("twoFactorEnabled", false),
        )
        val s = Session(token, account, dataKey)
        var recoveryRetired = false
        val adoption = when (
            val result = operation.commitSessionMutation(
                onCommitted = ::cancelSessionWork,
            ) {
                if (recoveryIntent != null &&
                    (recoveryCaller?.isActive == false || recoveryAttemptCurrent?.invoke() != true ||
                        !pickerFileRecoveryIntentCurrent(recoveryIntent))) {
                    recoveryRetired = true
                    return@commitSessionMutation false
                }
                sessionState.replace(s) {
                    publishPickerFileRecoverySession(s.takeIf { recoveryIntent != null })
                    nativeGateway?.retire()
                    bindLibraryAccount(account.id)
                    AddonTombstones.activateAccount(account.id)
                    AddonPrefsStore.activateAccount(account.id)
                    _account.value = account
                    _sessionUiState.value = SessionUiState.SignedIn(account)
                    completion?.record(capturePickerCompletionOwner())
                }
            }
        ) {
            is SessionMutationResult.Applied ->
                if (result.value) SessionAdoption.ADOPTED
                else if (recoveryRetired) SessionAdoption.STALE else SessionAdoption.STORAGE_FAILURE
            SessionMutationResult.Stale -> SessionAdoption.STALE
        }
        if (adoption == SessionAdoption.ADOPTED && recoveryIntent == null) {
            captureSyncLease()?.takeIf { it.accountId == account.id && it.token == token }?.let { lease ->
                armPendingSync(lease, recordEdit = false)
                scope.launch { syncDown(lease, force = true) }
            }
        }
        return adoption
    }

    private class SessionRenewalCapture(
        val owner: Session, val operationGeneration: Long, val ownerEpoch: Long,
        val sentToken: String, val dataKey: ByteArray,
    )

    private fun captureSessionRenewal(bearer: String?, permit: SessionOperationCoordinator.OutboundCallPermit): SessionRenewalCapture? =
        operations.snapshot { generation -> sessionState.serialized {
            val owner = sessionState.value ?: return@serialized null
            if (permit.owner != SessionOperationCoordinator.OutboundCallOwner.SESSION || !permit.isCurrent() ||
                bearer != owner.token || _sessionUiState.value != SessionUiState.SignedIn(owner.account) ||
                _account.value != owner.account || owner.dataKey.size != 32) return@serialized null
            SessionRenewalCapture(owner, generation, sessionState.ownerEpoch, owner.currentBearer, owner.dataKey.copyOf())
        } }

    private fun storeSessionRenewal(candidate: String?, captured: SessionRenewalCapture?,
                                    permit: SessionOperationCoordinator.OutboundCallPermit,
                                    method: String, path: String, status: Int, ifNoneMatch: String?,
                                    etag: String?, emptyBody: Boolean) {
        if (captured == null || !SessionRenewalPolicy.eligibleResponse(method, path, status, ifNoneMatch, etag, emptyBody) ||
            !SessionRenewalPolicy.accepts(candidate, captured.sentToken, captured.owner.account.id,
                sessionRenewalNowTestSeam?.invoke() ?: System.currentTimeMillis())) return
        operations.mutateIfCurrent(captured.operationGeneration) { sessionState.serialized {
            val owner = sessionState.value ?: return@serialized
            if (!permit.isCurrent() || owner !== captured.owner || sessionState.ownerEpoch != captured.ownerEpoch ||
                owner.currentBearer != captured.sentToken || !owner.dataKey.contentEquals(captured.dataKey) ||
                _sessionUiState.value != SessionUiState.SignedIn(owner.account) || _account.value != owner.account) return@serialized
            val next = candidate ?: return@serialized
            val saved = sessionRenewalPersistTestSeam?.invoke(owner, captured.sentToken, captured.ownerEpoch, next)
                ?: store.renew(owner, captured.sentToken, captured.ownerEpoch, next)
            if (saved && permit.isCurrent() && sessionState.value === owner &&
                sessionState.ownerEpoch == captured.ownerEpoch && owner.dataKey.contentEquals(captured.dataKey)) {
                owner.publishConfirmedRenewal(captured.sentToken, next)
            }
        } }
    }

    // Synthetic response and persistence boundaries for actual manager renewal regression tests.
    // Production still uses the real URL connection and exact encrypted tuple CAS above.
    internal data class SessionRenewalTestResponse(val status: Int, val body: JSONObject? = null,
        val renewal: String? = null, val etag: String? = null, val emptyBody: Boolean = true,
        val rawBody: ByteArray? = null)
    @Volatile private var sessionRenewalNowTestSeam: (() -> Long)? = null
    @Volatile private var sessionRenewalPersistTestSeam: ((Session, String, Long, String) -> Boolean)? = null
    @Volatile private var sessionRenewalTransportTestSeam: (suspend (String, String, String?) -> SessionRenewalTestResponse)? = null
    internal fun installSessionRenewalTestSeam(now: () -> Long,
        persist: (Session, String, Long, String) -> Boolean,
        transport: suspend (String, String, String?) -> SessionRenewalTestResponse) {
        sessionRenewalNowTestSeam = now; sessionRenewalPersistTestSeam = persist
        sessionRenewalTransportTestSeam = transport
    }
    internal suspend fun requestSessionRenewalForTest(method: String = "GET", path: String = "/v1/backup",
        ifNoneMatch: String? = null, authPermit: Boolean = false): Pair<Int, JSONObject?> {
        val lease = captureSyncLease() ?: return 0 to null
        val permit = if (authPermit) operations.beginAuth().acquireCallPermit() else acquireSyncCallPermit(lease)
        return request(method, path, null, lease.token, permit ?: return 0 to null, ifNoneMatch)
    }

    // MARK: - HTTP (tiny JSON-over-HttpURLConnection helper, same shape as IntegrationsHttp)

    /**
     * POST [body] to `api.vortx.tv` + [path], returning (status, parsed JSON or null). A transport failure
     * surfaces as (0, null) rather than throwing, so the auth flows stay fail-soft. `api.vortx.tv` is the
     * account-authed host and is deliberately NOT edge-signed (it is excluded from [VortXEdgeAuth]'s gate).
     */
    private suspend fun request(
        method: String,
        path: String,
        body: JSONObject?,
        bearerToken: String? = null,
        callPermit: SessionOperationCoordinator.OutboundCallPermit,
        ifNoneMatch: String? = null,
        receiveETag: ((String?) -> Unit)? = null,
        candidateCurrent: () -> Boolean = { true },
        accountFileDownload: AccountFileDownload? = null,
    ): Pair<Int, JSONObject?> {
        val renewalCapture = captureSessionRenewal(bearerToken, callPermit)
        val effectiveBearer = renewalCapture?.sentToken ?: bearerToken
        sessionRenewalTransportTestSeam?.let { transport ->
            try {
                if (!callPermit.isCurrent() || !candidateCurrent()) return 0 to null
                val response = transport(method, path, effectiveBearer)
                kotlinx.coroutines.currentCoroutineContext().ensureActive()
                if (!callPermit.isCurrent() || !candidateCurrent()) return 0 to null
                receiveETag?.invoke(response.etag)
                storeSessionRenewal(response.renewal, renewalCapture, callPermit, method, path,
                    response.status, ifNoneMatch, response.etag, response.emptyBody)
                if (accountFileDownload != null) {
                    check(method == "GET" && path == "/v1/backup" && body == null && ifNoneMatch == null &&
                        bearerToken == accountFileDownload.lease.token)
                    if (!isAccountFileDownloadCurrent(accountFileDownload)) return 0 to null
                    if (response.status == 200 && response.rawBody != null) accountFileDownload.response =
                        response.rawBody.inputStream().use(AccountBackupFile::readBoundedResponse)
                    return response.status to null
                }
                return response.status to response.body
            } finally { callPermit.close() }
        }
        if (accountFileDownload != null) {
            check(method == "GET" && path == "/v1/backup" && body == null && ifNoneMatch == null &&
                bearerToken == accountFileDownload.lease.token)
            accountFileTransportTestSeam?.let { transport ->
                return try {
                    if (!callPermit.isCurrent() || !candidateCurrent() || !isAccountFileDownloadCurrent(accountFileDownload)) 0 to null
                    else {
                        val (status, raw) = transport(method, path, effectiveBearer)
                        if (!callPermit.isCurrent() || !candidateCurrent() || !isAccountFileDownloadCurrent(accountFileDownload)) 0 to null
                        else {
                            if (status == 200 && raw != null) accountFileDownload.response =
                                raw.inputStream().use(AccountBackupFile::readBoundedResponse)
                            status to null
                        }
                    }
                } finally { callPermit.close() }
            }
        }
        conditionalRequestTestSeam?.let { testTransport ->
            if (!callPermit.isCurrent() || !candidateCurrent()) { callPermit.close(); return 0 to null }
            return try {
                val (status, json, etag) = testTransport(method, path, body, effectiveBearer, ifNoneMatch)
                receiveETag?.invoke(etag)
                status to json
            } finally { callPermit.close() }
        }
        requestTestSeam?.let { testTransport ->
            if (!callPermit.isCurrent() || !candidateCurrent()) { callPermit.close(); return 0 to null }
            return try {
                testTransport(method, path, body, effectiveBearer)
            } finally {
                callPermit.close()
            }
        }
        try {
            return withContext(Dispatchers.IO) {
                val bodyBytes = body?.toString()?.toByteArray(Charsets.UTF_8)
                if (!callPermit.isCurrent() || !candidateCurrent()) return@withContext 0 to null
                var connection: HttpURLConnection? = null
                try {
                    val opened = URL(BASE + path).openConnection() as HttpURLConnection
                    connection = opened
                    if (!callPermit.attachCancellation(opened::disconnect)) {
                        opened.disconnect()
                        return@withContext 0 to null
                    }
                    opened.apply {
                        requestMethod = method.uppercase()
                        connectTimeout = TIMEOUT_MS
                        readTimeout = TIMEOUT_MS
                        useCaches = false
                        // The session bearer for the backup/sync endpoints. `api.vortx.tv` is the account-authed
                        // host and is deliberately NOT edge-signed (excluded from VortXEdgeAuth's gate).
                        // Never follow a response to another origin with a stored bearer.
                        if (renewalCapture != null) instanceFollowRedirects = false
                        effectiveBearer?.let { setRequestProperty("authorization", "Bearer $it") }
                        if (method == "GET" && path == "/v1/backup") ifNoneMatch?.let { setRequestProperty("If-None-Match", it) }
                        if (bodyBytes != null) {
                            doOutput = true
                            setRequestProperty("content-type", "application/json")
                        }
                    }
                    if (bodyBytes != null) {
                        if (!callPermit.isCurrent() || !candidateCurrent()) return@withContext 0 to null
                        opened.outputStream.use { it.write(bodyBytes) }
                        // Once the request body is accepted, absolute server-side cancellation requires a
                        // server nonce. The post-response auth/session fence still blocks stale publication.
                    }
                    if (!callPermit.isCurrent()) return@withContext 0 to null
                    val status = opened.responseCode
                    val responseETag = opened.getHeaderField("ETag")
                    receiveETag?.invoke(responseETag)
                    val emptyNotModified = status != 304 || opened.inputStream.use { it.read() == -1 }
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    if (!callPermit.isCurrent() || !candidateCurrent()) return@withContext 0 to null
                    if (opened.url.protocol == "https" && opened.url.host == "api.vortx.tv" &&
                        opened.url.port in setOf(-1, 443) && opened.url.file == path) {
                        val renewals = opened.headerFields.entries.filter { it.key?.equals("X-VortX-Session", true) == true }
                            .flatMap { it.value.orEmpty() }
                        storeSessionRenewal(renewals.singleOrNull(), renewalCapture, callPermit,
                            method, path, status, ifNoneMatch, responseETag, emptyNotModified)
                    }
                    if (accountFileDownload != null) {
                        if (!callPermit.isCurrent() || !candidateCurrent() || !isAccountFileDownloadCurrent(accountFileDownload)) return@withContext 0 to null
                        if (status != 200) return@withContext status to null
                        val raw = opened.inputStream.use(AccountBackupFile::readBoundedResponse)
                        if (!callPermit.isCurrent() || !candidateCurrent() || !isAccountFileDownloadCurrent(accountFileDownload)) {
                            raw.fill(0)
                            return@withContext 0 to null
                        }
                        accountFileDownload.response = raw
                        return@withContext status to null
                    }
                    if (status == 304) return@withContext if (emptyNotModified) 304 to null else 0 to null
                    val stream = if (status in 200..399) opened.inputStream else opened.errorStream
                    val text = try { stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty() }
                        catch (error: IOException) {
                            // A known upgrade status is terminal even if its body is truncated.
                            if (status == 426) "" else throw error
                        }
                    val json = if (path == "/v1/backup") BackupRevisionPolicy.decodeResponse(text)
                        else runCatching { if (text.isNotEmpty()) JSONObject(text) else null }.getOrNull()
                    status to json
                } catch (_: IOException) {
                    0 to null
                } finally {
                    callPermit.close()
                    connection?.disconnect()
                }
            }
        } finally {
            callPermit.close()
        }
    }

    /**
     * Keystore-encrypted persistence for the session (token + account JSON + base64 data key). A rejected
     * mutation returns false, which prevents [DurableSessionState] from publishing a memory-only session.
     * Session credentials are never written to plain SharedPreferences.
     */
    private class SessionStore(appContext: Context) {
        private val store = FailClosedCredentialStore(
            context = appContext,
            encryptedFileName = ENCRYPTED_FILE,
            legacyPlainFileName = PLAIN_FALLBACK_FILE,
            tag = TAG,
        )

        fun persist(s: Session, ownerEpoch: Long): Boolean {
            val acct = JSONObject().apply {
                put("id", s.account.id)
                put("email", s.account.email)
                put("username", s.account.username)
                put("twoFactorEnabled", s.account.twoFactorEnabled)
            }
            return store.set(
                mapOf(
                    KEY_TOKEN to s.currentBearer,
                    KEY_ACCOUNT to acct.toString(),
                    KEY_DATA_KEY to VortXCrypto.b64(s.dataKey),
                    KEY_OWNER_EPOCH to ownerEpoch.toString(),
                ),
            )
        }

        fun renew(expected: Session, sentToken: String, ownerEpoch: Long, candidate: String): Boolean =
            SessionRenewalPolicy.persistConfirmed(candidate, sentToken, expected, ownerEpoch,
                store.confirmedSnapshot(*SessionRenewalPolicy.tupleKeys), store::replaceConfirmed)

        fun load(): SessionLoad {
            val snapshot = store.confirmedSnapshot(KEY_TOKEN, KEY_ACCOUNT, KEY_DATA_KEY, KEY_OWNER_EPOCH)
            if (snapshot.availability != PersistentCredentialAvailability.AVAILABLE) {
                return SessionLoad.UnknownOrUnavailable
            }
            val tokenRaw = snapshot.values[KEY_TOKEN]
            val accountRaw = snapshot.values[KEY_ACCOUNT]
            val dataKeyRaw = snapshot.values[KEY_DATA_KEY]
            val ownerEpochRaw = snapshot.values[KEY_OWNER_EPOCH]
            val ownerEpoch = ownerEpochRaw
                ?.toLongOrNull()
                ?.takeIf { it >= INITIAL_SESSION_OWNER_EPOCH }
                ?: if (ownerEpochRaw == null) {
                    INITIAL_SESSION_OWNER_EPOCH
                } else {
                    return SessionLoad.UnknownOrUnavailable
                }
            if (tokenRaw == null && accountRaw == null && dataKeyRaw == null) {
                return SessionLoad.Available(null, ownerEpoch)
            }
            val token = tokenRaw?.takeIf { it.isNotBlank() }
                ?: return SessionLoad.UnknownOrUnavailable
            val acctStr = accountRaw ?: return SessionLoad.UnknownOrUnavailable
            val dkStr = dataKeyRaw ?: return SessionLoad.UnknownOrUnavailable
            val dataKey = VortXCrypto.unb64(dkStr)
                ?.takeIf { it.size == 32 }
                ?: return SessionLoad.UnknownOrUnavailable
            val acct = runCatching { JSONObject(acctStr) }.getOrNull()
                ?: return SessionLoad.UnknownOrUnavailable
            val account = Account(
                id = acct.optString("id"),
                email = acct.optString("email"),
                username = acct.optString("username"),
                twoFactorEnabled = acct.optBoolean("twoFactorEnabled", false),
            )
            if (account.id.isBlank()) return SessionLoad.UnknownOrUnavailable
            return SessionLoad.Available(Session(token, account, dataKey), ownerEpoch)
        }

        fun clear(ownerEpoch: Long): Boolean =
            store.setAndPurgeLegacy(
                mapOf(
                    KEY_TOKEN to null,
                    KEY_ACCOUNT to null,
                    KEY_DATA_KEY to null,
                    KEY_OWNER_EPOCH to ownerEpoch.toString(),
                ),
            )

        private companion object {
            const val TAG = "VortXSyncSession"
            const val ENCRYPTED_FILE = "vortx_sync_session"
            const val PLAIN_FALLBACK_FILE = "vortx_sync_session_plain"
            const val KEY_TOKEN = "token"
            const val KEY_ACCOUNT = "account"
            const val KEY_DATA_KEY = "dataKey"
            const val KEY_OWNER_EPOCH = "ownerEpoch"
        }
    }

    private sealed interface SessionLoad {
        data class Available(
            val session: Session?,
            val ownerEpoch: Long,
        ) : SessionLoad
        data object UnknownOrUnavailable : SessionLoad
    }

    private fun SessionLoad.ownerEpochOrInitial(): Long =
        (this as? SessionLoad.Available)?.ownerEpoch ?: INITIAL_SESSION_OWNER_EPOCH

    private fun SessionLoad.uiState(): SessionUiState = when (this) {
        is SessionLoad.Available ->
            session?.account?.let(SessionUiState::SignedIn) ?: SessionUiState.SignedOut
        SessionLoad.UnknownOrUnavailable -> SessionUiState.UnknownOrUnavailable
    }

    /**
     * Per-account version, downgrade-ratchet, and pending-push persistence for the sync engine. Plain
     * SharedPreferences (the UserDefaults analogue Apple uses for these): the version high-water mark,
     * booleans, and dirty bit are not sensitive, so they never need the encrypted session store.
     */
    private class SyncStateStore(appContext: Context) {
        private val prefs: SharedPreferences =
            appContext.getSharedPreferences(STATE_FILE, Context.MODE_PRIVATE)

        fun captureRestoreBacking(): (() -> Boolean)? =
            NativeSettingsFence.capturePristineRestoreBacking(prefs, NativeSettingsFence.RestoreAuxiliaryBacking.SYNC_STATE)

        fun lastVersion(accountId: String): Long = prefs.getLong(KEY_VERSION + accountId, 0L)
        fun hasLastVersion(accountId: String): Boolean = prefs.contains(KEY_VERSION + accountId)
        fun setLastVersion(accountId: String, version: Long): Boolean =
            prefs.edit().putLong(KEY_VERSION + accountId, version).commit()

        fun sawV2(accountId: String): Boolean = prefs.getBoolean(KEY_SAW_V2 + accountId, false)
        fun nativeBackupSeen(accountId: String): Boolean = prefs.getBoolean("nativeBackupSeen." + accountId, false)
        fun markNativeBackupSeen(accountId: String): Boolean = prefs.edit().putBoolean("nativeBackupSeen." + accountId, true).commit()
        fun setSawV2(accountId: String) {
            prefs.edit().putBoolean(KEY_SAW_V2 + accountId, true).apply()
        }

        fun hasPendingPush(accountId: String): Boolean =
            accountId.isNotEmpty() && prefs.getBoolean(KEY_PENDING_PUSH + accountId, false)

        fun setPendingPush(accountId: String, pending: Boolean): Boolean {
            if (accountId.isEmpty()) return false
            val edit = prefs.edit()
            if (pending) {
                edit.putBoolean(KEY_PENDING_PUSH + accountId, true)
            } else {
                edit.remove(KEY_PENDING_PUSH + accountId)
            }
            return edit.commit()
        }

        private companion object {
            const val STATE_FILE = "vortx_sync_state"
            const val KEY_VERSION = "lastSyncedVersion."
            const val KEY_SAW_V2 = "sawDocV2."
            const val KEY_PENDING_PUSH = "pendingPush."
        }
    }

    companion object {
        internal fun qrPollDisposition(status: Int, hasApproval: Boolean): QrPollDisposition = when {
            status == 404 || status == 410 -> QrPollDisposition.EXPIRED
            status == 0 || status == 429 || status >= 500 -> QrPollDisposition.RETRIABLE_ERROR
            status == 200 && hasApproval -> QrPollDisposition.READY
            else -> QrPollDisposition.PENDING
        }

        internal fun unwrapQrPayload(payload: String, privateKey: ByteArray): ByteArray? {
            val envelope = runCatching { JSONObject(payload) }.getOrNull() ?: return null
            val claim = envelope.optString("claim").takeIf { it.isNotBlank() } ?: return null
            val wrapped = envelope.optString("wrapped").takeIf { it.isNotBlank() } ?: return null
            return VortXPairingCrypto.unwrapDataKey(wrapped, claim, privateKey)
        }

        private const val BASE = "https://api.vortx.tv"
        // Flat mirrors of native profile preferences must not become account-global registers.
        // Keep receive, export and settings-only scheduling on the same ownership boundary.
        private val NATIVE_PROFILE_SETTING_KEYS = setOf(
            "stremiox.theme.accent", "stremiox.theme.oled", "stremiox.theme.textScale",
            "stremiox.sub.font", "stremiox.sub.size", "stremiox.sub.color",
            "stremiox.sub.brightness", "stremiox.sub.background", "stremiox.sub.sizeScale",
        )
        private const val TIMEOUT_MS = 20_000
        private const val SESSION_STORAGE_FAILURE =
            "Secure storage is unavailable. Your VortX session was not changed. Please try again."
        private const val AUTH_SUPERSEDED =
            "This account action was superseded by a newer sign-in or sign-out."
        private const val NATIVE_ACCOUNT_UNAVAILABLE =
            "The native engine is unavailable or incompatible. Your saved data and pending changes are preserved. Update VortX or export diagnostics, then retry sync."

        /**
         * The v2 sync-document WRITE gate, held FALSE. Matches Apple `VortXSyncManager.writeSyncDocV2`
         * (VortXSyncManager.swift:73) and web `vault.ts` WRITE_SYNC_DOC_V2. A v2 doc is unreadable by any
         * client that predates `openDocument`, so v2 writes stay off until every client ships dual-read.
         * `openDocument` reads BOTH formats regardless; only WRITE is gated. DO NOT flip.
         */
        private const val WRITE_SYNC_DOC_V2 = false

        /** Debounce for the coalesced auto-push (Apple `requestSyncSoon`: 2.5s). */
        private const val SYNC_DEBOUNCE_MS = 2_500L
        /** A progress window this close to due is treated as due rather than slept again. */
        private const val PROGRESS_WINDOW_SLACK_MS = 50L

        /** Cap for failed pending-push retries; the delay doubles from [SYNC_DEBOUNCE_MS]. */
        private const val SYNC_RETRY_MAX_MS = 60_000L

        /** Bounded optimistic-concurrency retries for a derived push (Apple `pushDerivedDoc`: 3). */
        private const val PUSH_MAX_RETRIES = 3

        /**
         * The shared settings [SharedPreferences] file (Android's `UserDefaults` analogue). Kept as a literal
         * here rather than reaching into one store's private constant; every settings store names the same file.
         */
        private const val SETTINGS_PREFS_FILE = "vortx_settings"
    }
}
