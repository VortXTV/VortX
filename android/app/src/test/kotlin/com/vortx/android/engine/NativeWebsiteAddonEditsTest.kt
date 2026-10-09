package com.vortx.android.engine

import java.math.BigDecimal
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

internal object WebsiteAddonFixtures {
    val scope = VortxAccountScope("account.test", "owner")
    const val url = "https://fixture.invalid/a/manifest.json"
    fun descriptor() = JSONObject().put("transportUrl", url).put("flags", JSONObject()).put("manifest", JSONObject()
        .put("id", url).put("name", "Fixture").put("version", "1.0.0").put("catalogs", JSONArray()).put("resources", JSONArray()).put("types", JSONArray())
        .put("extension", JSONObject().put("2", "line\n").put("10", "slash/").put("\uE000", BigDecimal("1e-7")).put("😀", BigDecimal("1.0"))))
    fun event(id: String = "00000000000000000000000000000001") = JSONObject().put("schemaVersion", 1).put("eventId", id)
        .put("counter", "1").put("wallTime", 1_000_000).put("scope", scope.accountID).put("ownerProfileId", scope.ownerProfileID).put("profileId", scope.ownerProfileID)
        .put("expectedBinding", JSONObject().put("account", JSONObject().put("kind", "local_only")).put("revision", 0).put("transactionId", JSONObject.NULL))
        .put("observed", JSONObject().put("records", JSONObject()).put("order", JSONObject().put("updatedAt", 0).put("ids", JSONArray())))
        .put("mutations", JSONArray().put(JSONObject().put("transportUrl", url).put("state", "present").put("addon", descriptor())))
    fun document(vararg events: JSONObject) = JSONObject().put("webAddonEdits", JSONObject().put("schemaVersion", 1).put("events", JSONArray(events.toList())))
    fun response(event: JSONObject) = JSONObject().put("ok", true).put("events", JSONArray().put(JSONObject().put("event", "website_addon_edits_applied")
        .put("receipt", JSONObject().put("schemaVersion", 1).put("fingerprint", "4698bb16ec9581e729f9fd93e2f7922ae8ad2f07d409dca3ed08a38dc6190a6a")
            .also { receipt -> for (key in listOf("eventId", "counter", "scope", "ownerProfileId", "profileId", "expectedBinding")) receipt.put(key, event.get(key)) })))
}

class NativeWebsiteAddonEditsTest {
    private val scope = WebsiteAddonFixtures.scope
    private fun event() = WebsiteAddonFixtures.event()
    private fun rejected(value: JSONObject) = assertTrue(runCatching { NativeWebsiteAddonEdits.events(value, scope) }.isFailure)

    @Test fun `queue keeps raw manifest extensions omissions and precise original numbers`() {
        val original = event()
        val result = NativeWebsiteAddonEdits.events(WebsiteAddonFixtures.document(original), scope).single()
        assertTrue(NativeHostPreferences.equal(original, result))
        assertNotSame(original, result)
        val addon = result.getJSONArray("mutations").getJSONObject(0).getJSONObject("addon")
        assertEquals(0, addon.getJSONObject("flags").length())
        assertEquals(4, addon.getJSONObject("manifest").getJSONObject("extension").length())
        original.put("counter", "2"); assertEquals("1", result.getString("counter"))
    }

    @Test fun `strict queue and event bounds reject before projection`() {
        assertTrue(NativeWebsiteAddonEdits.events(JSONObject(), scope).isEmpty())
        rejected(JSONObject().put("webAddonEdits", event()))
        rejected(WebsiteAddonFixtures.document(event(), event()))
        rejected(WebsiteAddonFixtures.document(event().put("future", true)))
        rejected(WebsiteAddonFixtures.document(event().put("counter", "01")))
        rejected(WebsiteAddonFixtures.document(event().put("counter", "18446744073709551615")))
        rejected(WebsiteAddonFixtures.document(event().put("scope", "account.foreign")))
        rejected(WebsiteAddonFixtures.document(event().put("wallTime", System.currentTimeMillis() + 49L * 60 * 60 * 1000)))
        rejected(WebsiteAddonFixtures.document(event().put("wallTime", BigDecimal("9007199254740990.1"))))
        rejected(WebsiteAddonFixtures.document(event().put("counter", 1)))
        val tooMany = (0..128).map { WebsiteAddonFixtures.event(it.toString(16).padStart(32, '0')) }.toTypedArray()
        rejected(WebsiteAddonFixtures.document(*tooMany))
        val tooLarge = event().also { it.getJSONArray("mutations").getJSONObject(0).getJSONObject("addon").getJSONObject("manifest").put("extension", "x".repeat(2 * 1024 * 1024)) }
        rejected(WebsiteAddonFixtures.document(tooLarge))
    }

