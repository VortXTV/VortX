package com.vortx.android.sync

import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal

/** Only compare accepted, account-joined wire carriers, never UI projections or local actor clocks. */
internal object NativeSyncPublicationPolicy {
    fun needsRepublish(remote: JSONObject, joined: NativeAccountExport, remoteRaw: ByteArray? = null): Boolean {
        joined.rawAccount?.let { accepted ->
            // Full admitted wire carriers, not the small native UI projection. Otherwise every
            // schema6 receive looks different and needlessly rearms a full account upload.
            val original = com.vortx.android.engine.NativeOwnerHistoryAccount(requireNotNull(remoteRaw))
            val next = com.vortx.android.engine.NativeOwnerHistoryAccount(accepted)
            return listOf("nativeSync", "nativeHostPreferences", "profileEditResults", "nativeOwnerHistorySources").any { key ->
                val a = original.raw(key); val b = next.raw(key)
                if (a == null || b == null) a != null || b != null else !com.vortx.android.engine.OHJson.equal(a, b)
            }
        }
        val incoming = remote.optJSONObject("nativeSync")
        if (incoming == null) return !remote.has("nativeSync") &&
            joined.nativeSync.optString("scope").isNotBlank() && joined.nativeSync.optJSONObject("legacyImport") != null
        // Both are already verified by the native gateway. A missing/wrong scope must not be
        // repaired by guessing an account or treating a migration projection as native authority.
        if (incoming.optString("scope").isBlank() || incoming.optString("scope") != joined.nativeSync.optString("scope")) return false
        return !same(incoming, joined.nativeSync) ||
            (joined.hostPreferences != null && !same(remote.optJSONObject("nativeHostPreferences"), joined.hostPreferences))
    }

    /** A securely joined provider register can retain an ACKed fact without new local intent. */
    fun needsProviderRepublish(remote: JSONObject, joined: JSONObject): Boolean {
        val carrier = joined.optJSONObject("nativeProviderCredentials") ?: return false
        // Empty initialized vaults contribute no causal facts and must not arm an idle echo.
        if (carrier.optJSONObject("fields")?.length() == 0) return false
        return !same(remote.optJSONObject("nativeProviderCredentials"), carrier) ||
            !same(remote.opt("apiKeys"), joined.opt("apiKeys"))
    }

    internal fun same(left: Any?, right: Any?): Boolean = when {
        left === right -> true
        left == null || right == null -> false
        left === JSONObject.NULL || right === JSONObject.NULL -> left === JSONObject.NULL && right === JSONObject.NULL
        left is JSONObject && right is JSONObject -> {
            val keys = left.keys().asSequence().toSet()
            keys == right.keys().asSequence().toSet() && keys.all { same(left.opt(it), right.opt(it)) }
        }
        left is JSONArray && right is JSONArray -> left.length() == right.length() &&
            (0 until left.length()).all { same(left.opt(it), right.opt(it)) }
        left is Number && right is Number -> runCatching {
            BigDecimal(left.toString()).compareTo(BigDecimal(right.toString())) == 0
        }.getOrDefault(false)
        else -> left == right
    }
}
