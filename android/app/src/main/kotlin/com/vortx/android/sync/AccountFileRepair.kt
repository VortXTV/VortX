package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.engine.VortxRuntimeBindings
import java.io.Closeable
import java.util.concurrent.CancellationException
import java.util.concurrent.TimeUnit

internal enum class AccountFileRepairReason { BUSY, ALREADY_REPAIRED, OWNER_UNAVAILABLE, ACCOUNT_UNSUPPORTED, EXPIRED, INVALID_FILE }
internal class AccountFileRepairFailure(val reason: AccountFileRepairReason) : Exception("Account backup repair refused: ${reason.name}")

internal fun accountFileRepairRemainingMillis(started: Long, now: Long): Long {
    val remaining = TimeUnit.MINUTES.toNanos(5) - (now - started)
    return if (remaining <= 0L) 0L else 1L + (remaining - 1L) / 1_000_000L
}

/** Worker result carries only encrypted output and its reviewed metadata. */
internal class AccountFileRepairPrepared(val bytes: ByteArray, val profileCount: Int, val nativeSchema: Int,
    val sha256: String, val headWasVersionBound: Boolean) {
    override fun toString() = "AccountFileRepairPrepared"
}

/** Exact original-owner capability; the controller can take the approved encrypted bytes once. */
internal class AccountFileRepairExport(prepared: AccountFileRepairPrepared, private val deadline: () -> Long,
    private val checkCurrent: () -> Unit, private val saveCurrent: () -> Boolean,
    private val onClose: () -> Unit) : Closeable {
    private val lock = Any()
    private var bytes: ByteArray? = prepared.bytes
    private var closed = false
    private var taken = false
    val profileCount = prepared.profileCount
    val nativeSchema = prepared.nativeSchema
    val byteCount = prepared.bytes.size
    val sha256 = prepared.sha256

    fun remainingMillis(): Long = deadline()
    fun canSave(): Boolean = synchronized(lock) { !closed && taken } && saveCurrent()

    fun take(): ByteArray {
        checkCurrent()
        val result = synchronized(lock) {
            if (closed || remainingMillis() == 0L) throw AccountFileRepairFailure(AccountFileRepairReason.EXPIRED)
            val approved = bytes ?: throw AccountFileRepairFailure(AccountFileRepairReason.EXPIRED)
            bytes = null // Transfer the bytes once, after both policy checks.
            approved
        }
        try {
            checkCurrent()
            synchronized(lock) {
                if (closed) throw AccountFileRepairFailure(AccountFileRepairReason.EXPIRED)
                taken = true
            }
        } catch (failure: Throwable) { result.fill(0); throw failure }
        return result
    }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            bytes?.fill(0)
            bytes = null
        }
        onClose()
    }
    override fun toString() = "AccountFileRepairExport"
}

