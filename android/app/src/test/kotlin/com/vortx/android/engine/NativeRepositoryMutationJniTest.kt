package com.vortx.android.engine

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Real immutable JNI; every resource is an in-memory fixture, never a provider request. */
class NativeRepositoryMutationJniTest {
    private val scope = VortxAccountScope("account.mutation-fixture", "owner")
    private class Store : VortxCheckpointStore {
        var value: String? = null
        var commits = 0
        var fail = false
        override fun read(scope: VortxAccountScope) = value
        override fun commit(scope: VortxAccountScope, snapshot: String) { check(!fail) { "Fixture commit rejected" }; value = snapshot; commits++ }
    }
    private fun bindings() = object : VortxRuntimeBindings {
        override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
        override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
        override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
        override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
        override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
        override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
        override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
    }
    private fun manifest(name: String = "Fixture") = JSONObject().put("id", "fixture").put("name", name).put("version", "1.0.0")
        .put("types", JSONArray(listOf("movie", "series"))).put("resources", JSONArray(listOf("meta"))).put("catalogs", JSONArray())
    private fun metadata(id: String) = JSONObject().put("meta", JSONObject().put("id", id).put("type", "series").put("name", "Exact inventory")
        .put("videos", JSONArray().put(JSONObject().put("id", "opaque-one").put("season", 1).put("episode", 2))
            .put(JSONObject().put("id", "opaque-two").put("season", 1).put("episode", 8))
            .put(JSONObject().put("id", "opaque-three").put("season", 3).put("episode", 1))))
    private inner class Transport : VortxResourceTransport {
        var payload: (JSONObject) -> JSONObject = { request -> if (request.getString("resource") == "manifest") manifest("Replacement") else metadata(request.getString("id")) }
        var entered: CountDownLatch? = null
        var release: CountDownLatch? = null
        var delayedId: String? = null
        var calls = 0
        override fun makeCancellation() = object : VortxResourceCancellation { override fun cancel() {}; override fun close() {} }
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
            val input = JSONObject(requestJson); val request = input.getJSONObject("request")
            calls++
            if (request.getString("id") == delayedId) { entered!!.countDown(); check(release!!.await(10, TimeUnit.SECONDS)) }
            val content = payload(request)
            val addons = input.getJSONArray("addons")
            return JSONObject().put("kind", "resource_result").put("requestId", input.getString("requestId")).put("generation", input.getLong("generation"))
                .put("request", request).put("cancelled", false).put("groups", JSONArray((0 until addons.length()).map {
                    JSONObject().put("addonId", addons.getJSONObject(it).getString("id")).put("status", "ready").put("content", content)
                })).toString()
        }
    }
    private fun open(store: Store, transport: Transport, runtime: VortxRuntimeBindings = bindings()): VortxNativeSession {
        val path = System.getenv("VORTX_JNI_LIBRARY")
        assumeTrue("Reviewed JNI fixture required", System.getenv("VORTX_JNI_SYNC") == "1" && !path.isNullOrBlank())
        System.load(requireNotNull(path))
        return VortxNativeSession.open(scope, "Owner", runtime, store, transport, true)
    }
    private fun install(session: VortxNativeSession, url: String = "https://old.invalid/manifest.json", protected: Boolean = false) {
        session.dispatch(listOf(JSONObject().put("type", "install_addon").put("profileId", "owner").put("addon", JSONObject().put("transportUrl", url)
            .put("manifest", manifest()).put("flags", JSONObject().put("official", false).put("protected", protected)))))
    }
    private fun watched(session: VortxNativeSession): Set<String> = session.resolve(JSONObject().put("kind", "profile_playback").put("profileId", "owner"))
        .getJSONObject("watchedVideoIdsByTitle").optJSONArray("series")?.let { values -> (0 until values.length()).map(values::getString).toSet() }.orEmpty()

    @Test fun `whole series and season use exact isolated inventory and one durable commit`() = runBlocking {
        val store = Store(); val transport = Transport()
        open(store, transport).use { session ->
            install(session); val repository = NativeCatalogRepository { session }
            transport.delayedId = "navigation"; transport.entered = CountDownLatch(1); transport.release = CountDownLatch(1)
            val navigation = async(Dispatchers.IO) { repository.meta(MediaType.SERIES, "navigation") }
            assertTrue(transport.entered!!.await(10, TimeUnit.SECONDS))
            try {
                val before = store.commits
                val capturedOwner = repository.continueWatchingOwner()
                repository.setCatalogWatched(MetaItem("series", MediaType.SERIES, "Card"), true, capturedOwner).getOrThrow()
                assertEquals(before + 1, store.commits)
                assertEquals(setOf("opaque-one", "opaque-two", "opaque-three"), watched(session))
                val detail = repository.setSeasonWatched(MediaType.SERIES, "series", 1, false).getOrThrow()
                assertEquals(setOf("opaque-three"), detail.watchedVideoIds)
                assertEquals(setOf("opaque-three"), watched(session))
                assertNull(repository.peekMeta(MediaType.SERIES, "series"))
            } finally { transport.release!!.countDown() }
            assertEquals("navigation", navigation.await().getOrThrow().id)
            assertEquals("navigation", repository.peekMeta(MediaType.SERIES, "navigation")!!.id)
        }
        open(store, transport).use { assertEquals(setOf("opaque-three"), watched(it)) }
    }

    @Test fun `foreign video malformed inventory and failed bulk commit never mutate playback`() = runBlocking {
        val store = Store(); val transport = Transport()
        open(store, transport).use { session ->
            install(session); val repository = NativeCatalogRepository { session }; val before = store.value
            assertTrue(repository.setVideoWatched(MediaType.SERIES, "series", "foreign", 1, 2, true).isFailure)
            assertTrue(repository.setVideoWatched(MediaType.SERIES, "series", "opaque-one", 3, 2, true).isFailure)
            assertEquals(before, store.value)
            transport.payload = { metadata("series").also { it.getJSONObject("meta").getJSONArray("videos").put(JSONObject().put("id", "opaque-one").put("season", 9).put("episode", 1)) } }
            assertTrue(repository.setWatched(MediaType.SERIES, "series", true).isFailure)
            assertEquals(before, store.value)
            transport.payload = { metadata("series") }; val owner = session.read().owner; store.fail = true
            assertTrue(repository.setWatched(MediaType.SERIES, "series", true).isFailure)
            assertEquals(before, store.value)
            assertTrue(session.requiresRecovery()); assertFalse(session.accepts(owner))
            assertTrue(runCatching { watched(session) }.isFailure)
            store.fail = false
            assertTrue(repository.setVideoWatched(MediaType.SERIES, "series", "opaque-two", 1, 8, true).isFailure)
            assertEquals(before, store.value)
        }
        // Restoring storage alone cannot revive uncertain ownership; recover from the same disk state.
        open(store, transport).use { session ->
            assertTrue(watched(session).isEmpty())
            val repository = NativeCatalogRepository { session }
            repository.setVideoWatched(MediaType.SERIES, "series", "opaque-two", 1, 8, true).getOrThrow()
            assertEquals(setOf("opaque-two"), watched(session))
        }
    }

    @Test fun `profile switch during inventory lookup cannot mark either profile`() = runBlocking {
        val store = Store(); val transport = Transport()
        open(store, transport).use { session ->
            install(session); session.dispatch(listOf(JSONObject("""{"type":"add_profile","id":"guest","name":"Guest"}""")))
            val repository = NativeCatalogRepository { session }
            transport.delayedId = "series"; transport.entered = CountDownLatch(1); transport.release = CountDownLatch(1)
            val pending = async(Dispatchers.IO) { repository.setWatched(MediaType.SERIES, "series", true) }
            assertTrue(transport.entered!!.await(10, TimeUnit.SECONDS))
            session.dispatch(listOf(JSONObject("""{"type":"switch_profile","id":"guest"}""")))
            val before = store.value; transport.release!!.countDown()
            assertTrue(pending.await().isFailure); assertEquals(before, store.value); assertTrue(watched(session).isEmpty())
        }
    }

    @Test fun `queued catalog event cannot adopt a profile owner after an ABA switch`() = runBlocking {
        val store = Store(); val transport = Transport()
        open(store, transport).use { session ->
            install(session); session.dispatch(listOf(JSONObject("""{"type":"add_profile","id":"guest","name":"Guest"}""")))
            val repository = NativeCatalogRepository { session }
            val captured = repository.continueWatchingOwner()
            session.dispatch(listOf(JSONObject("""{"type":"switch_profile","id":"guest"}""")))
            session.dispatch(listOf(JSONObject("""{"type":"switch_profile","id":"owner"}""")))
            val before = store.value; val calls = transport.calls
            assertTrue(repository.setCatalogWatched(MetaItem("series", MediaType.SERIES, "Card"), true, captured).isFailure)
            assertEquals(calls, transport.calls)
            assertEquals(before, store.value)
            assertTrue(watched(session).isEmpty())
        }
    }

    @Test fun `captured catalog event rejects profile retirement after metadata await`() = runBlocking {
        val store = Store(); val transport = Transport()
        open(store, transport).use { session ->
            install(session); session.dispatch(listOf(JSONObject("""{"type":"add_profile","id":"guest","name":"Guest"}""")))
            val repository = NativeCatalogRepository { session }
            val captured = repository.continueWatchingOwner()
            transport.delayedId = "series"; transport.entered = CountDownLatch(1); transport.release = CountDownLatch(1)
            val pending = async(Dispatchers.IO) { repository.setCatalogWatched(MetaItem("series", MediaType.SERIES, "Card"), true, captured) }
            assertTrue(transport.entered!!.await(10, TimeUnit.SECONDS))
            session.dispatch(listOf(JSONObject("""{"type":"switch_profile","id":"guest"}""")))
            val before = store.value
            transport.release!!.countDown()
            assertTrue(pending.await().isFailure)
            assertEquals(before, store.value)
            assertTrue(watched(session).isEmpty())
        }
    }

    @Test fun `action acknowledgments without a matching watched projection cannot commit`() = runBlocking {
        val store = Store(); val transport = Transport(); val native = bindings()
        var hideReceipt = false
        val intercepted = object : VortxRuntimeBindings by native {
            override fun resolve(handle: Long, request: String): String? {
                val value = native.resolve(handle, request)
                return if (hideReceipt && JSONObject(request).getString("kind") == "profile_playback") JSONObject(requireNotNull(value))
                    .put("watchedVideoIdsByTitle", JSONObject()).toString() else value
            }
        }
        open(store, transport, intercepted).use { session ->
            install(session); val before = store.value; val commits = store.commits
            hideReceipt = true
            assertTrue(NativeCatalogRepository { session }.setWatched(MediaType.SERIES, "series", true).isFailure)
            assertEquals(before, store.value); assertEquals(commits, store.commits)
            hideReceipt = false; assertTrue(watched(session).isEmpty())
        }
    }

    @Test fun `validated addon replacement keeps order disabled intent and unchanged peers atomically`() = runBlocking {
        val store = Store(); val transport = Transport()
        open(store, transport).use { session ->
            install(session, "https://first.invalid/manifest.json"); install(session); install(session, "https://last.invalid/manifest.json")
            val repository = NativeCatalogRepository { session }
            repository.applyAddonOrder(listOf("https://first.invalid/manifest.json", "https://old.invalid/manifest.json", "https://last.invalid/manifest.json")).getOrThrow()
            repository.setAddonDisabled("https://old.invalid/manifest.json", true).getOrThrow()
            val old = repository.installedAddons().getOrThrow().single { it.transportUrl.contains("old.invalid") }
            val before = store.commits
            repository.changeAddonUrl(old, "https://new.invalid/Config%2Fsecret").getOrThrow()
            assertEquals(before + 1, store.commits)
            val installed = repository.installedAddons().getOrThrow()
            assertEquals(listOf("https://first.invalid/manifest.json", "https://new.invalid/Config%2Fsecret/manifest.json", "https://last.invalid/manifest.json"), installed.map { it.transportUrl })
            assertTrue(installed[1].isDisabled); assertEquals("Replacement", installed[1].name)
            assertFalse(installed[1].isOfficial); assertFalse(installed[1].isProtected)
            repository.changeAddonUrl(installed[1], installed[1].transportUrl).getOrThrow()
            assertEquals(installed.map { it.transportUrl }, repository.installedAddons().getOrThrow().map { it.transportUrl })
            assertEquals(installed.map { it.isDisabled }, repository.installedAddons().getOrThrow().map { it.isDisabled })
        }
        open(store, transport).use { session -> assertTrue(NativeCatalogRepository { session }.installedAddons().getOrThrow()[1].isDisabled) }
    }

    @Test fun `invalid failed protected and stale addon replacements preserve original state`() = runBlocking {
        val store = Store(); val transport = Transport()
        open(store, transport).use { session ->
            install(session); val repository = NativeCatalogRepository { session }
            val old = repository.installedAddons().getOrThrow().single(); val before = store.value
            transport.payload = { JSONObject().put("name", "Invalid") }
            assertTrue(repository.changeAddonUrl(old, "https://new.invalid").isFailure); assertEquals(before, store.value)
            transport.payload = { manifest("Replacement") }; val owner = session.read().owner; store.fail = true
            assertTrue(repository.changeAddonUrl(old, "https://new.invalid").isFailure); assertEquals(before, store.value)
            assertTrue(session.requiresRecovery()); assertFalse(session.accepts(owner))
            store.fail = false
            assertTrue(runCatching { install(session, "https://protected.invalid/manifest.json", true) }.isFailure)
            assertEquals(before, store.value)
        }
        open(store, transport).use { session ->
            val repository = NativeCatalogRepository { session }
            val old = repository.installedAddons().getOrThrow().single()
            assertEquals("https://old.invalid/manifest.json", old.transportUrl)
            install(session, "https://protected.invalid/manifest.json", true)
            val protected = repository.installedAddons().getOrThrow().single { it.isProtected }; val protectedState = store.value; val calls = transport.calls
            assertTrue(repository.changeAddonUrl(protected, "https://new.invalid").isFailure)
            assertEquals(calls, transport.calls); assertEquals(protectedState, store.value)
            transport.delayedId = ""; transport.entered = CountDownLatch(1); transport.release = CountDownLatch(1)
            val pending = async(Dispatchers.IO) { repository.changeAddonUrl(old, "https://new.invalid") }
            assertTrue(transport.entered!!.await(10, TimeUnit.SECONDS))
            repository.removeAddon(old).getOrThrow(); val removedState = store.value
            transport.release!!.countDown()
            assertTrue(pending.await().isFailure); assertEquals(removedState, store.value)
            assertTrue(repository.installedAddons().getOrThrow().none { it.transportUrl.contains("new.invalid") })
        }
    }
}
