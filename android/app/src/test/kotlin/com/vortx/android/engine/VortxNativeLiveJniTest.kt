package com.vortx.android.engine

import java.io.File
import java.nio.file.Files
import javax.crypto.KeyGenerator
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.CoroutineStart
import com.vortx.android.model.MediaType
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.SessionOwnerSnapshot
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Explicit local host artifact only. Never launches an app, player, provider or network request. */
class VortxNativeLiveJniTest {
    private fun noNetwork() = object : VortxResourceTransport {
        override fun makeCancellation(): VortxResourceCancellation = error("No resource request permitted")
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network permitted")
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
    private fun load() {
        val path = System.getenv("VORTX_JNI_LIBRARY")
        assumeTrue("Set VORTX_JNI_LIBRARY to the reviewed host JNI artifact", !path.isNullOrBlank())
        System.load(requireNotNull(path))
    }
    @Test fun `host JNI exports hydrate full state and expose versioned resource host`() {
        load()
        assertEquals(1, VortxCore.nativeResourceHostAbiVersion())
        val host = VortxCore.nativeResourceHostNew(); assertTrue(host != 0L)
        VortxCore.nativeResourceHostFree(host)
        val handle = VortxCore.nativeInitRuntime("{\"ownerId\":\"jni-owner\",\"ownerName\":\"Fixture\"}")
        assertTrue(handle != 0L)
        try {
            assertTrue(JSONObject(VortxCore.nativeDispatchJson(handle, "{\"type\":\"add_profile\",\"id\":\"viewer\",\"name\":\"Viewer\"}")!!).getBoolean("ok"))
            val state = requireNotNull(VortxCore.nativeGetStateJson(handle))
            val restored = VortxCore.nativeInitFromStateJson(state); assertTrue(restored != 0L)
            try { assertEquals(state, VortxCore.nativeGetStateJson(restored)) } finally { VortxCore.nativeEngineFree(restored) }
            assertEquals(0L, VortxCore.nativeInitFromStateJson("{}"))
        } finally { VortxCore.nativeEngineFree(handle) }
    }

    @Test fun `native sync JNI session persists library profile and progress across encrypted restart`() = runBlocking {
        assumeTrue("Requires the separately reviewed native-sync JNI artifact", System.getenv("VORTX_JNI_SYNC") == "1")
        load()
        // Raw bindings deliberately avoid Android logging/library-loader stubs in the JVM runner.
        val bindings = object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
            override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
            override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
        }
        val fixture = JSONObject(File("../../test/fixtures/native-resource-contract.json").readText())
        val noNetwork = object : VortxResourceTransport {
            override fun makeCancellation() = object : VortxResourceCancellation { override fun cancel() {}; override fun close() {} }
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
                val input = JSONObject(requestJson); val request = input.getJSONObject("request"); val addons = input.getJSONArray("addons")
                return JSONObject().put("kind", "resource_result").put("requestId", input.getString("requestId")).put("generation", input.getLong("generation"))
                    .put("request", request).put("cancelled", false).put("groups", JSONArray((0 until addons.length()).map {
                        JSONObject().put("addonId", addons.getJSONObject(it).getString("id")).put("status", "ready").put("content", fixture.getJSONObject(request.getString("resource")))
                    })).toString()
            }
        }
        val directory = Files.createTempDirectory(File("build").toPath(), "native-sync-jni-").toFile()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val store = VortxEncryptedCheckpointStore(directory) { key }
        val scope = VortxAccountScope("native-test-account", "native-owner")
        try {
            val captured = VortxNativeSession.open(scope, "Owner", bindings, store, noNetwork, true).use { session ->
                session.dispatch(listOf(JSONObject("""{"type":"add_profile","id":"guest","name":"Guest"}"""),
                    JSONObject("""{"type":"add_library_item","profileId":"native-owner","item":{"kind":"standard","id":"tt-local","type":"movie","name":"Local fixture"}}"""),
                    JSONObject("""{"type":"report_progress","metaId":"tt-local","videoId":"tt-local","name":"Local fixture","positionMs":15000,"durationMs":120000}""")))
                session.dispatch(listOf(JSONObject().put("type", "install_addon").put("profileId", "native-owner").put("addon",
                    JSONObject().put("transportUrl", "https://fixture.invalid/manifest.json").put("manifest", fixture.getJSONObject("manifest"))
                        .put("flags", JSONObject().put("official", false).put("protected", false)))))
                val repository = NativeCatalogRepository { session }
                assertEquals("Local fixture", repository.library().getOrThrow().items.single().name)
                assertEquals("Fixture Series", repository.home().getOrThrow().last().items.single().name)
                assertEquals("Fixture Series", repository.meta(MediaType.SERIES, "tt-fixture").getOrThrow().name)
                val season = repository.setSeasonWatched(MediaType.SERIES, "tt-fixture", 1, true).getOrThrow()
                assertEquals(season.videos.filter { it.season == 1 }.map { it.id }.toSet(), season.watchedVideoIds)
                assertTrue(repository.setSeasonWatched(MediaType.SERIES, "tt-fixture", 1, false).getOrThrow().watchedVideoIds.isEmpty())
                val beforeInvalidSeason = session.read().state.toString()
                assertTrue(repository.setSeasonWatched(MediaType.SERIES, "tt-fixture", 99, true).isFailure)
                assertEquals(beforeInvalidSeason, session.read().state.toString())
                val source = repository.streams(MediaType.SERIES, "tt-fixture", "tt-fixture:1:2").getOrThrow().flatMap { it.streams }.first { it.url != null }
                val playable = repository.resolve(source).getOrThrow()
                val playback = repository.beginPlaybackSession(playable.playbackContext, repository.continueWatchingOwner()).getOrThrow()
                repository.reportProgress(playback, 43210, 123450).getOrThrow()
                assertEquals(43210L, repository.resolve(source).getOrThrow().startPositionMs)
                val priorSync = session.read()
                session.dispatch(listOf(JSONObject().put("type", "merge_native_sync").put("document", priorSync.state.getJSONObject("nativeSync"))),
                    priorSync.owner, priorSync.state.getJSONObject("hostProfilePreferences"), notifyMutation = false)
                assertEquals(priorSync.owner, session.read().owner)
                repository.reportProgress(playback, 44000, 123450).getOrThrow()
                val remote = bindings.hydrate(session.read().state.toString())
                try {
                    assertTrue(JSONObject(bindings.dispatch(remote, """{"type":"patch_profile","id":"native-owner","edits":[{"field":"name","value":"Remote name"}]}""")!!).getBoolean("ok"))
                    session.dispatch(listOf(JSONObject().put("type", "merge_native_sync").put("document", JSONObject(bindings.state(remote)!!).getJSONObject("nativeSync"))))
                    assertNotEquals(priorSync.owner, session.read().owner)
                    assertTrue(repository.reportProgress(playback, 45000, 123450).isFailure)
                } finally { bindings.free(remote) }
                repository.setCatalogWatched(com.vortx.android.model.MetaItem("unsaved", MediaType.MOVIE, "Unsaved movie", "https://fixture.invalid/poster"), true).getOrThrow()
                val projection = session.resolve(JSONObject().put("kind", "profile_playback").put("profileId", "native-owner"))
                val history = projection.getJSONArray("history")
                val marked = (0 until history.length()).map(history::getJSONObject).single { it.getString("metaId") == "unsaved" }
                assertEquals("Unsaved movie", marked.getString("name")); assertEquals("movie", marked.getString("type"))
                assertEquals(1, JSONArray(repository.subtitles(MediaType.SERIES, "tt-fixture:1:2").getOrThrow()).length())
                val state = session.read().state
                assertEquals(1, state.getJSONObject("libraries").getJSONObject("native-owner").getJSONArray("items").length())
                assertEquals(15L, state.getJSONObject("libraries").getJSONObject("native-owner").getJSONObject("resume").getJSONObject("tt-local").getLong("offsetSecs"))
                val before = state.toString()
                val foreign = JSONObject(state.getJSONObject("nativeSync").toString()).put("scope", "foreign")
                assertTrue(runCatching { session.dispatch(listOf(JSONObject().put("type", "merge_native_sync").put("document", foreign))) }.isFailure)
                assertEquals(before, session.read().state.toString())
                before
            }
            VortxNativeSession.open(scope, "Owner", bindings, store, noNetwork).use { restored ->
                assertEquals(captured, restored.read().state.toString())
                restored.dispatch(listOf(JSONObject("""{"type":"switch_profile","id":"guest"}""")))
                assertEquals("guest", restored.read().owner.profileID)
                assertEquals(0, restored.read().state.getJSONObject("libraries").getJSONObject("guest").getJSONArray("items").length())
            }
        } finally { directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }

