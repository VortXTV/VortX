package com.vortx.android.engine

import com.vortx.android.debrid.DebridOwnerScope
import com.vortx.android.debrid.DebridOwnerToken
import com.vortx.android.model.*
import com.vortx.android.nzb.*
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
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
    private class Runtime(private val kids: Boolean = false, var blockedMeta: Boolean = false,
        private val addonCount: Int = 1) : VortxRuntimeBindings {
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
                    .put("addons", JSONArray().also { addons -> repeat(addonCount) { index ->
                        val host = if (index == 0) "addon" else "peer$index"
                        addons.put(JSONObject().put("transportUrl", "https://$host.invalid/manifest.json").put("manifest", JSONObject()
                            .put("id", host).put("name", host).put("catalogs", JSONArray()).put("resources", JSONArray(listOf("meta", "stream")))))
                    } }).toString()
                "resume_point" -> JSONObject().put("kind", "resume_point").put("resume", JSONObject.NULL).toString()
                "meta" -> JSONObject().put("kind", "meta").put("meta", if (blockedMeta || input.getJSONObject("meta").optString("name") == "Blocked") JSONObject.NULL else input.get("meta")).toString()
                else -> "{\"kind\":\"error\"}"
            }
        }
    }
    private class Transport : VortxResourceTransport {
        var failStreams = false
        var beforeLoad: (JSONObject) -> Unit = {}
        var contentOverride: (JSONObject, String) -> JSONObject? = { _, _ -> null }
        val streamCalls = AtomicInteger()
        val cancelCalls = AtomicInteger()
        override fun makeCancellation() = object : VortxResourceCancellation {
            override fun cancel() { cancelCalls.incrementAndGet() }
            override fun close() {}
        }
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
            val input = JSONObject(requestJson); val request = input.getJSONObject("request")
            beforeLoad(input)
            val addonId = input.getJSONArray("addons").getJSONObject(0).getString("id")
            val stream = request.getString("resource") == "stream"
            if (stream) streamCalls.incrementAndGet()
            val content = contentOverride(request, addonId) ?: if (stream) JSONObject().put("streams", JSONArray().put(JSONObject().put("url", "https://addon.invalid/video").put("name", "Addon source")))
            else JSONObject().put("meta", JSONObject().put("id", request.getString("id")).put("type", request.getString("type")).put("name", "Fixture")
                .put("releaseInfo", "2024").put("videos", JSONArray().put(JSONObject().put("id", "tt123456:1:2").put("season", 1).put("episode", 2).put("title", "Second"))))
            return JSONObject().put("kind", "resource_result").put("requestId", input.getString("requestId")).put("generation", input.getLong("generation"))
                .put("request", request).put("cancelled", false).put("groups", JSONArray().put(JSONObject().put("addonId", addonId)
                    .put("status", if (stream && failStreams) "error" else "ready").put("content", content))).toString()
        }
    }
    private fun open(transport: Transport = Transport(), kids: Boolean = false, blockedMeta: Boolean = false, addonCount: Int = 1) =
        VortxNativeSession.open(scope, "Owner", Runtime(kids, blockedMeta, addonCount), Store(), transport, true)
    private fun repository(source: ConfigSource, session: () -> VortxNativeSession) = NativeCatalogRepository(
        playbackResolver = NativePlaybackResolver { stream, _ -> Playable(stream.nzbUrl ?: stream.url!!, "Fixture") },
        nzbSourceAggregator = source.aggregator(), sessionProvider = session,
    )

    @Test fun preparedSourcesDoNotRevokeForegroundAndAdoptWithoutProviderRefetch() = runBlocking {
        val transport = Transport()
        open(transport).use { session ->
            val repo = repository(ConfigSource(account)) { session }
            val first = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:1").getOrThrow().first().streams.first()
            val episode = Episode("tt123456:1:2", "Second", 1, 2)
            val preparation = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", episode))
            preparation.updates().collect {}
            val warmed = preparation.groups.first().streams.first()
            val playable = preparation.resolve(warmed).getOrThrow()
            assertEquals(episode.id, playable.playbackContext!!.videoId)
            assertTrue(repo.resolve(first, Episode("tt123456:1:1", "First", 1, 1)).isSuccess)
            assertTrue("Warm rows are private until adopted", repo.resolve(warmed, episode).isFailure)
            val calls = transport.streamCalls.get()
            val adopted = requireNotNull(preparation.adopt())
            preparation.close()
            assertEquals(preparation.groups, adopted.groups)
            assertTrue("Adopted source menu resolves using retained bindings", repo.resolve(warmed, episode).isSuccess)
            assertTrue(repo.resolve(first).isFailure)
            assertEquals("Adoption and source menu do not refetch providers", calls, transport.streamCalls.get())
            assertNull("Preparation is consumed once", preparation.adopt())
        }
    }

    @Test fun gatedForegroundAndPreparedProviderLoadsAndResolversRemainIndependent() = runBlocking {
        val providerEntered = CountDownLatch(1); val providerRelease = CountDownLatch(1)
        val transport = Transport().also { it.beforeLoad = { input ->
            val request = input.getJSONObject("request")
            if (request.getString("resource") == "stream" && request.getString("id").endsWith(":1:1")) {
                providerEntered.countDown(); check(providerRelease.await(3, TimeUnit.SECONDS))
            }
        } }
        open(transport).use { session ->
            val resolveEntered = Channel<String>(Channel.UNLIMITED)
            val resolveRelease = CompletableDeferred<Unit>()
            val repo = NativeCatalogRepository(playbackResolver = NativePlaybackResolver { _, episode ->
                resolveEntered.send(episode!!.id); resolveRelease.await()
                Playable("https://fixture.invalid/${episode.id}", "Fixture")
            }, sessionProvider = { session })
            val pendingForeground = async(Dispatchers.Default) { repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:1") }
            try {
                assertTrue(providerEntered.await(2, TimeUnit.SECONDS))
                val episode = Episode("tt123456:1:2", "Second", 1, 2)
                val prepared = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", episode))
                withTimeout(2_000) { prepared.updates().collect {} }
                providerRelease.countDown()
                val outgoing = withTimeout(2_000) { pendingForeground.await().getOrThrow() }.first().streams.first()
                val foregroundResolve = async { repo.resolve(outgoing, Episode("tt123456:1:1", "First", 1, 1)) }
                val warmResolve = async { prepared.resolve(prepared.groups.first().streams.first()) }
                val entered = withTimeout(2_000) { setOf(resolveEntered.receive(), resolveEntered.receive()) }
                assertEquals(setOf("tt123456:1:1", "tt123456:1:2"), entered)
                resolveRelease.complete(Unit)
                assertTrue(foregroundResolve.await().isSuccess)
                assertTrue(warmResolve.await().isSuccess)
                prepared.close()
            } finally {
                providerRelease.countDown(); resolveRelease.complete(Unit); pendingForeground.cancelAndJoin(); resolveEntered.close()
            }
        }
    }

    @Test fun exactTicketRetirementCannotRevokeReplacementAndPreparedSlotsDoNotAccumulate() = runBlocking {
        open().use { session ->
            val owner = session.read().owner
            lateinit var oldTicket: java.util.UUID
            lateinit var currentTicket: java.util.UUID
            var pages = emptyList<VortxResourceSnapshot>()
            session.loadProviders("fixture-slot", owner, emptyList()) { update, ticket -> oldTicket = ticket; pages = update.pages }
            session.loadProviders("fixture-slot", owner, emptyList()) { update, ticket -> currentTicket = ticket; pages = update.pages }
            session.retireResourceSlot("fixture-slot", oldTicket)
            assertTrue(session.publish("fixture-slot", owner, pages, currentTicket) { true })
            session.retireResourceSlot("fixture-slot", currentTicket)
            assertTrue(runCatching { session.publish("fixture-slot", owner, pages, currentTicket) {} }.isFailure)
            val repo = repository(ConfigSource(account)) { session }
            repeat(5) {
                val prepared = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", Episode("tt123456:1:2", "Second", 1, 2)))
                prepared.updates().collect {}
                prepared.close()
            }
            val slots = VortxNativeSession::class.java.getDeclaredField("slots").also { it.isAccessible = true }
            assertEquals("Completed unique preparation slots must be retired", 0, (slots.get(session) as Map<*, *>).size)
        }
    }

    @Test fun preparedTargetRequiresFreshApprovedMetadataAndExactEpisodeCoordinates() = runBlocking {
        open().use { session ->
            val repo = repository(ConfigSource(account)) { session }
            val prepared = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", Episode("tt123456:1:2", "Wrong coordinates", 9, 9)))
            assertTrue(runCatching { prepared.updates().collect {} }.isFailure)
            assertTrue(prepared.groups.isEmpty())
            assertNull(prepared.adopt())
            prepared.close()
        }
    }

    @Test fun rejectedPreparationRestoresOnlyItsExactForegroundAndNeverNewerState() = runBlocking {
        open().use { session ->
            val repo = repository(ConfigSource(account)) { session }
            val first = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:1").getOrThrow().first().streams.first()
            val episode = Episode("tt123456:1:2", "Second", 1, 2)
            val preparation = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", episode))
            preparation.updates().collect {}
            val warm = preparation.groups.first().streams.first()
            val adoption = requireNotNull(preparation.adopt())
            adoption.rollback(); adoption.rollback(); preparation.close()
            assertTrue(repo.resolve(first).isSuccess)
            assertTrue(repo.resolve(warm).isFailure)

            val another = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", episode))
            another.updates().collect {}
            val retired = requireNotNull(another.adopt())
            val newest = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:3").getOrThrow().first().streams.first()
            retired.rollback(); another.close()
            assertTrue(repo.resolve(newest).isSuccess)
            assertTrue(repo.resolve(first).isFailure)
        }
    }

    @Test fun preparationCloseAndOwnerABARejectLateNonCooperativeLeaseExactlyOnce() = runBlocking {
        for (changeOwner in listOf(false, true)) {
            open().use { session ->
                val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
                val closes = AtomicInteger()
                val repo = NativeCatalogRepository(playbackResolver = NativePlaybackResolver { _, _ ->
                    withContext(NonCancellable) { entered.complete(Unit); release.await() }
                    Playable("https://fixture.invalid/prepared", "Prepared", playbackLease = AutoCloseable { closes.incrementAndGet() })
                }, sessionProvider = { session })
                val preparation = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", Episode("tt123456:1:2", "Second", 1, 2)))
                preparation.updates().collect {}
                val pending = async { preparation.resolve(preparation.groups.first().streams.first()) }
                withTimeout(2_000) { entered.await() }
                if (changeOwner) {
                    session.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")), session.read().owner)
                    session.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "owner")), session.read().owner)
                } else preparation.close()
                release.complete(Unit)
                assertTrue(withTimeout(2_000) { pending.await() }.isFailure)
                assertFalse(preparation.isCurrent())
                assertNull(preparation.adopt())
                preparation.close(); preparation.close()
                assertEquals(1, closes.get())
            }
        }
    }

    @Test fun firstApprovedMetadataPublishesIndexerBeforeUnrelatedAddonLegsSettle() = runBlocking {
        val gate = CountDownLatch(1)
        val observed = CopyOnWriteArrayList<String>()
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
        source.search = { _, _, search ->
            assertEquals(1, search.season); assertEquals(2, search.episode)
            Result.success(listOf(release()))
        }
        val transport = Transport().also { it.beforeLoad = { input ->
            val resource = input.getJSONObject("request").getString("resource")
            val addon = input.getJSONArray("addons").getJSONObject(0).getString("id")
            if (resource == "stream" || "peer" in addon) {
                check(gate.await(3, TimeUnit.SECONDS)) { "Synthetic provider gate expired" }
            }
        } }
        // Two metadata permits: one must remain available for the approved provider. Holding
        // both permits would test queue admission order instead of early indexer publication.
        open(transport, addonCount = 2).use { session ->
            val repo = repository(source) { session }
            val updates = Channel<com.vortx.android.data.StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = async(Dispatchers.Default) {
                repo.streamUpdates(MediaType.SERIES, "tt123456", "tt123456:1:2").collect {
                    observed += "${it.loaded}/${it.total}:${it.groups.map(StreamGroup::addon)}"
                    updates.send(it)
                }
            }
            try {
                val early = try { withTimeout(1_000) {
                    var update = updates.receive()
                    while (update.groups.none { it.addon == "direct" }) update = updates.receive()
                    update
                } } catch (timeout: kotlinx.coroutines.TimeoutCancellationException) {
                    throw AssertionError("No early indexer; calls=${source.calls.get()}, updates=$observed", timeout)
                }
                assertFalse("Indexer completion must not terminalize pending add-ons", early.terminal)
                assertTrue(early.loaded < early.total)
                assertEquals(1, source.calls.get())
                val direct = early.groups.single().streams.single()
                assertNotNull(direct.nativePlaybackToken)
                assertEquals("tt123456:1:2", repo.resolve(direct, Episode("tt123456:1:2", "Second", 1, 2))
                    .getOrThrow().playbackContext!!.videoId)
                gate.countDown()
                withTimeout(2_000) { pending.await() }
                val final = generateSequence { updates.tryReceive().getOrNull() }.last()
                assertTrue(final.terminal)
                assertEquals(listOf("addon.invalid", "peer1.invalid", "direct"), final.groups.map(StreamGroup::addon))
                assertEquals(direct.nativePlaybackToken, final.groups.last().streams.single().nativePlaybackToken)
            } finally {
                gate.countDown(); pending.cancelAndJoin(); updates.close()
            }
        }
    }

    @Test fun indexerFailureSettlesOnceWithoutDroppingSuccessfulProviders() = runBlocking {
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val indexerStarted = CountDownLatch(1)
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
        source.search = { _, _, _ -> entered.complete(Unit); indexerStarted.countDown(); release.await(); throw IllegalStateException("Synthetic indexer failure") }
        val transport = Transport().also { it.beforeLoad = { input -> if (input.getJSONObject("request").getString("resource") == "stream") {
            check(indexerStarted.await(2, TimeUnit.SECONDS))
        } } }
        open(transport).use { session ->
            val updates = Channel<com.vortx.android.data.StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = async(Dispatchers.Default) {
                repository(source) { session }.streamUpdates(MediaType.SERIES, "tt123456", "tt123456:1:2").collect { updates.send(it) }
            }
            try {
                withTimeout(1_000) { entered.await() }
                val partial = withTimeout(1_000) {
                    var update = updates.receive()
                    while (update.groups.isEmpty()) update = updates.receive()
                    update
                }
                assertFalse(partial.terminal); assertFalse(partial.selectionReady)
                release.complete(Unit); withTimeout(2_000) { pending.await() }
                val remaining = generateSequence { updates.tryReceive().getOrNull() }.toList()
                assertEquals(1, remaining.count { it.terminal })
                assertEquals(listOf("addon.invalid"), remaining.last().groups.map(StreamGroup::addon))
                assertEquals(1, source.calls.get())
            } finally { release.complete(Unit); pending.cancelAndJoin(); updates.close() }
        }
    }

    @Test fun configuredIndexerCannotBeSkippedByStreamsArrivingBeforeMetadata() = runBlocking {
        val metaGate = CountDownLatch(1)
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
        source.search = { _, _, _ -> Result.success(listOf(release())) }
        val transport = Transport().also { it.beforeLoad = { input -> if (input.getJSONObject("request").getString("resource") == "meta") {
            check(metaGate.await(3, TimeUnit.SECONDS))
        } } }
        open(transport).use { session ->
            val updates = Channel<com.vortx.android.data.StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = async(Dispatchers.Default) {
                repository(source) { session }.streamUpdates(MediaType.SERIES, "tt123456", "tt123456:1:2").collect { updates.send(it) }
            }
            try {
                val preMetadata = withTimeout(1_000) { updates.receive() }
                assertEquals(listOf("addon.invalid"), preMetadata.groups.map(StreamGroup::addon))
                assertFalse("Configured contributor is pending even before its metadata admission", preMetadata.selectionReady)
                assertFalse(preMetadata.terminal); assertEquals(0, source.calls.get())
                metaGate.countDown(); withTimeout(2_000) { pending.await() }
                val remaining = generateSequence { updates.tryReceive().getOrNull() }.toList()
                assertEquals(1, remaining.count { it.terminal })
                assertEquals(listOf("addon.invalid", "direct"), remaining.last().groups.map(StreamGroup::addon))
                assertEquals(1, source.calls.get())
            } finally { metaGate.countDown(); pending.cancelAndJoin(); updates.close() }
        }
    }

    @Test fun emptyAndDisabledConfigurationsKeepFastPathAndLateEnableNeedsFreshRequest() = runBlocking {
        for (initial in listOf(emptyList(), listOf(config("disabled", enabled = false)))) {
            val metaGate = CountDownLatch(1)
            val source = ConfigSource(account).also { it.configs = initial }
            source.search = { _, _, _ -> Result.success(listOf(release())) }
            val transport = Transport().also { it.beforeLoad = { input -> if (input.getJSONObject("request").getString("resource") == "meta") {
                check(metaGate.await(3, TimeUnit.SECONDS))
            } } }
            open(transport).use { session ->
                val repo = repository(source) { session }
                val updates = Channel<com.vortx.android.data.StreamLoadUpdate>(Channel.UNLIMITED)
                val pending = async(Dispatchers.Default) {
                    repo.streamUpdates(MediaType.SERIES, "tt123456", "tt123456:1:2").collect { updates.send(it) }
                }
                try {
                    val early = withTimeout(1_000) { updates.receive() }
                    assertTrue("No configured participant must retain stream-settled fast selection", early.selectionReady)
                    assertFalse(early.terminal); assertEquals(listOf("addon.invalid"), early.groups.map(StreamGroup::addon))
                    source.configs = listOf(config("direct")); source.revision++
                    metaGate.countDown(); withTimeout(2_000) { pending.await() }
                    assertEquals(0, source.calls.get())
                    assertTrue(generateSequence { updates.tryReceive().getOrNull() }.all { update -> update.groups.none { it.addon == "direct" } })
                    val fresh = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2", forceRefresh = true).getOrThrow()
                    assertEquals(listOf("addon.invalid", "direct"), fresh.map(StreamGroup::addon)); assertEquals(1, source.calls.get())
                } finally { metaGate.countDown(); pending.cancelAndJoin(); updates.close() }
            }
        }
    }

    @Test fun blockedCurrentMetadataCannotLaunchFromSameOwnerWarmCache() = runBlocking {
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
        source.search = { _, _, _ -> Result.success(listOf(release())) }
        val runtime = Runtime(kids = true)
        val transport = Transport()
        VortxNativeSession.open(scope, "Owner", runtime, Store(), transport, true).use { session ->
            val repo = repository(source) { session }
            repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").getOrThrow()
            assertEquals(1, source.calls.get()); source.calls.set(0)
            runtime.blockedMeta = true
            val gate = CountDownLatch(1)
            transport.beforeLoad = { input -> if (input.getJSONObject("request").getString("resource") == "meta") {
                check(gate.await(3, TimeUnit.SECONDS))
            } }
            val updates = Channel<com.vortx.android.data.StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = async(Dispatchers.Default) { runCatching {
                repo.streamUpdates(MediaType.SERIES, "tt123456", "tt123456:1:2").collect { updates.send(it) }
            } }
            try {
                withTimeout(1_000) { updates.receive() }
                assertEquals("Pending parental metadata must not authorize from cache", 0, source.calls.get())
                gate.countDown()
                assertTrue(withTimeout(2_000) { pending.await() }.isFailure)
                assertEquals(0, source.calls.get())
                assertTrue(generateSequence { updates.tryReceive().getOrNull() }.all { update -> update.groups.none { it.addon == "direct" } })
            } finally { gate.countDown(); pending.cancelAndJoin(); updates.close() }
        }
    }

    @Test fun capturedNullScopeNeverRetargetsWhenProfileBecomesAvailableDuringMetadata() = runBlocking {
        val source = ConfigSource(account).also { it.profile = null; it.configs = listOf(config("direct")) }
        val transport = Transport().also { it.beforeLoad = { source.profile = "owner" } }
        open(transport).use { session ->
            assertEquals(listOf("addon.invalid"), repository(source) { session }.streams(MediaType.SERIES, "tt123456", "tt123456:1:2")
                .getOrThrow().map(StreamGroup::addon))
            assertEquals(0, source.calls.get())
        }
    }

    @Test fun callerCancellationRetiresIndexerAndPendingNativeBridgesWithoutTerminal() = runBlocking {
        val entered = CompletableDeferred<Unit>(); val retired = CompletableDeferred<Unit>()
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
        source.search = { _, _, _ -> entered.complete(Unit); try { awaitCancellation() } finally { retired.complete(Unit) } }
        val gate = CountDownLatch(1)
        val transport = Transport().also { it.beforeLoad = { input -> if (input.getJSONObject("request").getString("resource") == "stream") {
            check(gate.await(3, TimeUnit.SECONDS))
        } } }
        open(transport).use { session ->
            val terminals = AtomicInteger()
            val pending = async(Dispatchers.Default) {
                repository(source) { session }.streamUpdates(MediaType.SERIES, "tt123456", "tt123456:1:2").collect {
                    if (it.terminal) terminals.incrementAndGet()
                }
            }
            try {
                withTimeout(1_000) { entered.await() }
                val cancellations = transport.cancelCalls.get()
                withTimeout(1_000) { pending.cancelAndJoin(); retired.await() }
                assertTrue(pending.isCancelled); assertEquals(0, terminals.get())
                assertTrue("Pending provider bridge must be cancelled", transport.cancelCalls.get() > cancellations)
            } finally { gate.countDown(); pending.cancelAndJoin() }
        }
    }

    @Test fun independentIndexerCancellationTerminatesInsteadOfStrandingCoordinator() = runBlocking {
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
        source.search = { _, _, _ -> throw CancellationException("Synthetic contributor cancellation") }
        open().use { session ->
            val terminals = AtomicInteger()
            val pending = async(Dispatchers.Default) {
                repository(source) { session }.streamUpdates(MediaType.SERIES, "tt123456", "tt123456:1:2").collect {
                    if (it.terminal) terminals.incrementAndGet()
                }
            }
            try {
                try { withTimeout(1_000) { pending.await() }; fail("Contributor cancellation must propagate") }
                catch (cancelled: CancellationException) {
                    assertFalse("Cancellation must not be an unreported contributor timeout", cancelled is kotlinx.coroutines.TimeoutCancellationException)
                }
                assertTrue(pending.isCancelled); assertEquals(0, terminals.get()); assertEquals(1, source.calls.get())
            } finally { pending.cancelAndJoin() }
        }
    }

    @Test fun ownerProfileAndAccountABARetireOldIndexerBeforePublishingReplacementBindings() = runBlocking {
        for (transition in listOf("profile", "account")) {
            val entered = CompletableDeferred<Unit>(); val unblock = CompletableDeferred<Unit>()
            val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
            source.search = { _, _, _ ->
                if (source.calls.get() == 1) { entered.complete(Unit); withContext(NonCancellable) { unblock.await() } }
                Result.success(listOf(release()))
            }
            open().use { first -> open().use { second -> open().use { replacement ->
                var mounted = first
                val repo = repository(source) { mounted }
                val stale = async(Dispatchers.Default) { repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2") }
                try {
                    withTimeout(1_000) { entered.await() }
                    if (transition == "profile") {
                        first.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest")))
                        source.profile = "guest"
                        first.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "owner")))
                        source.profile = "owner"
                    } else {
                        mounted = second; source.owner = DebridOwnerToken(DebridOwnerScope.Account("other"), 2)
                        mounted = replacement; source.owner = DebridOwnerToken(DebridOwnerScope.Account(account), 3)
                        first.close()
                    }
                    unblock.complete(Unit)
                    assertTrue("Old $transition A→B→A request must fail", withTimeout(2_000) { stale.await() }.isFailure)
                    val fresh = repo.streams(MediaType.SERIES, "tt123456", "tt123456:1:2").getOrThrow().last().streams.single()
                    assertTrue(repo.resolve(fresh).isSuccess)
                } finally { unblock.complete(Unit); stale.cancelAndJoin() }
            } } }
        }
    }

    @Test fun restoredConfigurationWithNewRevisionCannotAdmitOldIndexerResult() = runBlocking {
        val entered = CompletableDeferred<Unit>(); val unblock = CompletableDeferred<Unit>()
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
        source.search = { _, _, _ -> entered.complete(Unit); unblock.await(); Result.success(listOf(release())) }
        open().use { session ->
            val pending = async(Dispatchers.Default) { repository(source) { session }.streams(MediaType.SERIES, "tt123456", "tt123456:1:2") }
            try {
                withTimeout(1_000) { entered.await() }
                val original = source.configs
                source.configs = listOf(config("other")); source.revision++
                source.configs = original; source.revision++
                unblock.complete(Unit)
                assertEquals(listOf("addon.invalid"), withTimeout(2_000) { pending.await() }.getOrThrow().map(StreamGroup::addon))
                assertEquals(1, source.calls.get())
            } finally { unblock.complete(Unit); pending.cancelAndJoin() }
        }
    }

    @Test fun blockedFirstMetadataWaitsForLaterApprovedExactEpisode() = runBlocking {
        val metaGate = CountDownLatch(1); val streamGate = CountDownLatch(1)
        val source = ConfigSource(account).also { it.configs = listOf(config("direct")) }
        source.search = { _, _, query ->
            assertEquals("Fixture", query.title); assertEquals(1, query.season); assertEquals(2, query.episode)
            Result.success(listOf(release()))
        }
        val transport = Transport().also {
            it.beforeLoad = { input ->
                val resource = input.getJSONObject("request").getString("resource")
                val addon = input.getJSONArray("addons").getJSONObject(0).getString("id")
                if (resource == "stream") check(streamGate.await(3, TimeUnit.SECONDS))
                else if ("peer" in addon) check(metaGate.await(3, TimeUnit.SECONDS))
            }
            it.contentOverride = { request, addon ->
                if (request.getString("resource") == "meta" && "peer" !in addon) JSONObject().put("meta", JSONObject()
                    .put("id", request.getString("id")).put("type", request.getString("type")).put("name", "Blocked")) else null
            }
        }
        open(transport, kids = true, addonCount = 2).use { session ->
            val updates = Channel<com.vortx.android.data.StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = async(Dispatchers.Default) {
                repository(source) { session }.streamUpdates(MediaType.SERIES, "tt123456", "tt123456:1:2").collect { updates.send(it) }
            }
            try {
                val blocked = withTimeout(1_000) { updates.receive() }
                assertTrue(blocked.groups.isEmpty()); assertEquals(0, source.calls.get())
                metaGate.countDown()
                val approved = withTimeout(1_000) {
                    var update = updates.receive()
                    while (update.groups.none { it.addon == "direct" }) update = updates.receive()
                    update
                }
                assertFalse(approved.terminal); assertEquals(1, source.calls.get())
                streamGate.countDown(); withTimeout(2_000) { pending.await() }
                assertEquals(1, generateSequence { updates.tryReceive().getOrNull() }.count { it.terminal })
            } finally { metaGate.countDown(); streamGate.countDown(); pending.cancelAndJoin(); updates.close() }
        }
    }

    @Test fun malformedMetadataPeerCannotDiscardFastIndexerOrFinalRegistryOrder() = runBlocking {
        val gate = CountDownLatch(1)
        val source = ConfigSource(account).also { it.configs = listOf(config("first"), config("failed"), config("last")) }
        source.search = { config, _, _ ->
            if (config.id == "failed") Result.failure(IllegalStateException("Synthetic failed indexer"))
            else Result.success(listOf(release(config.name)))
        }
        val transport = Transport().also {
            it.beforeLoad = { input -> if (input.getJSONObject("request").getString("resource") == "stream") {
                check(gate.await(3, TimeUnit.SECONDS))
            } }
            it.contentOverride = { request, addon ->
                if (request.getString("resource") == "meta" && "peer" in addon) JSONObject().put("meta", JSONObject()
                    .put("id", "wrong-title").put("type", "series").put("name", "Malformed")) else null
            }
        }
        open(transport, addonCount = 2).use { session ->
            val updates = Channel<com.vortx.android.data.StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = async(Dispatchers.Default) {
                repository(source) { session }.streamUpdates(MediaType.SERIES, "tt123456", "tt123456:1:2").collect { updates.send(it) }
            }
            try {
                val early = withTimeout(1_000) {
                    var update = updates.receive()
                    while (update.groups.none { it.addon == "last" }) update = updates.receive()
                    update
                }
                assertEquals(listOf("first", "last"), early.groups.map(StreamGroup::addon)); assertFalse(early.terminal)
                gate.countDown(); withTimeout(2_000) { pending.await() }
                val final = generateSequence { updates.tryReceive().getOrNull() }.last()
                assertTrue(final.terminal)
                assertEquals(listOf("addon.invalid", "peer1.invalid", "first", "last"), final.groups.map(StreamGroup::addon))
                assertEquals(3, source.calls.get())
            } finally { gate.countDown(); pending.cancelAndJoin(); updates.close() }
        }
    }

    @Test fun auxiliaryPublicationDefersOnlyEvolvingReceiptNotReplacedSlot() = runBlocking {
        open(addonCount = 2).use { session ->
            val owner = session.read().owner
            val request = VortxResourceRequest(VortxResourceRequest.Resource.META, "series", "tt123456")
            val legs = listOf("addon", "peer1").map { name -> NativeProviderLeg(request,
                VortxResourceAddon("https://$name.invalid/manifest.json", "https://$name.invalid/manifest.json")) }
            val receipts = mutableListOf<Pair<NativeProviderUpdate, java.util.UUID>>()
            session.loadProviders("streams", owner, legs) { update, ticket -> receipts += update to ticket }
            val (older, ticket) = receipts.first(); val latest = receipts.last().first
            assertNull(session.publishIfLatestReceipt("streams", owner, older.pages, ticket) { "outdated" })
            assertEquals("latest", session.publishIfLatestReceipt("streams", owner, latest.pages, ticket) { "latest" })
            session.loadProviders("streams", owner, emptyList()) { _, _ -> }
            assertTrue(runCatching { session.publishIfLatestReceipt("streams", owner, latest.pages, ticket) { "replaced" } }.isFailure)
        }
    }

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
