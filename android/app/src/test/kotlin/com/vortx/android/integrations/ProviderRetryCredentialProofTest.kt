package com.vortx.android.integrations

import com.vortx.android.integrations.ProviderRetryCredentialProof.Provider
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderRetryCredentialProofTest {
    private val owner = "212d365a-9292-483b-a9de-2da7875fcb2a"
    private val otherOwner = "31edd52a-ec71-4052-ad50-5f04a91b3b19"
    private val key = ByteArray(32) { it.toByte() }

    @Test
    fun reloadedOriginalIsStableAcrossOtherProviderEditAndAcknowledgement() {
        val vault = vault().apply { edit(trakt(), mapOf("traktCreated" to "100")) }
        val original = proof(vault)
        val reloaded = NativeProviderCredentials(vault.scope, vault.encoded())
        assertTrue(matches(original, proof(reloaded)))

        reloaded.edit(mapOf("simklAccess" to "simkl-value", "simklExpiry" to "0"))
        reloaded.acknowledge(reloaded.document())
        assertTrue(matches(original, proof(reloaded)))
        assertFalse(matches(original, proof(reloaded, provider = Provider.SIMKL)))
    }

    @Test
    fun originalCannotMatchReplacementAccountKeyEpochVaultOrCredentialEvents() {
        val originalVault = vault().apply { edit(trakt()) }
        val original = proof(originalVault)
        assertFalse(matches(original, proof(originalVault, epoch = 8)))
        assertFalse(matches(original, proof(originalVault, dataKey = ByteArray(32) { 4 })))
        assertFalse(matches(original, proof(vault(actor = SECOND_ACTOR).apply { edit(trakt()) })))
        assertFalse(matches(original, proof(vault(account = otherOwner).apply { edit(trakt()) })))
        assertFalse(matches(original, original.copyOf(31)))
        assertNull(ProviderRetryCredentialProof.derive(otherOwner, 7, key, Provider.TRAKT, originalVault.encoded()))

        originalVault.edit(trakt("different-access"))
        assertFalse(matches(original, proof(originalVault)))
        originalVault.edit(trakt())
        assertFalse(matches(original, proof(originalVault)))
    }

    @Test
    fun legacyFallbackDisconnectedAndUnprovenOwnerCannotMintProof() {
        val vault = vault().apply { merge(JSONObject().put("apiKeys", JSONObject(trakt()))) }
        assertTrue(vault.value("traktAccess") == "access-value")
        assertNull(ProviderRetryCredentialProof.derive(owner, 7, key, Provider.TRAKT, vault.encoded()))

        vault.edit(trakt())
        assertNull(ProviderRetryCredentialProof.derive(owner, 0, key, Provider.TRAKT, vault.encoded()))
        assertNull(ProviderRetryCredentialProof.derive(owner, 7, key, Provider.TRAKT, "{}"))
        vault.edit(trakt().mapValues { null })
        assertNull(ProviderRetryCredentialProof.derive(owner, 7, key, Provider.TRAKT, vault.encoded()))
    }

    @Test
    fun strictOriginalNumbersCannotRoundIntoNativeIntegerAuthority() {
        val original = vault().apply {
            edit(trakt())
            merge(JSONObject().put("apiKeys", JSONObject().put("tmdb", "legacy-fixture")))
        }
        val encoded = original.encoded()
        val expected = proof(original)
        val paths = listOf(
            listOf("counter"),
            listOf("document", "schemaVersion"),
            listOf("document", "fields", "traktAccess", "clock"),
            listOf("pending", "traktAccess", "clock"),
            listOf("baseline", "tmdb", "clock"),
        )
        for (path in paths) {
            val originalInteger = if (path.first() == "baseline") "0" else "1"
            val exact = replaceRawNumber(encoded, path, originalInteger)
            assertTrue(matches(expected, checkNotNull(ProviderRetryCredentialProof.derive(owner, 7, key, Provider.TRAKT, exact))))
            val rounded = replaceRawNumber(encoded, path, "1.000000000000000001")
            assertNull("raw number at ${path.joinToString(".")}", ProviderRetryCredentialProof.derive(owner, 7, key, Provider.TRAKT, rounded))
        }
    }

    private fun replaceRawNumber(encoded: String, path: List<String>, replacement: String): String {
        val fixture = JSONObject(encoded)
        val parent = path.dropLast(1).fold(fixture) { parent, field -> parent.getJSONObject(field) }
        val marker = "exact-number-fixture"
        parent.put(path.last(), marker)
        return fixture.toString().replace(JSONObject.quote(marker), replacement)
    }

    private fun vault(account: String = owner, actor: String = ORIGINAL_ACTOR): NativeProviderCredentials {
        val scope = "account.$account"
        val fixture = JSONObject(NativeProviderCredentials(scope).encoded()).put("actor", actor)
        return NativeProviderCredentials(scope, fixture.toString())
    }

    private fun proof(
        vault: NativeProviderCredentials,
        epoch: Long = 7,
        dataKey: ByteArray = key,
        provider: Provider = Provider.TRAKT,
    ): ByteArray = requireNotNull(
        ProviderRetryCredentialProof.derive(vault.scope.removePrefix("account."), epoch, dataKey, provider, vault.encoded()),
    )

    private fun matches(left: ByteArray, right: ByteArray): Boolean = ProviderRetryCredentialProof.matches(left, right)

    private fun trakt(access: String = "access-value"): Map<String, String> = mapOf(
        "traktAccess" to access,
        "traktRefresh" to "refresh-value",
        "traktExpiry" to "6000",
    )

    companion object {
        private const val ORIGINAL_ACTOR = "bff293a7-10a9-47b7-9f07-61f48d63e6d0"
        private const val SECOND_ACTOR = "58d0134b-8181-4b06-9bf5-c67af16efe49"
    }
}
