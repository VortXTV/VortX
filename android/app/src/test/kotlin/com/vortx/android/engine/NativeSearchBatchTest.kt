package com.vortx.android.engine

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeSearchBatchTest {
    @Test fun `fast results publish before slow legs and final order follows registry`() = runBlocking {
        val gates = List(3) { CompletableDeferred<Unit>() }
        val updates = Channel<Pair<List<Int>, Boolean>>(Channel.UNLIMITED)
        val pending = launch {
            collectNativeResourceBatch(3, load = { index -> gates[index].await(); index }) { pages, loading ->
                updates.send(pages to loading)
            }
        }
        gates[2].complete(Unit)
        assertEquals(listOf(2) to true, withTimeout(2000) { updates.receive() })
        gates[1].complete(Unit)
        assertEquals(listOf(1, 2) to true, withTimeout(2000) { updates.receive() })
        gates[0].complete(Unit)
        assertEquals(listOf(0, 1, 2) to false, withTimeout(2000) { updates.receive() })
        pending.join()
    }

    @Test fun `four request cap and failed leg retain successful incremental pages`() = runBlocking {
        val active = AtomicInteger(); val peak = AtomicInteger()
        val entered = Channel<Int>(Channel.UNLIMITED)
        val release = CompletableDeferred<Unit>()
        val updates = mutableListOf<Pair<List<Int>, Boolean>>()
        val pending = launch {
            collectNativeResourceBatch(7, load = { index ->
                val count = active.incrementAndGet(); peak.updateAndGet { maxOf(it, count) }
                try {
                    entered.send(index); release.await()
                    if (index == 1) error("Broken provider")
                    index
                } finally { active.decrementAndGet() }
            }) { pages, loading -> updates += pages to loading }
        }
        repeat(4) { withTimeout(2000) { entered.receive() } }
        assertNull(entered.tryReceive().getOrNull())
        release.complete(Unit); pending.join()
        assertEquals(4, peak.get())
        assertEquals(listOf(0, 2, 3, 4, 5, 6) to false, updates.last())
        assertTrue(updates.dropLast(1).all { it.second })
    }

    @Test fun `cancelling a batch cancels every child and prevents final publication`() = runBlocking {
        val entered = Channel<Int>(Channel.UNLIMITED)
        val stopped = AtomicInteger()
        val gate = CompletableDeferred<Unit>()
        var published = false
        val pending = launch {
            collectNativeResourceBatch(4, load = { index ->
                try { entered.send(index); gate.await(); index }
                finally { stopped.incrementAndGet() }
            }) { _, _ -> published = true }
        }
        repeat(4) { withTimeout(2000) { entered.receive() } }
        pending.cancelAndJoin()
        assertEquals(4, stopped.get()); assertFalse(published)
    }

    @Test fun `loader cancellation cancels the batch rather than leaving a missing settlement`() = runBlocking {
        val result = runCatching {
            withTimeout(2000) {
                collectNativeResourceBatch(2, load = { index ->
                    if (index == 0) throw CancellationException("Lease revoked")
                    CompletableDeferred<Unit>().await(); index
                }) { _, _ -> fail("Cancelled batch must not publish") }
            }
        }
        assertTrue(result.exceptionOrNull() is CancellationException)
        assertFalse(result.exceptionOrNull() is kotlinx.coroutines.TimeoutCancellationException)
    }

    @Test fun `session query clear closes every bridge and fences a late completion`() = runBlocking {
        val transport = BlockingTransport(2)
        open(transport).use { session ->
            val owner = session.read().owner
            var published = false
            val pending = async(Dispatchers.Default) {
                runCatching { session.loadIncrementally("search", owner, requests(2)) { _, _, _ -> published = true } }
            }
            assertTrue(transport.entered.await(3, TimeUnit.SECONDS))
            session.loadIncrementally("search", owner, emptyList()) { pages, loading, _ ->
                assertTrue(pages.isEmpty()); assertFalse(loading)
            }
            assertEquals(2, transport.cancelled.get())
            transport.release.countDown()
            assertTrue(withTimeout(3000) { pending.await() }.isFailure)
            assertFalse(published)
        }
    }

    @Test fun `session owner mutation revokes every concurrent request`() = runBlocking {
        val transport = BlockingTransport(2)
        open(transport).use { session ->
            val owner = session.read().owner
            var published = false
            val pending = async(Dispatchers.Default) {
                runCatching { session.loadIncrementally("search", owner, requests(2)) { _, _, _ -> published = true } }
            }
            assertTrue(transport.entered.await(3, TimeUnit.SECONDS))
            session.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")))
            assertFalse(session.accepts(owner)); assertEquals(2, transport.cancelled.get())
            transport.release.countDown()
            assertTrue(withTimeout(3000) { pending.await() }.isFailure)
            assertFalse(published)
        }
    }

    @Test fun `session partial receipt cannot publish after replacement`() = runBlocking {
        val transport = BlockingTransport(1, slowId = "1")
        open(transport).use { session ->
            val owner = session.read().owner
            val received = CompletableDeferred<List<VortxResourceSnapshot>>()
            val pending = async(Dispatchers.Default) {
                runCatching {
                    session.loadIncrementally("search", owner, requests(2)) { pages, _, ticket ->
                        if (pages.isNotEmpty()) {
                            assertEquals("accepted", session.publish("search", owner, pages, ticket) { "accepted" })
                            received.complete(pages)
                        }
                    }
                }
            }
            val pages = withTimeout(3000) { received.await() }
            session.loadIncrementally("search", owner, emptyList()) { _, _, _ -> }
            assertTrue(runCatching { session.publish("search", owner, pages) { "stale" } }.isFailure)
            transport.release.countDown()
            assertTrue(withTimeout(3000) { pending.await() }.isFailure)
        }
    }

    @Test fun `repository exposes fast titles while a catalog is pending and keeps success after failure`() = runBlocking {
        val transport = BlockingTransport(1, slowId = "0", failedId = "1")
        val store = Store(); val runtime = Runtime()
        VortxNativeSession.open(VortxAccountScope("search-fixture", "owner"), "Owner", runtime, store, transport, true).close()
        val state = JSONObject(store.value!!)
        val addon = JSONObject().put("transportUrl", "https://fixture.invalid/manifest.json").put("flags", JSONObject())
            .put("manifest", JSONObject().put("id", "fixture").put("name", "Fixture").put("resources", JSONArray(listOf("catalog")))
                .put("catalogs", JSONArray(List(3) { index -> JSONObject().put("type", "movie").put("id", index.toString())
                    .put("extra", JSONArray().put(JSONObject().put("name", "search"))) })))
        state.getJSONObject("nativeSync").getJSONObject("addons").put("owner", JSONObject().put("records", JSONObject()
            .put(addon.getString("transportUrl"), JSONObject().put("addedAt", 1).put("removedAt", 0).put("valueAt", 1).put("value", addon)))
            .put("order", JSONObject().put("ids", JSONArray())))
        store.value = state.toString()
        VortxNativeSession.open(VortxAccountScope("search-fixture", "owner"), "Owner", runtime, store, transport).use { session ->
            val updates = Channel<Pair<List<com.vortx.android.model.MetaItem>, Boolean>>(Channel.UNLIMITED)
            val pending = launch { NativeCatalogRepository { session }.searchUpdates("fixture").collect { updates.send(it) } }
            assertEquals(emptyList<com.vortx.android.model.MetaItem>() to true, withTimeout(3000) { updates.receive() })
            var incremental = withTimeout(3000) { updates.receive() }
            while (incremental.first.isEmpty()) incremental = withTimeout(3000) { updates.receive() }
            assertEquals(listOf("2"), incremental.first.map { it.id }); assertTrue(incremental.second)
            transport.release.countDown(); pending.join()
            var final = incremental
            while (true) {
                val next = updates.tryReceive().getOrNull() ?: break
                final = next
            }
            assertEquals(listOf("0", "2"), final.first.map { it.id }); assertFalse(final.second)
        }
    }

    @Test fun `empty incremental receipt cannot publish into a replacement empty batch`() = runBlocking {
        open(BlockingTransport(0)).use { session ->
            val owner = session.read().owner
            var oldTicket: java.util.UUID? = null
            session.loadIncrementally("search", owner, emptyList()) { _, _, ticket -> oldTicket = ticket }
            session.loadIncrementally("search", owner, emptyList()) { _, _, _ -> }
            assertTrue(runCatching { session.publish("search", owner, emptyList(), requireNotNull(oldTicket)) { "stale" } }.isFailure)
        }
    }

    private fun requests(count: Int) = List(count) { index ->
        VortxResourceRequest(VortxResourceRequest.Resource.CATALOG, "movie", index.toString()) to
            listOf(VortxResourceAddon("fixture", "https://fixture.invalid/manifest.json", "{}"))
    }
    private fun open(transport: VortxResourceTransport): VortxNativeSession =
        VortxNativeSession.open(VortxAccountScope("search-fixture", "owner"), "Owner", Runtime(), Store(), transport, true)

    private class Store : VortxCheckpointStore {
        var value: String? = null
        override fun read(scope: VortxAccountScope) = value
        override fun commit(scope: VortxAccountScope, snapshot: String) { value = snapshot }
    }
    private class Runtime : VortxRuntimeBindings {
        private val values = mutableMapOf<Long, String>(); private var next = 0L
        private fun profile(id: String, owner: Boolean) = JSONObject().put("id", id).put("name", id).put("owner", owner)
            .put("deleted", false).put("addons", "share_primary").put("parental", JSONObject().put("kids", false))
            .put("settings", JSONObject().put("disabledAddons", JSONArray()))
        private fun library() = JSONObject().put("items", JSONArray()).put("history", JSONArray()).put("resume", JSONObject())
            .put("watched", JSONObject()).put("cwBoard", JSONArray())
        override fun create(ownerId: String, ownerName: String) = hydrate(JSONObject()
            .put("roster", JSONObject().put("profiles", JSONObject().put(ownerId, profile(ownerId, true)).put("guest", profile("guest", false))))
            .put("activeProfileId", ownerId).put("libraries", JSONObject().put(ownerId, library()).put("guest", library())).toString())
        override fun hydrate(snapshot: String) = (++next).also { values[it] = snapshot }
        override fun state(handle: Long) = values[handle]
        override fun delta(handle: Long): String? = error("No delta fixture")
        override fun resolve(handle: Long, request: String): String {
            val query = JSONObject(request)
            check(query.getString("kind") == "installed_addons")
            val profile = query.getString("profileId")
            val records = JSONObject(values[handle]!!).getJSONObject("nativeSync").getJSONObject("addons")
                .optJSONObject(profile)?.optJSONObject("records") ?: JSONObject()
            return JSONObject().put("kind", "installed_addons").put("profileId", profile).put("addons", JSONArray(
                records.keys().asSequence().map { records.getJSONObject(it).getJSONObject("value") }.toList())).toString()
        }
        override fun free(handle: Long) { check(values.remove(handle) != null) }
        override fun dispatch(handle: Long, action: String): String {
            val state = JSONObject(values[handle]!!); val input = JSONObject(action)
            when (input.getString("type")) {
                "bind_sync_scope" -> if (!state.has("nativeSync")) state.put("nativeSync", JSONObject().put("schemaVersion", 1).put("scope", input.getString("scope"))
                    .put("ownerProfileId", "owner").put("profiles", JSONObject()).put("addons", JSONObject()).put("libraries", JSONObject()).put("watches", JSONObject()))
                "switch_profile" -> state.put("activeProfileId", input.getString("id"))
                "get_state" -> Unit
                else -> return "{\"ok\":false}"
            }
            values[handle] = state.toString(); return "{\"ok\":true}"
        }
    }
    private class BlockingTransport(count: Int, private val slowId: String? = null, private val failedId: String? = null) : VortxResourceTransport {
        val entered = CountDownLatch(count); val release = CountDownLatch(1); val cancelled = AtomicInteger()
        override fun makeCancellation() = object : VortxResourceCancellation {
            private var wasCancelled = false
            @Synchronized override fun cancel() { if (!wasCancelled) { wasCancelled = true; cancelled.incrementAndGet() } }
            override fun close() {}
        }
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
            val input = JSONObject(requestJson); val request = input.getJSONObject("request")
            if (request.getString("id") == failedId) error("Failed fixture provider")
            if (slowId == null || request.getString("id") == slowId) {
                entered.countDown(); check(release.await(5, TimeUnit.SECONDS))
            }
            return JSONObject().put("kind", "resource_result").put("requestId", input.getString("requestId"))
                .put("generation", input.getLong("generation")).put("request", request).put("cancelled", false)
                .put("groups", JSONArray().put(JSONObject().put("addonId", input.getJSONArray("addons").getJSONObject(0).getString("id")).put("status", "ready")
                    .put("content", JSONObject().put("metas", JSONArray().put(JSONObject().put("id", request.getString("id"))
                        .put("type", request.getString("type")).put("name", "Fixture ${request.getString("id")}")))))).toString()
        }
    }
}
