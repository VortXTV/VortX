package com.vortx.android.sync

import com.vortx.android.account.TitleRef
import com.vortx.android.engine.NativeLibraryMirrorOrigin
import com.vortx.android.security.AccountFileProviderWriters
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Application supplies the exact persisted original owner. No default or current-account fallback. */
internal interface ProviderRetryHost {
    fun captureCommitted(origin: NativeLibraryMirrorOrigin): ProviderRetrySession?
    /** Cheap scalar original foreground issuer. Only the counted worker opens its persisted session. */
    fun captureForeground(): (() -> ProviderRetrySession?)?
}

internal interface ProviderRetrySession : AutoCloseable {
    val owner: SessionOwnerSnapshot.Account

    /** Scalar original lease/route and cancellation assertion. The outbox can invoke it under its disk lock. */
    fun requireCurrent()

    /** Borrow a short-lived copy of the original key, without holding manager or credential locks over block. */
    fun <T> withDataKey(block: (ByteArray) -> T): T

    /** Exact original user's watchlist setting. Reads must not start unrelated provider work. */
    fun isEnabled(provider: ProviderRetryOutbox.Provider): Boolean

    /** Existing-only, confirmed exact provider proof. No refresh, vault seed or provider request. */
    suspend fun prepareCredential(provider: ProviderRetryOutbox.Provider): ProviderRetryCredential?
}

internal interface ProviderRetryCredential : AutoCloseable {
    fun copyProof(): ByteArray

    /**
     * Prepare each actual call from this original provider tuple. Recheck exact material and the original
     * session/mount in the one-use first-I/O admission, then drain the prepared call before returning.
     * A provider response without independently confirmed item settlement is Unsettled.
     */
    suspend fun dispatch(
        lane: ProviderRetryOutbox.Lane,
        row: ProviderRetryOutbox.Row,
        start: ProviderRetryStart,
    ): ProviderRetryDispatchOutcome
}

/** No production implementation exists in outbox V2. A memory flag or a V2 read cannot mint it. */
internal interface ProviderRetryStartLedger {
    /**
     * Under the same original outbox issuer, mark the exact authenticated, never-claimed head
     * durably before returning. Restart and interrupted publication must preserve the veto.
     * Unknown or previously claimed rows return null. Do not initialize or retire their state.
     */
    fun claimBeforeIo(
        lane: ProviderRetryOutbox.Lane,
        dataKey: ByteArray,
        expected: ProviderRetryOutbox.Snapshot,
        requireCurrent: () -> Unit,
    ): ProviderRetryStart?

    /**
     * Settle the exact still-issued start and receipt. There must never be a crash window in
     * which an unsettled ciphertext becomes a never-claimed head. Do not unmark then use V2 CAS.
     */
    fun retireAccepted(
        lane: ProviderRetryOutbox.Lane,
        dataKey: ByteArray,
        start: ProviderRetryStart,
        accepted: ProviderRetryDispatchOutcome.Accepted,
        requireCurrent: () -> Unit,
    ): ProviderRetryOutbox.Retire
}

internal interface ProviderRetryStart {
    val head: ProviderRetryOutbox.Snapshot

    /** Scalar, single-use and checked at actual transport admission. No disk or network under its guard. */
    fun tryClaimFirstIo(): Boolean

    /** Sticky for this exact issued start even after cancellation or closure. */
    fun wasClaimed(): Boolean
}

internal sealed interface ProviderRetryDispatchOutcome {
    data object Refused : ProviderRetryDispatchOutcome
    data object Unsettled : ProviderRetryDispatchOutcome
    /** Issued by the reviewed endpoint adapter only after exact item-level settlement. */
    class Accepted(
        private val start: ProviderRetryStart,
        val lane: ProviderRetryOutbox.Lane,
        val operationId: UUID,
        val add: Boolean,
        val ref: TitleRef,
    ) : ProviderRetryDispatchOutcome {
        fun matches(original: ProviderRetryStart): Boolean {
            val head = original.head
            val row = head.row
            return start === original && lane == head.lane && operationId == row.operationId && add == row.add &&
                ref == TitleRef(row.imdb, row.tmdb, row.isSeries)
        }
    }
}

