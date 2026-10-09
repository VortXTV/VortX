package com.vortx.android.sync

import android.content.Context
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** Configured endpoints can contain credentials. Persist only encrypted and never log their identity. */
internal class AddonPublicationProofs(private val persistence: LibraryProofPersistence) {
    constructor(context: Context) : this(object : LibraryProofPersistence {
        private val store = FailClosedCredentialStore(context, "vortx_addon_publication", tag = "AddonPublication")
        override fun read(key: String): Result<String?> {
            val snapshot = store.confirmedSnapshot(key)
            return if (snapshot.availability == PersistentCredentialAvailability.AVAILABLE) Result.success(snapshot.values[key])
            else Result.failure(IllegalStateException("Publication storage unavailable"))
        }
        override fun write(key: String, value: String): Boolean = store.set(key, value)
    })

    @Synchronized fun published(account: String, native: NativeLibraryOwner, raw: VortXSyncDoc.AddonDescriptor): VortXSyncDoc.AddonDescriptor? {
        val entry = load(account)?.optJSONObject(entryKey(native, raw)) ?: return null
        if (entry.optString("fingerprint") != fingerprint(raw)) return null
        return entry.optJSONObject("outbound")?.let(VortXSyncDoc::addonDescriptor)
    }

    @Synchronized fun grant(account: String, native: NativeLibraryOwner, pairs: List<Pair<VortXSyncDoc.AddonDescriptor, VortXSyncDoc.AddonDescriptor>>): Boolean {
        if (pairs.isEmpty()) return true
        val ledger = load(account) ?: return false
        for ((raw, outbound) in pairs) {
            if (!matchesInstalled(outbound, raw)) return false
            ledger.put(entryKey(native, raw), JSONObject().put("fingerprint", fingerprint(raw)).put("outbound", JSONObject(outbound.raw.toString())))
        }
        val encoded = ledger.toString()
        val key = "owner." + digest(account)
        return persistence.write(key, encoded) && persistence.read(key).getOrNull() == encoded
    }

    private fun load(account: String): JSONObject? {
        val result = persistence.read("owner." + digest(account))
        if (result.isFailure) return null
        val encoded = result.getOrNull() ?: return JSONObject()
        return runCatching { JSONObject(encoded) }.getOrNull()
    }

    private fun entryKey(native: NativeLibraryOwner, row: VortXSyncDoc.AddonDescriptor) =
        digest(JSONArray().put(native.uid ?: JSONObject.NULL).put(endpoint(row.transportUrl)).toString())

    companion object {
        // Never lowercase a credential-bearing path/query or collapse different configured endpoints.
        internal fun endpoint(url: String): String = url.trim()
        internal fun fingerprint(row: VortXSyncDoc.AddonDescriptor): String = digest(canonical(row.raw))
        internal fun matchesInstalled(expected: VortXSyncDoc.AddonDescriptor, actual: VortXSyncDoc.AddonDescriptor): Boolean =
            endpoint(expected.transportUrl) == endpoint(actual.transportUrl) &&
                containsExpected(expected.raw.optJSONObject("manifest"), actual.raw.optJSONObject("manifest")) &&
                // Absent legacy flags remain absent authority; explicit trusted flags need a receipt.
                (expected.raw.optJSONObject("flags")?.let { it.length() == 0 || containsExpected(it, actual.raw.optJSONObject("flags")) } ?: true)

        // Native serde can add defaults. Only action/account-authored fields are exported; a proof never
        // authorizes those extra native fields, even if they were inherited from a previous account.
        private fun containsExpected(expected: Any?, actual: Any?): Boolean = when (expected) {
            is JSONObject -> actual is JSONObject && expected.keys().asSequence().all { actual.has(it) && containsExpected(expected.get(it), actual.get(it)) }
            is JSONArray -> actual is JSONArray && expected.length() == actual.length() && (0 until expected.length()).all { containsExpected(expected.get(it), actual.get(it)) }
            else -> expected == actual
        }
        private fun canonical(value: Any?): String = when (value) {
            is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(prefix = "{", postfix = "}") { JSONObject.quote(it) + ":" + canonical(value.get(it)) }
            is JSONArray -> (0 until value.length()).joinToString(prefix = "[", postfix = "]") { canonical(value.get(it)) }
            is String -> JSONObject.quote(value)
            else -> value?.toString() ?: "null"
        }
        private fun digest(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}

internal class AddonPublicationLease(
    private val account: String,
    private val proofs: AddonPublicationProofs,
    private val admit: ((() -> Boolean) -> Boolean),
) {
    /** Called under the captured native fence. No proof follows a no-op, changed owner, or failed read. */
    fun install(native: NativeLibraryOwner, expected: VortXSyncDoc.AddonDescriptor, read: () -> List<VortXSyncDoc.AddonDescriptor>, action: () -> Unit): Boolean = admit {
        action()
        if (!admit { true }) return@admit false
        val actual = read().singleOrNull { AddonPublicationProofs.endpoint(it.transportUrl) == AddonPublicationProofs.endpoint(expected.transportUrl) }
            ?: return@admit false
        if (!AddonPublicationProofs.matchesInstalled(expected, actual)) return@admit false
        proofs.grant(account, native, listOf(actual to expected))
    }
}
