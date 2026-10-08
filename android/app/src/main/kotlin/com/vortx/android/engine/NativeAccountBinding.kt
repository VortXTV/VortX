package com.vortx.android.engine

import org.json.JSONObject
import java.math.BigDecimal

/** Immutable selection identity, not a token or an account-wide mutable credential pointer. */
internal class NativeAccountBinding private constructor(private val value: JSONObject) {
    val kind: String get() = value.getJSONObject("account").getString("kind")
    val streamingUID: String? get() = if (kind == "own") value.getJSONObject("account").getString("value") else null
    val transactionID: String? get() = value.opt("transactionId") as? String
    val revision: Long get() = BigDecimal(value.get("revision").toString()).longValueExact()
    fun json(): JSONObject = JSONObject(value.toString())
    fun matches(other: NativeAccountBinding): Boolean = NativeHostPreferences.equal(value, other.value)

    companion object {
        fun read(state: JSONObject, profileID: String): NativeAccountBinding {
            val profile = state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(profileID)
            require(!profile.getBoolean("deleted")) { "Profile is no longer available" }
            val binding = state.optJSONObject("nativeSync")?.optJSONObject("accountSlots")?.optJSONObject(profileID)
                ?.getJSONObject("activeBinding") ?: JSONObject().put("account", profile.getJSONObject("account"))
                .put("revision", 0).put("transactionId", JSONObject.NULL)
            return parse(binding).also {
                require(NativeHostPreferences.equal(binding.getJSONObject("account"), profile.getJSONObject("account"))) {
                    "Native account projection mismatch"
                }
            }
        }

        fun parse(value: JSONObject): NativeAccountBinding {
            require(value.keys().asSequence().toSet() == setOf("account", "revision", "transactionId"))
            val account = value.getJSONObject("account")
            val kind = account.getString("kind")
            require(kind in setOf("local_only", "shared", "own", "pending_own"))
            require(account.keys().asSequence().toSet() == if (kind in setOf("shared", "own")) setOf("kind", "value") else setOf("kind"))
            if (kind in setOf("shared", "own")) requireNativeStreamingUID(account.getString("value"))
            require(value.get("revision") is Number)
            val revision = BigDecimal(value.get("revision").toString()).longValueExact()
            require(revision in 0..9_007_199_254_740_991L)
            val transaction = value.get("transactionId")
            require(transaction == JSONObject.NULL || transaction is String)
            if (transaction is String) requireTransactionID(transaction)
            require((revision == 0L) == (transaction == JSONObject.NULL))
            return NativeAccountBinding(JSONObject(value.toString()))
        }

        internal fun requireTransactionID(value: String) {
            require(value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= 128 && value.none(Char::isISOControl)) {
                "Invalid native account transaction"
            }
        }
    }
}