    @Test fun `exact original observed clock cannot round into accepted range`() {
        val value = event()
        value.getJSONObject("observed").getJSONObject("order").put("updatedAt", BigDecimal("9007199254740990.1"))
        rejected(WebsiteAddonFixtures.document(value))
        assertEquals(BigDecimal("9007199254740990.1"), value.getJSONObject("observed").getJSONObject("order").get("updatedAt"))
    }

    @Test fun `mutations reject unknown fields duplicate identity and removed descriptor`() {
        val removal = event().also { it.getJSONArray("mutations").getJSONObject(0).put("state", "removed") }
        rejected(WebsiteAddonFixtures.document(removal))
        val duplicate = event().also { it.getJSONArray("mutations").put(it.getJSONArray("mutations").getJSONObject(0)) }
        rejected(WebsiteAddonFixtures.document(duplicate))
        val wrongURL = event().also { it.getJSONArray("mutations").getJSONObject(0).put("transportUrl", "https://fixture.invalid/b/manifest.json") }
        rejected(WebsiteAddonFixtures.document(wrongURL))
        val invalidBinding = event().also { it.getJSONObject("expectedBinding").getJSONObject("account").put("kind", "own").put("value", 123) }
        rejected(WebsiteAddonFixtures.document(invalidBinding))
    }

    @Test fun `receipt is exact source scoped and native fingerprint remains native authority`() {
        val source = event(); val response = WebsiteAddonFixtures.response(source)
        assertEquals("4698bb16ec9581e729f9fd93e2f7922ae8ad2f07d409dca3ed08a38dc6190a6a", NativeWebsiteAddonEdits.receipt(scope, source, response).getString("fingerprint"))
        response.getJSONArray("events").getJSONObject(0).getJSONObject("receipt").put("profileId", "foreign")
        assertTrue(runCatching { NativeWebsiteAddonEdits.receipt(scope, source, response) }.isFailure)
        assertTrue(runCatching { NativeWebsiteAddonEdits.receipt(scope, source, JSONObject().put("ok", false)) }.exceptionOrNull() is NativeWebsiteAddonEdits.Conflict)
    }

    @Test fun `pending conflicts preserve both raw sources and prune only exact accepted source`() {
        val source = event(); val divergent = event().put("counter", "2")
        var pending = NativeWebsiteAddonEdits.retain(scope, NativeWebsiteAddonEdits.emptyPending(), source)
        pending = NativeWebsiteAddonEdits.retain(scope, pending, divergent)
        pending = NativeWebsiteAddonEdits.retain(scope, pending, divergent)
        assertEquals(2, pending.getJSONArray("events").length())
        val remaining = NativeWebsiteAddonEdits.remove(pending, source)
        assertEquals("2", remaining.getJSONArray("events").getJSONObject(0).getString("counter"))
    }

    @Test fun `union retains cloud pruned sources detects collisions and bounds combined size`() {
        val first = event()
        val pending = NativeWebsiteAddonEdits.retain(scope, NativeWebsiteAddonEdits.emptyPending(), first)
        assertTrue(NativeHostPreferences.equal(first, NativeWebsiteAddonEdits.union(scope, pending, emptyList()).single()))
        assertEquals(1, NativeWebsiteAddonEdits.union(scope, pending, listOf(event())).size)
        assertEquals(2, NativeWebsiteAddonEdits.union(scope, pending, listOf(event().put("counter", "2"))).size)
        val incoming = (2..129).map { WebsiteAddonFixtures.event(it.toString(16).padStart(32, '0')) }
        assertTrue(runCatching { NativeWebsiteAddonEdits.union(scope, pending, incoming) }.isFailure)
        assertEquals(1, pending.getJSONArray("events").length())
        assertTrue(runCatching { NativeWebsiteAddonEdits.union(VortxAccountScope("account.foreign", "owner"), pending, emptyList()) }.isFailure)
    }

    @Test fun `typed random event identities survive scanner without exempting encoded secrets`() {
        val source = WebsiteAddonFixtures.event("e9" + "0".repeat(30))
        NativeWebsiteAddonEdits.events(WebsiteAddonFixtures.document(source), scope)
        val receipt = WebsiteAddonFixtures.response(source).getJSONArray("events").getJSONObject(0).getJSONObject("receipt")
        NativeHostDocument.requireCredentialFree(JSONObject().put("nativeSync", JSONObject().put("websiteAddonReceipts", JSONObject().put(source.getString("eventId"), receipt))))
        val encodedSecret = Base64.getEncoder().encodeToString("{\"authKey\":\"secret\"}".toByteArray())
        source.getJSONArray("mutations").getJSONObject(0).getJSONObject("addon").getJSONObject("manifest").put("extension", encodedSecret)
        rejected(WebsiteAddonFixtures.document(source))
        assertTrue(runCatching { NativeHostDocument.requireCredentialFree(JSONObject().put("arbitrary", "e9" + "0".repeat(30))) }.isFailure)
    }
}
