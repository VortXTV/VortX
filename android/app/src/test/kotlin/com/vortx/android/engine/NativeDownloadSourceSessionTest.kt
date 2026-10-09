package com.vortx.android.engine

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeDownloadSourceSessionTest {
    private val scope = VortxAccountScope("download-account", "owner")
    private val first = Episode("tt-download:1:1", "First", 1, 1)
    private val second = Episode("tt-download:1:2", "Second", 1, 2)
    private val third = Episode("tt-download:1:3", "Third", 1, 3)

    @Test fun `batch fetches and interactive streams have independent channels`() = runBlocking {
        val transport = Transport().apply { blockedVideo = first.id }
        open(transport).use { native ->
            val repo = NativeCatalogRepository { native }
            val owner = repo.continueWatchingOwner()
            repo.captureDownloadSession(owner)!!.use { batch ->
                repo.captureDownloadSession(owner)!!.use { other ->
                    val pending = async(Dispatchers.Default) { batch.streams(MediaType.SERIES, "tt-download", first) }
                    try {
                        assertTrue(transport.entered.await(5, TimeUnit.SECONDS))
                        val interactive = repo.streams(MediaType.SERIES, "tt-download", second.id).getOrThrow().single().streams.single()
                        val unrelated = other.streams(MediaType.SERIES, "tt-download", third).getOrThrow().single().streams.single()
                        assertEquals(third.id, other.pin(unrelated, third)!!.resolve().getOrThrow().playbackContext!!.videoId)
                        other.close()
                        assertEquals(second.id, repo.resolve(interactive, second).getOrThrow().playbackContext!!.videoId)
                    } finally { transport.release.countDown() }
                    val selected = pending.await().getOrThrow().single().streams.single()
                    assertEquals(first.id, batch.pin(selected, first)!!.resolve().getOrThrow().playbackContext!!.videoId)
                }
            }
        }
    }

    @Test fun `pins survive later episode loads and batch close with exact detached source and independent leases`() = runBlocking {
        val resolutions = mutableListOf<StreamSource>()
        val lifetimes = mutableListOf<() -> Boolean>()
        val closes = mutableListOf<AtomicInteger>()
        val resolver = object : NativePlaybackResolver {
            override suspend fun resolve(source: StreamSource, episode: Episode?): Playable = error("Owner probes required")
            override suspend fun resolve(source: StreamSource, episode: Episode?, isCurrent: () -> Boolean,
                playbackIsCurrent: () -> Boolean): Playable {
                assertTrue(isCurrent()); assertTrue(playbackIsCurrent())
                resolutions += source
                lifetimes += playbackIsCurrent
                val closed = AtomicInteger().also(closes::add)
                return Playable(source.url!!, source.title, headers = source.requestHeaders,
                    playbackLease = AutoCloseable { closed.incrementAndGet() })
            }
        }
        open().use { native ->
            val repo = NativeCatalogRepository(resolver) { native }
            val batch = repo.captureDownloadSession(repo.continueWatchingOwner())!!
            val selected = batch.streams(MediaType.SERIES, "tt-download", first).getOrThrow().single().streams.single()
            val firstPin = batch.pin(selected, first)!!
            @Suppress("UNCHECKED_CAST")
            (selected.requestHeaders as MutableMap<String, String>)["X-Fixture"] = "changed-after-pin"
            val next = batch.streams(MediaType.SERIES, "tt-download", second).getOrThrow().single().streams.single()
            val secondPin = batch.pin(next, second)!!
            batch.close()
            assertNull(batch.pin(selected, first))
            assertTrue(batch.streams(MediaType.SERIES, "tt-download", third).isFailure)
            val one = firstPin.resolve().getOrThrow()
            val two = secondPin.resolve().getOrThrow()
            (one.headers as MutableMap<String, String>)["X-Fixture"] = "changed-after-resolve"
            one.playbackLease!!.close()
            val renewed = firstPin.resolve().getOrThrow()
            assertEquals(listOf(1, 0, 0), closes.map { it.get() })
            assertTrue(lifetimes.all { it() })
            assertEquals(one.playbackContext, renewed.playbackContext)
            assertEquals(first.id, one.playbackContext!!.videoId)
            assertEquals(second.id, two.playbackContext!!.videoId)
            assertEquals(listOf(selected.url, next.url, selected.url), resolutions.map { it.url })
            assertEquals(mapOf("Referer" to "https://fixture.invalid/", "X-Fixture" to "source"), renewed.headers)
            var admitted = 0
            assertTrue(firstPin.admit { admitted++ }); assertEquals(1, admitted)
            native.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")))
            assertFalse(firstPin.isCurrent()); assertFalse(secondPin.isCurrent())
            assertTrue(lifetimes.none { it() })
            assertFalse(firstPin.admit { admitted++ }); assertEquals(1, admitted)
            two.playbackLease!!.close(); renewed.playbackLease!!.close()
            assertEquals(listOf(1, 1, 1), closes.map { it.get() })
        }
    }

    @Test fun `pins reject copied forged foreign and wrong episode sources`() = runBlocking {
        open().use { native ->
            val repo = NativeCatalogRepository { native }
            val owner = repo.continueWatchingOwner()
            repo.captureDownloadSession(owner)!!.use { batch ->
                repo.captureDownloadSession(owner)!!.use { other ->
                    val source = batch.streams(MediaType.SERIES, "tt-download", first).getOrThrow().single().streams.single()
                    assertNull(batch.pin(source.copy(), first))
                    assertNull(batch.pin(source.copy(url = "https://unrelated.invalid/video"), first))
                    assertNull(other.pin(source, first))
                    assertNull(batch.pin(source, second))
                    assertNull(batch.pin(source, first.copy(episode = 99)))
                    assertTrue(repo.resolve(source, first).isFailure)
                    val playerSource = repo.streams(MediaType.SERIES, "tt-download", first.id).getOrThrow().single().streams.single()
                    assertNull(batch.pin(playerSource, first))
                    assertNotNull(batch.pin(source, first))
                }
            }
        }
    }

    @Test fun `visible single source pins survive shared streams replacement and reject forged attribution`() = runBlocking {
        open().use { native ->
            val repo = NativeCatalogRepository { native }
            val owner = repo.continueWatchingOwner()
            val source = repo.streams(MediaType.SERIES, "tt-download", first.id).getOrThrow().single().streams.single()
            assertNull(repo.pinDownloadSource(owner.copy(revision = owner.revision + 1), source, first))
            assertNotNull(repo.pinDownloadSource(owner, source.copy(), first))
            assertNull(repo.pinDownloadSource(owner, source.copy(url = "https://unrelated.invalid/video"), first))
            assertNull(repo.pinDownloadSource(owner, source, second))
            val pin = repo.pinDownloadSource(owner, source, first)!!
            repo.streams(MediaType.SERIES, "tt-download", second.id).getOrThrow()
            assertNull(repo.pinDownloadSource(owner, source, first))
            assertTrue(repo.resolve(source, first).isFailure)
            val playable = pin.resolve().getOrThrow()
            assertEquals(source.url, playable.url)
            assertEquals(first.id, playable.playbackContext!!.videoId)
            assertEquals(owner.revision, playable.playbackContext!!.nativeSessionRevision)
            assertTrue(pin.admit {})
        }
    }

    @Test fun `batch refuses a foreign or mislabeled episode when title metadata is available`() = runBlocking {
        open().use { native ->
            val repo = NativeCatalogRepository { native }
            repo.captureDownloadSession(repo.continueWatchingOwner())!!.use { batch ->
                assertTrue(batch.streams(MediaType.SERIES, "tt-download", first.copy(id = "other-title:1:1")).isFailure)
                assertTrue(batch.streams(MediaType.SERIES, "tt-download", first.copy(episode = 99)).isFailure)
                assertTrue(batch.streams(MediaType.SERIES, "tt-download", first).isSuccess)
            }
        }
    }

    @Test fun `single source cache badges pin the original payload but cannot alter its transport`() = runBlocking {
        val resolved = mutableListOf<StreamSource>()
        val resolver = NativePlaybackResolver { source, _ ->
            resolved += source
            Playable(source.url!!, source.title, headers = source.requestHeaders)
        }
        open().use { native ->
            val repo = NativeCatalogRepository(resolver) { native }
            val owner = repo.continueWatchingOwner()
            val issued = repo.streams(MediaType.SERIES, "tt-download", first.id).getOrThrow().single().streams.single()
            val decorated = issued.copy(id = issued.id + "#cached", description = "Cached")
            assertNull(repo.pinDownloadSource(owner, decorated.copy(url = "https://unrelated.invalid/video"), first))
            assertNull(repo.pinDownloadSource(owner, decorated.copy(requestHeaders = mapOf("Referer" to "https://unrelated.invalid/")), first))
            val pin = repo.pinDownloadSource(owner, decorated, first)!!
            repo.streams(MediaType.SERIES, "tt-download", second.id).getOrThrow()
            assertEquals(issued.url, pin.resolve().getOrThrow().url)
            assertEquals(issued, resolved.single())
            assertEquals(issued.url, pin.resolve().getOrThrow().url)
            assertEquals(listOf(issued, issued), resolved)
        }
    }

    @Test fun `profile round trip and account replacement never revive stale pins or batch owners`() = runBlocking {
        open().use { original ->
            var current = original
            val repo = NativeCatalogRepository { current }
            val owner = repo.continueWatchingOwner()
            repo.captureDownloadSession(owner)!!.use { batch ->
                val source = batch.streams(MediaType.SERIES, "tt-download", first).getOrThrow().single().streams.single()
                val pin = batch.pin(source, first)!!
                original.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")))
                original.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "owner")))
                assertNotEquals(owner, repo.continueWatchingOwner())
                assertNull(repo.captureDownloadSession(owner))
                assertNull(batch.pin(source, first))
                assertFalse(pin.isCurrent()); assertTrue(pin.resolve().isFailure)
                assertTrue(batch.streams(MediaType.SERIES, "tt-download", first).isFailure)
                val fresh = repo.captureDownloadSession(repo.continueWatchingOwner())!!
                val freshSource = fresh.streams(MediaType.SERIES, "tt-download", second).getOrThrow().single().streams.single()
                val freshPin = fresh.pin(freshSource, second)!!
                fresh.close()
                open().use { replacement ->
                    current = replacement
                    assertFalse(freshPin.isCurrent()); assertTrue(freshPin.resolve().isFailure)
                    assertFalse(freshPin.admit { fail("Stale account admitted queue mutation") })
                }
            }
        }
    }

    @Test fun `owner change during resolution closes the late operation lease`() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val closes = AtomicInteger()
        val resolver = NativePlaybackResolver { source, _ ->
            entered.complete(Unit); release.await()
            Playable(source.url!!, source.title, playbackLease = AutoCloseable { closes.incrementAndGet() })
        }
        open().use { native ->
            val repo = NativeCatalogRepository(resolver) { native }
            val batch = repo.captureDownloadSession(repo.continueWatchingOwner())!!
            val source = batch.streams(MediaType.SERIES, "tt-download", first).getOrThrow().single().streams.single()
            val pin = batch.pin(source, first)!!
            batch.close()
            val pending = async { pin.resolve() }
            withTimeout(5000) { entered.await() }
            native.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")))
            release.complete(Unit)
            assertTrue(pending.await().isFailure)
            assertEquals(1, closes.get())
        }
    }

    @Test fun `admitted mutation failures propagate unchanged and stale owners never run the action`() = runBlocking {
        open().use { native ->
            val repo = NativeCatalogRepository { native }
            repo.captureDownloadSession(repo.continueWatchingOwner())!!.use { batch ->
                val source = batch.streams(MediaType.SERIES, "tt-download", first).getOrThrow().single().streams.single()
                val pin = batch.pin(source, first)!!
                val failure = java.io.IOException("Fixture file mutation failed")
                assertSame(failure, runCatching { pin.admit { throw failure } }.exceptionOrNull())
                native.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")))
                var ran = false
                assertFalse(pin.admit { ran = true })
                assertFalse(ran)
            }
        }
    }

    @Test fun `renewal supersedes only its own pending resolve and preserves handed off leases`() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val calls = AtomicInteger()
        val closed = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val resolver = NativePlaybackResolver { source, _ ->
            val call = calls.incrementAndGet()
            if (call == 1) { entered.complete(Unit); release.await() }
            Playable(source.url!!, source.title, playbackLease = AutoCloseable { closed += call })
        }
        open().use { native ->
            val repo = NativeCatalogRepository(resolver) { native }
            repo.captureDownloadSession(repo.continueWatchingOwner())!!.use { batch ->
                val a = batch.streams(MediaType.SERIES, "tt-download", first).getOrThrow().single().streams.single()
                val pin = batch.pin(a, first)!!
                val b = batch.streams(MediaType.SERIES, "tt-download", second).getOrThrow().single().streams.single()
                val independent = batch.pin(b, second)!!
                val pending = async { pin.resolve() }
                withTimeout(5000) { entered.await() }
                val otherLease = independent.resolve().getOrThrow()
                val replacementLease = pin.resolve().getOrThrow()
                release.complete(Unit)
                assertTrue(pending.await().isFailure)
                assertEquals(listOf(1), closed.toList())
                assertTrue(pin.isCurrent()); assertTrue(independent.isCurrent())
                otherLease.playbackLease!!.close(); replacementLease.playbackLease!!.close()
                assertEquals(listOf(1, 2, 3), closed.toList())
            }
        }
    }

    @Test fun `close cancels only its pending channel and blocks late publication`() = runBlocking {
        val transport = Transport().apply { blockedVideo = first.id }
        open(transport).use { native ->
            val repo = NativeCatalogRepository { native }
            val batch = repo.captureDownloadSession(repo.continueWatchingOwner())!!
            val pending = async(Dispatchers.Default) { batch.streams(MediaType.SERIES, "tt-download", first) }
            try {
                assertTrue(transport.entered.await(5, TimeUnit.SECONDS))
                batch.close()
                assertTrue(transport.blockedToken!!.cancelled)
                repo.captureDownloadSession(repo.continueWatchingOwner())!!.use { other ->
                    val source = other.streams(MediaType.SERIES, "tt-download", second).getOrThrow().single().streams.single()
                    assertNotNull(other.pin(source, second))
                }
            } finally { transport.release.countDown() }
            assertTrue(pending.await().isFailure)
        }
    }

    @Test fun `channel release matches both name and owner and never retires another consumer`() = runBlocking {
        open().use { native ->
            val owner = native.read().owner
            val request = VortxResourceRequest(VortxResourceRequest.Resource.STREAM, "series", first.id) to listOf(addon())
            val a = native.load("download-A", owner, listOf(request))
            val b = native.load("download-B", owner, listOf(request))
            native.release("download-A", owner.copy(revision = owner.revision + 1))
            assertTrue(native.publish("download-A", owner, a) { true })
            native.release("download-A", owner)
            assertTrue(runCatching { native.publish("download-A", owner, a) {} }.isFailure)
            assertTrue(native.publish("download-B", owner, b) { true })
            native.release("download-B", owner)
        }
    }

    private fun open(transport: Transport = Transport()) =
        VortxNativeSession.open(scope, "Owner", Runtime(), Store(), transport, allowNewAccount = true)

    private class Store : VortxCheckpointStore {
        private var value: String? = null
        override fun read(scope: VortxAccountScope) = value
        override fun commit(scope: VortxAccountScope, snapshot: String) { value = snapshot }
    }

    private class Runtime : VortxRuntimeBindings {
        private val states = mutableMapOf<Long, String>()
        private var next = 0L
        private fun profile(id: String, owner: Boolean) = JSONObject().put("id", id).put("name", id)
            .put("owner", owner).put("deleted", false).put("addons", "share_primary")
            .put("parental", JSONObject().put("kids", false))
            .put("settings", JSONObject().put("disabledAddons", JSONArray()))
        override fun create(ownerId: String, ownerName: String) = hydrate(JSONObject()
            .put("roster", JSONObject().put("profiles", JSONObject().put(ownerId, profile(ownerId, true)).put("guest", profile("guest", false))))
            .put("activeProfileId", ownerId).put("libraries", JSONObject().put(ownerId, JSONObject()).put("guest", JSONObject())).toString())
        override fun hydrate(snapshot: String) = (++next).also { states[it] = snapshot }
        override fun state(handle: Long) = states[handle]
        override fun delta(handle: Long): String? = error("Not a download operation")
        override fun free(handle: Long) { states.remove(handle) }
        override fun resolve(handle: Long, request: String): String {
            val input = JSONObject(request)
            return when (input.getString("kind")) {
                "installed_addons" -> JSONObject().put("kind", "installed_addons").put("profileId", input.getString("profileId"))
                    .put("addons", JSONArray().put(JSONObject().put("transportUrl", ADDON_URL).put("manifest", manifest()))).toString()
                "resume_point" -> JSONObject().put("kind", "resume_point").put("resume", JSONObject.NULL).toString()
                else -> error("Unexpected download projection")
            }
        }
        override fun dispatch(handle: Long, action: String): String {
            val state = JSONObject(states.getValue(handle)); val input = JSONObject(action)
            when (input.getString("type")) {
                "bind_sync_scope" -> state.put("nativeSync", JSONObject().put("schemaVersion", 1)
                    .put("scope", input.getString("scope")).put("ownerProfileId", "owner").put("profiles", JSONObject())
                    .put("addons", JSONObject()).put("libraries", JSONObject()).put("watches", JSONObject()))
                "switch_profile" -> state.put("activeProfileId", input.getString("id"))
                else -> error("Unexpected download mutation")
            }
            states[handle] = state.toString()
            return "{\"ok\":true}"
        }
    }

    private class Transport : VortxResourceTransport {
        @Volatile var blockedVideo: String? = null
        @Volatile var blockedToken: Token? = null
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        class Token : VortxResourceCancellation {
            @Volatile var cancelled = false
            override fun cancel() { cancelled = true }
            override fun close() = Unit
        }
        override fun makeCancellation() = Token()
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
            val input = JSONObject(requestJson); val request = input.getJSONObject("request")
            val kind = request.getString("resource"); val id = request.getString("id")
            if (kind == "stream" && id == blockedVideo) {
                blockedToken = cancellation as Token
                entered.countDown(); check(release.await(10, TimeUnit.SECONDS))
            }
            val content = if (kind == "meta") JSONObject().put("meta", JSONObject().put("id", "tt-download")
                .put("type", "series").put("name", "Download Fixture").put("videos", JSONArray((1..3).map {
                    JSONObject().put("id", "tt-download:1:$it").put("season", 1).put("episode", it).put("title", "Episode $it")
                }))) else JSONObject().put("streams", JSONArray().put(JSONObject().put("url", "https://fixture.invalid/$id.mp4")
                .put("name", "Fixture source").put("behaviorHints", JSONObject().put("proxyHeaders", JSONObject().put("request",
                    JSONObject().put("Referer", "https://fixture.invalid/").put("X-Fixture", "source"))))))
            val addons = input.getJSONArray("addons")
            return JSONObject().put("kind", "resource_result").put("requestId", input.getString("requestId"))
                .put("generation", input.getLong("generation")).put("request", request).put("cancelled", false)
                .put("groups", JSONArray((0 until addons.length()).map {
                    JSONObject().put("addonId", addons.getJSONObject(it).getString("id")).put("status", "ready").put("content", content)
                })).toString()
        }
    }

    companion object {
        private const val ADDON_URL = "https://fixture.invalid/manifest.json"
        private fun manifest() = JSONObject().put("id", "download-fixture").put("name", "Download Fixture")
            .put("resources", JSONArray(listOf("meta", "stream"))).put("types", JSONArray(listOf("series"))).put("catalogs", JSONArray())
        private fun addon() = VortxResourceAddon(ADDON_URL, ADDON_URL, manifest().toString())
    }
}
