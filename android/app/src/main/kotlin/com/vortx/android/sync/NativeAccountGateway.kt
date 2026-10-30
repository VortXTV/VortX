package com.vortx.android.sync

import org.json.JSONObject
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.flow.Flow
import com.vortx.android.engine.NativePlaylistCloudReceiptLedger
import org.json.JSONArray

internal data class NativeAccountExport(val nativeSync: JSONObject, val roster: List<UserProfile>, val rosterModifiedSeconds: Double,
    val rawRoster: JSONArray = JSONArray(roster.map { it.encode() }), val hostProfileSyncPending: Boolean = false,
    val hostPreferences: JSONObject? = null, val hostSettingsBaseline: Any? = null,
    /** Complete raw account from the accepted typed checkpoint, never a reconstructed DTO. */
    val rawAccount: ByteArray? = null,
    /** Actual source-only JNI projection paired with the retained authenticated generic GET. */
    val genericSourceNativeProjection: ByteArray? = null,
    /** Detached original/derived raw host document. Read provenance only, never a write permit. */
    val rawHostPreferences: ByteArray? = null)

/** Opaque current mount and mutation generation; contains no account document or credentials. */
internal data class NativeAccountMountToken(val installation: Any, val revision: Long)

/**
 * Exact bytes and non-secret identity of one authenticated backup GET. The bytes are sensitive:
 * the full decrypted account may contain provider credentials or API keys. This is provenance,
 * not a write permit; it must never be logged or exported. Zeroing is best effort for arrays this
 * object owns and cannot scrub transport, parser, caller, or runtime copies.
 * Direct construction is private. The production factory is called only by the authenticated
 * pull adapter in VortXSyncManager; this internal type is not independent authority.
 */
internal class NativeAccountReadCapture private constructor(
    val account: SessionOwnerSnapshot.Account,
    val operationGeneration: Long,
    val baseRevision: Long,
    raw: ByteArray,
    private val readNonce: Any = Any(),
) {
    private val lock = Any()
    private var active = true
    private var rawBytes = raw.copyOf()

    /** The only raw-byte export is a bounded copy for the exact account admission path. */
    internal fun copyRawForApply(expected: SessionOwnerSnapshot.Account): ByteArray = synchronized(lock) {
        check(active && expected == account) { "Authenticated account read is stale" }
        rawBytes.copyOf()
    }

    /** A private mount copy separates retained provenance from the transient sync-call capture. */
    internal fun retainedCopyFor(expected: SessionOwnerSnapshot.Account): NativeAccountReadCapture = synchronized(lock) {
        check(active && expected == account) { "Authenticated account read is stale" }
        NativeAccountReadCapture(account, operationGeneration, baseRevision, rawBytes, readNonce)
    }

    /** Non-secret pairing identity survives transient raw-byte retirement. Equal version/bytes
     * from a different authenticated GET are not this observation and cannot reuse an export. */
    internal fun sameObservation(other: NativeAccountReadCapture): Boolean = readNonce === other.readNonce &&
        account == other.account && operationGeneration == other.operationGeneration && baseRevision == other.baseRevision

    /** Best-effort zeroing of this capture's owned bytes on reject, replacement, or mount retirement. */
    internal fun retire() = synchronized(lock) {
        if (active) {
            active = false
            rawBytes.fill(0)
            rawBytes = byteArrayOf()
        }
    }

    companion object {
        /** Called by VortXSyncManager only after matching Doc, lease, account, and version witnesses. */
        internal fun fromAuthenticatedPull(
            account: SessionOwnerSnapshot.Account,
            operationGeneration: Long,
            leaseAccountId: String,
            leaseOwnerEpoch: Long,
            baseRevision: Long,
            raw: ByteArray,
        ): NativeAccountReadCapture {
            require(account.id == leaseAccountId && account.generation == leaseOwnerEpoch)
            require(operationGeneration >= 0L && baseRevision >= 0L && raw.isNotEmpty())
            require(raw.size <= com.vortx.android.engine.OHJson.MAX)
            return NativeAccountReadCapture(account, operationGeneration, baseRevision, raw)
        }
    }
}

/**
 * Called with a successfully authenticated/decrypted account document under a captured session
 * lease. The bearer and account data key are not separately passed as authorization material here;
 * the decrypted payload itself is sensitive and may contain provider credentials or API keys.
 * Never log or export its raw bytes.
 */