/** One application instance. The lane mutex serializes one FIFO, never the whole account or an OS store. */
internal class ProviderRetryCoordinator(
    private val outbox: ProviderRetryOutbox,
    private val startLedger: ProviderRetryStartLedger,
) {
    enum class Submit {
        Settled,
        RecordedUnsettled,
        Capacity,
        UnconfirmedPersistence,
        Unavailable,
        UnsupportedTitle,
    }

    private class Slot(val mutex: Mutex = Mutex(), var members: Int = 0)
    private val slots = mutableMapOf<ProviderRetryOutbox.Lane, Slot>()
    private val slotLock = Any()

    suspend fun submit(
        session: ProviderRetrySession,
        provider: ProviderRetryOutbox.Provider,
        add: Boolean,
        ref: TitleRef,
    ): Submit = AccountFileProviderWriters.withEffectfulWriter(Submit.Unavailable) {
        if (!ref.hasUsableId || provider == ProviderRetryOutbox.Provider.SIMKL && !add)
            return@withEffectfulWriter Submit.UnsupportedTitle
        val lane = ProviderRetryOutbox.Lane(session.owner, provider)
        withLane(lane) {
            if (!session.isEnabled(provider)) return@withLane Submit.Unavailable
            val requireCurrent = currentAssertion(session)
            requireCurrent()
            val credential = session.prepareCredential(provider) ?: return@withLane Submit.Unavailable
            credential.use {
                val proof = credential.copyProof()
                try {
                    if (proof.size != PROOF_BYTES) return@withLane Submit.Unavailable
                    val row = try {
                        ProviderRetryOutbox.Row(UUID.randomUUID(), add, ref.imdb, ref.tmdb, ref.isSeries, proof)
                    } catch (_: IllegalArgumentException) { return@withLane Submit.UnsupportedTitle }
                    val appended = try {
                        session.withDataKey { outbox.append(lane, it, row, requireCurrent) }
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) { ProviderRetryOutbox.Append.Unavailable }
                    when (appended) {
                        ProviderRetryOutbox.Append.Capacity -> Submit.Capacity
                        ProviderRetryOutbox.Append.Unavailable -> Submit.UnconfirmedPersistence
                        ProviderRetryOutbox.Append.Enqueued, ProviderRetryOutbox.Append.AlreadyQueued ->
                            if (drainRecorded(session, lane, credential, proof, requireCurrent, row.operationId)) Submit.Settled
                            else Submit.RecordedUnsettled
                    }
                } finally { proof.fill(0) }
            }
        }
    }

    suspend fun drain(session: ProviderRetrySession, provider: ProviderRetryOutbox.Provider) {
        AccountFileProviderWriters.withEffectfulWriter(Unit) {
            val lane = ProviderRetryOutbox.Lane(session.owner, provider)
            withLane(lane) {
                if (!session.isEnabled(provider)) return@withLane
                val requireCurrent = currentAssertion(session)
                requireCurrent()
                val original = (session.withDataKey { outbox.readHead(lane, it, requireCurrent) }
                    as? ProviderRetryOutbox.Read.Pending)?.head ?: return@withLane
                val credential = session.prepareCredential(provider) ?: return@withLane
                credential.use {
                    val proof = credential.copyProof()
                    try {
                        if (proof.size == PROOF_BYTES)
                            drainRecorded(session, lane, credential, proof, requireCurrent, target = null, first = original)
                    } finally { proof.fill(0) }
                }
            }
        }
    }

    private suspend fun drainRecorded(
        session: ProviderRetrySession,
        lane: ProviderRetryOutbox.Lane,
        credential: ProviderRetryCredential,
        proof: ByteArray,
        requireCurrent: () -> Unit,
        target: UUID?,
        first: ProviderRetryOutbox.Snapshot? = null,
    ): Boolean {
        try {
            repeat(MAX_PER_PASS) { step ->
                requireCurrent()
                if (!session.isEnabled(lane.provider)) return false
                val head = if (step == 0 && first != null) first else {
                    (session.withDataKey { outbox.readHead(lane, it, requireCurrent) }
                        as? ProviderRetryOutbox.Read.Pending)?.head ?: return false
                }
                val original = head.row.credentialProof()
                val matches = try { MessageDigest.isEqual(original, proof) } finally { original.fill(0) }
                // A different proof can also mean unavailable or ambiguous origin. Preserve FIFO and
                // every original byte; this coordinator never infers credential replacement from it.
                if (!matches) return false
                val start = session.withDataKey { startLedger.claimBeforeIo(lane, it, head, requireCurrent) }
                    ?: return false
                if (start.head !== head || start.wasClaimed()) return false
                requireCurrent()
                val outcome = credential.dispatch(lane, head.row, start)
                if (!start.wasClaimed() || outcome !is ProviderRetryDispatchOutcome.Accepted || !outcome.matches(start))
                    return false
                requireCurrent()
                val retired = session.withDataKey { startLedger.retireAccepted(lane, it, start, outcome, requireCurrent) }
                if (retired != ProviderRetryOutbox.Retire.Retired) return false
                if (head.row.operationId == target) return true
            }
            return false
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // Persistence or settlement may already be ambiguous. A later exact read owns recovery.
            return false
        }
    }

    private suspend fun currentAssertion(session: ProviderRetrySession): () -> Unit {
        val caller = currentCoroutineContext()
        return { caller.ensureActive(); session.requireCurrent() }
    }

    private suspend fun <T> withLane(lane: ProviderRetryOutbox.Lane, block: suspend () -> T): T {
        val slot = synchronized(slotLock) { slots.getOrPut(lane) { Slot() }.also { it.members++ } }
        return try { slot.mutex.withLock { block() } } finally {
            synchronized(slotLock) {
                if (--slot.members == 0) slots.remove(lane)
            }
        }
    }

    private companion object {
        const val PROOF_BYTES = 32
        const val MAX_PER_PASS = 200
    }
}