/** Pure worker. Only the manager supplies the original authenticated raw GET, lease/key and fences. */
internal fun prepareAccountFileRepair(selected: ByteArray, authenticatedRawHead: ByteArray, accountId: String,
    dataKey: ByteArray, operationGeneration: Long, ownerEpoch: Long, requiresVersionBoundHead: () -> Boolean,
    bindings: VortxRuntimeBindings, checkCurrent: () -> Unit): AccountFileRepairPrepared {
    checkCurrent()
    if (selected.size !in 1..AccountBackupFile.MAXIMUM_FILE_BYTES || dataKey.size != 32)
        throw AccountFileRepairFailure(AccountFileRepairReason.INVALID_FILE)
    val head = try {
        val envelope = AccountBackupFile.encodeServerResponse(authenticatedRawHead, username = "", exportedAtMillis = 0L)
        try { AccountBackupFile.inspect(envelope) } finally { envelope.fill(0) }
    } catch (_: AccountBackupFile.Failure) {
        throw AccountFileRepairFailure(AccountFileRepairReason.OWNER_UNAVAILABLE)
    }
    val headV2 = head.document.startsWith(VortXCrypto.DOC_V2_PREFIX)
    if (!headV2 && requiresVersionBoundHead()) throw AccountFileRepairFailure(AccountFileRepairReason.OWNER_UNAVAILABLE)
    val headPlaintext = VortXCrypto.openDocument(dataKey, head.document, accountId, head.version)
        ?: throw AccountFileRepairFailure(AccountFileRepairReason.OWNER_UNAVAILABLE)
    val owner = try {
        checkCurrent()
        if (headPlaintext.size > AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES)
            throw AccountFileRepairFailure(AccountFileRepairReason.OWNER_UNAVAILABLE)
        if (OHJson.Obj(headPlaintext)["nativeSync"] != null)
            throw AccountFileRepairFailure(AccountFileRepairReason.ACCOUNT_UNSUPPORTED)
        AccountFileLegacyAdmission.legacyOwnerID(headPlaintext)
    } catch (failure: AccountFileRepairFailure) { throw failure }
    catch (cancelled: CancellationException) { throw cancelled }
    catch (_: Exception) { throw AccountFileRepairFailure(AccountFileRepairReason.OWNER_UNAVAILABLE) }
    finally { headPlaintext.fill(0) }
    checkCurrent()
    try {
        val ownerWitness = OHJson.sha(authenticatedRawHead)
        val scope = VortxAccountScope("account.$accountId", owner)
        AccountBackupRepair.Context(accountId, dataKey, owner, ownerWitness, operationGeneration, ownerEpoch).use { context ->
            if (OHJson.Obj(selected)[AccountBackupRepair.REPAIR_KEY] != null) {
                AccountBackupRepair.validateReimport(selected, context, bindings, checkCurrent).use {
                    checkCurrent()
                    throw AccountFileRepairFailure(AccountFileRepairReason.ALREADY_REPAIRED)
                }
            }
            AccountBackupRepair.convert(selected, context, bindings, checkCurrent).use { candidate ->
                checkCurrent()
                if (candidate.disposition != AccountBackupRepair.Disposition.CONVERTED_LEGACY ||
                    candidate.ownerWitnessSHA256 != ownerWitness || candidate.sourceSHA256 != OHJson.sha(selected))
                    throw AccountFileRepairFailure(AccountFileRepairReason.INVALID_FILE)
                val bytes = candidate.fileBytes()
                try {
                    if (candidate.fileSHA256 != OHJson.sha(bytes))
                        throw AccountFileRepairFailure(AccountFileRepairReason.INVALID_FILE)
                    val inspection = AccountBackupFile.inspect(bytes)
                    if (inspection.version != candidate.originalVersion || !inspection.document.startsWith(VortXCrypto.DOC_V2_PREFIX))
                        throw AccountFileRepairFailure(AccountFileRepairReason.INVALID_FILE)
                    val plaintext = VortXCrypto.openDocument(dataKey, inspection.document, accountId, inspection.version)
                        ?: throw AccountFileRepairFailure(AccountFileRepairReason.INVALID_FILE)
                    try {
                        if (plaintext.size > AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES ||
                            OHJson.sha(plaintext) != candidate.candidatePlaintextSHA256)
                            throw AccountFileRepairFailure(AccountFileRepairReason.INVALID_FILE)
                        AccountFileHostAdmission.requireCandidate(plaintext, scope, bindings, checkCurrent)
                    } finally { plaintext.fill(0) }
                    checkCurrent()
                    if (!headV2 && requiresVersionBoundHead())
                        throw AccountFileRepairFailure(AccountFileRepairReason.OWNER_UNAVAILABLE)
                    return AccountFileRepairPrepared(bytes, candidate.profileCount, candidate.nativeSchema,
                        candidate.fileSHA256, headV2)
                } catch (failure: Throwable) {
                    bytes.fill(0)
                    throw failure
                }
            }
        }
    } catch (failure: AccountFileRepairFailure) { throw failure }
    catch (cancelled: CancellationException) { throw cancelled }
    catch (_: Exception) {
        checkCurrent()
        throw AccountFileRepairFailure(AccountFileRepairReason.INVALID_FILE)
    }
}