internal interface NativeAccountGateway {
    fun retire()
    /** Bound by the account manager; credentials remain inside its composer, outside Session/JNI. */
    fun installPlaylistAccountProducer(producer: NativePlaylistAccountProducer) {}
    /** Cheap certification only. Missing/recovering mounts must take the full checkpoint path. */
    fun currentMountToken(account: SessionOwnerSnapshot.Account): NativeAccountMountToken? = null
    /** Scalar currency and Session health are separate lock-order boundaries. Missing original
     * authentication admission fails closed; readonly exports never manufacture this authority. */
    fun captureUploadOrigin(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): NativeAccountUploadCurrency.Origin? = null
    suspend fun prepareUploadSeed(account: SessionOwnerSnapshot.Account, original: NativeAccountUploadCurrency.Origin, isCurrent: () -> Boolean):
        Pair<JSONObject, NativeAccountUploadCurrency>? = null
    suspend fun applyUploadSeed(account: SessionOwnerSnapshot.Account, document: JSONObject,
        original: NativeAccountUploadCurrency, isCurrent: () -> Boolean): NativeAccountUploadCurrency? = null
    /** Requires a captured, durably authenticated account lease; never infers a global owner. */
    suspend fun reopenCheckpoint(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): Boolean = false
    /** Called only after an authenticated 404 with no prior backup evidence. */
    suspend fun prepareEmptyAccount(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): JSONObject? = null
    suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean
    suspend fun applyRawDocument(account: SessionOwnerSnapshot.Account, raw: ByteArray, isCurrent: () -> Boolean): Boolean {
        val document = com.vortx.android.engine.NativeProfileOverlayWitness.parseAccountDocument(raw)
        // Old/fake gateways cannot accidentally normalize a history carrier through JSONObject.
        require(!document.has("nativeOwnerHistorySources") && document.optJSONObject("nativeSync")?.optInt("schemaVersion") != 6) {
            "Typed owner-history gateway required"
        }
        return applyDocument(account, document, isCurrent)
    }
    /**
     * Authenticated read path. Legacy/fake gateways retain their old apply behavior but do not
     * acquire the captured baseline unless they explicitly override this method.
     */
    suspend fun applyRawDocument(
        account: SessionOwnerSnapshot.Account,
        captured: NativeAccountReadCapture,
        isCurrent: () -> Boolean,
    ): Boolean {
        val raw = captured.copyRawForApply(account)
        return try {
            if (!isCurrent()) return false
            applyRawDocument(account, raw, isCurrent)
        } finally {
            raw.fill(0)
            captured.retire()
        }
    }
    fun exportDocument(account: SessionOwnerSnapshot.Account): NativeAccountExport?
    /** Synchronous export/compose scope after this exact authenticated GET has been applied.
     * No callback suspends. Real generic mounts supply a Session-issued whole-host composer;
     * legacy/fake gateways retain only the conservative readonly export path. The composer
     * expires on return. The action owns any supplied acknowledgement and must close it. */
    fun <T> withUploadExport(account: SessionOwnerSnapshot.Account, source: NativeAccountReadCapture,
        originalRaw: ByteArray, original: NativeAccountUploadCurrency.Origin, isCurrent: () -> Boolean,
        action: (NativeAccountExport, NativeAccountMountToken?, ((JSONObject) -> ByteArray)?, NativeHostUploadAcknowledgment?, NativeAccountUploadCurrency) -> T): T? {
        // Readonly data cannot manufacture original authentication/installation authority.
        return null
    }
    fun recordGlobalPreferences(account: SessionOwnerSnapshot.Account, changes: JSONObject,
        original: NativeAccountUploadCurrency.Origin): Boolean = false
    fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean = false
    /** Opaque frozen receipt IDs only; no credential or account document is retained here. */
    fun freezePlaylistReceipts(account: SessionOwnerSnapshot.Account): Any? = null
    fun acceptPlaylistReceipts(account: SessionOwnerSnapshot.Account, frozen: Any?,
        acceptedCandidate: String, version: Long) {}
}

/** Original auth/account/installation capability. isCurrent MUST NOT enter a Session monitor:
 * request/receipt predicates run inside the manager operations monitor. Session health and local
 * receipt work instead use withCurrentSession, which acquires Session BEFORE the auth monitor.
 * Neither operation binds a frozen wire candidate to later ordinary checkpoint revisions. */
internal interface NativeAccountUploadCurrency {
    /** Authentication/account operation captured before the first GET. No installation is bound
     * until the same operation has actually merged/reopened its genuine current checkpoint. */
    interface Origin { fun isCurrent(): Boolean }
    fun isCurrent(): Boolean
    fun <T> withCurrentSession(action: () -> T): T?
}

/** Exact sent-host acknowledgement metadata. It is neither a host-field setter nor server ACK
 * proof: the manager must supply its original accepted-candidate/lease/mount predicate. */
