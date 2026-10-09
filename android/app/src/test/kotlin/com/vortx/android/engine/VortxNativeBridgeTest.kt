package com.vortx.android.engine

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class VortxNativeBridgeTest {
    private class Runtime : VortxRuntimeBindings {
        val values = mutableMapOf<Long, String>()
        val freed = mutableListOf<Long>()
        val dirty = mutableSetOf<Long>()
        var next = 0L
        override fun create(ownerId: String, ownerName: String) = hydrate(JSONObject().put("owner", ownerId).toString())
        override fun hydrate(snapshot: String): Long = if (runCatching { JSONObject(snapshot) }.isFailure) 0 else (++next).also { values[it] = snapshot }
        override fun dispatch(handle: Long, action: String): String { dirty += handle; return "{\"ok\":true}" }
        override fun resolve(handle: Long, request: String) = request
        override fun state(handle: Long) = values[handle]
        override fun delta(handle: Long) = if (dirty.remove(handle)) values[handle] else "{}"
        override fun free(handle: Long) { check(values.remove(handle) != null); freed += handle }
    }

    private class Transport : VortxResourceTransport {
        val fixture = JSONObject(File("../../test/fixtures/native-resource-contract.json").readText())
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val cancelled = AtomicInteger()
        val closed = AtomicInteger()
        override fun makeCancellation() = object : VortxResourceCancellation {
            val didClose = AtomicBoolean()
            override fun cancel() { cancelled.incrementAndGet() }
            override fun close() { check(didClose.compareAndSet(false, true)); closed.incrementAndGet() }
        }
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
            val input = JSONObject(requestJson)
            val request = input.getJSONObject("request")
            if (request.getString("id") == "slow") { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
            return JSONObject().put("kind", "resource_result").put("requestId", if (request.getString("id") == "wrong") "foreign" else input.getString("requestId"))
                .put("generation", input.getLong("generation")).put("request", request).put("cancelled", false)
                .put("groups", JSONArray().put(JSONObject().put("addonId", "a").put("status", "ready").put("content", fixture.getJSONObject(request.getString("resource"))))
                    .put(JSONObject().put("addonId", "b").put("status", "timeout").put("error", JSONObject().put("code", "timeout")))).toString()
        }
    }
    private fun registry() = listOf("a", "b").map { VortxResourceAddon(it, "https://$it.example/manifest.json", "{}") }
    private fun request(resource: VortxResourceRequest.Resource, id: String = "tt-fixture") = VortxResourceRequest(resource, "series", id)

    @Test fun `failed hydration preserves old account and close frees each handle once`() {
        val abi = Runtime()
        val runtime = VortxNativeRuntime.create(abi, "account/profile", "Owner")
        runtime.dispatch("{}")
        val captured = runtime.stateJson()
        assertEquals(captured, runtime.takeDeltaJson()); assertEquals("{}", runtime.takeDeltaJson())
        assertTrue(runCatching { runtime.replaceFromSnapshot("bad") }.isFailure)
        assertEquals(captured, runtime.stateJson()); assertTrue(abi.freed.isEmpty())
        runtime.replaceFromSnapshot(captured)
        assertEquals(listOf(1L), abi.freed); assertEquals("{}", runtime.takeDeltaJson())
        runtime.close(); runtime.close()
        assertEquals(listOf(1L, 2L), abi.freed)
        assertTrue(runCatching { runtime.stateJson() }.isFailure)
        VortxNativeRuntime.hydrate(abi, captured).use { assertEquals(captured, it.stateJson()) }
    }

    @Test fun `native resources project into real shipping decoders`() = runBlocking {
        VortxResourceBridge(Transport()).use { bridge ->
            val addons = registry()
            val catalogRequest = request(VortxResourceRequest.Resource.CATALOG, "popular")
            val catalog = bridge.load("owner", catalogRequest, addons)
            val page = bridge.load("owner", catalogRequest.copy(extra = listOf("skip" to "100")), addons)
            val board = VortxResourceProjection.board(listOf(catalog, page), addons)
            assertEquals(2, JSONObject(board).getJSONArray("catalogs").getJSONArray(0).length())
            assertEquals("Fixture Series", EngineState.parseCatalogs(board).single().items.single().name)
            val meta = bridge.load("owner", request(VortxResourceRequest.Resource.META), addons)
            val streamRequest = request(VortxResourceRequest.Resource.STREAM, "tt-fixture:1:2")
            val streams = bridge.load("owner", streamRequest, addons)
            val detail = VortxResourceProjection.metaDetails(meta, streams, streamRequest, addons)
            assertEquals("Fixture Series", EngineState.parseMetaDetail(detail)?.name)
            assertEquals(2, EngineState.parseStreamGroups(detail, "tt-fixture:1:2").size)
            val raw = JSONObject(detail).getJSONArray("streams").getJSONObject(0).getJSONObject("content").getJSONArray("content")
            assertEquals(2, raw.length())
            assertEquals(9007199254740993L, raw.getJSONObject(0).getJSONObject("behaviorHints").getLong("videoSize"))
            assertEquals(3, raw.getJSONObject(1).getInt("fileIdx"))
            val replacedRegistry = listOf(addons[0].copy(transportUrl = "https://replacement.example/manifest.json"), addons[1])
            assertTrue(runCatching { VortxResourceProjection.metaDetails(meta, streams, streamRequest, replacedRegistry) }.isFailure)
            val emptyMeta = VortxResourceGroup("a", "ready", "{\"meta\":null}", null)
            assertEquals("Err", VortxResourceProjection.entry(emptyMeta, request(VortxResourceRequest.Resource.META), addons).getJSONObject("content").getString("type"))
            val subtitles = bridge.load("owner", request(VortxResourceRequest.Resource.SUBTITLES), addons)
            val subtitleGroups = JSONArray(VortxResourceProjection.subtitles(subtitles, addons))
            assertEquals(2, subtitleGroups.getJSONObject(0).getJSONObject("content").getJSONArray("content").length())
            assertEquals("Err", subtitleGroups.getJSONObject(1).getJSONObject("content").getString("type"))
            assertTrue(runCatching { bridge.load("owner", request(VortxResourceRequest.Resource.STREAM, "wrong"), addons) }.isFailure)
        }
    }

    @Test fun `new owner fences late result even when transport ignores cancellation`() = runBlocking {
        val transport = Transport()
        VortxResourceBridge(transport).use { bridge ->
            val old = async(Dispatchers.Default) { runCatching { bridge.load("old-owner", request(VortxResourceRequest.Resource.STREAM, "slow"), registry()) } }
            assertTrue(transport.entered.await(5, TimeUnit.SECONDS))
            val newer = bridge.load("new-owner", request(VortxResourceRequest.Resource.STREAM), registry())
            transport.release.countDown()
            assertTrue(old.await().isFailure); assertTrue(bridge.accepts(newer))
            assertTrue(transport.cancelled.get() > 0)
            bridge.invalidate(); assertFalse(bridge.accepts(newer))
        }
    }

    @Test fun `cancellation defers native token free until load returns`() = runBlocking {
        val transport = Transport()
        VortxResourceBridge(transport).use { bridge ->
            val pending = async(Dispatchers.Default) { bridge.load("owner", request(VortxResourceRequest.Resource.STREAM, "slow"), registry()) }
            assertTrue(transport.entered.await(5, TimeUnit.SECONDS))
            pending.cancel()
            assertEquals(0, transport.closed.get())
            transport.release.countDown(); pending.join()
            assertTrue(pending.isCancelled)
        }
    }
}
