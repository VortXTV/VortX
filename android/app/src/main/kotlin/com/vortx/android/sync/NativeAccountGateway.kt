package com.vortx.android.sync

import org.json.JSONObject
import com.vortx.android.profile.UserProfile
import org.json.JSONArray

internal data class NativeAccountExport(val nativeSync: JSONObject, val roster: List<UserProfile>, val rosterModifiedSeconds: Double,
    val rawRoster: JSONArray = JSONArray(roster.map { it.encode() }), val hostProfileSyncPending: Boolean = false)

/** Only called with a successfully authenticated/decrypted document under a captured session lease.
 * Credentials and the account data key never cross this boundary. */
internal interface NativeAccountGateway {
    fun retire()
    suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean
    fun exportDocument(account: SessionOwnerSnapshot.Account): NativeAccountExport?
}
