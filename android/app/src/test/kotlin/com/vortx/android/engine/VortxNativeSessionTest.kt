package com.vortx.android.engine

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PlaybackContext
import com.vortx.android.model.Playable
import com.vortx.android.model.Episode
import com.vortx.android.stats.WatchStatsModel
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.crypto.KeyGenerator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class VortxNativeSessionTest {
    private val scope = VortxAccountScope("account-A", "owner")
    private class Store : VortxCheckpointStore {
        var value: String? = null
        var failRead = false
        var failWrite = false
        var mismatch = false
        override fun read(scope: VortxAccountScope): String? { check(!failRead); return if (mismatch) "{}" else value }
        override fun commit(scope: VortxAccountScope, snapshot: String) { check(!failWrite); value = snapshot }
    }
    private class Runtime : VortxRuntimeBindings {
        val values = mutableMapOf<Long, String>()
        var created = 0
        var next = 0L
        var dispatched = 0
        fun profile(id: String, owner: Boolean) = JSONObject().put("id", id).put("name", id).put("owner", owner).put("deleted", false)
            .put("addons", "share_primary").put("parental", JSONObject().put("kids", false)).put("settings", JSONObject().put("disabledAddons", JSONArray()))
        fun library() = JSONObject().put("items", JSONArray()).put("history", JSONArray()).put("resume", JSONObject()).put("watched", JSONObject()).put("cwBoard", JSONArray())
        override fun create(ownerId: String, ownerName: String): Long {
            created++
            return hydrate(JSONObject().put("roster", JSONObject().put("profiles", JSONObject().put(ownerId, profile(ownerId, true)).put("guest", profile("guest", false))))
                .put("activeProfileId", ownerId).put("libraries", JSONObject().put(ownerId, library()).put("guest", library())).toString())
        }
        override fun hydrate(snapshot: String): Long = (++next).also { values[it] = JSONObject(snapshot).toString() }
        override fun state(handle: Long) = values[handle]
        override fun delta(handle: Long): String? = error("Session must checkpoint full state, not drain deltas")
        override fun resolve(handle: Long, request: String): String {
            val query = JSONObject(request)
            if (query.getString("kind") == "resume_point") {
                val state = JSONObject(values[handle]!!)
                return JSONObject().put("kind", "resume_point").put("resume", if (query.getString("id") == state.optString("fixtureVideoId"))
                    JSONObject().put("offsetMs", state.getLong("fixtureProgress")) else JSONObject.NULL).toString()
            }
            if (query.getString("kind") == "profile_playback") return JSONObject().put("kind", "profile_playback")
                .put("profileId", query.getString("profileId")).put("continueWatching", JSONArray()).put("history", JSONArray())
                .put("watchedVideoIdsByTitle", JSONObject()).put("watchedTitles", JSONObject()).toString()
            if (query.getString("kind") != "installed_addons") return "{\"kind\":\"error\"}"
            val id = query.getString("profileId")
            val records = JSONObject(values[handle]!!).getJSONObject("nativeSync").getJSONObject("addons").optJSONObject(id)?.optJSONObject("records") ?: JSONObject()
            return JSONObject().put("kind", "installed_addons").put("profileId", id).put("addons", JSONArray(records.keys().asSequence()
                .map { records.getJSONObject(it) }.filter { it.optJSONObject("value") != null && it.getLong("addedAt") > it.getLong("removedAt") }.map { it.getJSONObject("value") }.toList())).toString()
        }
        override fun free(handle: Long) { check(values.remove(handle) != null) }
        override fun dispatch(handle: Long, action: String): String {
            dispatched++
            val state = JSONObject(requireNotNull(values[handle])); val input = JSONObject(action)
            when (input.getString("type")) {
                "bind_sync_scope" -> state.put("nativeSync", JSONObject().put("schemaVersion", 1).put("scope", input.getString("scope")).put("ownerProfileId", "owner")
                    .put("profiles", JSONObject()).put("addons", JSONObject()).put("libraries", JSONObject()).put("watches", JSONObject()))
                "switch_profile" -> state.put("activeProfileId", input.getString("id"))
                "add_library_item" -> state.getJSONObject("libraries").getJSONObject(input.getString("profileId")).getJSONArray("items").put(input.getJSONObject("item"))
                "get_state", "merge_native_sync" -> Unit
                "report_progress" -> state.put("fixtureProgress", input.getLong("positionMs")).put("fixtureVideoId", input.getString("videoId"))
                "reorder_addons" -> state.put("fixtureReorder", input)
                else -> return "{\"ok\":false}"
            }
            values[handle] = state.toString()
            return "{\"ok\":true}"
        }
    }
    private class Transport : VortxResourceTransport {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val fixture = JSONObject(File("../../test/fixtures/native-resource-contract.json").readText())
        var emptyStreams = false
        var failedStreams = false
        var failedCatalog = ""
        val catalogSkips = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun makeCancellation() = object : VortxResourceCancellation { override fun cancel() {}; override fun close() {} }
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
            val input = JSONObject(requestJson); val request = input.getJSONObject("request")
            if (request.getString("id") == "slow" || request.getJSONArray("extra").toString().contains("slow")) { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
            val skip = request.getJSONArray("extra").let { extras -> (0 until extras.length()).map { extras.getJSONArray(it) }.find { it.getString(0) == "skip" }?.getString(1) }
            if (skip != null) catalogSkips += skip
            val content = if (skip != null && request.getString("resource") == "catalog") JSONObject().put("metas", JSONArray()) else fixture.getJSONObject(request.getString("resource"))
            val addons = input.getJSONArray("addons")
            return JSONObject().put("kind", "resource_result").put("requestId", input.getString("requestId")).put("generation", input.getLong("generation"))
                .put("request", request).put("cancelled", false).put("groups", JSONArray((0 until if (emptyStreams && request.getString("resource") == "stream") 0 else addons.length()).map {
                    JSONObject().put("addonId", addons.getJSONObject(it).getString("id")).put("status", if (failedStreams && request.getString("resource") == "stream" || failedCatalog == request.getString("id")) "error" else "ready").put("content", content)
                })).toString()
        }
    }
    private fun open(runtime: Runtime = Runtime(), store: Store = Store(), transport: Transport = Transport()) =
        VortxNativeSession.open(scope, "Owner", runtime, store, transport, true)
    private fun request(id: String) = VortxResourceRequest(VortxResourceRequest.Resource.CATALOG, "series", id) to listOf(VortxResourceAddon("a", "https://fixture.invalid/manifest.json", "{}"))

    @Test fun `failed durable writes dispatches and readback never publish candidate`() {
        val runtime = Runtime(); val store = Store()
        open(runtime, store).use { session ->
            val original = session.read().state.toString(); val owner = session.read().owner
            store.failWrite = true
            assertTrue(runCatching { session.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest"))) }.isFailure)
            assertEquals(original, session.read().state.toString()); assertEquals(owner, session.read().owner); assertEquals(1, runtime.values.size)
            store.failWrite = false
            assertTrue(runCatching { session.dispatch(listOf(JSONObject().put("type", "unsupported"))) }.isFailure)
            assertEquals(original, session.read().state.toString())
            store.mismatch = true
            assertTrue(runCatching { session.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest"))) }.isFailure)
            assertEquals(owner, session.read().owner); assertEquals(1, runtime.values.size)
        }
        assertTrue(runtime.values.isEmpty())
    }
    @Test fun `unavailable malformed and cross-owner snapshots never create empty account`() {
        val runtime = Runtime(); val store = Store().also { it.failRead = true }
        assertTrue(runCatching { open(runtime, store) }.isFailure); assertEquals(0, runtime.created)
        store.failRead = false; store.value = "{}"
        assertTrue(runCatching { open(runtime, store) }.isFailure); assertEquals(0, runtime.created)
        val good = Store(); open(store = good).close()
        store.value = JSONObject(good.value!!).put("hostProfilePreferences", "invalid").toString()
        assertTrue(runCatching { open(runtime, store) }.isFailure); assertEquals(0, runtime.created)
        val foreign = JSONObject(good.value!!).put("nativeSync", JSONObject(good.value!!).getJSONObject("nativeSync").put("scope", "account-B"))
        store.value = foreign.toString()
        assertTrue(runCatching { open(runtime, store) }.isFailure); assertEquals(0, runtime.created)
        assertTrue(runCatching { VortxNativeSession.open(scope, "Owner", runtime, Store(), Transport()) }.isFailure)
    }
    @Test fun `AES GCM checkpoint survives cold read and rejects tamper wrong key wrong account`() {
        val directory = Files.createTempDirectory(File("build").toPath(), "native-session-test-").toFile()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val store = VortxEncryptedCheckpointStore(directory) { key }
        val runtime = Runtime()
        try {
            val before = VortxNativeSession.open(scope, "Owner", runtime, store, Transport(), true).use { it.read().state.toString() }
            assertEquals(before, store.read(scope))
            val target = directory.listFiles()!!.single()
            assertFalse(target.readBytes().toString(Charsets.UTF_8).contains("account-A"))
            VortxNativeSession.open(scope, "Owner", runtime, store, Transport()).use { assertEquals(before, it.read().state.toString()) }
            val wrong = VortxEncryptedCheckpointStore(directory) { KeyGenerator.getInstance("AES").apply { init(256) }.generateKey() }
            assertTrue(runCatching { wrong.read(scope) }.isFailure)
            val other = VortxAccountScope("account-B", "owner")
            target.copyTo(File(directory, "native-state-v1-${other.digest}.sealed"))
            assertTrue(runCatching { store.read(other) }.isFailure)
            val bytes = target.readBytes(); bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte(); target.writeBytes(bytes)
            assertTrue(runCatching { VortxNativeSession.open(scope, "Owner", runtime, store, Transport(), true) }.isFailure)
        } finally { directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }
    @Test fun `independent consumers load concurrently while a profile switch fences late results`() = runBlocking {
        val transport = Transport()
        open(transport = transport).use { session ->
            val owner = session.read().owner
            val old = async(Dispatchers.Default) { runCatching { session.load("board", owner, listOf(request("slow"))) } }
            assertTrue(transport.entered.await(5, TimeUnit.SECONDS))
            assertEquals(1, session.load("discover", owner, listOf(request("popular"))).size)
            session.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")), owner)
            transport.release.countDown()
            assertTrue(old.await().isFailure); assertFalse(session.accepts(owner))
            assertTrue(runCatching { session.dispatch(listOf(JSONObject().put("type", "get_state")), owner) }.isFailure)
        }
    }
    @Test fun `authenticated account revocation fences reads even without repository reacquisition`() {
        var current = true
        VortxNativeSession.open(scope, "Owner", Runtime(), Store(), Transport(), true) { current }.use { session ->
            val owner = session.read().owner; current = false
            assertFalse(session.accepts(owner)); assertTrue(runCatching { session.read() }.isFailure)
        }
    }
    @Test fun `reopening the same account rejects old playback tokens and series card mutations`() = runBlocking {
        val runtime = Runtime(); val store = Store(); var session = open(runtime, store)
        val repo = NativeCatalogRepository { session }
        val oldOwner = repo.continueWatchingOwner()
        val context = PlaybackContext(PlaybackContext.Owner("owner", true), "movie", "movie", "movie", null, null,
            "Fixture", null, PlaybackContext.Provenance(null, null, false, null, null))
        val token = repo.beginPlaybackSession(context, oldOwner).getOrThrow()
        repo.reportProgress(token, 1000, 10000).getOrThrow()
        session.close(); session = open(runtime, store)
        try {
            assertNotEquals(oldOwner, repo.continueWatchingOwner())
            assertTrue(repo.beginPlaybackSession(context.copy(nativeSessionRevision = oldOwner.revision), repo.continueWatchingOwner()).isFailure)
            val before = session.read().state.toString(); val dispatches = runtime.dispatched
            assertTrue(repo.reportProgress(token, 2000, 10000).isFailure)
            assertTrue(repo.setCatalogWatched(MetaItem("series", MediaType.SERIES, "Series"), true).isFailure)
            assertTrue(repo.setWatched(MediaType.SERIES, "series", true).isFailure)
            assertEquals(before, session.read().state.toString()); assertEquals(dispatches, runtime.dispatched)
        } finally { session.close() }
    }
    @Test fun `completed parsing cannot publish across same screen replacement or empty clear`() = runBlocking {
        open().use { session ->
            val owner = session.read().owner
            val old = session.load("search", owner, listOf(request("popular")))
            assertEquals("old", session.publish("search", owner, old) { "old" })
            val cleared = session.load("search", owner, emptyList())
            assertEquals("empty", session.publish("search", owner, cleared) { "empty" })
            assertTrue(runCatching { session.publish("search", owner, old) { "stale" } }.isFailure)
        }
    }
    @Test fun `configured addon URLs retain percent encoded path identity`() {
        val repo = NativeCatalogRepository { error("No session required") }
        assertEquals("https://addon.example/config%2Fsecret%3Fvalue/manifest.json", repo.normalizedAddonUrl("https://ADDON.example/config%2Fsecret%3Fvalue/"))
        assertNull(repo.normalizedAddonUrl("https://addon.example/manifest.json?token=never-forward"))
    }
    @Test fun `repository reads native resource fixtures and durable library without legacy engine`() = runBlocking {
        val runtime = Runtime(); val store = Store(); open(runtime, store).close()
        val state = JSONObject(store.value!!)
        val addon = JSONObject().put("transportUrl", "https://fixture.invalid/manifest.json").put("flags", JSONObject()).put("manifest", JSONObject()
            .put("id", "fixture").put("name", "Fixture").put("catalogs", JSONArray().put(JSONObject().put("type", "series").put("id", "popular")
                .put("extra", JSONArray().put(JSONObject().put("name", "search")).put(JSONObject().put("name", "skip"))))).put("resources", JSONArray(listOf("catalog", "meta", "stream", "subtitles"))))
        addon.getJSONObject("manifest").getJSONArray("catalogs").put(JSONObject().put("type", "series").put("id", "broken")
            .put("extra", JSONArray().put(JSONObject().put("name", "search"))))
        state.getJSONObject("nativeSync").getJSONObject("addons").put("owner", JSONObject().put("records", JSONObject().put(addon.getString("transportUrl"), JSONObject()
            .put("addedAt", 1).put("removedAt", 0).put("valueAt", 1).put("value", addon))).put("order", JSONObject().put("ids", JSONArray())))
        // Hydration does not alter an existing sync carrier in this focused fake.
        val bindings = object : VortxRuntimeBindings by runtime {
            override fun dispatch(handle: Long, action: String): String = if (JSONObject(action).getString("type") == "bind_sync_scope") "{\"ok\":true}" else runtime.dispatch(handle, action)
        }
        store.value = state.toString()
        val transport = Transport().also { it.failedCatalog = "broken" }
        VortxNativeSession.open(scope, "Owner", bindings, store, transport).use { session ->
            val repo = NativeCatalogRepository { session }
            val stats = WatchStatsModel(File("build/never-read-legacy"), repo, nativeEnabled = true)
            stats.load(); assertNull(stats.state.value.error)
            assertEquals("Fixture Series", repo.home().getOrThrow().last().items.single().name)
            val homeRow = repo.home().getOrThrow().last()
            assertTrue(homeRow.hasNextPage)
            repo.loadHomeRowNextPage(homeRow).getOrThrow()
            repo.loadHomeRowNextPage(homeRow).getOrThrow()
            assertEquals(listOf("1"), transport.catalogSkips.toList())
            assertEquals(1, repo.discover().getOrThrow().items.size)
            val next = repo.discoverNextPage().getOrThrow()
            assertEquals(1, next.items.size); assertFalse(next.filters.hasNextPage)
            assertEquals(1, repo.search("fixture").getOrThrow().size)
            assertEquals("Fixture Series", repo.meta(MediaType.SERIES, "tt-fixture").getOrThrow().name)
            assertTrue(repo.streams(MediaType.SERIES, "tt-fixture", "tt-fixture:1:2").getOrThrow().isNotEmpty())
            transport.emptyStreams = true
            assertTrue(repo.streams(MediaType.SERIES, "tt-fixture", "tt-fixture:1:2").getOrThrow().any { it.streams.isNotEmpty() })
            transport.emptyStreams = false; transport.failedStreams = true
            assertTrue(repo.streams(MediaType.SERIES, "tt-fixture", "tt-fixture:1:2").getOrThrow().any { it.streams.isNotEmpty() })
            assertEquals(1, JSONArray(repo.subtitles(MediaType.SERIES, "tt-fixture:1:2").getOrThrow()).length())
            repo.addToLibrary(MetaItem("saved", MediaType.MOVIE, "Saved title")).getOrThrow()
            assertEquals("Saved title", repo.library().getOrThrow().items.single().name)
            assertTrue(repo.signIn("unused", "never-forwarded").isFailure)
            val direct = repo.resolveDirectLink("https://fixture.invalid/movie", "Fixture").getOrThrow()
            assertEquals("https://fixture.invalid/movie", direct.url); assertNull(direct.playbackContext)
            assertTrue(repo.resolveDirectLink("file:///private/file", "Invalid").isFailure)
            val selected = repo.streams(MediaType.SERIES, "tt-fixture", "tt-fixture:1:2").getOrThrow()
                .flatMap { it.streams }.first { it.url != null }
            val playable = repo.resolve(selected, Episode("tt-fixture:1:2", "Episode", 1, 2)).getOrThrow()
            assertEquals("tt-fixture:1:2", playable.playbackContext!!.videoId)
            assertEquals("tt-fixture", playable.playbackContext!!.contentId)
            assertTrue(repo.resolve(selected, Episode("other", "Wrong", 1, 3)).isFailure)
            val token = repo.beginPlaybackSession(playable.playbackContext, repo.continueWatchingOwner()).getOrThrow()
            repo.reportProgress(token, 4321, 12345).getOrThrow()
            assertEquals(4321, session.read().state.getInt("fixtureProgress"))
            assertEquals(4321L, repo.resolve(selected).getOrThrow().startPositionMs)
            val beforeSync = session.read()
            session.dispatch(listOf(JSONObject().put("type", "merge_native_sync").put("document", beforeSync.state.getJSONObject("nativeSync"))),
                beforeSync.owner, beforeSync.state.getJSONObject("hostProfilePreferences"), notifyMutation = false)
            assertEquals(beforeSync.owner, session.read().owner)
            repo.reportProgress(token, 5000, 12345).getOrThrow()
            assertEquals(5000L, repo.resolve(selected).getOrThrow().startPositionMs)
            val resolveEntered = CountDownLatch(1); val resolveRelease = CountDownLatch(1); var disposed = false
            val slowResolver = NativeCatalogRepository(NativePlaybackResolver { source, _ ->
                resolveEntered.countDown(); check(resolveRelease.await(10, TimeUnit.SECONDS))
                Playable(source.url!!, "Slow", playbackLease = AutoCloseable { disposed = true })
            }) { session }
            val staleSource = slowResolver.streams(MediaType.SERIES, "tt-fixture", "tt-fixture:1:2").getOrThrow().flatMap { it.streams }.first { it.url != null }
            val resolving = async(Dispatchers.Default) { slowResolver.resolve(staleSource) }
            assertTrue(resolveEntered.await(5, TimeUnit.SECONDS))
            slowResolver.streams(MediaType.SERIES, "tt-fixture", "tt-fixture:1:2").getOrThrow()
            resolveRelease.countDown(); assertTrue(resolving.await().isFailure); assertTrue(disposed)
            val pending = async(Dispatchers.Default) { repo.search("slow") }
            assertTrue(transport.entered.await(5, TimeUnit.SECONDS))
            assertTrue(repo.searchUpdates("").toList().single().first.isEmpty())
            transport.release.countDown(); assertTrue(pending.await().isFailure)
            session.close(); stats.load()
            assertNotNull(stats.state.value.error); assertNull(stats.state.value.stats)
        }
    }

    @Test fun `late player resolution releases its lease after a profile transition`() = runBlocking {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); var closed = false
        open().use { session ->
            val repository = NativeCatalogRepository(NativePlaybackResolver { source, _ ->
                entered.countDown(); check(release.await(10, TimeUnit.SECONDS))
                Playable(source.url!!, source.title, playbackLease = AutoCloseable { closed = true })
            }) { session }
            val pending = async(Dispatchers.Default) { repository.resolveDirectLink("https://fixture.invalid/slow", "Fixture") }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            session.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")))
            release.countDown(); assertTrue(pending.await().isFailure); assertTrue(closed)
            assertEquals(com.vortx.android.data.PlaybackSessionToken.NOOP, repository.beginPlaybackSession(null, repository.continueWatchingOwner()).getOrThrow())
        }
    }

    @Test fun `adjacent full profile preferences commit and reopen with state or remain unchanged`() {
        val runtime = Runtime(); val store = Store()
        val preferences = JSONObject().put("owner", JSONObject().put("avatar", "fixture").put("playback", JSONObject().put("audioLang", "fr")))
        open(runtime, store).use { session ->
            session.dispatch(emptyList(), hostProfiles = preferences)
            assertEquals(preferences.toString(), session.read().state.getJSONObject("hostProfilePreferences").toString())
            store.failWrite = true
            assertTrue(runCatching { session.dispatch(emptyList(), hostProfiles = JSONObject()) }.isFailure)
            assertEquals(preferences.toString(), session.read().state.getJSONObject("hostProfilePreferences").toString())
        }
        store.failWrite = false
        open(runtime, store).use { assertEquals(preferences.toString(), it.read().state.getJSONObject("hostProfilePreferences").toString()) }
        val newer = JSONObject().put("modifiedSeconds", 20).put("owner", JSONObject().put("avatar", "newer"))
        VortxNativeSession.open(scope, "Owner", runtime, store, Transport(), initialHostProfiles = newer).use {
            assertEquals("newer", it.read().state.getJSONObject("hostProfilePreferences").getJSONObject("owner").getString("avatar"))
        }
        VortxNativeSession.open(scope, "Owner", runtime, store, Transport(), initialHostProfiles = JSONObject().put("modifiedSeconds", 10)).use {
            assertEquals("newer", it.read().state.getJSONObject("hostProfilePreferences").getJSONObject("owner").getString("avatar"))
        }
    }

    @Test fun `native stats projects only supplied native profile history and resume`() {
        val library = JSONObject("""{"items":[{"kind":"standard","id":"tt1","type":"series","name":"Fixture"}],"history":[{"id":"tt1","videoId":"tt1:1:1","watchedAt":100}],"resume":{"tt1:1:2":{"offsetSecs":15,"durationSecs":100,"updatedAt":200}},"watchContexts":{"tt1:1:1":{"metaId":"tt1","videoId":"tt1:1:1","name":"Fixture","durationMs":100000,"updatedAt":100},"tt1:1:2":{"metaId":"tt1","videoId":"tt1:1:2","name":"Fixture","durationMs":100000,"updatedAt":200}}}""")
        val records = NativeWatchStatsProjection.records(library)
        assertEquals(1, records.size); assertEquals(115.0, records.single().watchSeconds, 0.0)
        assertEquals(1, records.single().plays); assertEquals(200L, records.single().lastWatched!!.epochSecond)
        assertTrue(NativeWatchStatsProjection.records(Runtime().library()).isEmpty())
    }

    @Test fun `unknown host profile fields survive known edits and known optional removal`() {
        val raw = JSONObject().put("id", com.vortx.android.profile.UserProfile.OWNER_ID).put("name", "Owner").put("avatar", "star")
            .put("isOwner", true).put("pin", "sha256:" + "a".repeat(64)).put("futureAvatar", "preserved")
            .put("playback", JSONObject().put("audioLang", "en").put("futureMixer", JSONObject().put("mode", "preserved")))
        val original = com.vortx.android.profile.UserProfile.decodeProfile(raw)
        val changed = original.copy(pin = null, playback = original.playback!!.copy(audioLang = "fr"))
        val merged = NativeHostProfiles.updated(raw, changed)
        assertFalse(merged.has("pin")); assertEquals("preserved", merged.getString("futureAvatar"))
        assertEquals("preserved", merged.getJSONObject("playback").getJSONObject("futureMixer").getString("mode"))
        assertEquals("fr", merged.getJSONObject("playback").getString("audioLang"))
        val wire = com.vortx.android.backup.SettingsBackup.settingsBlobFor(null, listOf(changed), 20.0, "fixture",
            rawRosterJson = JSONArray().put(merged).toString())
        assertNotNull(wire)
        assertEquals("preserved", com.vortx.android.backup.SettingsBackup.rawRosterFromBlob(wire)!!.getJSONObject(0).getString("futureAvatar"))
    }

    @Test fun `explicit native addon reenable overrides legacy disabled values and child inherits live owner`() {
        open().use { session ->
            val read = session.read()
            val url = "https://addon.example/CaseSensitive/manifest.json"
            read.state.getJSONObject("roster").getJSONObject("profiles").getJSONObject("owner").getJSONObject("settings").put("disabledAddons", JSONArray().put(url))
            val host = read.state.getJSONObject("hostProfilePreferences")
            host.put("guest", JSONObject().put("addonPreferences", JSONObject()))
            val guest = read.copy(owner = read.owner.copy(profileID = "guest"))
            assertEquals(setOf(url), NativeAddonPreferences.disabled(guest))
            host.getJSONObject("guest").getJSONObject("addonPreferences").put("disabledAddonURLsOverride", JSONArray())
            assertTrue(NativeAddonPreferences.disabled(guest).isEmpty())
            host.getJSONObject("guest").getJSONObject("addonPreferences").remove("disabledAddonURLsOverride")
            host.put("owner", JSONObject().put("addonPreferences", JSONObject().put("disabledAddonURLsOverride", JSONArray())))
            assertTrue(NativeAddonPreferences.disabled(guest).isEmpty())
        }
    }

    @Test fun `lifecycle flows survive retired runtime update and recover the next mount`() = runBlocking {
        var current: VortxNativeSession? = open()
        val changes = MutableStateFlow(0)
        val entered = CountDownLatch(2)
        val repository = NativeCatalogRepository(sessionChanges = changes.map { Unit }) { checkNotNull(current) }
        val values = async(Dispatchers.Default) { withTimeout(10000) {
            repository.homeUpdates().filter { it.profileId == "owner" }.onEach { entered.countDown() }.take(2).toList()
        } }
        val contexts = async(Dispatchers.Default) { withTimeout(10000) {
            repository.ctxUpdates().onEach { entered.countDown() }.take(2).toList()
        } }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        current!!.close(); current = null; changes.value++
        current = open(); changes.value++
        try { assertEquals(2, values.await().size); assertEquals(2, contexts.await().size) } finally { current!!.close() }
    }

    @Test fun `addon reorder updates owner override and shared child order never mutates account`() = runBlocking {
        open().use { session ->
            val first = "https://addon.example/First/manifest.json"
            val second = "https://addon.example/Second/manifest.json"
            val read = session.read()
            val host = read.state.getJSONObject("hostProfilePreferences")
            host.put("owner", JSONObject().put("addonPreferences", JSONObject().put("rankingOverride", JSONObject()
                .put("addonOrder", JSONArray().put(first).put(second)).put("sourceTypeOrder", JSONArray().put("direct")).put("useAddonOrder", true))))
            host.put("guest", JSONObject().put("addonPreferences", JSONObject()))
            session.dispatch(emptyList(), read.owner, host)
            val repository = NativeCatalogRepository { session }
            repository.applyAddonOrder(listOf(second, first)).getOrThrow()
            assertEquals(listOf(second, first), NativeAddonPreferences.order(session.read()))
            assertEquals("owner", session.read().state.getJSONObject("fixtureReorder").getString("profileId"))
            repository.switchProfile("guest").getOrThrow()
            val previous = session.read().owner
            repository.applyAddonOrder(listOf(first, second)).getOrThrow()
            val changed = session.read()
            assertNotEquals(previous, changed.owner)
            assertEquals(listOf(first, second), NativeAddonPreferences.order(changed))
            assertEquals(second, changed.state.getJSONObject("fixtureReorder").getJSONArray("transportUrls").getString(0))
            val ranking = changed.state.getJSONObject("hostProfilePreferences").getJSONObject("guest").getJSONObject("addonPreferences").getJSONObject("rankingOverride")
            assertTrue(ranking.getBoolean("useAddonOrder")); assertEquals("direct", ranking.getJSONArray("sourceTypeOrder").getString(0))
            ranking.remove("addonOrder")
            assertNull(NativeAddonPreferences.order(changed))
        }
    }

    @Test fun `native player uses exact current resume including reset and explicit user overrides`() {
        fun start(resolved: Long, explicit: Long? = null, fromStart: Boolean = false, native: Boolean = true) =
            com.vortx.android.ui.viewmodel.selectedPlaybackStartPosition(native, resolved, 10000, explicit, fromStart)
        assertEquals(20000L, start(20000)); assertEquals(0L, start(0))
        assertEquals(0L, start(20000, explicit = 0)); assertEquals(3000L, start(20000, explicit = 3000))
        assertEquals(0L, start(20000, fromStart = true)); assertEquals(10000L, start(20000, native = false))
    }

    @Test fun `credential guard preserves configured URL identity keys but rejects secret fields`() {
        scope.rejectCredentials(JSONObject().put("https://addon.example/ConfiguredSecret", JSONObject().put("key", "movie:tt1")))
        assertTrue(runCatching { scope.rejectCredentials(JSONObject().put("access_token", "secret")) }.isFailure)
        assertTrue(runCatching { scope.rejectCredentials(JSONObject().put("apiKeys", JSONObject())) }.isFailure)
        assertTrue(runCatching { scope.rejectCredentials(JSONObject().put("data_key", "secret")) }.isFailure)
    }
}
