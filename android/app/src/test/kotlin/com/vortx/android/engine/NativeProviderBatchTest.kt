package com.vortx.android.engine

import com.vortx.android.model.MediaType
import com.vortx.android.model.PlaybackContext
import com.vortx.android.model.Episode
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.collect
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeProviderBatchTest {
    @Test fun `community contributor finish cannot admit a stale coalescer epoch or earlier target`() {
        val state = SourceListState(requestGeneration = 3, streamId = "opaque", torboxEpoch = 4, singularityEpoch = 5, communityJsEpoch = 6)
        val done = SourceContributorSettlement(3, true)
        fun accepted(current: SourceListState = state, jsEpoch: Int = 6, jsDone: Boolean = true) =
            sourceAssemblySettledForTarget(current, 3, "opaque", done, done, 4, 5, jsEpoch, jsDone)
        assertTrue(accepted()); assertFalse(accepted(jsEpoch = 7)); assertFalse(accepted(jsDone = false))
        assertFalse(accepted(state.copy(requestGeneration = 2))); assertFalse(accepted(state.copy(streamId = "other")))
        assertFalse(accepted(state.copy(torboxEpoch = 3))); assertFalse(accepted(state.copy(singularityEpoch = 4)))
        assertTrue(accepted(state.copy(communityJsEpoch = 7), jsEpoch = 7))
        assertFalse(sourceAssemblySettledForTarget(state, 3, "opaque", done, done, 4, 5, 6, true, rawGroupsHash = 1))
        assertFalse(sourceAssemblySettledForTarget(state, 3, "opaque", done, done, 4, 5, 6, true, mediaServerGroupsHash = 1))
    }
    private val meta = VortxResourceRequest(VortxResourceRequest.Resource.META, "series", "title")
    private val stream = VortxResourceRequest(VortxResourceRequest.Resource.STREAM, "series", "title:1:2")
    private fun addon(index: Int) = VortxResourceAddon("p$index", "https://p$index.invalid/manifest.json", "{}")
    private fun legs(count: Int, metadata: Boolean = false) = List(count) { NativeProviderLeg(if (metadata) meta else stream, addon(it)) }
    private fun page(leg: NativeProviderLeg, body: String = "{\"streams\":[]}") = VortxResourceSnapshot("owner", leg.addon.id, 1, leg.request,
        listOf(VortxResourceGroup(leg.addon.id, "ready", body, null)), mapOf(leg.addon.id to leg.addon.transportUrl))

    @Test fun `twenty two providers settle once in registry order with fast partial and malformed peer retained as failure`() = runBlocking {
        val gates = List(22) { CompletableDeferred<Unit>() }
        val entered = Channel<Int>(Channel.UNLIMITED)
        val updates = Channel<NativeProviderUpdate>(Channel.UNLIMITED)
        val job = launch { collectNativeProviderBatch(legs(22), load = { leg ->
            val index = leg.addon.id.drop(1).toInt(); entered.send(index); gates[index].await()
            if (index == 2) error("Malformed provider")
            page(leg)
        }, onUpdate = { updates.send(it) }) }
        repeat(4) { assertTrue(withTimeout(2000) { entered.receive() } < 4) }
        assertNull(entered.tryReceive().getOrNull())
        gates[3].complete(Unit)
        val first = withTimeout(2000) { updates.receive() }
        assertEquals(listOf("p3"), first.pages.map { it.groups.single().addonId }); assertTrue(first.pending)
        gates.forEach { it.complete(Unit) }; job.join()
        var last = first
        while (true) { last = updates.tryReceive().getOrNull() ?: break }
        assertEquals(22, last.settled); assertFalse(last.pending)
        assertFalse(first.resourceSettled(VortxResourceRequest.Resource.STREAM, 22))
        assertTrue(last.resourceSettled(VortxResourceRequest.Resource.STREAM, 22)) // includes the failed peer
        assertEquals((0 until 22).filter { it != 2 }.map { "p$it" }, last.pages.map { it.groups.single().addonId })
    }

    @Test fun `metadata two and streams four are independent admission queues`() = runBlocking {
        val currentMeta = AtomicInteger(); val currentStream = AtomicInteger()
        val peakMeta = AtomicInteger(); val peakStream = AtomicInteger()
        val release = CompletableDeferred<Unit>(); val entered = Channel<Unit>(Channel.UNLIMITED)
        val job = launch { collectNativeProviderBatch(legs(22, true) + legs(22), load = { leg ->
            val isMeta = leg.request == meta
            val active = if (isMeta) currentMeta else currentStream
            val peak = if (isMeta) peakMeta else peakStream
            val activeCount = active.incrementAndGet()
            peak.updateAndGet { maxOf(it, activeCount) }
            try { entered.send(Unit); release.await(); page(leg, if (isMeta) "{\"meta\":null}" else "{\"streams\":[]}") }
            finally { active.decrementAndGet() }
        }) {} }
        repeat(6) { withTimeout(2000) { entered.receive() } }; assertNull(entered.tryReceive().getOrNull())
        assertEquals(2, currentMeta.get()); assertEquals(4, currentStream.get())
        release.complete(Unit); job.join(); assertEquals(2, peakMeta.get()); assertEquals(4, peakStream.get())
    }

    @Test fun `each provider keeps eight MiB body and each resource keeps thirty two MiB aggregate`() {
        val budget = NativeProviderResultBudget()
        val body = "{\"streams\":[],\"extension\":\"${"x".repeat(2_097_024)}\"}"
        repeat(16) { assertEquals("ready", budget.admit(page(legs(1).single(), body)).groups.single().status) }
        assertEquals("response_budget_exceeded", budget.admit(page(legs(1).single(), body)).groups.single().errorCode)
        assertEquals("ready", budget.admit(page(legs(1, true).single(), body)).groups.single().status)
        val overBody = "x".repeat(8_388_609)
        assertEquals("error", NativeProviderResultBudget().admit(page(legs(1).single(), overBody)).groups.single().status)
    }

    @Test fun `cancellation cancels active and queued jobs without terminal publication`() = runBlocking {
        val entered = Channel<Unit>(Channel.UNLIMITED); val stopped = AtomicInteger(); var published = false
        val job = launch { collectNativeProviderBatch(legs(22, true) + legs(22), load = { leg ->
            try { entered.send(Unit); awaitCancellation() } finally { stopped.incrementAndGet() }
        }) { published = true } }
        repeat(6) { withTimeout(2000) { entered.receive() } }; job.cancelAndJoin()
        assertEquals(6, stopped.get()); assertFalse(published)
    }

    @Test fun `native series progress requires exact video target and never title fallback`() {
        val context = PlaybackContext(PlaybackContext.Owner("owner", true), "series-title", "opaque-video", "series",
            2, 4, "Fixture", null, PlaybackContext.Provenance(null, null, false, null, null))
        assertTrue(nativePlaybackIdentityCanRecord(context))
        assertFalse(nativePlaybackIdentityCanRecord(context.copy(videoId = "")))
        assertFalse(nativePlaybackIdentityCanRecord(context.copy(videoId = context.contentId)))
        assertFalse(nativePlaybackIdentityCanRecord(context.copy(contentId = "")))
        assertTrue(nativePlaybackIdentityCanRecord(context.copy(type = "movie", videoId = context.contentId, season = null, episode = null)))
    }

    @Test fun `fifth dispatched native request gets fresh full budget and single addon body allowance`() = runBlocking {
        val transport = Transport(slow = setOf("p0", "p1", "p2", "p3"), enteredCount = 4)
        open(transport).use { session ->
            val pending = async(Dispatchers.Default) { session.loadProviders("streams", session.read().owner, legs(22)) { _, _ -> } }
            assertTrue(transport.entered.await(3, TimeUnit.SECONDS)); assertEquals(4, transport.calls.get())
            transport.virtualClock.set(19_000); transport.release.countDown(); pending.await()
            assertEquals(22, transport.calls.get()); assertTrue(transport.dispatched.any { it.first == "p4" && it.second == 19_000 })
            assertTrue(transport.wires.all { it.getLong("budgetMs") == 20_000L && it.getLong("maxResponseBytes") == 8_388_608L && it.getJSONArray("addons").length() == 1 })
        }
    }

    @Test fun `owner invalidation cancels all current bridges and rejects A B A late receipts`() = runBlocking {
        val transport = Transport(slow = (0..5).map { "p$it" }.toSet(), enteredCount = 6)
        open(transport).use { session ->
            val owner = session.read().owner; var published = false
            val pending = async(Dispatchers.Default) { runCatching { session.loadProviders("streams", owner, legs(4) + legs(2, true)) { _, _ -> published = true } } }
            assertTrue(transport.entered.await(3, TimeUnit.SECONDS))
            session.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")))
            session.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "owner")))
            assertFalse(session.accepts(owner)); assertEquals(6, transport.cancelled.get())
            transport.release.countDown(); assertTrue(pending.await().isFailure); assertFalse(published)
        }
    }

    @Test fun `native repository paints fast sources and preserves source tokens across partials and malformed peer`() = runBlocking {
        val transport = Transport(slow = setOf("https://p0.invalid/manifest.json"), enteredCount = 1,
            malformed = "https://p2.invalid/manifest.json")
        val store = NativeSearchBatchTest.Store(); val runtime = NativeSearchBatchTest.Runtime()
        VortxNativeSession.open(VortxAccountScope("source-fixture", "owner"), "Owner", runtime, store, transport, true).close()
        val state = JSONObject(store.value!!); val records = JSONObject()
        repeat(22) { index ->
            val endpoint = addon(index).transportUrl
            val value = JSONObject().put("transportUrl", endpoint).put("flags", JSONObject()).put("manifest", JSONObject()
                .put("id", "p$index").put("name", "Provider $index").put("resources", JSONArray(listOf("meta", "stream"))).put("catalogs", JSONArray()))
            records.put(endpoint, JSONObject().put("addedAt", index + 1).put("removedAt", 0).put("valueAt", index + 1).put("value", value))
        }
        state.getJSONObject("nativeSync").getJSONObject("addons").put("owner", JSONObject().put("records", records).put("order", JSONObject().put("ids", JSONArray())))
        store.value = state.toString()
        VortxNativeSession.open(VortxAccountScope("source-fixture", "owner"), "Owner", runtime, store, transport).use { session ->
            val updates = Channel<com.vortx.android.data.StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = launch { NativeCatalogRepository { session }.streamUpdates(MediaType.SERIES, "title", "title:1:2", null, null, false).collect { updates.send(it) } }
            var first = withTimeout(4000) { updates.receive() }
            while (first.groups.isEmpty()) first = withTimeout(4000) { updates.receive() }
            assertFalse(first.terminal); assertFalse(first.selectionReady)
            val firstSource = first.groups.first().streams.first(); assertNotNull(firstSource.nativePlaybackToken)
            transport.release.countDown(); pending.join()
            var last = first
            while (true) { last = updates.tryReceive().getOrNull() ?: break }
            assertTrue(last.terminal); assertTrue(last.selectionReady); assertEquals(44, last.loaded); assertEquals(21, last.groups.flatMap { it.streams }.size)
            assertEquals(firstSource.nativePlaybackToken, last.groups.flatMap { it.streams }.single { it.id == firstSource.id }.nativePlaybackToken)
            assertEquals(44, transport.calls.get())
        }
    }

    @Test fun `adult sources publish before metadata and first valid metadata does not await all peers`() = runBlocking {
        val endpoint = addon(0).transportUrl
        val transport = Transport(slow = setOf(endpoint), enteredCount = 1, slowMetadataOnly = true)
        val store = NativeSearchBatchTest.Store(); val runtime = NativeSearchBatchTest.Runtime()
        VortxNativeSession.open(VortxAccountScope("source-fixture", "owner"), "Owner", runtime, store, transport, true).close()
        val state = JSONObject(store.value!!); val records = JSONObject()
        val value = JSONObject().put("transportUrl", endpoint).put("flags", JSONObject()).put("manifest", JSONObject()
            .put("id", "p0").put("name", "Provider").put("resources", JSONArray(listOf("meta", "stream"))).put("catalogs", JSONArray()))
        records.put(endpoint, JSONObject().put("addedAt", 1).put("removedAt", 0).put("valueAt", 1).put("value", value))
        state.getJSONObject("nativeSync").getJSONObject("addons").put("owner", JSONObject().put("records", records).put("order", JSONObject().put("ids", JSONArray())))
        store.value = state.toString()
        VortxNativeSession.open(VortxAccountScope("source-fixture", "owner"), "Owner", runtime, store, transport).use { session ->
            val repo = NativeCatalogRepository { session }
            val updates = Channel<com.vortx.android.data.StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = launch { repo.streamUpdates(MediaType.SERIES, "title", "title:1:2", null, null, false).collect { updates.send(it) } }
            val first = withTimeout(2000) { updates.receive() }
            assertFalse(first.terminal); assertEquals(1, first.groups.flatMap { it.streams }.size)
            assertTrue(first.selectionReady) // the stream resource settled; do not await metadata peers
            assertTrue(transport.entered.await(1, TimeUnit.SECONDS))
            transport.release.countDown(); pending.join()
            val original = first.groups.first().streams.first()
            val playable = repo.resolve(original, Episode("title:1:2", "Two", 1, 2)).getOrThrow()
            assertEquals("title:1:2", playable.playbackContext?.videoId)
            assertEquals(1, playable.playbackContext?.season); assertEquals(2, playable.playbackContext?.episode)
            assertEquals("Fixture", playable.playbackContext?.title) // stable token enriched after metadata
        }
        val metaTransport = Transport(slow = setOf(endpoint), enteredCount = 1)
        repeat(21) { index ->
            val provider = addon(index + 1).transportUrl
            val peer = JSONObject(value.toString()).put("transportUrl", provider)
            peer.getJSONObject("manifest").put("id", "p${index + 1}")
            records.put(provider, JSONObject().put("addedAt", index + 2).put("removedAt", 0).put("valueAt", index + 2).put("value", peer))
        }
        store.value = state.toString()
        VortxNativeSession.open(VortxAccountScope("source-fixture", "owner"), "Owner", runtime, store, metaTransport).use { session ->
            val detail = withTimeout(2000) { NativeCatalogRepository { session }.meta(MediaType.SERIES, "title").getOrThrow() }
            assertEquals("title", detail.id); assertEquals("title:1:2", detail.videos.single().id)
            assertTrue(metaTransport.cancelled.get() > 0)
            metaTransport.release.countDown()
        }
    }

    private fun open(transport: VortxResourceTransport) = VortxNativeSession.open(VortxAccountScope("source-fixture", "owner"), "Owner",
        NativeSearchBatchTest.Runtime(), NativeSearchBatchTest.Store(), transport, true)
    private class Transport(private val slow: Set<String>, enteredCount: Int, private val malformed: String? = null,
                            private val slowMetadataOnly: Boolean = false) : VortxResourceTransport {
        val entered = CountDownLatch(enteredCount); val release = CountDownLatch(1); val cancelled = AtomicInteger(); val calls = AtomicInteger()
        val virtualClock = AtomicInteger(); val dispatched = java.util.Collections.synchronizedList(mutableListOf<Pair<String, Int>>())
        val wires = java.util.Collections.synchronizedList(mutableListOf<JSONObject>())
        override fun makeCancellation() = object : VortxResourceCancellation {
            private var once = false
            @Synchronized override fun cancel() { if (!once) { once = true; cancelled.incrementAndGet() } }
            override fun close() {}
        }
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
            val input = JSONObject(requestJson); val request = input.getJSONObject("request"); val addon = input.getJSONArray("addons").getJSONObject(0).getString("id")
            wires += input; calls.incrementAndGet(); dispatched += addon to virtualClock.get()
            if (addon in slow && (!slowMetadataOnly || request.getString("resource") == "meta")) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
            val content = if (request.getString("resource") == "meta") JSONObject().put("meta", JSONObject()
                .put("id", request.getString("id")).put("type", request.getString("type")).put("name", "Fixture")
                .put("videos", JSONArray().put(JSONObject().put("id", "title:1:2").put("title", "Two").put("season", 1).put("episode", 2))))
            else JSONObject().put("streams", JSONArray().put(JSONObject().put("url", "https://cdn.invalid/$addon.mkv").put("title", addon)))
            return JSONObject().put("kind", "resource_result").put("requestId", if (addon == malformed) "foreign-request" else input.getString("requestId"))
                .put("generation", input.getLong("generation")).put("request", request).put("cancelled", false)
                .put("groups", JSONArray().put(JSONObject().put("addonId", addon).put("status", "ready").put("content", content))).toString()
        }
    }
}
