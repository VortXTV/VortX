package com.vortx.android.sync

import org.json.JSONObject
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.flow.Flow
import org.json.JSONArray

internal data class NativeAccountExport(val nativeSync: JSONObject, val roster: List<UserProfile>, val rosterModifiedSeconds: Double,
    val rawRoster: JSONArray = JSONArray(roster.map { it.encode() }), val hostProfileSyncPending: Boolean = false,
    val hostPreferences: JSONObject? = null, val hostSettingsBaseline: Any? = null,
    /** Complete raw account from the accepted typed checkpoint, never a reconstructed DTO. */
    val rawAccount: ByteArray? = null)

/** Opaque current mount and mutation generation; contains no account document or credentials. */
internal data class NativeAccountMountToken(val installation: Any, val revision: Long)

/** Only called with a successfully authenticated/decrypted document under a captured session lease.
 * Credentials and the account data key never cross this boundary. */
internal interface NativeAccountGateway {
    fun retire()
    /** Cheap certification only. Missing/recovering mounts must take the full checkpoint path. */
    fun currentMountToken(account: SessionOwnerSnapshot.Account): NativeAccountMountToken? = null
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
    fun exportDocument(account: SessionOwnerSnapshot.Account): NativeAccountExport?
    fun recordGlobalPreferences(account: SessionOwnerSnapshot.Account, changes: JSONObject): Boolean = false
    fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean = false
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
    /** Opaque original gesture authority. Display identities are not sufficient for admission. */
    interface Target {
        val accountId: String
        val profileId: String
    }

    /** Detached raw playlist registers, including tombstones and bounded future versions. */
    interface Snapshot {
        val target: Target
        val registers: JSONObject
    }

    /** Mount, profile, full host-merge and acknowledged playlist-register changes only. */
    val playlistChanges: Flow<Unit>

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

    /**
     * Performs one mandatory playlist-domain admission and exact observed-register CAS, then
     * checkpoints and reads back the full native account before acknowledging the new snapshot.
     * `null` means the field was absent; a tombstone is a non-null register whose value is JSON null.
     */
    suspend fun compareAndSetPlaylistField(
        target: Target,
        field: String,
        expectedRegister: JSONObject?,
        value: Any,
    ): Result<Snapshot>
}
