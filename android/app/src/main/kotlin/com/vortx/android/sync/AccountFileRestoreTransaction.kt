package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.engine.VortxRuntimeBindings
import com.vortx.android.sync.AccountFileRestoreJournal.Mutation
import com.vortx.android.sync.AccountFileRestoreJournal.Read
import com.vortx.android.sync.AccountFileRestoreJournal.Snapshot
import com.vortx.android.sync.AccountFileRestoreJournal.State
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicReference

/** Dedicated file-origin cloud transaction. The caller holds its original account's exclusion
 * reservation for the entire call and runs on an owned worker that can block for journal/ABI work.
 * Nothing here mounts a session, applies a document, acknowledges edits or advances a sync floor. */
internal class AccountFileRestoreTransaction(
    private val journal: AccountFileRestoreJournal,
    private val bindings: VortxRuntimeBindings,
    private val admitCandidate: CandidateAdmission,
) {
    internal fun interface CandidateAdmission {
        /** Real shared, complete host/source admission. Do not rewrite or retain the input bytes. */
        fun requireCandidate(plaintext: ByteArray, scope: VortxAccountScope, bindings: VortxRuntimeBindings,
            checkCurrent: () -> Unit)
    }

    internal interface AuthenticatedReads {
        /** Bind this exact lease to the original Session, account, key, owner and operation generations. */
        fun requireCurrent(original: SyncSessionLease)
        /** Read current guards only. Unknown floor, ratchet or write policy must refuse. */
        fun policy(original: SyncSessionLease): HeadPolicy
        /** Actual uncached, bounded authenticated GET /v1/backup on the fixed origin, with no redirects.
         * Response body ownership transfers to this transaction. No request echo, 304 or applied snapshot. */
        suspend fun getHead(original: SyncSessionLease): RawResponse
    }

    internal interface ExclusiveRestore : AuthenticatedReads {
        /** Verify the original exclusion reservation is still live and other account work is idle. */
        fun requireIdle(original: SyncSessionLease)
        /** Existing-only absence proof under that reservation, before/after retention and at send.
         * Inspect actual local/durable sources, pending edits and existing keys without repairing them.
         * The dedicated file-restore journal is handled separately by the transaction. */
        fun requireLocalAbsence(original: SyncSessionLease, scope: VortxAccountScope)
        /** One actual bounded raw PUT /v1/backup using the original outbound permit and current
         * confirmed bearer. No redirect, automatic retry or success side effect. Take exact bytes
         * once at the dispatch boundary, recheck transport admission and clear that owned body. */
        suspend fun putOnce(original: SyncSessionLease, grant: PutGrant): RawResponse
    }

    internal fun interface PutGrant {
        fun take(original: SyncSessionLease): ByteArray
    }

    internal class RawResponse(val status: Int, val body: ByteArray?) : Closeable {
        override fun close() { body?.fill(0) }
        override fun toString() = "AccountFileRestoreTransaction.RawResponse"
    }

    internal data class HeadPolicy(val floor: Long, val requiresVersionBound: Boolean, val writesVersionBound: Boolean) {
        init { require(floor in 0..BackupRevisionPolicy.MAX_VERSION) }
    }

    internal enum class Reason {
        CANCELLED, ACCOUNT_CHANGED, BUSY, LOCAL_STATE_UNVERIFIABLE, PENDING_LOCAL_CHANGES,
        UNSUPPORTED_FILE, UNSUPPORTED_HEAD, INVALID_HOST_DATA, NO_CLOUD_BACKUP, HEAD_UNAVAILABLE,
        STALE_HEAD, REVISION_UNAVAILABLE, RECOVERY_UNAVAILABLE, WRONG_OPERATION,
    }
    internal class Refusal(val reason: Reason) : Exception("Account file restore refused: ${reason.name}")

    internal sealed interface Result {
        data class NotSubmitted(val reason: Reason) : Result
        /** An earlier retained record blocks another submission. This is a historical journal status. */
        data class ExistingIntent(val operationId: UUID, val state: State) : Result
        data class Conflict(val operationId: UUID) : Result
        data class DeliveryUnconfirmed(val operationId: UUID) : Result
        data class UploadAccepted(val operationId: UUID) : Result
        data class ServerConfirmed(val operationId: UUID, val revision: Long) : Result
    }

    private class Head(val raw: ByteArray, val document: String, val revision: Long) : Closeable {
        val versionBound: Boolean get() = document.startsWith(VortXCrypto.DOC_V2_PREFIX)
        override fun close() { raw.fill(0) }
        override fun toString() = "AccountFileRestoreTransaction.Head"
    }

    private class Prepared(val scope: VortxAccountScope, val file: ByteArray, val plaintext: ByteArray) : Closeable {
        override fun close() { file.fill(0); plaintext.fill(0) }
        override fun toString() = "AccountFileRestoreTransaction.Prepared"
    }

    private class LiveSend(private val original: SyncSessionLease, private val intent: AccountFileRestoreJournal.Intent,
        private val requireSend: () -> Unit) : PutGrant {
        private enum class Claim { Open, Claiming, Released, Retired }
        private val claim = AtomicReference(Claim.Open)
        val released: Boolean get() = claim.get() == Claim.Released

        override fun take(original: SyncSessionLease): ByteArray {
            if (this.original !== original || !claim.compareAndSet(Claim.Open, Claim.Claiming))
                refuse(Reason.ACCOUNT_CHANGED)
            val bytes = intent.submissionBytes()
            try {
                requireSend()
                if (!claim.compareAndSet(Claim.Claiming, Claim.Released)) refuse(Reason.ACCOUNT_CHANGED)
                return bytes
            } catch (failure: Throwable) { bytes.fill(0); throw failure }
        }

        fun retire() { claim.set(Claim.Retired) }
    }

    suspend fun restore(original: SyncSessionLease, selectedFile: ByteArray, access: ExclusiveRestore): Result {
        if (selectedFile.size !in 1..AccountBackupFile.MAXIMUM_FILE_BYTES) return Result.NotSubmitted(Reason.UNSUPPORTED_FILE)
        val context = currentCoroutineContext()
        val key = original.dataKeyCopy()
        val selected = selectedFile.copyOf()
        var retained: Snapshot? = null
        var possible: Snapshot? = null
        try {
            fun requireCurrent() {
                context.ensureActive()
                access.requireCurrent(original)
            }
            fun requireIdle() {
                requireCurrent()
                access.requireIdle(original)
                requireCurrent()
            }
            requireIdle()
            when (val existing = journal.readExisting(original.accountId, key)) {
                Read.Missing -> Unit
                Read.Unavailable -> refuse(Reason.RECOVERY_UNAVAILABLE)
                is Read.Present -> {
                    requireCurrent()
                    return Result.ExistingIntent(existing.snapshot.intent.operationId, existing.snapshot.state)
                }
            }
            readHead(original, access, ::requireCurrent).use { first ->
                requireHeadPolicy(first, access.policy(original))
                prepare(selected, first, original, key, ::requireCurrent).use { candidate ->
                    fun requireAbsence() {
                        requireIdle()
                        access.requireLocalAbsence(original, candidate.scope)
                        requireIdle()
                    }
                    requireAbsence()
                    readHead(original, access, ::requireCurrent).use { fresh ->
                        val policy = access.policy(original)
                        if (fresh.revision != first.revision || fresh.document != first.document) refuse(Reason.STALE_HEAD)
                        requireHeadPolicy(fresh, policy)
                        if ((fresh.versionBound || policy.requiresVersionBound) && !policy.writesVersionBound)
                            refuse(Reason.REVISION_UNAVAILABLE)
                        val revision = BackupRevisionPolicy.next(fresh.revision) ?: refuse(Reason.REVISION_UNAVAILABLE)
                        val submission = submission(candidate.plaintext, original.accountId, key, fresh.revision,
                            revision, policy.writesVersionBound)
                        val intent = try {
                            AccountFileRestoreJournal.Intent(UUID.randomUUID(), original.accountId, candidate.scope.ownerProfileID,
                                fresh.revision, revision, OHJson.sha(candidate.plaintext), selected, candidate.file, fresh.raw, submission)
                        } finally { submission.fill(0) }
                        requireIdle()
                        // admit() is create-only and includes durability plus exact sealed readback.
                        val admitted = (journal.admit(intent, key) as? Mutation.Applied)?.snapshot
                            ?: refuse(Reason.RECOVERY_UNAVAILABLE)
                        retained = admitted
                        fun requireSend() {
                            requireAbsence()
                            val currentPolicy = access.policy(original)
                            requireHeadPolicy(fresh, currentPolicy)
                            if (currentPolicy.writesVersionBound != policy.writesVersionBound ||
                                ((fresh.versionBound || currentPolicy.requiresVersionBound) && !policy.writesVersionBound))
                                refuse(Reason.REVISION_UNAVAILABLE)
                            requireCurrent()
                        }
                        requireSend()
                        // Only this invocation's live admission can create PossibleSend. A retained
                        // snapshot recovered from disk has no grant even with the original key.
                        val marked = advance(admitted, State.PossibleSend, key) ?: refuse(Reason.RECOVERY_UNAVAILABLE)
                        possible = marked
                        val grant = LiveSend(original, intent, ::requireSend)
                        return try {
                            finishSubmission(original, marked, key, access, grant, ::requireCurrent)
                        } finally { grant.retire() }
                    }
                }
            }
        } catch (failure: Exception) {
            val uncertain = possible
            if (uncertain != null) {
                advance(uncertain, State.DeliveryUnconfirmed, key)
                return Result.DeliveryUnconfirmed(uncertain.intent.operationId)
            }
            retained?.let { advance(it, State.NotSubmitted, key) }
            return Result.NotSubmitted(reason(failure))
        } finally {
            key.fill(0)
            selected.fill(0)
        }
    }

    /** Verification has read transport only. Existing Retained, Conflict and NotSubmitted records
     * have no path into transport dispatch. Completed records report historical status. */
    suspend fun verify(original: SyncSessionLease, operationId: UUID, access: AuthenticatedReads): Result {
        val context = currentCoroutineContext()
        val key = original.dataKeyCopy()
        var pending: Snapshot? = null
        try {
            fun requireCurrent() {
                context.ensureActive()
                access.requireCurrent(original)
            }
            requireCurrent()
            val stored = journal.readExisting(original.accountId, key)
            val snapshot = when (stored) {
                is Read.Present -> stored.snapshot
                Read.Missing -> refuse(Reason.WRONG_OPERATION)
                Read.Unavailable -> refuse(Reason.RECOVERY_UNAVAILABLE)
            }
            requireCurrent()
            if (snapshot.intent.operationId != operationId) refuse(Reason.WRONG_OPERATION)
            if (snapshot.state !in setOf(State.PossibleSend, State.DeliveryUnconfirmed, State.UploadAccepted))
                return Result.ExistingIntent(operationId, snapshot.state)
            pending = snapshot
            return verifyPossibleSend(original, snapshot, key, access, ::requireCurrent)
        } catch (failure: Exception) {
            return pending?.let(::unconfirmed) ?: Result.NotSubmitted(reason(failure))
        } finally { key.fill(0) }
    }

    private suspend fun finishSubmission(original: SyncSessionLease, snapshot: Snapshot, key: ByteArray,
        access: ExclusiveRestore, grant: LiveSend, requireCurrent: () -> Unit): Result {
        var current = snapshot
        try {
            requireCurrent()
            // This is the only outbound PUT invocation in the transaction, including retries.
            val verdict = try {
                access.putOnce(original, grant).use { response ->
                    if (grant.released) acceptedVerdict(response) else null
                }
            } finally { grant.retire() }
            requireCurrent()
            when (verdict) {
                false -> {
                    return if (advance(current, State.Conflict, key) != null) Result.Conflict(current.intent.operationId)
                    else Result.DeliveryUnconfirmed(current.intent.operationId)
                }
                true -> current = advance(current, State.UploadAccepted, key) ?: current
                null -> current = advance(current, State.DeliveryUnconfirmed, key) ?: current
            }
            return verifyPossibleSend(original, current, key, access, requireCurrent)
        } catch (_: Exception) {
            if (current.state == State.PossibleSend)
                advance(current, State.DeliveryUnconfirmed, key)
            return unconfirmed(current)
        }
    }

    private suspend fun verifyPossibleSend(original: SyncSessionLease, snapshot: Snapshot, key: ByteArray,
        access: AuthenticatedReads, requireCurrent: () -> Unit): Result {
        val intent = snapshot.intent
        val submittedV2 = submittedVersionBound(intent, key)
        fun matchingPolicy(readback: Head): Boolean {
            val policy = access.policy(original)
            return readback.revision >= policy.floor &&
                (readback.versionBound || (!policy.requiresVersionBound && !submittedV2))
        }
        readHead(original, access, requireCurrent).use { readback ->
            if (readback.revision != intent.revision || !matchingPolicy(readback))
                return unconfirmed(snapshot)
            val plaintext = VortXCrypto.openDocument(key, readback.document, intent.accountId, readback.revision)
                ?: return unconfirmed(snapshot)
            try {
                if (plaintext.size > AccountBackupRepair.MAXIMUM_PLAINTEXT_BYTES ||
                    OHJson.sha(plaintext) != intent.plaintextSha256) return unconfirmed(snapshot)
            } finally { plaintext.fill(0) }
            requireCurrent()
            if (!matchingPolicy(readback)) return unconfirmed(snapshot)
            requireCurrent()
            if (advance(snapshot, State.ServerConfirmed, key) == null) return unconfirmed(snapshot)
            requireCurrent()
            return Result.ServerConfirmed(intent.operationId, intent.revision)
        }
    }

    private suspend fun readHead(original: SyncSessionLease, access: AuthenticatedReads,
        requireCurrent: () -> Unit): Head {
        requireCurrent()
        val response = try { access.getHead(original) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (refusal: Refusal) { throw refusal }
        catch (_: Exception) { refuse(Reason.HEAD_UNAVAILABLE) }
        var retained = false
        try {
            requireCurrent()
            if (response.status == 404) refuse(Reason.NO_CLOUD_BACKUP)
            val bytes = response.body ?: refuse(Reason.HEAD_UNAVAILABLE)
            if (response.status != 200 || bytes.size !in 1..AccountBackupFile.MAXIMUM_RESPONSE_BYTES)
                refuse(Reason.HEAD_UNAVAILABLE)
            val head = try {
                val file = AccountBackupFile.encodeServerResponse(bytes, "", 0L)
                try { AccountBackupFile.inspect(file) } finally { file.fill(0) }
            } catch (_: AccountBackupFile.Failure) { refuse(Reason.HEAD_UNAVAILABLE) }
            val result = Head(bytes, head.document, head.version)
            retained = true
            return result
        } finally { if (!retained) response.close() }
    }

    private fun prepare(selected: ByteArray, head: Head, original: SyncSessionLease, key: ByteArray,
        requireCurrent: () -> Unit): Prepared {
        requireCurrent()
        val headPlaintext = VortXCrypto.openDocument(key, head.document, original.accountId, head.revision)
            ?: refuse(Reason.HEAD_UNAVAILABLE)
        val scope = try {
            requireCurrent()
            if (headPlaintext.size > AccountBackupRepair.MAXIMUM_PLAINTEXT_BYTES) refuse(Reason.UNSUPPORTED_HEAD)
            val owner = AccountFileLegacyAdmission.legacyOwnerID(headPlaintext)
            val destination = VortxAccountScope("account.${original.accountId}", owner)
            requireCurrent()
            // Roster resolution alone does not admit independent profiles, queued edits, held
            // units or pending membership. Project the exact authenticated destination first.
            val material = AccountFileLegacyAdmission.admitLegacy(headPlaintext, owner).prepareMaterial(destination)
            try {
                requireCurrent()
                if (material.size !in 1..AccountBackupRepair.MAXIMUM_PLAINTEXT_BYTES) refuse(Reason.UNSUPPORTED_HEAD)
                destination
            } finally { material.fill(0) }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (refusal: Refusal) { throw refusal }
        catch (_: Exception) { refuse(Reason.UNSUPPORTED_HEAD) }
        finally { headPlaintext.fill(0) }
        requireCurrent()
        val owner = scope.ownerProfileID
        val ownerWitness = OHJson.sha(head.raw)
        val inspected = AccountBackupRepair.inspect(selected) as? AccountBackupRepair.Format.EncryptedAccount
            ?: refuse(Reason.UNSUPPORTED_FILE)
        val reimport = OHJson.Obj(selected)[AccountBackupRepair.REPAIR_KEY] != null
        AccountBackupRepair.Context(original.accountId, key, owner, ownerWitness,
            original.operationGeneration, original.ownerEpoch).use { context ->
            val output = if (reimport) AccountBackupRepair.validateReimport(selected, context, bindings, requireCurrent)
                else AccountBackupRepair.convert(selected, context, bindings, requireCurrent)
            output.use { candidate ->
                requireCurrent()
                val expectedDisposition = if (reimport) AccountBackupRepair.Disposition.VALIDATED_EXISTING_CANDIDATE
                    else AccountBackupRepair.Disposition.CONVERTED_LEGACY
                if (candidate.disposition != expectedDisposition || candidate.originalVersion != inspected.version ||
                    candidate.ownerWitnessSHA256 != ownerWitness ||
                    (!reimport && candidate.sourceSHA256 != OHJson.sha(selected))) refuse(Reason.UNSUPPORTED_FILE)
                val file = candidate.fileBytes()
                var plain: ByteArray? = null
                var transferred = false
                try {
                    if (candidate.fileSHA256 != OHJson.sha(file) || (reimport && !file.contentEquals(selected)))
                        refuse(Reason.UNSUPPORTED_FILE)
                    val envelope = AccountBackupFile.inspect(file)
                    if (envelope.version != inspected.version || !envelope.document.startsWith(VortXCrypto.DOC_V2_PREFIX))
                        refuse(Reason.UNSUPPORTED_FILE)
                    val reopened = VortXCrypto.openDocument(key, envelope.document, original.accountId, envelope.version)
                        ?: refuse(Reason.UNSUPPORTED_FILE)
                    plain = reopened
                    if (reopened.size > AccountBackupRepair.MAXIMUM_PLAINTEXT_BYTES ||
                        OHJson.sha(reopened) != candidate.candidatePlaintextSHA256) refuse(Reason.UNSUPPORTED_FILE)
                    try { admitCandidate.requireCandidate(reopened, scope, bindings, requireCurrent) }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (refusal: Refusal) { throw refusal }
                    catch (_: Exception) { refuse(Reason.INVALID_HOST_DATA) }
                    requireCurrent()
                    if (OHJson.sha(reopened) != candidate.candidatePlaintextSHA256) refuse(Reason.INVALID_HOST_DATA)
                    val prepared = Prepared(scope, file, reopened)
                    transferred = true
                    return prepared
                } finally {
                    if (!transferred) { plain?.fill(0); file.fill(0) }
                }
            }
        }
    }

    private fun submission(plaintext: ByteArray, accountId: String, key: ByteArray,
        base: Long, revision: Long, writeV2: Boolean): ByteArray {
        val document = VortXCrypto.sealDocument(key, plaintext, accountId, revision, writeV2)
            ?: refuse(Reason.REVISION_UNAVAILABLE)
        val body = OHJson.Obj().set("document", OHJson.quote(document))
            .set("version", OHJson.literal(revision.toString()))
            .set("baseRevision", OHJson.literal(base.toString())).encoded()
        if (body.size > AccountBackupFile.MAXIMUM_FILE_BYTES) { body.fill(0); refuse(Reason.REVISION_UNAVAILABLE) }
        return body
    }

    private fun submittedVersionBound(intent: AccountFileRestoreJournal.Intent, key: ByteArray): Boolean {
        val bytes = intent.submissionBytes()
        try {
            val body = OHJson.Obj(bytes)
            check(body.keys == setOf("document", "version", "baseRevision") &&
                OHJson.integer(body.raw("version")) == intent.revision &&
                OHJson.integer(body.raw("baseRevision")) == intent.baseRevision)
            val document = body.text("document")
            val plaintext = checkNotNull(VortXCrypto.openDocument(key, document, intent.accountId, intent.revision))
            try {
                check(plaintext.size <= AccountBackupRepair.MAXIMUM_PLAINTEXT_BYTES &&
                    OHJson.sha(plaintext) == intent.plaintextSha256)
            } finally { plaintext.fill(0) }
            return document.startsWith(VortXCrypto.DOC_V2_PREFIX)
        } finally { bytes.fill(0) }
    }

    companion object {
        const val CONTROL_RESPONSE_LIMIT = 64 * 1024

        private fun acceptedVerdict(response: RawResponse): Boolean? {
            val bytes = response.body ?: return null
            if (response.status != 200 || bytes.size !in 1..CONTROL_RESPONSE_LIMIT) return null
            val accepted = try { OHJson.Obj(bytes)["accepted"] } catch (_: Exception) { return null }
            return when {
                accepted == null -> null
                accepted.contentEquals(OHJson.literal("true")) -> true
                accepted.contentEquals(OHJson.literal("false")) -> false
                else -> null
            }
        }

        private fun requireHeadPolicy(head: Head, policy: HeadPolicy) {
            if (head.revision < policy.floor) refuse(Reason.STALE_HEAD)
            if (!head.versionBound && policy.requiresVersionBound) refuse(Reason.UNSUPPORTED_HEAD)
        }

        private fun unconfirmed(snapshot: Snapshot): Result = if (snapshot.state == State.UploadAccepted)
            Result.UploadAccepted(snapshot.intent.operationId) else Result.DeliveryUnconfirmed(snapshot.intent.operationId)

        private fun reason(failure: Exception): Reason = when (failure) {
            is Refusal -> failure.reason
            is CancellationException -> Reason.CANCELLED
            else -> Reason.UNSUPPORTED_FILE
        }

        private fun refuse(reason: Reason): Nothing = throw Refusal(reason)
    }

    private fun advance(snapshot: Snapshot, state: State, key: ByteArray): Snapshot? =
        (journal.compareAndAdvance(snapshot, state, key) as? Mutation.Applied)?.snapshot
}