internal interface NativeHostUploadAcknowledgment : AutoCloseable {
    /** Original auth/account/mount only after composition; later local checkpoints are allowed. */
    fun isCurrent(): Boolean
    fun acknowledge(isAcceptedCurrent: () -> Boolean): Boolean
    override fun close()
}

/** One edit's immutable full-family observations; raw GET operation metadata is not its authority. */
internal fun interface NativePlaylistAccountProducer {
    fun capture(account: SessionOwnerSnapshot.Account): NativePlaylistAccountWrite?
}
internal interface NativePlaylistAccountWrite : AutoCloseable {
    /** Detached values only. No caller can mutate the captured family witness. */
    fun pendingGlobalValues(): JSONObject
    /** Must hold original account/provider/settings witnesses through [commit], without suspension. */
    fun commitCandidate(raw: ByteArray, originalNativeProjection: ByteArray,
        candidateNative: ByteArray, candidateHost: ByteArray, commit: () -> Unit)
    /** Domain-specific whole-host raw preview, only after the original Session's raw CAS.
     * Old/fake writers cannot silently fall back to a DTO/playlist composition path. */
    fun commitXperienceCandidate(raw: ByteArray, originalNativeProjection: ByteArray,
        candidateNative: ByteArray, host: com.vortx.android.engine.VortxNativeSession.XperienceHostPreview,
        commit: () -> Unit) {
        error("Xperience complete-account admission unavailable")
    }
    /** App-owned typed hook supplies the ACTUAL prepared full account. The separately supplied
     * prospective host includes pending globals only for budget sizing, not durable ack. */
    fun commitPreparedCandidate(raw: ByteArray, prospectiveHost: ByteArray, commit: () -> Unit) {
        error("Prepared complete-account admission unavailable")
    }
    override fun close()
}

/**
 * Registry-independent boundary for catalog-only saved playlists in the encrypted native account.
 * The implementation owns the exact account/session/profile admission, host Lamport clocks,
 * complete prospective account-export budget and durable readback. A mounted engine without that
 * full-account authority is unavailable for playlist mutation; its larger local checkpoint limit
 * is never accepted as cloud eligibility. Callers never receive a generic host-field setter and
 * cannot recapture a newer account when an operation resumes.
 */
internal interface NativePlaylistProfileGateway {
    /** Read-only receipt scope, never mutation authority. */
    interface ReceiptOwner
    /** Opaque original gesture authority. Display identities are not sufficient for admission. */
    interface Target {
        val accountId: String
        val profileId: String
        val receiptOwner: ReceiptOwner
    }

    /** Detached raw playlist registers, including tombstones and bounded future versions. */
    interface Snapshot {
        val target: Target
        val registers: JSONObject
        val receipt: NativePlaylistCloudReceiptLedger.Ticket? get() = null
    }

    /** Mount, profile, full host-merge and acknowledged playlist-register changes only. */
    val playlistChanges: Flow<Unit>
    /** Data-free hint that cached receipt metadata may have changed. */
    val playlistReceiptChanges: Flow<Long>

    /** Captures only an active signed-in account/profile with a full-account budgeted checkpoint. */
    fun capturePlaylistProfile(): Result<Snapshot>

    /** Checks only the supplied original target; it never activates or adopts a current owner. */
    fun playlistTargetIsCurrent(target: Target): Boolean

    /** Re-reads this target's detached raw playlist family under its original admission. */
    fun playlistSnapshot(target: Target): Result<Snapshot>

    /** Closes read-to-publication races. The callback may acquire only the consumer's monitor. */
    fun publishPlaylistIfCurrent(snapshot: Snapshot, publication: () -> Unit): Boolean

    /** Revokes only this captured consumer lifetime. Stored registers are never deleted. */
    fun retirePlaylistTarget(target: Target)
    fun retirePlaylistReceiptOwner(owner: ReceiptOwner)

    fun playlistReceiptState(owner: ReceiptOwner, ticket: NativePlaylistCloudReceiptLedger.Ticket,
                             current: NativePlaylistCloudReceiptLedger.Fingerprint): NativePlaylistCloudReceiptLedger.State

    /**
     * Performs one mandatory playlist-domain admission and exact observed-register CAS, then
     * checkpoints and reads back the full native account before acknowledging the new snapshot.
     * `null` means the field was absent; a tombstone is a non-null register whose value is JSON null.
     */
    suspend fun compareAndSetPlaylistField(
        target: Target,
        editId: String,
        field: String,
        expectedRegister: JSONObject?,
        value: Any,
    ): Result<Snapshot>
}
