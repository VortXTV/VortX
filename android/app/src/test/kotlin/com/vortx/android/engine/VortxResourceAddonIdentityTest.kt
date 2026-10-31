package com.vortx.android.engine

import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Public client identity/serialization/projection tests; no JNI or native guard substitute. */
class VortxResourceAddonIdentityTest {
    private val manifest = """{"id":"shared.manifest","name":"Same Name","version":"1.0.0","types":["movie"],"resources":["stream"],"catalogs":[]}"""

    private fun configuredUrl(bytes: Int): String {
        val prefix = "https://aio.example.invalid/"
        val suffix = "/manifest.json"
        return prefix + "a".repeat(bytes - prefix.length - suffix.length) + suffix
    }

    @Test
    fun exactTransportBytesHaveStableKnownSha256Identity() {
        val url = "https://aio.example.invalid/Config-A/manifest.json?fixture=Alpha"
        val addon = VortxResourceAddon.fromTransportUrl(url, manifest)
        // Independently authored SHA-256 golden, not another implementation in this fixture.
        assertEquals("751abe3271d5c8fb476eed3ccee06aa3c0198eab7642e636c6b6e14c97e5ca8c", addon.id)
        assertEquals(addon.id, VortxResourceAddon.fromTransportUrl(url).id)
        assertEquals(url, addon.transportUrl)
        assertEquals(manifest, addon.manifestJson)
        assertEquals(addon.id, VortxResourceAddon.fromTransportUrl(url, manifest.replace("1.0.0", "2.0.0")).id)
    }

    @Test
    fun longConfiguredUrlsKeepFullTransportAndBoundedSerializedIds() {
        for (bytes in listOf(512, 513, 4_096, 16_384)) {
            val url = configuredUrl(bytes)
            val addon = VortxResourceAddon.fromTransportUrl(url)
            assertEquals(bytes, url.toByteArray(Charsets.UTF_8).size)
            assertEquals(64, addon.id.toByteArray(Charsets.UTF_8).size)
            assertTrue(addon.id.matches(Regex("[0-9a-f]{64}")))
            assertTrue(addon.id.toByteArray(Charsets.UTF_8).size <= 512)
            assertNotEquals(url, addon.id)
            val wire = addon.json()
            assertEquals(addon.id, wire.getString("id"))
            assertEquals(url, wire.getString("transportUrl"))
            assertFalse(wire.has("manifest"))
        }
    }

    @Test
    fun equalManifestNamesAndIdsDoNotMergePathQueryOrCaseVariants() {
        val urls = listOf(
            "https://aio.example.invalid/Config-A/manifest.json?fixture=Alpha",
            "https://aio.example.invalid/config-A/manifest.json?fixture=Alpha",
            "https://aio.example.invalid/Config-A/manifest.json?fixture=alpha",
            "https://aio.example.invalid/Config-B/manifest.json?fixture=Alpha",
        )
        val addons = urls.map { VortxResourceAddon.fromTransportUrl(it, manifest) }
        assertEquals(urls.size, addons.map { it.id }.toSet().size)
        assertEquals(urls, addons.map { it.transportUrl })
        assertEquals(1, addons.map { it.json().getJSONObject("manifest").getString("id") }.toSet().size)
        assertEquals(1, addons.map { it.json().getJSONObject("manifest").getString("name") }.toSet().size)
    }

    private class RecordingTransport : VortxResourceTransport {
        val wire = AtomicReference<String>()
        override fun makeCancellation() = object : VortxResourceCancellation {
            override fun cancel() = Unit
            override fun close() = Unit
        }
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
            wire.set(requestJson)
            val input = JSONObject(requestJson)
            val addons = input.getJSONArray("addons")
            val groups = JSONArray()
            for (index in 0 until addons.length()) {
                val source = JSONObject().put("url", "https://media.example.invalid/$index")
                    .put("name", "same row label")
                groups.put(JSONObject().put("addonId", addons.getJSONObject(index).getString("id"))
                    .put("status", "ready").put("content", JSONObject().put("streams", JSONArray().put(source))))
            }
            return JSONObject().put("kind", "resource_result").put("requestId", input.getString("requestId"))
                .put("generation", input.getLong("generation")).put("request", input.getJSONObject("request"))
                .put("cancelled", false).put("groups", groups).toString()
        }
    }

    @Test
    fun actualBridgeAndProjectionRecoverEveryExactLongConfiguredBase() = runBlocking {
        val urls = listOf(configuredUrl(513), configuredUrl(16_384))
        val addons = urls.map { VortxResourceAddon.fromTransportUrl(it, manifest) }
        val stream = VortxResourceRequest(VortxResourceRequest.Resource.STREAM, "movie", "tt-fixture")
        val meta = VortxResourceRequest(VortxResourceRequest.Resource.META, "movie", "tt-fixture")
        val transport = RecordingTransport()
        VortxResourceBridge(transport).use { bridge ->
            val snapshot = bridge.load("fixture-owner", stream, addons)
            val serialized = JSONObject(transport.wire.get()).getJSONArray("addons")
            for (index in addons.indices) {
                assertEquals(addons[index].id, serialized.getJSONObject(index).getString("id"))
                assertEquals(urls[index], serialized.getJSONObject(index).getString("transportUrl"))
            }
            assertEquals(addons.map { it.id }, snapshot.groups.map { it.addonId })
            assertEquals(addons.associate { it.id to it.transportUrl }, snapshot.sourceUrls)
            val projection = VortxResourceProjection.providerDetails(listOf(snapshot), meta, stream, addons)
            val parsed = EngineState.parseStreamGroups(projection, "tt-fixture")
            assertEquals(urls, parsed.map { it.base })
            assertEquals(urls, parsed.map { it.sourceInstanceId })
            assertEquals(2, parsed.size)
            assertEquals(1, parsed.map { it.addon }.toSet().size)
            assertEquals(listOf("https://media.example.invalid/0", "https://media.example.invalid/1"),
                parsed.flatMap { it.streams }.map { it.url })
        }
    }

    @Test
    fun projectionStillRejectsRegistryTransportReplacementForAnExistingId() {
        val original = VortxResourceAddon.fromTransportUrl(configuredUrl(513), manifest)
        val request = VortxResourceRequest(VortxResourceRequest.Resource.STREAM, "movie", "tt-fixture")
        val meta = VortxResourceRequest(VortxResourceRequest.Resource.META, "movie", "tt-fixture")
        val content = JSONObject().put("streams", JSONArray().put(JSONObject().put("url", "https://media.example.invalid/0")))
        val snapshot = VortxResourceSnapshot("fixture-owner", "fixture-request", 1, request,
            listOf(VortxResourceGroup(original.id, "ready", content.toString(), null)),
            mapOf(original.id to original.transportUrl))
        val changed = original.copy(transportUrl = configuredUrl(514))
        assertTrue(runCatching {
            VortxResourceProjection.providerDetails(listOf(snapshot), meta, request, listOf(changed))
        }.isFailure)
    }
}