    @Test fun `authenticated legacy bootstrap native profile lifecycle and same-account reopen use real JNI`() = runBlocking {
        assumeTrue("Requires reviewed importer JNI", System.getenv("VORTX_JNI_SYNC") == "1")
        load()
        val noNetwork = object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No resource request permitted")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network permitted")
        }
        val directory = Files.createTempDirectory(File("build").toPath(), "native-bootstrap-jni-").toFile()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val checkpoints = VortxEncryptedCheckpointStore(directory) { key }
        val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 4)
        var current: SessionOwnerSnapshot.Account? = account
        var mutations = 0
        fun coordinator() = NativeAccountCoordinator(bindings(), checkpoints, { noNetwork }, { current == it }, { it() }, {}, { mutations++ })
        val owner = UserProfile(id = "00000000-0000-0000-0000-000000000111", name = "Historical owner", avatar = "star", isOwner = true)
        val doc = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode()
            .put("auth", "never-copy-secret-profile-auth").put("dataKey", "never-copy-secret-profile-key"))).put("rosterModified", 123.5)
            .put("library", JSONArray()).put("addons", JSONArray())).put("futurePreference", JSONObject().put("mode", "preserved"))
            .put("apiKeys", JSONObject().put("fixture", "never-copy-secret"))
        var runtime = coordinator()
        try {
            assertTrue(runtime.applyDocument(account, doc) { current == account })
            val first = runtime.session().read().owner
            assertEquals("account.00000000-0000-0000-0000-000000000123", first.scope.accountID)
            assertEquals(0, mutations)
            val retained = runtime.session().read().state.getJSONObject("legacyImportMaterial").toString()
            assertEquals(123.5, JSONObject(retained).getDouble("rosterModifiedSeconds"), 0.0)
            assertFalse(runtime.session().read().state.toString().contains("never-copy-secret"))
            assertFalse(runtime.session().read().state.getJSONObject("hostDocument").has("apiKeys"))
            assertFalse(runtime.session().read().state.getJSONObject("hostProfilePreferences").getJSONObject(owner.id).has("auth"))
            assertFalse(runtime.session().read().state.getJSONObject("hostProfilePreferences").getJSONObject(owner.id).has("dataKey"))
            assertTrue(runtime.session().read().state.getJSONArray("excludedCredentialPaths").toString().contains("/vortx/roster/0/dataKey"))
            assertEquals("preserved", runtime.session().read().state.getJSONObject("hostDocument").getJSONObject("futurePreference").getString("mode"))
            val profiles = NativeProfileAccess { runtime.session() }
            val changed = profiles.read().profiles.single().copy(name = "Native owner", avatar = "moon")
            profiles.save(changed, adding = false)
            val guest = UserProfile(id = "00000000-0000-0000-0000-000000000456", name = "Guest", avatar = "person")
            profiles.save(guest, adding = true); profiles.select(guest.id)
            assertEquals(guest.id, runtime.session().read().owner.profileID)
            profiles.remove(guest.id)
            assertEquals(owner.id, runtime.session().read().owner.profileID)
            assertTrue(mutations >= 4)
            val exported = runtime.exportDocument(account)!!
            assertEquals("moon", exported.roster.single().avatar)
            assertFalse(exported.nativeSync.has("activeProfileId"))
            assertFalse(exported.nativeSync.has("legacyImportMaterial"))
            runtime.retire(); runtime = coordinator()
            // No cloud document or global roster is supplied: the sealed account locator retains
            // this historical (non-A11C) identity and the exact locally edited account state.
            assertTrue(runtime.reopenCheckpoint(account) { current == account })
            assertEquals(owner.id, runtime.session().scope.ownerProfileID)
            assertNotEquals(first, runtime.session().read().owner)
            assertEquals("moon", NativeProfileAccess { runtime.session() }.read().profiles.single().avatar)
            runtime.retire(); runtime = coordinator()
            // Identical authenticated legacy material is a no-op receipt, not a reset of local edits.
            assertTrue(runtime.applyDocument(account, doc) { true })
            assertNotEquals(first, runtime.session().read().owner)
            assertEquals("Native owner", NativeProfileAccess { runtime.session() }.read().profiles.single().name)
            assertEquals("moon", NativeProfileAccess { runtime.session() }.read().profiles.single().avatar)
            assertEquals(retained, runtime.session().read().state.getJSONObject("legacyImportMaterial").toString())
            assertEquals("preserved", runtime.session().read().state.getJSONObject("hostDocument").getJSONObject("futurePreference").getString("mode"))
            val before = runtime.session().read().state.toString()
            val changedLegacy = JSONObject(doc.toString())
            changedLegacy.getJSONObject("vortx").getJSONArray("roster").getJSONObject(0).put("name", "Old client edit")
            assertTrue(runCatching { runtime.applyDocument(account, changedLegacy) { true } }.isFailure)
            assertEquals(before, runtime.session().read().state.toString())
            current = account.copy(generation = 5)
            assertTrue(runCatching { runtime.session() }.isFailure)
            assertNull(runtime.exportDocument(account))
        } finally { runtime.retire(); directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }

    @Test fun `native carrier always validates current legacy material before warm cold or first adoption`() = runBlocking {
        assumeTrue("Requires reviewed importer JNI", System.getenv("VORTX_JNI_SYNC") == "1")
        load()
        val directory = Files.createTempDirectory(File("build").toPath(), "native-receipt-jni-").toFile()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val checkpoints = VortxEncryptedCheckpointStore(directory) { key }
        val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 4)
        val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Baseline owner", avatar = "star", isOwner = true)
        val doc = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode()))
            .put("rosterModified", 123.5).put("library", JSONArray()).put("addons", JSONArray()))
        val scope = VortxAccountScope("account.${account.id}", owner.id)
        fun coordinator() = NativeAccountCoordinator(bindings(), checkpoints, { noNetwork() }, { it == account }, { it() }, {})
        var runtime = coordinator()
        try {
            assertTrue(runtime.applyDocument(account, doc) { true })
            val originalMaterial = runtime.session().read().state.getJSONObject("legacyImportMaterial").toString()
            NativeProfileAccess { runtime.session() }.save(owner.copy(name = "Native name"), adding = false)
            val remote = VortxNativeRuntime.hydrate(bindings(), runtime.session().read().state.toString())
            val carrier = remote.use {
                assertTrue(JSONObject(it.dispatch("""{"type":"add_library_item","profileId":"${owner.id}","item":{"kind":"standard","id":"native-only","type":"movie","name":"Native film"}}""")).getBoolean("ok"))
                JSONObject(doc.toString()).put("nativeSync", JSONObject(it.stateJson()).getJSONObject("nativeSync"))
            }
            assertTrue(runtime.applyDocument(account, carrier) { true })
            assertEquals("Native name", NativeProfileAccess { runtime.session() }.read().profiles.single().name)
            assertEquals("native-only", NativeCatalogRepository { runtime.session() }.library().getOrThrow().items.single().id)
            assertEquals(originalMaterial, runtime.session().read().state.getJSONObject("legacyImportMaterial").toString())
            val rejected = listOf(
                JSONObject(carrier.toString()).put("profileEdits", JSONObject().put(owner.id, JSONObject().put("name", "Pending web edit"))),
                JSONObject(carrier.toString()).put("profileEdits", JSONArray()),
                JSONObject(carrier.toString()).also { it.getJSONObject("vortx").getJSONArray("roster").getJSONObject(0).put("name", "Old client name") },
                JSONObject(carrier.toString()).also { it.getJSONObject("vortx").getJSONArray("library").put(JSONObject().put("id", "legacy-only").put("type", "movie").put("name", "Old client film")) },
                JSONObject(carrier.toString()).also { it.getJSONObject("nativeSync").remove("legacyImport") },
            )
            val before = runtime.session().read().state.toString()
            for (bad in rejected) {
                assertTrue(runCatching { runtime.applyDocument(account, bad) { true } }.isFailure)
                assertEquals(before, runtime.session().read().state.toString())
                assertEquals(before, checkpoints.read(scope))
            }
            runtime.retire()
            for (bad in rejected) {
                runtime = coordinator()
                assertTrue(runCatching { runtime.applyDocument(account, bad) { true } }.isFailure)
                assertTrue(runCatching { runtime.session() }.isFailure)
                assertEquals(before, checkpoints.read(scope))
            }
            // A valid native-native update with unchanged old material remains usable on cold reopen.
            assertTrue(runtime.applyDocument(account, carrier) { true })
            assertEquals("Native name", NativeProfileAccess { runtime.session() }.read().profiles.single().name)
            val absent = object : VortxCheckpointStore {
                var committed: String? = null
                override fun read(scope: VortxAccountScope) = committed
                override fun commit(scope: VortxAccountScope, snapshot: String) { committed = snapshot }
            }
            val fresh = NativeAccountCoordinator(bindings(), absent, { noNetwork() }, { true }, { it() }, {})
            try {
                for (bad in rejected) {
                    assertTrue(runCatching { fresh.applyDocument(account, bad) { true } }.isFailure)
                    assertNull(absent.committed)
                }
                val unsafeImport = JSONObject(doc.toString())
                unsafeImport.getJSONObject("vortx").getJSONArray("addons").put(JSONObject()
                    .put("transportUrl", "https://fixture.invalid/manifest.json").put("manifest", JSONObject()
                        .put("id", "encoded-fixture").put("name", "Fixture").put("version", "1.0.0")
                        .put("description", java.util.Base64.getEncoder().encodeToString("{\"authKey\":\"fixture-only-secret\"}".toByteArray()))))
                assertTrue(runCatching { fresh.applyDocument(account, unsafeImport) { true } }.isFailure)
                assertNull(absent.committed)
                assertTrue(fresh.applyDocument(account, carrier) { true })
                assertEquals("Native name", NativeProfileAccess { fresh.session() }.read().profiles.single().name)
            } finally { fresh.retire() }
        } finally { runtime.retire(); directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }

    @Test fun `real JNI parental catalog metadata embedded streams and pagination fail closed on missing certification`() = runBlocking {
        assumeTrue("Requires reviewed native JNI", System.getenv("VORTX_JNI_SYNC") == "1"); load()
        val requests = mutableListOf<JSONObject>()
        var firstPageBlocked = false
        fun meta(id: String) = JSONObject().put("id", id).put("type", "movie").put("name", id).also {
            if (id.startsWith("g")) it.put("certification", "G")
            if (id == "r") it.put("certification", "R")
            it.put("streams", JSONArray().put(JSONObject().put("url", "https://fixture.invalid/$id.mp4").put("name", "1080p")))
        }
        val transport = object : VortxResourceTransport {
            override fun makeCancellation() = object : VortxResourceCancellation { override fun cancel() {}; override fun close() {} }
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
                val input = JSONObject(requestJson); val request = input.getJSONObject("request"); requests += request
                val content = when (request.getString("resource")) {
                    "catalog" -> JSONObject().put("metas", if (request.getJSONArray("extra").toString().contains("skip")) JSONArray().put(meta("g2"))
                        else if (firstPageBlocked) JSONArray().put(meta("r")).put(meta("u")) else JSONArray().put(meta("g")).put(meta("r")).put(meta("u")))
                    "meta" -> JSONObject().put("meta", meta(request.getString("id")).also {
                        if (request.getString("type") == "series") it.put("type", "series").put("videos", JSONArray()
                            .put(JSONObject().put("id", "g-series:1:1").put("title", "Episode").put("season", 1).put("episode", 1)))
                    })
                    "stream" -> JSONObject().put("streams", JSONArray().put(JSONObject().put("url", "https://fixture.invalid/unsafe.mp4").put("name", "CAM porn XXX")))
                    "subtitles" -> JSONObject().put("subtitles", JSONArray())
                    else -> error("Unexpected request")
                }
                return JSONObject().put("kind", "resource_result").put("requestId", input.getString("requestId")).put("generation", input.getLong("generation"))
                    .put("request", request).put("cancelled", false).put("groups", JSONArray().put(JSONObject()
                        .put("addonId", input.getJSONArray("addons").getJSONObject(0).getString("id")).put("status", "ready").put("content", content))).toString()
            }
        }
        val store = object : VortxCheckpointStore {
            var state: String? = null
            override fun read(scope: VortxAccountScope) = state
            override fun commit(scope: VortxAccountScope, snapshot: String) { state = snapshot }
        }
        val scope = VortxAccountScope("parental-fixture", "owner")
        VortxNativeSession.open(scope, "Owner", bindings(), store, transport, allowNewAccount = true).use { session ->
            val manifest = JSONObject().put("id", "fixture").put("name", "Fixture").put("version", "1.0.0").put("types", JSONArray().put("movie").put("series"))
                .put("resources", JSONArray().put("catalog").put("meta").put("stream").put("subtitles"))
                .put("catalogs", JSONArray().put(JSONObject().put("type", "movie").put("id", "fixture").put("extra", JSONArray()
                    .put(JSONObject().put("name", "skip")).put(JSONObject().put("name", "search")))))
            session.dispatch(listOf(JSONObject().put("type", "install_addon").put("profileId", "owner").put("addon", JSONObject()
                .put("transportUrl", "https://fixture.invalid/manifest.json").put("manifest", manifest).put("flags", JSONObject().put("official", false).put("protected", false))),
                JSONObject("""{"type":"patch_profile","id":"owner","edits":[{"field":"kids","value":true}]}""")))
            val repo = NativeCatalogRepository { session }
            val row = repo.home().getOrThrow().last()
            assertEquals(listOf("g"), row.items.map { it.id })
            repo.loadHomeRowNextPage(row).getOrThrow()
            assertEquals("3", requests.last().getJSONArray("extra").getJSONArray(0).getString(1))
            assertEquals(listOf("g"), repo.discover().getOrThrow().items.map { it.id })
            assertEquals(listOf("g", "g2"), repo.discoverNextPage().getOrThrow().items.map { it.id })
            assertEquals("3", requests.last().getJSONArray("extra").getJSONArray(0).getString(1))
            assertEquals(listOf("g"), repo.search("fixture").getOrThrow().map { it.id })
            assertTrue(repo.meta(MediaType.MOVIE, "r").isFailure); assertTrue(repo.meta(MediaType.MOVIE, "u").isFailure)
            assertTrue(repo.streams(MediaType.MOVIE, "r").isFailure); assertTrue(repo.streams(MediaType.MOVIE, "u").isFailure)
            assertTrue(repo.subtitles(MediaType.MOVIE, "r").isFailure)
            assertTrue(repo.streams(MediaType.SERIES, "g-series", "foreign:1:1").isFailure)
            assertTrue(repo.streams(MediaType.MOVIE, "g", "foreign").isFailure)
            val groups = repo.streams(MediaType.MOVIE, "g").getOrThrow()
            assertEquals(listOf("https://fixture.invalid/g.mp4"), groups.flatMap { it.streams }.map { it.url })
            assertTrue(repo.resolveDirectLink("https://fixture.invalid/unknown.mp4", "Uncertified").isFailure)
            assertTrue(repo.resolveMagnet("a".repeat(40), "Uncertified").isFailure)
            firstPageBlocked = true
            val blocked = repo.home().getOrThrow().last()
            assertTrue(blocked.items.isEmpty()); assertTrue(blocked.hasNextPage)
            assertTrue(com.vortx.android.ui.components.showEmptyCatalogContinuation(blocked))
            assertFalse(com.vortx.android.ui.components.showEmptyCatalogContinuation(blocked, false))
            assertFalse(com.vortx.android.ui.components.showEmptyCatalogContinuation(row))
            repo.loadHomeRowNextPage(blocked).getOrThrow()
            assertEquals("2", requests.last().getJSONArray("extra").getJSONArray(0).getString(1))
        }
    }

    @Test fun `account retirement during suspended projection never reports a successful native install`() = runBlocking {
        assumeTrue("Requires reviewed importer JNI", System.getenv("VORTX_JNI_SYNC") == "1")
        load()
        val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 4)
        val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Owner", avatar = "star", isOwner = true)
        val doc = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode()))
            .put("rosterModified", 123.5).put("library", JSONArray()).put("addons", JSONArray()))
        for (mode in listOf("warm", "cold", "offline")) {
            var current = account
            var suspendProjection = false
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val store = object : VortxCheckpointStore {
                var checkpoint: String? = null
                override fun read(scope: VortxAccountScope) = checkpoint
                override fun commit(scope: VortxAccountScope, snapshot: String) { checkpoint = snapshot }
                override fun discover(accountID: String) = checkpoint?.let { VortxAccountScope(accountID, owner.id) }
            }
            val runtime = NativeAccountCoordinator(bindings(), store, { noNetwork() }, { it == current }, { it() }, {
                if (suspendProjection) { entered.complete(Unit); release.await() }
            })
            try {
                assertTrue(runtime.applyDocument(account, doc) { account == current })
                val carrier = JSONObject(doc.toString()).put("nativeSync", runtime.exportDocument(account)!!.nativeSync)
                if (mode != "warm") runtime.retire()
                suspendProjection = true
                val applying = async(start = CoroutineStart.UNDISPATCHED) {
                    runCatching {
                        if (mode == "offline") runtime.reopenCheckpoint(account) { account == current }
                        else runtime.applyDocument(account, carrier) { account == current }
                    }
                }
                entered.await()
                current = account.copy(generation = 5)
                runtime.retire()
                release.complete(Unit)
                assertTrue(applying.await().isFailure)
                assertNull(runtime.exportDocument(account))
                assertTrue(runCatching { runtime.session() }.isFailure)
            } finally { release.complete(Unit); runtime.retire() }
        }
    }
}
