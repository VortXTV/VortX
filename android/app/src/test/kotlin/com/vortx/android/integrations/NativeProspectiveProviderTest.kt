package com.vortx.android.integrations

import com.vortx.android.sync.SessionOwnerSnapshot
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Proposed read-only producer regressions. UNCOMPILED/UNRUN. All credential values are fixtures. */
class NativeProspectiveProviderTest {
    private val owner = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 7)
    @Test fun `absent vault observes qualified legacy fallback without initializing secure storage`() {
        val secure = NativeProviderTestStore()
        var legacy = "fixture-qualified-key"
        val vault = NativeProviderVault(secure) { expected ->
            assertEquals(owner, expected)
            JSONObject().put("apiKeys", JSONObject().put("tmdb", legacy))
        }
        val captured = vault.observe(owner)
        assertTrue(secure.values.isEmpty())
        val complete = vault.prospective(captured, JSONObject().put("apiKeys", JSONObject().put("unknown", "retain")))
        assertEquals(legacy, complete.getJSONObject("apiKeys").getString("tmdb"))
        assertEquals(legacy, complete.getJSONObject("apiKeys").getJSONObject("metadata").getString("tmdb"))
        assertEquals("retain", complete.getJSONObject("apiKeys").getString("unknown"))
        assertEquals(0, complete.getJSONObject("nativeProviderCredentials").getJSONObject("fields").length())
        assertTrue(secure.values.isEmpty()) // No credential register/actor was made durable.
        legacy = "new-qualified-key"
        assertTrue(runCatching { vault.requireCurrent(captured) }.isFailure)
    }
    @Test fun `complete vault witness rejects same encoded replacement and pending only change`() {
        val secure = NativeProviderTestStore()
        val vault = NativeProviderVault(secure)
        val value = vault.load(owner)
        value.edit(mapOf("tmdb" to "fixture-key")); vault.commit(owner, value)
        val original = vault.observe(owner)
        vault.commit(owner, value) // Same bytes still retire the witness.
        assertTrue(runCatching { vault.requireCurrent(original) }.isFailure)
        val pending = vault.observe(owner)
        value.acknowledge(value.document()); vault.commit(owner, value)
        assertTrue(runCatching { vault.requireCurrent(pending) }.isFailure)
    }
}
