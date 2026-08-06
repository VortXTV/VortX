package com.vortx.android.sync

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.vortx.android.backup.SettingsBackup
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.Collections
import java.util.IdentityHashMap

internal const val INITIAL_SESSION_OWNER_EPOCH = 1L

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

    fun clear(publish: () -> Unit = {}): Boolean {
        check(!Thread.holdsLock(this)) {
            "clear must acquire the owner transition before the session monitor"
        }
        return ownerTransition {
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
    private val activeCalls: MutableSet<OutboundCallPermit> =
        Collections.newSetFromMap(IdentityHashMap())

    fun beginAuth(): AuthOperation {
        var cancellations = emptyList<() -> Unit>()
        val operation = synchronized(lock) {
            authGeneration = nextGeneration(authGeneration)
            cancellations = retireCallsLocked { it.owner == OutboundCallOwner.AUTH }
            AuthOperation(authGeneration)
        }
        cancelCalls(cancellations)
        return operation
    }

    fun <T> invalidate(mutation: () -> T): T {
        var cancellations = emptyList<() -> Unit>()
        return try {
            synchronized(lock) {
                authGeneration = nextGeneration(authGeneration)
                sessionGeneration = nextGeneration(sessionGeneration)
                cancellations = retireCallsLocked { true }
                mutation()
            }
        } finally {
            cancelCalls(cancellations)
        }
    }

    fun <T> snapshot(read: (Long) -> T): T = synchronized(lock) {
        read(sessionGeneration)
    }

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
                        val nextSessionGeneration = nextGeneration(sessionGeneration)
                        val committed = mutation()
                        if (committed) {
                            sessionGeneration = nextSessionGeneration
                            cancellations = retireCallsLocked {
                                it.owner == OutboundCallOwner.SESSION
                            }
                            onCommitted()
                        }
                        SessionMutationResult.Applied(committed)
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
) {
    private val immutableDataKey = dataKey.copyOf()

    fun dataKeyCopy(): ByteArray = immutableDataKey.copyOf()
}

internal fun sessionTruthMatches(
    left: VortXSyncManager.Session?,
    right: VortXSyncManager.Session?,
): Boolean {
    if (left == null || right == null) return left == null && right == null
    return left.token == right.token &&
        left.account == right.account &&
        left.dataKey.contentEquals(right.dataKey)
}

internal suspend fun runPendingSyncRetryLoop(
    initialDelayMs: Long,
    maxDelayMs: Long,
    shouldContinue: () -> Boolean,
    wait: suspend (Long) -> Unit,
    attempt: suspend () -> Boolean,
): Boolean {
    require(initialDelayMs > 0 && maxDelayMs >= initialDelayMs)
    var retryDelayMs = initialDelayMs
    while (shouldContinue()) {
        wait(retryDelayMs)
        if (!shouldContinue()) return false
        val succeeded = attempt()
        if (succeeded) return true
        if (!shouldContinue()) return false
        retryDelayMs =
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
    ): PendingSyncClaim = synchronized(lock) {
        // Synchronous durable write precedes creation and start of the debounce coroutine.
        truthByAccount[nextOwner.accountId] = if (writeMarker(nextOwner.accountId, true)) {
            PendingMarkerTruth.DIRTY_CONFIRMED
        } else {
            // A failed SharedPreferences commit may still mutate its process-local cache. Remember the
            // uncertainty and never trust a same-process read as proof of restart durability.
            PendingMarkerTruth.DIRTY_UNCONFIRMED
        }
        val replaced = attempt?.job
        owner = nextOwner
        attempt = nextAttempt
        PendingSyncClaim(blockPull = true, attemptToStart = nextAttempt, replacedJob = replaced)
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
        isCurrentSnapshot: () -> Boolean,
    ): Boolean = synchronized(lock) {
        val accountId = expectedAttempt.owner.accountId
        if (
            owner != expectedAttempt.owner ||
            attempt !== expectedAttempt ||
            expectedAttempt.job !== job ||
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
class VortXSyncManager(context: Context) {

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
        override fun equals(other: Any?): Boolean =
            other is Session && token == other.token && account == other.account && dataKey.contentEquals(other.dataKey)
        override fun hashCode(): Int = 31 * (31 * token.hashCode() + account.hashCode()) + dataKey.contentHashCode()
    }

    private val appContext = context.applicationContext
    private val settingsBundleId = appContext.packageName
    private val debridKeys = DebridKeys(appContext)
    private val store = SessionStore(appContext)
    private val initialSessionLoad = store.load()
    private val sessionState = DurableSessionState(
        initialValue = (initialSessionLoad as? SessionLoad.Available)?.session,
        initialOwnerEpoch = initialSessionLoad.ownerEpochOrInitial(),
        persist = store::persist,
        clear = store::clear,
        ownerTransition = debridKeys::runOwnerTransition,
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

    /** IO scope for the debounced auto-push (requestSyncSoon) and background catch-up pulls. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The roster/overlay store the sync engine reads + folds into. Set by [attachSyncSeams]. */
    @Volatile private var profileStore: ProfileStore? = null

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
     * A persistence-backed owner snapshot for account-scoped device credentials. `null account` is only
     * published as a definitive signed-out state after the encrypted session store was read successfully.
     * Keystore unavailability, a partial/corrupt session tuple, or any disagreement between the live and
     * persisted session stays unknown so another subsystem cannot adopt signed-out local data by mistake.
     */
    internal fun sessionOwnerSnapshot(): SessionOwnerSnapshot = sessionState.serialized {
        val loaded = store.load()
        val available = loaded as? SessionLoad.Available
        if (available == null) {
            _sessionUiState.value = SessionUiState.UnknownOrUnavailable
            return@serialized SessionOwnerSnapshot.UnknownOrUnavailable(sessionState.ownerEpoch)
        }
        val persisted = available.session
        val live = sessionState.value
        val persistedOwnerEpoch = available.ownerEpoch
        if (_sessionUiState.value == SessionUiState.UnknownOrUnavailable) {
            sessionState.restore(persisted, persistedOwnerEpoch)
            _account.value = persisted?.account
        } else if (
            !sessionTruthMatches(live, persisted) ||
            sessionState.ownerEpoch != persistedOwnerEpoch
        ) {
            _sessionUiState.value = SessionUiState.UnknownOrUnavailable
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
    }

    /** Retry an unavailable/corrupt secure-session read without misclassifying it as sign-out. */
    fun retrySessionRestore() {
        sessionOwnerSnapshot()
    }

    private fun beginAuthOperation(): SessionOperationCoordinator.AuthOperation =
        operations.beginAuth()

    private fun cancelSessionWork() {
        stopRealtime()
        pendingState.resetTransient()?.cancel()
        applyingRemote = false
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
                realtime.start()
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
                )
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
        publication: () -> Unit,
    ): Boolean {
        val result = operations.mutateIfCurrent(lease.operationGeneration) {
            sessionState.serialized {
                if (!sessionMatchesLease(lease)) {
                    false
                } else {
                    publication()
                    true
                }
            }
        }
        return when (result) {
            is SessionMutationResult.Applied -> result.value
            SessionMutationResult.Stale -> false
        }
    }

    private fun sessionMatchesLease(lease: SyncSessionLease): Boolean {
        val current = sessionState.value ?: return false
        return sessionState.ownerEpoch == lease.ownerEpoch &&
            current.account.id == lease.accountId &&
            current.token == lease.token
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

    /**
     * Create an account. Generates the kdf salt, derives the master key, mints a random data key + a
     * recovery code, wraps the data key under BOTH the master key and the recovery key, and posts the
     * verifiers + wrapped keys. On success adopts the session and returns the one-time recovery code (the
     * UI must show it once and tell the user to store it offline). Mirrors Apple `register`.
     */
    suspend fun register(email: String, username: String, password: String): RegisterResult {
        val operation = beginAuthOperation()
        val kdfSalt = VortXCrypto.randomBytes(16)
        val iters = VortXCrypto.DEFAULT_ITERS
        val masterKey = VortXCrypto.masterKey(password, kdfSalt, iters)
        val dataKey = VortXCrypto.randomBytes(32)
        val recoveryCode = VortXCrypto.makeRecoveryCode()
        val recoveryKey = VortXCrypto.recoveryKey(recoveryCode, kdfSalt, iters)
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
            return when (adopt(operation, token, acct, dataKey)) {
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
    }

    /**
     * Sign in with email-or-username + password (+ optional TOTP). Pre-login fetches the account's kdf salt
     * + iterations; the master key is derived locally and only the auth verifier crosses the wire. On
     * success the password-wrapped data key is unwrapped on-device. Mirrors Apple `signIn`.
     */
    suspend fun signIn(login: String, password: String, totp: String? = null): AuthResult {
        val operation = beginAuthOperation()
        val preloginPermit = operation.acquireCallPermit()
            ?: return AuthResult.Failed(AUTH_SUPERSEDED)
        val (_, pre) = request(
            "POST",
            "/v1/auth/prelogin",
            JSONObject().put("login", login),
            callPermit = preloginPermit,
        )
        if (!operation.isCurrent()) return AuthResult.Failed(AUTH_SUPERSEDED)
        val salt = pre?.optString("kdfSalt").takeUnless { it.isNullOrEmpty() }?.let { VortXCrypto.unb64(it) }
        val iters = pre?.optInt("kdfIters", -1)?.takeIf { it > 0 }
        if (salt == null || iters == null) return AuthResult.Failed("Could not reach VortX. Try again.")
        // Reject a downgraded work factor from the UNAUTHENTICATED prelogin response before deriving the key.
        if (iters < VortXCrypto.MIN_ITERS) return AuthResult.Failed("Could not verify VortX security parameters. Try again.")

        val masterKey = VortXCrypto.masterKey(password, salt, iters)
        val body = JSONObject().apply {
            put("login", login)
            put("authVerifier", VortXCrypto.authVerifier(masterKey, password))
            if (!totp.isNullOrEmpty()) put("totp", totp)
        }
        if (!operation.isCurrent()) return AuthResult.Failed(AUTH_SUPERSEDED)
        val loginPermit = operation.acquireCallPermit()
            ?: return AuthResult.Failed(AUTH_SUPERSEDED)
        val (code, json) = request(
            "POST",
            "/v1/auth/login",
            body,
            callPermit = loginPermit,
        )
        if (!operation.isCurrent()) return AuthResult.Failed(AUTH_SUPERSEDED)
        if (code == 401 && json?.optString("error") == "totp_required") return AuthResult.TotpRequired

        val token = json?.optString("token").takeUnless { it.isNullOrEmpty() }
        val acct = json?.optJSONObject("account")
        val wrappedPw = json?.optString("wrappedKeyPassword").takeUnless { it.isNullOrEmpty() }
        val dataKey = wrappedPw?.let { VortXCrypto.open(masterKey, it) }
        if (code == 200 && token != null && acct != null && dataKey != null) {
            return when (adopt(operation, token, acct, dataKey)) {
                SessionAdoption.ADOPTED -> AuthResult.Ok
                SessionAdoption.STALE -> AuthResult.Failed(AUTH_SUPERSEDED)
                SessionAdoption.STORAGE_FAILURE -> AuthResult.Failed(SESSION_STORAGE_FAILURE)
            }
        }
        return AuthResult.Failed(if (code == 401) "Wrong login or password." else "Could not sign in.")
    }

    /**
     * Forgot-password recovery (DATA-PRESERVING): the user still has the recovery code. Unwrap the data key
     * with the recovery key, then re-derive a new master key from the SAME kdf salt the account already uses
     * (so the recovery key stays valid afterwards) and re-wrap the data key under it. Mirrors Apple `recover`.
     */
    suspend fun recover(email: String, recoveryCode: String, newPassword: String): AuthResult {
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

        val recoveryKey = VortXCrypto.recoveryKey(trimmed, salt, iters)
        val dataKey = VortXCrypto.open(recoveryKey, wrappedRec) ?: return AuthResult.Failed("That recovery code is not correct.")
        // Keep the existing kdfSalt (it also derives the recovery key); derive the new master from it.
        val newMaster = VortXCrypto.masterKey(newPassword, salt, iters)
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
            return when (adopt(operation, token, acct, dataKey)) {
                SessionAdoption.ADOPTED -> AuthResult.Ok
                SessionAdoption.STALE -> AuthResult.Failed(AUTH_SUPERSEDED)
                SessionAdoption.STORAGE_FAILURE -> AuthResult.Failed(SESSION_STORAGE_FAILURE)
            }
        }
        return AuthResult.Failed("Recovery failed.")
    }

    /** Sign out only after the encrypted session clear succeeds. */
    fun signOut(): Boolean {
        var retained: RetainedSessionWork? = null
        val cleared = operations.invalidate {
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
            cancelSessionWork()
            sessionState.clear {
                _account.value = null
                _sessionUiState.value = SessionUiState.SignedOut
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

    private fun resolveStore(): ProfileStore? = profileStore ?: ProfileStore.sharedOrNull()

    // ---- Per-account version guards (H-1 downgrade ratchet, H-2 high-water floor) ----

    /**
     * Newest doc version this device has pushed or applied FOR THE SIGNED-IN ACCOUNT (epoch-ms, a 64-bit
     * value — always a [Long]). Per-account so an account switch (out of A at v1000, into B at v5) never
     * treats B's pulls as stale. A fresh account key starts at 0, so the first pull is applied once.
     */
    private fun lastSyncedVersion(lease: SyncSessionLease): Long =
        syncState.lastVersion(lease.accountId)

    private fun advanceVersion(lease: SyncSessionLease, version: Long): Boolean =
        publishIfSyncLeaseCurrent(lease) {
            syncState.setLastVersion(
                lease.accountId,
                maxOf(version, syncState.lastVersion(lease.accountId)),
            )
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

    // ---- Tri-state pull (never conflate "no backup yet" with "the pull failed") ----

    private sealed interface SyncDocPull {
        data class Doc(val doc: JSONObject, val version: Long) : SyncDocPull
        data object Empty : SyncDocPull
        data object Failed : SyncDocPull
    }

    /**
     * Pull the account doc, distinguishing "no backup yet" (safe to seed) from "the pull failed" (must NOT
     * push, or it clobbers the account's existing doc). A non-200/non-404, an undecryptable doc, or a
     * version older than this account's high-water mark (H-2 rollback replay) is a FAILURE. A DECRYPT-MISS
     * throws no exception and yields Failed, never an empty `{}` that would wipe state.
     */
    private suspend fun pullSyncDocResult(lease: SyncSessionLease): SyncDocPull {
        if (!isSyncLeaseCurrent(lease)) return SyncDocPull.Failed
        val callPermit = acquireSyncCallPermit(lease) ?: return SyncDocPull.Failed
        val (code, json) = request(
            "GET",
            "/v1/backup",
            null,
            bearerToken = lease.token,
            callPermit = callPermit,
        )
        if (!isSyncLeaseCurrent(lease)) return SyncDocPull.Failed
        if (code == 404) return SyncDocPull.Empty                 // no backup yet
        if (code != 200) return SyncDocPull.Failed                // network/server error: do not clobber
        val body = json ?: return SyncDocPull.Empty               // 200 with no readable body: no backup
        val docStr = body.optString("document", "").takeUnless { it.isEmpty() } ?: return SyncDocPull.Empty
        // Version is a 64-bit epoch-ms value: read as LONG (optLong), NEVER optInt (which truncates it).
        val pulledVersion = body.optLong("version", 0L)
        // H-2: refuse an honest-label replay of a doc OLDER than what this account already applied. A real
        // server only returns a version >= our high-water mark, so this fires only on a rollback/replay.
        if (pulledVersion < lastSyncedVersion(lease)) return SyncDocPull.Failed
        val plaintext = openSyncDocument(lease, docStr, pulledVersion) ?: return SyncDocPull.Failed
        val obj = runCatching { JSONObject(String(plaintext, Charsets.UTF_8)) }.getOrNull()
            ?: return SyncDocPull.Failed                          // undecodable plaintext: do not clobber
        return if (isSyncLeaseCurrent(lease)) {
            SyncDocPull.Doc(obj, pulledVersion)
        } else {
            SyncDocPull.Failed
        }
    }

    // ---- Push with optimistic concurrency ----

    private sealed interface PushOutcome {
        data class Accepted(val version: Long) : PushOutcome
        data class Rejected(val storedVersion: Long?) : PushOutcome
        data object Error : PushOutcome
    }

    /**
     * Seal + PUT the doc at an explicit [version] (epoch-ms, a [Long]). Advances the per-account
     * high-water mark ONLY on accepted == true — advancing it on a rejected write would suppress the
     * recovery pull and silently drop a write that LOST the race. `accepted` defaults true so an older
     * worker without the field (which stored the write) still advances, matching the web's `accepted !== false`.
     */
    private suspend fun pushSyncDocAt(
        lease: SyncSessionLease,
        obj: JSONObject,
        version: Long,
    ): PushOutcome {
        if (!isSyncLeaseCurrent(lease)) return PushOutcome.Error
        val plaintext = obj.toString().toByteArray(Charsets.UTF_8)
        val ciphertext = VortXCrypto.sealDocument(
            lease.dataKeyCopy(),
            plaintext,
            lease.accountId,
            version,
            writeSyncDocV2,
        )
            ?: return PushOutcome.Error
        if (!isSyncLeaseCurrent(lease)) return PushOutcome.Error
        val body = JSONObject().put("document", ciphertext).put("version", version)  // Long: no truncation
        val callPermit = acquireSyncCallPermit(lease) ?: return PushOutcome.Error
        val (code, json) = request(
            "PUT",
            "/v1/backup",
            body,
            bearerToken = lease.token,
            callPermit = callPermit,
        )
        if (!isSyncLeaseCurrent(lease)) return PushOutcome.Error
        if (code != 200) return PushOutcome.Error
        val accepted = if (json != null && json.has("accepted")) json.optBoolean("accepted", true) else true
        if (accepted) {
            val published = publishIfSyncLeaseCurrent(lease) {
                syncState.setLastVersion(
                    lease.accountId,
                    maxOf(version, syncState.lastVersion(lease.accountId)),
                )
                if (writeSyncDocV2) markSawDocV2(lease.accountId)
            }
            if (!published) return PushOutcome.Error
            return PushOutcome.Accepted(version)
        }
        // Rejected (a concurrent write won). The worker echoes the current stored version (a Long) so we can
        // retry deterministically at stored+1 instead of racing epoch-ms again. Do NOT advance the version.
        val stored = json?.takeIf { it.has("version") }?.optLong("version")
        return PushOutcome.Rejected(stored)
    }

    /**
     * Push a doc DERIVED from a pulled base, with optimistic-concurrency recovery. On a lost race, [rebuild]
     * re-runs the caller's exact merge onto a freshly pulled base and retries strictly above the winner
     * (`max(stored + 1, epochMs)`, so a backward wall-clock can never lock the device out). On exhaustion or
     * a failed rebuild, the version is left unadvanced so the next natural pull reconciles. Mirrors Apple
     * `pushDerivedDoc`.
     */
    private suspend fun pushDerivedDoc(
        lease: SyncSessionLease,
        initial: JSONObject,
        rebuild: suspend () -> JSONObject?,
    ): Boolean {
        var doc = initial
        var version = System.currentTimeMillis()
        repeat(PUSH_MAX_RETRIES) { attempt ->
            when (val outcome = pushSyncDocAt(lease, doc, version)) {
                is PushOutcome.Accepted -> return true
                is PushOutcome.Error -> return false              // network/server/encode failure: reconcile later
                is PushOutcome.Rejected -> {
                    if (!isSyncLeaseCurrent(lease)) return false
                    if (attempt >= PUSH_MAX_RETRIES - 1) return false
                    val rebuilt = rebuild() ?: return false       // rebuild's pull now fails: abort, do not clobber
                    if (!isSyncLeaseCurrent(lease)) return false
                    doc = rebuilt
                    version = outcome.storedVersion?.let { maxOf(it + 1, System.currentTimeMillis()) }
                        ?: System.currentTimeMillis()
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

    private suspend fun syncUp(lease: SyncSessionLease): Boolean {
        if (!isSyncLeaseCurrent(lease)) return false
        val initial = mergeLocalIntoDoc(lease) ?: return false    // failed pull: never overwrite the account doc
        if (!isSyncLeaseCurrent(lease)) return false
        return pushDerivedDoc(lease, initial) { mergeLocalIntoDoc(lease) }
    }

    /**
     * Build the doc to push by MERGING this device's state onto a freshly pulled base. Returns null on a
     * FAILED pull (network / undecryptable): a failed pull must NEVER overwrite the account's doc, or it
     * wipes keys other surfaces wrote. UNIONs the cloud roster into the local one BEFORE building the vortx
     * block, so a device with FEWER profiles never shrinks the cloud's set. Mirrors Apple `mergeLocalIntoDoc`.
     */
    private suspend fun mergeLocalIntoDoc(lease: SyncSessionLease): JSONObject? {
        if (!isSyncLeaseCurrent(lease)) return null
        val store = resolveStore() ?: return null
        val doc: JSONObject = when (val pull = pullSyncDocResult(lease)) {
            is SyncDocPull.Failed -> return null
            is SyncDocPull.Empty -> JSONObject()
            is SyncDocPull.Doc -> pull.doc
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
                    resolvedRoster.roster?.let {
                        if (it.isNotEmpty()) store.mergeInRoster(it, resolvedRoster.modifiedSeconds)
                    }
                } finally {
                    applyingRemote = false
                }
                SettingsBackup.settingsBlobFor(
                    pulledBlob = doc.opt("settings"),
                    roster = store.profiles,
                    rosterModifiedSeconds = store.rosterModified,
                    bundleId = settingsBundleId,
                )?.let { doc.put("settings", it) }
                doc.put("vortx", VortXSyncDoc.buildVortx(store, doc.optJSONObject("vortx")))
            }
        }
        return doc.takeIf { published && isSyncLeaseCurrent(lease) }
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
    ): Boolean {
        if (!isSyncLeaseCurrent(lease)) return false
        // PENDING-EDIT GUARD: restore a durable process-death marker and retry its push before any
        // foreground pull. Even a forced pull must not overwrite a fresh local edit.
        if (retryPendingPushBeforePull(lease)) return false
        val pull = pullSyncDocResult(lease)
        if (!isSyncLeaseCurrent(lease)) return false
        if (retryPendingPushBeforePull(lease)) return false
        val doc: JSONObject
        val version: Long
        when (pull) {
            is SyncDocPull.Doc -> { doc = pull.doc; version = pull.version }
            else -> return false                                 // .empty / .failed: never wipe local
        }
        // VERSION-WINS: apply only a STRICTLY-NEWER remote; a stale or equal pull is a no-op.
        if (!force && version <= lastSyncedVersion(lease)) return false
        val parsed = VortXSyncDoc.parse(doc)
        val resolvedRoster = SettingsBackup.resolveRosterForPull(
            pulledBlob = doc.opt("settings"),
            fallbackRoster = parsed.roster,
            fallbackModifiedSeconds = parsed.rosterModifiedSeconds,
            fallbackIsLossless = parsed.rosterIsLossless,
        )
        var restored = false
        val published = withContext(Dispatchers.Main) {
            val store = resolveStore() ?: return@withContext false
            publishIfSyncLeaseCurrent(lease) {
                applyingRemote = true                            // the whole apply must not arm a self-echo push
                try {
                    // TOMBSTONES FIRST so the roster union below can never resurrect a deleted profile
                    // (tombstone-vs-resurrection precedence). mergeDeletedTombstones also prunes the live roster.
                    if (parsed.deletedProfiles.isNotEmpty() &&
                        store.mergeDeletedTombstones(parsed.deletedProfiles)
                    ) {
                        restored = true
                    }
                    // Roster UNION (never shrinks local; newest-wins by epoch-SECONDS; subtracts tombstones).
                    resolvedRoster.roster?.let { remote ->
                        if (remote.isNotEmpty()) {
                            store.mergeInRoster(remote, resolvedRoster.modifiedSeconds)
                            restored = true
                        }
                    }
                    // Per-profile watch overlays: union + LWW by lastWatched, never touching owner/engine history.
                    if (parsed.overlays.isNotEmpty()) {
                        for ((profileId, entries) in parsed.overlays) {
                            store.applyRemoteOverlay(profileId, entries)
                        }
                        restored = true
                    }
                    // Re-assert this session's local deletes after the fold: a profile deleted this session stays
                    // gone even if the pulled doc predates its tombstone (the resurrect window).
                    store.applyLocalTombstones()
                } finally {
                    applyingRemote = false
                }
            }
        }
        if (!published || !isSyncLeaseCurrent(lease)) return false
        // Stamp the applied version so the version-wins guard holds across relaunches (per account).
        if (!advanceVersion(lease, version)) return false
        return restored
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
    ): Boolean {
        if (!isSyncLeaseCurrent(lease)) return false
        val owner = pendingOwner(lease)
        val proposedAttempt = PendingSyncAttempt(owner)
        val claim = if (recordEdit) {
            pendingState.recordEdit(owner, proposedAttempt)
        } else {
            pendingState.claimRestored(owner, proposedAttempt)
        }
        claim.replacedJob?.cancel()
        val attempt = claim.attemptToStart ?: return claim.blockPull

        val job = scope.launch(start = CoroutineStart.LAZY) {
            val runningJob = currentCoroutineContext()[Job] ?: return@launch
            runPendingSyncRetryLoop(
                initialDelayMs = SYNC_DEBOUNCE_MS,
                maxDelayMs = SYNC_RETRY_MAX_MS,
                shouldContinue = {
                    isActive &&
                        isSyncLeaseCurrent(lease) &&
                        pendingState.owns(attempt, runningJob)
                },
                wait = { delay(it) },
                attempt = {
                    if (!pendingState.ensureMarker(attempt, runningJob)) {
                        false
                    } else {
                        val synced = syncUp(lease)
                        synced &&
                            pendingState.completeAccepted(
                                expectedAttempt = attempt,
                                job = runningJob,
                                isCurrentSnapshot = { isSyncLeaseCurrentSnapshot(lease) },
                            )
                    }
                },
            )
        }
        if (!pendingState.attachJob(attempt, job)) {
            job.cancel()
            return claim.blockPull
        }
        if (!isSyncLeaseCurrent(lease)) {
            pendingState.abandon(attempt, job)
            job.cancel()
            return claim.blockPull
        }
        job.start()
        return claim.blockPull
    }

    /** Catch-up PULL entry point (manual "Sync now"); [startRealtime] is the foreground entry point. */
    fun syncDownSoon() {
        val lease = captureSyncLease() ?: return
        scope.launch { syncDown(lease) }
    }

    // ---- Real-time pull channel (WebSocket SyncRoom + while-active poll fallback) ----

    /**
     * The Android port of the Apple realtime leg ([VortXSyncRealtime]): the worker SyncRoom WebSocket
     * plus the 10s while-active fallback poll. Lazy so a signed-out launch never builds the OkHttp
     * client. The channel only ever calls the guarded [syncDown] -- the #145 pull guards (tri-state
     * pull, version-wins, pending-push defer) all still apply to every realtime-triggered apply.
     */
    private val realtime by lazy {
        VortXSyncRealtime(this, scope, BASE.replaceFirst("https://", "wss://") + "/v1/sync/connect")
    }

    /**
     * Open the real-time channel + run one catch-up pull. Called on app-foreground (the
     * [com.vortx.android.VortXApplication] started-activity hook) and after a successful sign-in.
     * Idempotent and fail-soft: a no-op when signed out or already live, and a failed socket degrades
     * to the fallback poll, never breaking the pull+debounced-push engine underneath.
     */
    fun startRealtime() {
        captureSyncLease()?.let(::retryPendingPushBeforePull)
        realtime.start()
    }

    /** Close the real-time channel. Called on app-background and inside [signOut]. Safe to repeat. */
    fun stopRealtime() {
        realtime.stop()
    }

    /**
     * The signed-in account's applied-version high-water mark, for the realtime channel's up-front
     * broadcast filter (only a strictly-newer pushed version triggers a pull). Same-package internal,
     * like [currentSession]: not part of the public API.
     */
    internal fun lastAppliedVersion(): Long =
        captureSyncLease()?.let(::lastSyncedVersion) ?: 0L

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
            is SyncDocPull.Failed -> AccountDataProbe.UNREACHABLE // blip / refused doc: retry, NEVER seed
        }
    }

    enum class SignInReconcile { SEEDED_FROM_DEVICE, HAS_ACCOUNT_DATA, UNREACHABLE }

    /**
     * Call right after a successful sign-in. A fresh (empty) account is seeded from this device; an account
     * with data returns [SignInReconcile.HAS_ACCOUNT_DATA] (the UI asks which side to keep); an unreachable
     * doc returns [SignInReconcile.UNREACHABLE] and pushes NOTHING (a blip is never treated as a fresh account).
     */
    suspend fun reconcileAfterSignIn(): SignInReconcile {
        val lease = captureSyncLease() ?: return SignInReconcile.UNREACHABLE
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
    suspend fun useAccountData() {
        val lease = captureSyncLease() ?: return
        syncDown(lease, force = true)
    }

    /** Conflict resolution / "Sync now": push this device's roster + overlays to the account. */
    suspend fun pushThisDevice(): Boolean {
        val lease = captureSyncLease() ?: return false
        if (retryPendingPushBeforePull(lease)) return false
        val pushed = syncUp(lease)
        return pushed && isSyncLeaseCurrent(lease)
    }

    /** "Sync now" recommended path: union both ways so EVERY profile from both sides survives, then push. */
    suspend fun mergeBoth(): Boolean {
        val lease = captureSyncLease() ?: return false
        if (retryPendingPushBeforePull(lease)) return false
        syncDown(lease, force = true)
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
    ): SessionAdoption {
        val account = Account(
            id = acct.optString("id"),
            email = acct.optString("email"),
            username = acct.optString("username"),
            twoFactorEnabled = acct.optBoolean("twoFactorEnabled", false),
        )
        val s = Session(token, account, dataKey)
        val adoption = when (
            val result = operation.commitSessionMutation(
                onCommitted = ::cancelSessionWork,
            ) {
                sessionState.replace(s) {
                    _account.value = account
                    _sessionUiState.value = SessionUiState.SignedIn(account)
                }
            }
        ) {
            is SessionMutationResult.Applied ->
                if (result.value) SessionAdoption.ADOPTED else SessionAdoption.STORAGE_FAILURE
            SessionMutationResult.Stale -> SessionAdoption.STALE
        }
        if (adoption == SessionAdoption.ADOPTED) {
            captureSyncLease()
                ?.takeIf { it.accountId == account.id && it.token == token }
                ?.let { armPendingSync(it, recordEdit = false) }
        }
        return adoption
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
    ): Pair<Int, JSONObject?> {
        try {
            return withContext(Dispatchers.IO) {
                val bodyBytes = body?.toString()?.toByteArray(Charsets.UTF_8)
                if (!callPermit.isCurrent()) return@withContext 0 to null
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
                        bearerToken?.let { setRequestProperty("authorization", "Bearer $it") }
                        if (bodyBytes != null) {
                            doOutput = true
                            setRequestProperty("content-type", "application/json")
                        }
                    }
                    if (bodyBytes != null) {
                        if (!callPermit.isCurrent()) return@withContext 0 to null
                        opened.outputStream.use { it.write(bodyBytes) }
                        // Once the request body is accepted, absolute server-side cancellation requires a
                        // server nonce. The post-response auth/session fence still blocks stale publication.
                    }
                    if (!callPermit.isCurrent()) return@withContext 0 to null
                    val status = opened.responseCode
                    val stream = if (status in 200..399) opened.inputStream else opened.errorStream
                    val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
                    val json = runCatching { if (text.isNotEmpty()) JSONObject(text) else null }.getOrNull()
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
                    KEY_TOKEN to s.token,
                    KEY_ACCOUNT to acct.toString(),
                    KEY_DATA_KEY to VortXCrypto.b64(s.dataKey),
                    KEY_OWNER_EPOCH to ownerEpoch.toString(),
                ),
            )
        }

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

        fun lastVersion(accountId: String): Long = prefs.getLong(KEY_VERSION + accountId, 0L)
        fun setLastVersion(accountId: String, version: Long) {
            prefs.edit().putLong(KEY_VERSION + accountId, version).apply()
        }

        fun sawV2(accountId: String): Boolean = prefs.getBoolean(KEY_SAW_V2 + accountId, false)
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

    private companion object {
        const val BASE = "https://api.vortx.tv"
        const val TIMEOUT_MS = 20_000
        const val SESSION_STORAGE_FAILURE =
            "Secure storage is unavailable. Your VortX session was not changed. Please try again."
        const val AUTH_SUPERSEDED =
            "This account action was superseded by a newer sign-in or sign-out."

        /**
         * The v2 sync-document WRITE gate, held FALSE. Matches Apple `VortXSyncManager.writeSyncDocV2`
         * (VortXSyncManager.swift:73) and web `vault.ts` WRITE_SYNC_DOC_V2. A v2 doc is unreadable by any
         * client that predates `openDocument`, so v2 writes stay off until every client ships dual-read.
         * `openDocument` reads BOTH formats regardless; only WRITE is gated. DO NOT flip.
         */
        const val WRITE_SYNC_DOC_V2 = false

        /** Debounce for the coalesced auto-push (Apple `requestSyncSoon`: 2.5s). */
        const val SYNC_DEBOUNCE_MS = 2_500L

        /** Cap for failed pending-push retries; the delay doubles from [SYNC_DEBOUNCE_MS]. */
        const val SYNC_RETRY_MAX_MS = 60_000L

        /** Bounded optimistic-concurrency retries for a derived push (Apple `pushDerivedDoc`: 3). */
        const val PUSH_MAX_RETRIES = 3
    }
}
