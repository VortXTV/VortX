package com.vortx.android.sync

import org.json.JSONObject
import com.vortx.android.profile.UserProfile
import org.json.JSONArray

internal data class NativeAccountExport(val nativeSync: JSONObject, val roster: List<UserProfile>, val rosterModifiedSeconds: Double,
    val rawRoster: JSONArray = JSONArray(roster.map { it.encode() }), val hostProfileSyncPending: Boolean = false,
    val hostPreferences: JSONObject? = null, val hostSettingsBaseline: Any? = null)

/** Only called with a successfully authenticated/decrypted document under a captured session lease.
 * Credentials and the account data key never cross this boundary. */
internal interface NativeAccountGateway {
    fun retire()
    /** Requires a captured, durably authenticated account lease; never infers a global owner. */
    suspend fun reopenCheckpoint(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): Boolean = false
    /** Called only after an authenticated 404 with no prior backup evidence. */
    suspend fun prepareEmptyAccount(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): JSONObject? = null
    suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean
    fun exportDocument(account: SessionOwnerSnapshot.Account): NativeAccountExport?
    fun recordGlobalPreferences(account: SessionOwnerSnapshot.Account, changes: JSONObject): Boolean = false
    fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean = false
}
