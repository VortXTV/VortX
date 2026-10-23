package com.vortx.android.sync

import org.json.JSONObject
import com.vortx.android.profile.UserProfile
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
