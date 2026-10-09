package com.vortx.android.engine

import com.vortx.android.debrid.DebridOwnerScope
import com.vortx.android.debrid.DebridOwnerToken
import com.vortx.android.model.*
import com.vortx.android.nzb.*
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Production aggregator/repository with synthetic configuration, bindings and resource replies only. */
class NativeNzbSourcesTest {
    private val account = "00000000-0000-0000-0000-000000000001"
    private val scope = VortxAccountScope("account.$account", "owner")
    private fun config(id: String, enabled: Boolean = true) = NzbIndexerConfig(id, id, "https://$id.invalid/api", enabled)
    private fun release(name: String = "Fixture S01E02") = NzbRelease(name, "https://fixture.invalid/nzb", 1024L)
    private class ConfigSource(val account: String) {
        var owner = DebridOwnerToken(DebridOwnerScope.Account(account), 1)
        var profile: String? = "owner"
        var revision = 1L
        var configs = emptyList<NzbIndexerConfig>()
        var beforeRead: (() -> Unit)? = null
        val calls = AtomicInteger()
        var search: suspend (NzbIndexerConfig, String, NzbSearch) -> Result<List<NzbRelease>> = { _, _, _ -> Result.success(emptyList()) }
        fun scope() = profile?.let { NzbIndexerStore.Scope(owner, it) }
        fun aggregator() = NzbSourceAggregator(
            captureScope = ::scope,
            readScope = { captured ->
                beforeRead?.invoke()
                if (captured == scope()) NzbIndexerStore.Read.Ready(NzbIndexerStore.Document(revision, configs)) else NzbIndexerStore.Read.Stale
            },
            keyFor = { _, captured -> "synthetic-key".takeIf { captured == scope() } },
            scopeCurrent = { it == scope() },
            searchReleases = { config, key, search -> calls.incrementAndGet(); this.search(config, key, search) },
        )
    }
    private class Store : VortxCheckpointStore {
        var snapshot: String? = null
        override fun read(scope: VortxAccountScope) = snapshot
        override fun commit(scope: VortxAccountScope, snapshot: String) { this.snapshot = snapshot }
    }
    private class Runtime(private val kids: Boolean = false, private val blockedMeta: Boolean = false) : VortxRuntimeBindings {
        private var sequence = 0L
        private val states = mutableMapOf<Long, JSONObject>()
        private fun profile(id: String, owner: Boolean) = JSONObject().put("id", id).put("name", id).put("owner", owner).put("deleted", false)
            .put("addons", "share_primary").put("parental", JSONObject().put("kids", kids)).put("settings", JSONObject().put("disabledAddons", JSONArray()))
        private fun library() = JSONObject().put("items", JSONArray()).put("history", JSONArray()).put("resume", JSONObject()).put("watched", JSONObject()).put("cwBoard", JSONArray())
        override fun create(ownerId: String, ownerName: String) = hydrate(JSONObject().put("roster", JSONObject().put("profiles", JSONObject()
            .put(ownerId, profile(ownerId, true)).put("guest", profile("guest", false)))).put("activeProfileId", ownerId)
            .put("libraries", JSONObject().put(ownerId, library()).put("guest", library())).toString())
        override fun hydrate(snapshot: String) = (++sequence).also { states[it] = JSONObject(snapshot) }
        override fun state(handle: Long) = states[handle]?.toString()
        override fun delta(handle: Long): String = error("Full checkpoint required")
        override fun free(handle: Long) { states.remove(handle) }
        override fun dispatch(handle: Long, action: String): String {
            val state = states.getValue(handle); val input = JSONObject(action)
            when (input.getString("type")) {
                "bind_sync_scope" -> state.put("nativeSync", JSONObject().put("schemaVersion", 1).put("scope", input.getString("scope"))
                    .put("ownerProfileId", "owner").put("profiles", JSONObject()).put("addons", JSONObject()).put("libraries", JSONObject()).put("watches", JSONObject()))
                "switch_profile" -> state.put("activeProfileId", input.getString("id"))
                "get_state" -> Unit
                else -> return "{\"ok\":false}"
            }
            return "{\"ok\":true}"
        }
        override fun resolve(handle: Long, request: String): String {
            val input = JSONObject(request)
            return when (input.getString("kind")) {
                "installed_addons" -> JSONObject().put("kind", "installed_addons").put("profileId", input.getString("profileId"))
                    .put("addons", JSONArray().put(JSONObject().put("transportUrl", "https://addon.invalid/manifest.json").put("manifest", JSONObject()
                        .put("id", "addon").put("name", "Addon").put("catalogs", JSONArray()).put("resources", JSONArray(listOf("meta", "stream")))))).toString()
                "resume_point" -> JSONObject().put("kind", "resume_point").put("resume", JSONObject.NULL).toString()
                "meta" -> JSONObject().put("kind", "meta").put("meta", if (blockedMeta) JSONObject.NULL else input.get("meta")).toString()
                else -> "{\"kind\":\"error\"}"
            }
        }
    }
    private class Transport : VortxResourceTransport {
        var failStreams = false
        val streamCalls = AtomicInteger()
        override fun makeCancellation() = object : VortxResourceCancellation { override fun cancel() {}; override fun close() {} }
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
            val input = JSONObject(requestJson); val request = input.getJSONObject("request")
            val stream = request.getString("resource") == "stream"
            if (stream) streamCalls.incrementAndGet()
            val content = if (stream) JSONObject().put("streams", JSONArray().put(JSONObject().put("url", "https://addon.invalid/video").put("name", "Addon source")))
            else JSONObject().put("meta", JSONObject().put("id", request.getString("id")).put("type", request.getString("type")).put("name", "Fixture")
                .put("releaseInfo", "2024").put("videos", JSONArray().put(JSONObject().put("id", "tt123456:1:2").put("season", 1).put("episode", 2).put("title", "Second"))))
            return JSONObject().put("kind", "resource_result").put("requestId", input.getString("requestId")).put("generation", input.getLong("generation"))
                .put("request", request).put("cancelled", false).put("groups", JSONArray().put(JSONObject().put("addonId", "https://addon.invalid/manifest.json")
                    .put("status", if (stream && failStreams) "error" else "ready").put("content", content))).toString()
        }
    }
    private fun open(transport: Transport = Transport(), kids: Boolean = false, blockedMeta: Boolean = false) =
        VortxNativeSession.open(scope, "Owner", Runtime(kids, blockedMeta), Store(), transport, true)
    private fun repository(source: ConfigSource, session: () -> VortxNativeSession) = NativeCatalogRepository(
        playbackResolver = NativePlaybackResolver { stream, _ -> Playable(stream.nzbUrl ?: stream.url!!, "Fixture") },
        nzbSourceAggregator = source.aggregator(), sessionProvider = session,
    )

    @Test fun productionNativeFactoryInjectsCapturedSecureIndexerStore() {
        // The runtime cases below prove repository behavior; this separate source contract makes
        // the real application factory mandatory, rather than passing only injected test instances.
        val relative = "android/app/src/main/kotlin/com/vortx/android/VortXApplication.kt"
        val source = generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
            .map { File(it, relative) }.firstOrNull(File::isFile)?.readText()
            ?: error("Actual application factory source is unavailable")
        val factory = source.substringAfter("private val nativeRepository: NativeCatalogRepository by lazy", "")
            .substringBefore("override fun onCreate()").filterNot(Char::isWhitespace)
            .replace(Regex(",(?=[)}])"), "") // Kotlin trailing commas do not change the wiring contract.
        assertTrue("Native factory must inject the production aggregator", factory.contains("nzbSourceAggregator=run{valkeys=DebridKeys(this)"))
        assertTrue("Secure indexer origin/profile/lifecycle must match settings", factory.contains(
            "NzbIndexerStore(this,keys::ownerToken,{ProfileStore.sharedOrNull()?.active?.id},keys::mutateCurrentOwner)"))
        assertTrue(factory.contains("NzbSourceAggregator("))
        assertFalse("Unavailable profile must not retarget to owner", factory.contains("UserProfile.OWNER_ID"))
        assertFalse("Fallback profile helper must not authorize indexers", factory.contains("ProfileStore.sharedOrNull()?.activeProfileId"))
        val injection = factory.indexOf("nzbSourceAggregator=")
        val trailingSession = factory.indexOf("nativeAccounts.session().also{it.read()}")
        assertTrue("Captured store injection must precede the native session closure", injection >= 0 && trailingSession > injection)
    }

    @Test fun emptyDisabledAndExplicitNullScopeNeverSearchOrRetarget() = runBlocking {
        val source = ConfigSource(account); val aggregator = source.aggregator(); val search = NzbSearch("Fixture")
        assertTrue(aggregator.aggregate(search).groups.isEmpty())
        source.configs = listOf(config("disabled", false))
        assertTrue(aggregator.aggregate(search).groups.isEmpty())
        source.configs = listOf(config("enabled")); source.search = { _, _, _ -> Result.success(listOf(release())) }
        assertTrue(aggregator.aggregate(search, null).groups.isEmpty())
        assertEquals(0, source.calls.get())
        val owner = VortxNativeOwner(scope, "owner", 0)
        assertNotNull(aggregator.captureNativeScope(owner))
        source.profile = null
        assertNull("Unknown/unprojected roster has no indexer scope", aggregator.captureNativeScope(owner))
        assertTrue(aggregator.aggregate(search).groups.isEmpty())
        assertEquals(0, source.calls.get())
        source.profile = "guest"; assertNull(aggregator.captureNativeScope(owner))
        source.profile = "owner"; source.owner = DebridOwnerToken(DebridOwnerScope.Account("other"), 2)
        assertNull(aggregator.captureNativeScope(owner))
    }

    @Test fun actualAggregatorRetainsConfiguredOrderAndIsolatesFailedIndexer() = runBlocking {
        val source = ConfigSource(account).also { it.configs = listOf(config("first"), config("failed"), config("last")) }
        source.search = { config, _, _ -> if (config.id == "failed") throw IllegalStateException("synthetic failure") else Result.success(listOf(release(config.id))) }
        val result = source.aggregator().aggregate(NzbSearch("Fixture"))
        assertEquals(listOf("first", "last"), result.groups.map(StreamGroup::addon))
        assertTrue(result.groups.all { it.streams.single().url == null && it.streams.single().nzbUrl != null })
    }

    @Test fun queryRequiresExactMetadataAndEpisode() {
        val detail = MetaDetail("tt123456", MediaType.SERIES, "Fixture", videos = listOf(Episode("tt123456:1:2", "Second", 1, 2)))
        val search = nativeNzbSearch(detail, MediaType.SERIES, detail.id, "tt123456:1:2")!!
        assertEquals(1, search.season); assertEquals(2, search.episode)
        assertNull(nativeNzbSearch(detail, MediaType.SERIES, "other", "tt123456:1:2"))
        assertNull(nativeNzbSearch(detail, MediaType.SERIES, detail.id, "missing"))
        assertNull(nativeNzbSearch(detail.copy(videos = detail.videos + detail.videos), MediaType.SERIES, detail.id, "tt123456:1:2"))
        assertEquals(2024, nativeNzbSearch(MetaDetail("tt123456", MediaType.MOVIE, "Fixture", releaseInfo = "2024"), MediaType.MOVIE, "tt123456", null)!!.year)
    }

    @Test fun repositoryAppendsDirectSourcesWithNativeTokenAndExactPlaybackContext() = runBlocking {
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
        source.search = { _, _, search -> assertEquals(2, search.episode); Result.success(listOf(release())) }
        open().use { session ->
            val repo = repository(source) { session }
            val groups = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").getOrThrow()
            assertEquals(listOf("addon.invalid", "direct"), groups.map(StreamGroup::addon))
            val direct = groups.last().streams.single(); assertNotNull(direct.nativePlaybackToken)
            val context = repo.resolve(direct, Episode("tt123456:1:2", "Second", 1, 2)).getOrThrow().playbackContext!!
            assertEquals("owner", context.owner.profileId); assertEquals("tt123456", context.contentId)
            assertEquals("tt123456:1:2", context.videoId); assertEquals(1, context.season); assertEquals(2, context.episode)
        }
    }

    @Test fun indexerOnlySuccessAndIndexerFailurePreserveIndependentAddonSettlement() = runBlocking {
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
        source.search = { _, _, _ -> Result.success(listOf(release())) }
        val transport = Transport().also { it.failStreams = true }
        open(transport).use { session ->
            val repo = repository(source) { session }
            assertEquals("direct", repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").getOrThrow().single().addon)
            transport.failStreams = false; source.search = { _, _, _ -> Result.failure(IllegalStateException("synthetic failure")) }
            assertEquals("addon.invalid", repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").getOrThrow().single().addon)
            transport.failStreams = true
            assertTrue(repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").isFailure)
        }
    }

    @Test fun parentalApprovalAndSourceFiltersAlsoCoverDirectIndexers() = runBlocking {
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")); it.search = { _, _, _ -> Result.success(listOf(release("XXX S01E02"))) } }
        open(kids = true, blockedMeta = true).use { session ->
            assertTrue(repository(source) { session }.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").isFailure)
            assertEquals(0, source.calls.get())
        }
        open(kids = true).use { session ->
            val groups = repository(source) { session }.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").getOrThrow()
            assertEquals(listOf("addon.invalid"), groups.filter { it.streams.isNotEmpty() }.map(StreamGroup::addon))
            assertTrue(groups.first { it.addon == "direct" }.streams.isEmpty())
        }
    }

    @Test fun forceRefreshSearchesAgainAndRetiresPriorSourceBindings() = runBlocking {
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")); it.search = { _, _, _ -> Result.success(listOf(release())) } }
        val transport = Transport()
        open(transport).use { session ->
            val repo = repository(source) { session }
            val old = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").getOrThrow().last().streams.single()
            val fresh = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2", forceRefresh = true).getOrThrow().last().streams.single()
            assertEquals(2, source.calls.get()); assertEquals(2, transport.streamCalls.get())
            assertNotEquals(old.nativePlaybackToken, fresh.nativePlaybackToken)
            assertTrue(repo.resolve(old).isFailure); assertTrue(repo.resolve(fresh).isSuccess)
        }
    }

    @Test fun changedConfigIsRecheckedInsidePublicationBeforeBindings() = runBlocking {
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")); it.search = { _, _, _ -> Result.success(listOf(release())) } }
        var reads = 0
        source.beforeRead = { if (++reads == 3) source.revision++ }
        open().use { session ->
            val groups = repository(source) { session }.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").getOrThrow()
            assertEquals(listOf("addon.invalid"), groups.map(StreamGroup::addon))
        }
    }

    @Test fun newerStreamsWinsAndOldResultCannotClearItsSourceBindings() = runBlocking {
        val entered = CompletableDeferred<Unit>(); val unblock = CompletableDeferred<Unit>()
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
        source.search = { _, _, _ -> if (source.calls.get() == 1) { entered.complete(Unit); unblock.await() }; Result.success(listOf(release())) }
        open().use { session ->
            val repo = repository(source) { session }
            val stale = async(Dispatchers.Default) { repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2") }
            entered.await()
            val fresh = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2", forceRefresh = true).getOrThrow().last().streams.single()
            unblock.complete(Unit); assertTrue(stale.await().isFailure)
            assertTrue(repo.resolve(fresh).isSuccess)
        }
    }

    @Test fun profileAndMountedAccountChangesRejectLateDirectResults() = runBlocking {
        for (profileChange in listOf(true, false)) {
            val entered = CompletableDeferred<Unit>(); val unblock = CompletableDeferred<Unit>()
            val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
            source.search = { _, _, _ -> entered.complete(Unit); unblock.await(); Result.success(listOf(release())) }
            open().use { first -> open().use { second ->
                var mounted = first; val repo = repository(source) { mounted }
                val stale = async(Dispatchers.Default) { repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2") }
                entered.await()
                if (profileChange) {
                    first.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")))
                    source.profile = "guest"
                } else {
                    mounted = second; source.owner = DebridOwnerToken(DebridOwnerScope.Account("other"), 2)
                }
                unblock.complete(Unit); assertTrue(stale.await().isFailure)
            } }
        }
    }

    @Test fun preparationProbeRetiresForProfileAccountSourceAndNewerResolveBeforeAwaitCompletes() = runBlocking {
        for (retirement in listOf("profile", "account", "source", "resolve")) {
            val entered = CompletableDeferred<() -> Boolean>(); val unblock = CompletableDeferred<Unit>()
            val resolveCalls = AtomicInteger(); val disposed = AtomicInteger()
            val resolver = object : NativePlaybackResolver {
                override suspend fun resolve(source: StreamSource, episode: Episode?): Playable = error("Captured retirement probe required")
                override suspend fun resolve(source: StreamSource, episode: Episode?, isCurrent: () -> Boolean): Playable {
                    if (resolveCalls.incrementAndGet() == 1) {
                        entered.complete(isCurrent)
                        unblock.await()
                    }
                    // Deliberately ignore retirement here: final host admission must still close
                    // a prepared lease, even when a resolver returns after its probe went false.
                    return Playable(source.url!!, source.title, playbackLease = AutoCloseable { disposed.incrementAndGet() })
                }
            }
            open().use { first -> open().use { second ->
                var mounted = first
                val repo = NativeCatalogRepository(playbackResolver = resolver, sessionProvider = { mounted })
                val source = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").getOrThrow().single().streams.single()
                val stale = async(Dispatchers.Default) { repo.resolve(source) }
                val isCurrent = entered.await()
                assertTrue("Initial $retirement admission", isCurrent())
                when (retirement) {
                    "profile" -> first.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")))
                    "account" -> mounted = second
                    "source" -> repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2", forceRefresh = true).getOrThrow()
                    "resolve" -> repo.resolve(source).getOrThrow().playbackLease?.close()
                }
                assertFalse("Retirement must precede await completion for $retirement", isCurrent())
                unblock.complete(Unit)
                assertTrue("Final admission must also reject $retirement", stale.await().isFailure)
                assertEquals(if (retirement == "resolve") 2 else 1, disposed.get())
            } }
        }
    }

    @Test fun genuineResolverAndCallerJobCancellationRemainTerminal() = runBlocking {
        open().use { session ->
            val cancelledResolver = NativeCatalogRepository(
                playbackResolver = NativePlaybackResolver { _, _ -> throw CancellationException("Synthetic current resolver cancellation") },
                sessionProvider = { session },
            )
            try {
                cancelledResolver.resolveDirectLink("https://fixture.invalid/video", "Fixture")
                fail("A still-current resolver cancellation must propagate")
            } catch (_: CancellationException) { /* Expected: not Result.failure. */ }

            val entered = CompletableDeferred<Unit>(); val left = CompletableDeferred<Unit>()
            val waitingResolver = NativeCatalogRepository(
                playbackResolver = NativePlaybackResolver { _, _ ->
                    entered.complete(Unit)
                    try { awaitCancellation() } finally { left.complete(Unit) }
                },
                sessionProvider = { session },
            )
            val pending = async(Dispatchers.Default) { waitingResolver.resolveDirectLink("https://fixture.invalid/video", "Fixture") }
            entered.await(); pending.cancel(CancellationException("Synthetic caller cancellation"))
            try { pending.await(); fail("A cancelled caller must propagate cancellation") }
            catch (_: CancellationException) { /* Expected: terminal caller cancellation. */ }
            left.await(); assertTrue(pending.isCancelled)
        }
    }

    @Test fun handedOffPlaybackAuthorityOutlivesResolveJobSourceRefreshAndPrewarmButNotItsOwner() = runBlocking {
        for (profileChange in listOf(true, false)) {
            val captured = CompletableDeferred<Pair<() -> Boolean, () -> Boolean>>()
            val resolver = object : NativePlaybackResolver {
                override suspend fun resolve(source: StreamSource, episode: Episode?): Playable = error("Separate lifetime authority required")
                override suspend fun resolve(source: StreamSource, episode: Episode?, isCurrent: () -> Boolean,
                    playbackIsCurrent: () -> Boolean): Playable {
                    captured.complete(isCurrent to playbackIsCurrent)
                    return Playable(source.url!!, source.title, playbackLease = AutoCloseable {})
                }
            }
            open().use { first -> open().use { second ->
                var mounted = first
                val repo = NativeCatalogRepository(playbackResolver = resolver, sessionProvider = { mounted })
                val source = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").getOrThrow().single().streams.single()
                val resolving = async(Dispatchers.Default) { repo.resolve(source).getOrThrow() }
                val playable = resolving.await()
                val (pendingCurrent, playbackCurrent) = captured.await()
                assertTrue(resolving.isCompleted)
                assertFalse("A completed resolve Job is no longer pending", pendingCurrent())
                assertTrue("Playback outlives the resolve Job", playbackCurrent())
                val fresh = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2", forceRefresh = true).getOrThrow().single().streams.single()
                assertTrue("Source refresh must not retire handed-off playback", playbackCurrent())
                repo.resolve(fresh).getOrThrow().playbackLease?.close()
                assertTrue("A newer prewarm resolve must not retire playback", playbackCurrent())
                if (profileChange) first.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")))
                else mounted = second
                assertFalse("Captured profile/mount retirement ends playback authority", playbackCurrent())
                // The real transport's lease watcher owns automatic disposal. This synthetic test
                // verifies only the callback's exact pending-versus-lifetime contract.
                playable.playbackLease?.close()
            } }
        }
    }
}
