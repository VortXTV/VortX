package com.vortx.android.integrations

import com.vortx.android.engine.NativeProfileOverlayWitness
import org.json.JSONObject
import java.math.BigDecimal
import java.security.MessageDigest
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Pure proof derivation. The caller owns and confirms the original persisted session and vault. */
internal object ProviderRetryCredentialProof {
    enum class Provider(val keys: List<String>) {
        TRAKT(listOf("traktAccess", "traktRefresh", "traktExpiry")),
        SIMKL(listOf("simklAccess", "simklExpiry"));

        val accessKey: String get() = keys.first()
        val expiryKey: String get() = keys.last()
    }

    class ExistingVault internal constructor(val actor: String, val credentials: NativeProviderCredentials)

    fun parseExisting(accountId: String, confirmedSealedVault: String): ExistingVault? {
        if (!canonicalActor(accountId) || confirmedSealedVault.length > MAX_VAULT_CHARS) return null
        return try {
            val bytes = confirmedSealedVault.toByteArray(Charsets.UTF_8)
            try {
                if (bytes.toString(Charsets.UTF_8) != confirmedSealedVault) return null
                val original = NativeProfileOverlayWitness.parseDocument(bytes)
                val actor = original.opt("actor") as? String ?: return null
                if (!canonicalActor(actor)) return null
                val scope = "account.$accountId"
                validateRawIntegers(original, scope)
                ExistingVault(actor, NativeProviderCredentials(scope, confirmedSealedVault))
            } finally {
                bytes.fill(0)
            }
        } catch (cancelled: kotlin.coroutines.cancellation.CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }

    /** Android JSONObject can round near-integers while reading a string. Validate the
     * strict parser's exact numbers in every native register carrier before that parse. */
    private fun validateRawIntegers(original: JSONObject, scope: String) {
        val counter = original.get("counter") as? Number ?: error("Invalid provider counter")
        require(BigDecimal(counter.toString()).longValueExact() in 0..NativeProviderCredentials.MAX_CLOCK)
        NativeProviderCredentials.validate(original.getJSONObject("document"), scope)
        for (carrier in listOf("pending", "baseline")) {
            NativeProviderCredentials.validate(
                JSONObject().put("schemaVersion", 1).put("scope", scope).put("fields", original.getJSONObject(carrier)),
                scope,
            )
        }
    }

    internal fun vaultActor(credentials: NativeProviderCredentials): String =
        JSONObject(credentials.encoded()).getString("actor")

    fun derive(
        accountId: String,
        persistedOwnerEpoch: Long,
        dataKey: ByteArray,
        provider: Provider,
        confirmedSealedVault: String,
    ): ByteArray? {
        val vault = parseExisting(accountId, confirmedSealedVault) ?: return null
        return derive(accountId, persistedOwnerEpoch, dataKey, provider, vault)
    }

    fun derive(
        accountId: String,
        persistedOwnerEpoch: Long,
        dataKey: ByteArray,
        provider: Provider,
        vault: ExistingVault,
    ): ByteArray? {
        if (vault.credentials.scope != "account.$accountId" || persistedOwnerEpoch <= 0 || dataKey.size != 32) return null
        val credentials = vault.credentials
        val fields = credentials.document().getJSONObject("fields")
        val events = provider.keys.map { key ->
            val event = fields.optJSONObject(key) ?: return null
            val actor = event.getString("actor")
            val clock = event.getLong("clock")
            val value = (event.opt("value") as? String)?.takeIf { it.length in 1..MAX_FIELD_CHARS } ?: return null
            if (!canonicalActor(actor) || clock <= 0) return null
            Event(key, actor, clock, value)
        }

        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(dataKey, "HmacSHA256"))
        val proofKey = mac.doFinal("$DOMAIN/key".toByteArray(Charsets.US_ASCII))
        try {
            mac.init(SecretKeySpec(proofKey, "HmacSHA256"))
            mac.field(DOMAIN)
            mac.field(accountId)
            mac.field(persistedOwnerEpoch.toString())
            mac.field(provider.name)
            mac.field(vault.actor)
            for (event in events) {
                mac.field(event.key)
                mac.field(event.actor)
                mac.field(event.clock.toString())
                mac.field(event.value)
            }
            if (provider == Provider.TRAKT) {
                val created = credentials.auxiliary("traktCreated")
                mac.update(if (created == null) 0.toByte() else 1.toByte())
                created?.let { mac.field(it) }
            }
            return mac.doFinal()
        } finally {
            proofKey.fill(0)
        }
    }

    fun matches(saved: ByteArray, current: ByteArray): Boolean =
        saved.size == 32 && current.size == 32 && MessageDigest.isEqual(saved, current)

    // Prefix Java String code-unit length and preserve every code unit, including opaque tokens.
    private fun Mac.field(value: String) {
        for (shift in LENGTH_SHIFTS) update((value.length ushr shift).toByte())
        for (codeUnit in value) {
            update((codeUnit.code ushr 8).toByte())
            update(codeUnit.code.toByte())
        }
    }

    private fun canonicalActor(value: String): Boolean =
        value != ZERO_ACTOR && runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)

    private class Event(val key: String, val actor: String, val clock: Long, val value: String)

    private const val DOMAIN = "vortx-android-provider-retry-credential-v1"
    private const val MAX_VAULT_CHARS = 512 * 1024
    private const val MAX_FIELD_CHARS = 16 * 1024
    private const val ZERO_ACTOR = "00000000-0000-0000-0000-000000000000"
    private val LENGTH_SHIFTS = intArrayOf(24, 16, 8, 0)
}
