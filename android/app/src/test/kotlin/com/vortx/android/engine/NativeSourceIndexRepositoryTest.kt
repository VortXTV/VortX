package com.vortx.android.engine

import com.vortx.android.data.StreamLoadUpdate
import com.vortx.android.model.*
import com.vortx.android.singularity.SourceIndexAuthorization
import com.vortx.android.singularity.SourceIndexClient
import com.vortx.android.singularity.SourceIndexLifecycle
import com.vortx.android.sources.SourceRequestFence
import com.vortx.android.ui.viewmodel.SourceIndexPublicationBridge
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CompletableJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ThreadContextElement
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/**
 * Source-only candidate tests, UNRUN. Real repository, source participant, native-session ownership and
 * resource envelopes; only runtime bindings, provider replies, authorization facts and resolver are fake.
 * These fixtures neither open a URL nor construct JNI, the legacy engine or a platform player.
 */
class NativeSourceIndexRepositoryTest {
    private val account = VortxAccountScope("account.00000000-0000-0000-0000-000000000001", "owner")
    private val episode = Episode("tt123456:1:2", "Second", 1, 2)
    private val defaultAddons = listOf("https://addon.invalid/manifest.json")
    private fun hash(index: Int) = (index + 1).toString(16).padStart(40, '0')
    private fun pooled(index: Int = 0) = SourceIndexClient.PooledSource("torrent", hash(index), "1080p", 1024L, 4, 3)
    private fun List<StreamGroup>.pool() = single { it.base == SourceIndexClient.GROUP_ID }.streams
    private fun List<StreamGroup>.ordinary() = filter { it.base != SourceIndexClient.GROUP_ID }.flatMap { it.streams }

    private class Store : VortxCheckpointStore {
        private var snapshot: String? = null
        override fun read(scope: VortxAccountScope) = snapshot
        override fun commit(scope: VortxAccountScope, snapshot: String) { this.snapshot = snapshot }
    }

    // Same fake full-checkpoint contract as NativeNzbSourcesTest, including real session owner changes.
    private class Runtime(private val addons: List<String>, private val kids: Boolean = false) : VortxRuntimeBindings {
        @Volatile var blockedMeta = false
        private var sequence = 0L
        private val states = mutableMapOf<Long, JSONObject>()
        private fun profile(id: String, owner: Boolean) = JSONObject().put("id", id).put("name", id)
            .put("owner", owner).put("deleted", false).put("addons", "share_primary")
            .put("account", JSONObject().put("kind", "local_only"))
            .put("parental", JSONObject().put("kids", kids)).put("settings", JSONObject().put("disabledAddons", JSONArray()))
        private fun library() = JSONObject().put("items", JSONArray()).put("history", JSONArray())
            .put("resume", JSONObject()).put("watched", JSONObject()).put("cwBoard", JSONArray())
        override fun create(ownerId: String, ownerName: String) = hydrate(JSONObject()
            .put("roster", JSONObject().put("profiles", JSONObject().put(ownerId, profile(ownerId, true)).put("guest", profile("guest", false))))
            .put("activeProfileId", ownerId).put("libraries", JSONObject().put(ownerId, library()).put("guest", library())).toString())
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
                    .put("addons", JSONArray().also { array -> addons.forEach { url -> array.put(JSONObject()
                        .put("transportUrl", url).put("manifest", JSONObject().put("id", "same-manifest-id").put("name", "Fixture")
                            .put("catalogs", JSONArray()).put("resources", JSONArray(listOf("meta", "stream"))))) } }).toString()
                "resume_point" -> JSONObject().put("kind", "resume_point").put("resume", JSONObject.NULL).toString()
                "meta" -> JSONObject().put("kind", "meta").put("meta", if (blockedMeta) JSONObject.NULL else input.get("meta")).toString()
                else -> "{\"kind\":\"error\"}"
            }
        }
    }

    private class Transport : VortxResourceTransport {
        @Volatile var beforeLoad: (JSONObject) -> Unit = {}
        @Volatile var contentOverride: (JSONObject, String) -> JSONObject? = { _, _ -> null }
        val streamCalls = AtomicInteger()
        val streamReturns = AtomicInteger()
        val cancelCalls = AtomicInteger()
        override fun makeCancellation() = object : VortxResourceCancellation {
            override fun cancel() { cancelCalls.incrementAndGet() }
            override fun close() {}
        }
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
            val input = JSONObject(requestJson); val request = input.getJSONObject("request")
            val stream = request.getString("resource") == "stream"
            if (stream) streamCalls.incrementAndGet()
            beforeLoad(input)
            val addon = input.getJSONArray("addons").getJSONObject(0).getString("id")
            val content = contentOverride(request, addon) ?: if (stream) JSONObject().put("streams", JSONArray().put(JSONObject()
                .put("url", "https://video.invalid/${addon.hashCode()}.mp4").put("name", "Ordinary source")))
            else JSONObject().put("meta", JSONObject().put("id", request.getString("id")).put("type", request.getString("type"))
                .put("name", "Fixture").put("videos", JSONArray().put(JSONObject().put("id", "tt123456:1:2")
                    .put("season", 1).put("episode", 2).put("title", "Second"))))
            if (stream) streamReturns.incrementAndGet()
            return JSONObject().put("kind", "resource_result").put("requestId", input.getString("requestId"))
                .put("generation", input.getLong("generation")).put("request", request).put("cancelled", false)
                .put("groups", JSONArray().put(JSONObject().put("addonId", addon).put("status", "ready").put("content", content))).toString()
        }
    }

    private fun open(transport: Transport = Transport(), runtime: Runtime = Runtime(defaultAddons)) =
        VortxNativeSession.open(account, "Owner", runtime, Store(), transport, true)

    private class PoolFixture(
        mounted: () -> VortxNativeSession,
        private val fetch: suspend (String, SourceIndexAuthorization) -> List<SourceIndexClient.PooledSource>,
        private val moat: String? = "synthetic-moat",
        contribute: suspend (String, List<SourceIndexClient.Descriptor>, SourceIndexAuthorization) -> Unit = { _, _, _ -> },
        scopeContext: CoroutineContext = EmptyCoroutineContext,
        onAuthorization: (SourceIndexAuthorization) -> Unit = {},
    ) : AutoCloseable {
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + scopeContext)
        val authorizations = CopyOnWriteArrayList<SourceIndexAuthorization>()
        @Volatile private var optedIn = true
        val queries = CopyOnWriteArrayList<String>()
        val source = NativeSourceIndexSource(scope, captureAuthorization = { session, owner ->
            SourceIndexLifecycle.issue(
                isCurrent = { optedIn && mounted() === session && session.accepts(owner) },
                moatProvider = { moat },
            )?.also { authorization ->
                authorizations += authorization
                onAuthorization(authorization)
            }
        }, fetch = { id, authorization -> queries += id; fetch(id, authorization) }, contribute = contribute)

        fun optOut() { optedIn = false; SourceIndexLifecycle.invalidate() }
        override fun close() { authorizations.forEach(SourceIndexAuthorization::close); scope.cancel() }
    }

    /** The first fake contribute and the subsequent empty-pending loop never suspend. Restoring that
     * exact worker's thread context therefore observes its body exit, even while an attached child keeps
     * the Job active. It avoids a timing delay or parsing private coroutine state for the trailing race. */
    private class WorkerBodyExitProbe : ThreadContextElement<Unit>, AbstractCoroutineContextElement(Key) {
        companion object Key : CoroutineContext.Key<WorkerBodyExitProbe>
        val worker = AtomicReference<Job?>(null)
        val contributeReturned = AtomicBoolean(false)
        val bodyExited = CompletableDeferred<Unit>()
        override fun updateThreadContext(context: CoroutineContext) = Unit
        override fun restoreThreadContext(context: CoroutineContext, oldState: Unit) {
            if (context[Job] === worker.get() && contributeReturned.get()) bodyExited.complete(Unit)
        }
    }

    private fun repository(pool: PoolFixture?, mounted: () -> VortxNativeSession,
        resolved: MutableList<StreamSource> = CopyOnWriteArrayList()) = NativeCatalogRepository(
        playbackResolver = NativePlaybackResolver { source, _ ->
            resolved += source
            Playable(source.url ?: "https://resolved.invalid/${requireNotNull(source.infoHash)}", "Fixture")
        }, sourceIndexSource = pool?.source, sessionProvider = mounted,
    )

    private suspend fun Channel<StreamLoadUpdate>.until(predicate: (StreamLoadUpdate) -> Boolean): StreamLoadUpdate = withTimeout(2_000) {
        var update = receive()
        while (!predicate(update)) update = receive()
        update
    }

    @Test fun externalPoolRowsWithoutPrivateRepositoryBindingCannotResolve() = runBlocking {
        open().use { session ->
            val resolved = CopyOnWriteArrayList<StreamSource>()
            val repo = repository(null, { session }, resolved)
            repo.streams(MediaType.SERIES, "tt123456", episode.id).getOrThrow()
            val external = SourceIndexClient.streams(listOf(pooled())).single()
            assertNull(external.nativePlaybackToken)
            assertTrue(repo.resolve(external, episode).isFailure)
            assertTrue(repo.resolve(external.copy(nativePlaybackToken = UUID.randomUUID().toString()), episode).isFailure)
            assertTrue(resolved.isEmpty())
        }
    }

    @Test fun authorizedParticipantPublishesBoundPoolBeforeOrdinaryProviderSettles() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val gate = CountDownLatch(1)
        val poolEntered = CompletableDeferred<Unit>(); val poolRelease = CompletableDeferred<Unit>()
        val lateAddon = "https://late.invalid/manifest.json"
        val transport = Transport().also { it.beforeLoad = { input ->
            if (input.getJSONObject("request").getString("resource") == "stream" &&
                input.getJSONArray("addons").getJSONObject(0).getString("id") == lateAddon) check(gate.await(3, TimeUnit.SECONDS))
        } }
        open(transport, Runtime(defaultAddons + lateAddon)).use { session -> PoolFixture({ session }, { _, _ ->
            poolEntered.complete(Unit); poolRelease.await(); listOf(pooled())
        }).use { pool ->
            val resolved = CopyOnWriteArrayList<StreamSource>(); val repo = repository(pool, { session }, resolved)
            val bridge = SourceIndexPublicationBridge(repo::isSourcePoolPublicationCurrent)
            val request = SourceRequestFence("owner").begin("owner", episode.id)
            val updates = Channel<StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = async(Dispatchers.Default) { repo.streamUpdates(MediaType.SERIES, "tt123456", episode.id).collect { updates.send(it) } }
            try {
                val ordinary = updates.until { it.groups.ordinary().isNotEmpty() && it.groups.none { group -> group.base == SourceIndexClient.GROUP_ID } }
                withTimeout(2_000) { poolEntered.await() }
                val publication = requireNotNull(ordinary.sourcePublicationId)
                assertFalse(poolRelease.isCompleted)
                assertTrue(repo.isSourcePoolPublicationCurrent(publication))
                assertEquals(ordinary.groups, bridge.accept(request, publication, ordinary.groups))
                assertFalse(bridge.isRevoked(request))
                poolRelease.complete(Unit)
                val early = updates.until { it.groups.any { group -> group.base == SourceIndexClient.GROUP_ID } }
                assertFalse(early.terminal); assertTrue(early.loaded < early.total)
                assertEquals(publication, early.sourcePublicationId)
                val visible = bridge.accept(request, early.sourcePublicationId, early.groups)
                assertEquals(early.groups.pool().single().nativePlaybackToken, visible.pool().single().nativePlaybackToken)
                assertFalse(bridge.isRevoked(request))
                assertEquals(listOf("tt123456:1:2"), pool.queries)
                val source = early.groups.pool().single(); assertNotNull(source.nativePlaybackToken)
                UUID.fromString(source.nativePlaybackToken)
                val playable = repo.resolve(source, episode).getOrThrow()
                assertEquals(hash(0), resolved.single().infoHash)
                assertEquals("https://resolved.invalid/${hash(0)}", playable.url)
                val playbackContext = requireNotNull(playable.playbackContext)
                assertEquals("tt123456", playbackContext.contentId)
                assertEquals(episode.id, playbackContext.videoId)
                assertEquals(1, playbackContext.season); assertEquals(2, playbackContext.episode)
                gate.countDown(); withTimeout(2_000) { pending.await() }
                val terminal = updates.until { it.terminal }
                assertEquals(source.nativePlaybackToken, terminal.groups.pool().single().nativePlaybackToken)
                bridge.accept(request, terminal.sourcePublicationId, terminal.groups)
                pool.optOut()
                assertFalse(repo.isSourcePoolPublicationCurrent(publication))
                assertFalse(requireNotNull(bridge.currentGroups(request)).any { it.base == SourceIndexClient.GROUP_ID })
                assertTrue(repo.resolve(source, episode).isFailure)
            } finally { poolRelease.complete(Unit); gate.countDown(); pending.cancelAndJoin(); updates.close() }
        } }
    }

    @Test fun all257CanonicalRowsGetPrivateBindingsAndCopiedHashCannotReuseOne() = runBlocking {
        SourceIndexLifecycle.invalidate()
        open().use { session -> PoolFixture({ session }, { _, _ -> (0 until 257).map(::pooled) }).use { pool ->
            val resolved = CopyOnWriteArrayList<StreamSource>(); val repo = repository(pool, { session }, resolved)
            val sources = repo.streams(MediaType.SERIES, "tt123456", episode.id).getOrThrow().pool()
            assertEquals(257, sources.size)
            assertEquals((0 until 257).map(::hash), sources.map { it.infoHash })
            assertEquals(257, sources.mapNotNull { it.nativePlaybackToken }.toSet().size)
            for (source in sources) assertTrue(repo.resolve(source, episode).isSuccess)
            assertEquals((0 until 257).map(::hash), resolved.map { it.infoHash })
            val admitted = sources.first()
            for (copy in listOf(admitted.copy(infoHash = hash(999)), admitted.copy(fileIdx = 3),
                admitted.copy(url = "https://forged.invalid/video"), admitted.copy(nzbUrl = "https://forged.invalid/nzb"),
                admitted.copy(addon = "Another provider"))) {
                assertTrue(repo.resolve(copy, episode).isFailure)
            }
            assertEquals(257, resolved.size)
            assertTrue(repo.resolve(admitted.copy(title = "UI title", description = "UI description", quality = "4K",
                accountConfirmedCacheRevision = 123L), episode).isSuccess)
            assertEquals(hash(0), resolved.last().infoHash)
        } }
    }

    @Test fun optOutStripsPoolBindingWithoutCancelingBlockedOrdinaryProvider() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val gate = CountDownLatch(1); val streamEntered = CountDownLatch(1)
        val blockedAddon = "https://peer.invalid/manifest.json"
        val transport = Transport().also { it.beforeLoad = { input ->
            if (input.getJSONObject("request").getString("resource") == "stream" &&
                input.getJSONArray("addons").getJSONObject(0).getString("id") == blockedAddon) {
                streamEntered.countDown(); check(gate.await(3, TimeUnit.SECONDS))
            }
        } }
        open(transport, Runtime(defaultAddons + blockedAddon)).use { session -> PoolFixture({ session }, { _, _ -> listOf(pooled()) }).use { pool ->
            val repo = repository(pool, { session }); val updates = Channel<StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = async(Dispatchers.Default) { repo.streamUpdates(MediaType.SERIES, "tt123456", episode.id).collect { updates.send(it) } }
            try {
                val early = updates.until { it.groups.any { group -> group.base == SourceIndexClient.GROUP_ID } && it.groups.ordinary().isNotEmpty() }
                assertTrue(streamEntered.await(2, TimeUnit.SECONDS))
                val oldPool = early.groups.pool().single(); val ordinary = early.groups.ordinary().single()
                val cancels = transport.cancelCalls.get()
                pool.optOut()
                assertEquals(early.sourcePublicationId, withTimeout(2_000) { repo.sourceInvalidations().first() })
                assertTrue(repo.resolve(oldPool, episode).isFailure)
                assertTrue(repo.resolve(ordinary, episode).isSuccess)
                assertTrue(pending.isActive); assertEquals(1, transport.streamReturns.get())
                assertEquals(cancels, transport.cancelCalls.get())
                gate.countDown(); withTimeout(2_000) { pending.await() }
                val terminal = updates.until { it.terminal }
                assertFalse(terminal.groups.any { it.base == SourceIndexClient.GROUP_ID })
                assertEquals(2, terminal.groups.ordinary().size)
                assertTrue(terminal.groups.ordinary().any { it.nativePlaybackToken == ordinary.nativePlaybackToken })
                terminal.groups.ordinary().forEach { assertTrue(repo.resolve(it, episode).isSuccess) }
            } finally { gate.countDown(); pending.cancelAndJoin(); updates.close() }
        } }
    }

    @Test fun terminalContextRetainsOpaqueInvalidationReplayAndOrdinaryToken() = runBlocking {
        SourceIndexLifecycle.invalidate()
        open().use { session -> PoolFixture({ session }, { _, _ -> listOf(pooled()) }).use { pool ->
            val repo = repository(pool, { session }); val updates = mutableListOf<StreamLoadUpdate>()
            repo.streamUpdates(MediaType.SERIES, "tt123456", episode.id).collect { updates += it }
            val terminal = updates.last(); assertTrue(terminal.terminal)
            val pooled = terminal.groups.pool().single(); val ordinary = terminal.groups.ordinary().single()
            val publication = requireNotNull(terminal.sourcePublicationId)
            UUID.fromString(publication); assertNotEquals(pooled.nativePlaybackToken, publication)
            pool.optOut()
            assertEquals(publication, withTimeout(2_000) { repo.sourceInvalidations().first() })
            // Subscribe again after the first callback has completed: finite loading has no collector now.
            assertEquals(publication, withTimeout(2_000) { repo.sourceInvalidations().first() })
            assertTrue(repo.resolve(pooled, episode).isFailure)
            assertTrue(repo.resolve(ordinary, episode).isSuccess)
        } }
    }

    @Test fun revokingSuspendedAuthorizedQueryCancelsOnlyPoolParticipant() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val gate = CountDownLatch(1); val streamEntered = CountDownLatch(1)
        val entered = CompletableDeferred<Unit>(); val stopped = CompletableDeferred<Unit>()
        val transport = Transport().also { it.beforeLoad = { input ->
            if (input.getJSONObject("request").getString("resource") == "stream") {
                streamEntered.countDown(); check(gate.await(3, TimeUnit.SECONDS))
            }
        } }
        open(transport).use { session -> PoolFixture({ session }, { id, authorization ->
            SourceIndexClient.fetchPooledAuthorizedUsing(id, authorization, nowNanos = { 0L }, page = { _, _, _, _ ->
                entered.complete(Unit)
                try { awaitCancellation() } finally { stopped.complete(Unit) }
            })
        }).use { pool ->
            val repo = repository(pool, { session }); val updates = Channel<StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = async(Dispatchers.Default) { repo.streamUpdates(MediaType.SERIES, "tt123456", episode.id).collect { updates.send(it) } }
            try {
                withTimeout(2_000) { entered.await() }; assertTrue(streamEntered.await(2, TimeUnit.SECONDS))
                val cancels = transport.cancelCalls.get()
                pool.optOut(); withTimeout(2_000) { stopped.await() }
                withTimeout(2_000) { repo.sourceInvalidations().first() }
                assertTrue(pending.isActive); assertEquals(cancels, transport.cancelCalls.get())
                gate.countDown(); withTimeout(2_000) { pending.await() }
                val terminal = updates.until { it.terminal }
                assertEquals(1, pool.queries.size)
                assertFalse(terminal.groups.any { it.base == SourceIndexClient.GROUP_ID })
                assertTrue(repo.resolve(terminal.groups.ordinary().single(), episode).isSuccess)
            } finally { gate.countDown(); pending.cancelAndJoin(); updates.close() }
        } }
    }

    @Test fun poolAwaiterCancellationRunsOutsideRepositoryAndSessionMonitors() = runBlocking {
        for (retireDuringPublication in listOf(false, true)) {
            SourceIndexLifecycle.invalidate()
            val metadataGate = CountDownLatch(1); val streamGate = CountDownLatch(1)
            val streamEntered = CountDownLatch(1)
            val queryEntered = CompletableDeferred<Unit>()
            val monitors = Channel<Pair<Boolean, Boolean>>(Channel.UNLIMITED)
            val primary = defaultAddons.single(); val peer = "https://peer.invalid/manifest.json"
            val transport = Transport().also {
                it.beforeLoad = { input ->
                    val resource = input.getJSONObject("request").getString("resource")
                    val addon = input.getJSONArray("addons").getJSONObject(0).getString("id")
                    if (resource == "meta" && addon == primary) check(metadataGate.await(3, TimeUnit.SECONDS))
                    if (resource == "stream" && addon == peer) {
                        streamEntered.countDown(); check(streamGate.await(3, TimeUnit.SECONDS))
                    }
                }
                it.contentOverride = { request, addon ->
                    if (request.getString("resource") != "meta" || addon != primary) null
                    else JSONObject().put("meta", JSONObject().put("id", "tt123456").put("type", "series").put("name", "Changed primary metadata")
                        .put("videos", JSONArray().put(JSONObject().put("id", episode.id).put("season", 9).put("episode", 9).put("title", "Changed coordinates"))))
                }
            }
            open(transport, Runtime(listOf(primary, peer))).use { session ->
                lateinit var repo: NativeCatalogRepository
                PoolFixture({ session }, { _, _ ->
                    suspendCancellableCoroutine<List<SourceIndexClient.PooledSource>> { continuation ->
                        continuation.invokeOnCancellation {
                            monitors.trySend(Thread.holdsLock(repo) to Thread.holdsLock(session))
                        }
                        queryEntered.complete(Unit)
                    }
                }).use { pool ->
                    repo = repository(pool, { session })
                    val original = async(Dispatchers.Default) { runCatching {
                        repo.streamUpdates(MediaType.SERIES, "tt123456", episode.id).collect {}
                    } }
                    try {
                        withTimeout(2_000) { queryEntered.await() }
                        assertTrue(streamEntered.await(2, TimeUnit.SECONDS))
                        assertEquals(listOf("tt123456:1:2"), pool.queries)
                        // Peer metadata admitted the original query. The later primary metadata
                        // changes its target inside real Session publication, without replacing a
                        // provider slot or canceling the shared coordinator through another path.
                        if (retireDuringPublication) metadataGate.countDown() else pool.optOut()
                        val held = withTimeout(2_000) { monitors.receive() }
                        assertFalse("Pool cancellation callback held repository monitor", held.first)
                        assertFalse("Pool cancellation callback held Session monitor", held.second)
                        assertTrue(original.isActive)
                        pool.optOut(); metadataGate.countDown(); streamGate.countDown()
                        withTimeout(2_000) { original.await() }
                    } finally {
                        pool.optOut(); metadataGate.countDown(); streamGate.countDown()
                        original.cancelAndJoin(); monitors.close()
                    }
                }
            }
        }
    }

    @Test fun lateOrdinaryTorrentPartialStartsNewHoardWorkerAfterPriorBodyExited() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val gate = CountDownLatch(1); val lateEntered = CountDownLatch(1)
        val lateAddon = "https://late.invalid/manifest.json"
        val probe = WorkerBodyExitProbe()
        val heldChild = AtomicReference<CompletableJob?>(null)
        val contributions = Channel<List<String>>(Channel.UNLIMITED)
        val calls = AtomicInteger()
        val transport = Transport().also {
            it.beforeLoad = { input ->
                if (input.getJSONObject("request").getString("resource") == "stream" &&
                    input.getJSONArray("addons").getJSONObject(0).getString("id") == lateAddon) {
                    lateEntered.countDown(); check(gate.await(3, TimeUnit.SECONDS))
                }
            }
            it.contentOverride = { request, addon ->
                if (request.getString("resource") != "stream") null else JSONObject().put("streams", JSONArray().put(JSONObject()
                    .put("infoHash", hash(if (addon == lateAddon) 1 else 0)).put("name", "Ordinary torrent")))
            }
        }
        open(transport, Runtime(defaultAddons + lateAddon)).use { session ->
            PoolFixture({ session }, { _, _ -> emptyList() }, contribute = { id, descriptors, _ ->
                assertEquals("tt123456:1:2", id)
                if (calls.incrementAndGet() == 1) {
                    val worker = requireNotNull(currentCoroutineContext()[Job])
                    probe.worker.set(worker)
                    heldChild.set(Job(worker))
                }
                contributions.trySend(descriptors.map { it.id })
                // No suspension follows in this fake. The context probe signals after the real
                // worker consumes its empty pending slot and exits its coroutine body.
                probe.contributeReturned.set(true)
            }, scopeContext = probe).use { pool ->
                val repo = repository(pool, { session })
                val pending = async(Dispatchers.Default) {
                    repo.streamUpdates(MediaType.SERIES, "tt123456", episode.id).collect {}
                }
                try {
                    assertTrue(lateEntered.await(2, TimeUnit.SECONDS))
                    withTimeout(2_000) { probe.bodyExited.await() }
                    val firstWorker = requireNotNull(probe.worker.get())
                    assertTrue(firstWorker.isActive); assertFalse(firstWorker.isCompleted)
                    assertTrue(requireNotNull(heldChild.get()).isActive)
                    assertEquals(listOf(hash(0)), withTimeout(2_000) { contributions.receive() })
                    gate.countDown()
                    val late = withTimeout(2_000) {
                        var emitted = contributions.receive()
                        while (hash(1) !in emitted) emitted = contributions.receive()
                        emitted
                    }
                    assertTrue(hash(0) in late); assertTrue(hash(1) in late)
                    // The original worker is still alive solely because of its unfinished child.
                    // The late hash therefore needed a replacement worker, not its completed loop.
                    assertTrue(firstWorker.isActive); assertFalse(firstWorker.isCompleted)
                    withTimeout(2_000) { pending.await() }
                } finally {
                    gate.countDown(); heldChild.get()?.complete()
                    pending.cancelAndJoin(); contributions.close()
                }
            }
        }
    }

    @Test fun missingMoatMakesNoPageRequestAndDoesNotBlockOrdinarySources() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val pages = AtomicInteger()
        open().use { session -> PoolFixture({ session }, { id, authorization ->
            SourceIndexClient.fetchPooledAuthorizedUsing(id, authorization, nowNanos = { 0L }, page = { _, _, _, _ ->
                pages.incrementAndGet(); error("Missing moat must prevent a page attempt")
            })
        }, moat = null).use { pool ->
            val repo = repository(pool, { session })
            val groups = repo.streams(MediaType.SERIES, "tt123456", episode.id).getOrThrow()
            assertEquals(0, pages.get()); assertFalse(groups.any { it.base == SourceIndexClient.GROUP_ID })
            assertTrue(repo.resolve(groups.ordinary().single(), episode).isSuccess)
        } }
    }

    @Test fun newRequestCannotAuthorizePoolFromSameOwnerCachedMetadata() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val runtime = Runtime(defaultAddons, kids = true); val transport = Transport(); val gate = CountDownLatch(1)
        open(transport, runtime).use { session -> PoolFixture({ session }, { _, _ -> listOf(pooled()) }).use { pool ->
            val repo = repository(pool, { session })
            repo.streams(MediaType.SERIES, "tt123456", episode.id).getOrThrow(); assertEquals(1, pool.queries.size)
            pool.queries.clear(); runtime.blockedMeta = true
            transport.beforeLoad = { input -> if (input.getJSONObject("request").getString("resource") == "meta") check(gate.await(3, TimeUnit.SECONDS)) }
            val updates = Channel<StreamLoadUpdate>(Channel.UNLIMITED)
            val pending = async(Dispatchers.Default) { runCatching {
                repo.streamUpdates(MediaType.SERIES, "tt123456", episode.id).collect { updates.send(it) }
            } }
            try {
                withTimeout(2_000) { updates.receive() }; assertTrue(pool.queries.isEmpty())
                gate.countDown(); withTimeout(2_000) { pending.await() }
                assertTrue(pool.queries.isEmpty())
                assertTrue(generateSequence { updates.tryReceive().getOrNull() }.all { update -> update.groups.none { it.base == SourceIndexClient.GROUP_ID } })
            } finally { gate.countDown(); pending.cancelAndJoin(); updates.close() }
        } }
    }

    @Test fun preparedPoolUsesFreshExactEpisodeAndRejectsMismatchedCoordinates() = runBlocking {
        SourceIndexLifecycle.invalidate()
        open().use { session -> PoolFixture({ session }, { _, _ -> listOf(pooled()) }).use { pool ->
            val repo = repository(pool, { session })
            repo.streams(MediaType.SERIES, "tt123456", episode.id).getOrThrow(); pool.queries.clear()
            val wrong = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", episode.copy(season = 9, episode = 9)))
            try {
                assertTrue(runCatching { wrong.updates().collect {} }.isFailure)
                assertTrue(wrong.groups.isEmpty()); assertTrue(pool.queries.isEmpty()); assertNull(wrong.adopt())
            } finally { wrong.close() }
            val exact = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", episode))
            try {
                exact.updates().collect {}
                assertEquals(listOf("tt123456:1:2"), pool.queries)
                val source = exact.groups.pool().single()
                assertTrue(exact.resolve(source.copy(infoHash = hash(999))).isFailure)
                val context = exact.resolve(source).getOrThrow().playbackContext!!
                assertEquals(episode.id, context.videoId); assertEquals(1, context.season); assertEquals(2, context.episode)
            } finally { exact.close() }
        } }
    }

    @Test fun retiredPreparedPoolIsHiddenBeforeCallbacksAndOnlySelectedPoolRetiresAdoption() = runBlocking {
        for (selectPooled in listOf(false, true)) {
            SourceIndexLifecycle.invalidate()
            val callbackEntered = CountDownLatch(1); val callbackRelease = CountDownLatch(1)
            val callbackFinished = CountDownLatch(1)
            open().use { session ->
                PoolFixture({ session }, { _, _ -> listOf(pooled()) }, onAuthorization = { authorization ->
                    // Registered before capture returns, hence before the real SourceContext observer.
                    authorization.onRevoked {
                        callbackEntered.countDown()
                        try { check(callbackRelease.await(5, TimeUnit.SECONDS)) }
                        finally { callbackFinished.countDown() }
                    }
                }).use { pool ->
                    val repo = repository(pool, { session })
                    val prepared = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", episode))
                    try {
                        prepared.updates().collect {}
                        val pooledSource = prepared.groups.pool().single()
                        val ordinary = prepared.groups.ordinary().single()
                        assertTrue(prepared.resolve(if (selectPooled) pooledSource else ordinary).isSuccess)
                        val authorization = pool.authorizations.single()
                        authorization.closeDeferred()
                        assertTrue(callbackEntered.await(2, TimeUnit.SECONDS))
                        assertTrue(authorization.isRetired())
                        assertEquals(1L, callbackFinished.count)
                        // No invalidation collector or cleanup callback has run. Scalar retirement
                        // must filter the synchronous getter without revoking ordinary bindings.
                        assertFalse(prepared.groups.any { it.base == SourceIndexClient.GROUP_ID })
                        assertEquals(ordinary.nativePlaybackToken, prepared.groups.ordinary().single().nativePlaybackToken)
                        assertTrue(prepared.resolve(pooledSource).isFailure)
                        if (selectPooled) {
                            assertFalse(prepared.isCurrent())
                            assertNull(prepared.adopt())
                        } else {
                            assertTrue(prepared.isCurrent())
                            assertTrue(prepared.resolve(ordinary).isSuccess)
                            val adoption = requireNotNull(prepared.adopt())
                            try {
                                assertFalse(adoption.groups.any { it.base == SourceIndexClient.GROUP_ID })
                                assertEquals(ordinary.nativePlaybackToken, adoption.groups.ordinary().single().nativePlaybackToken)
                                assertTrue(repo.resolve(ordinary, episode).isSuccess)
                                assertEquals(1L, callbackFinished.count)
                            } finally { adoption.rollback() }
                        }
                    } finally {
                        callbackRelease.countDown(); prepared.close()
                        if (callbackEntered.count == 0L) assertTrue(callbackFinished.await(2, TimeUnit.SECONDS))
                    }
                }
            }
        }
    }

    @Test fun preparedAdoptionRetiresOnlyPreviousPoolAfterPublishedCommitAndPreservesRollback() = runBlocking {
        SourceIndexLifecycle.invalidate()
        open().use { session -> PoolFixture({ session }, { _, _ -> listOf(pooled()) }).use { pool ->
            val repo = repository(pool, { session })
            val foreground = repo.streams(MediaType.SERIES, "tt123456", episode.id).getOrThrow().pool().single()
            val foregroundLease = pool.authorizations.single()
            val rejected = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", episode))
            try {
                rejected.updates().collect {}
                val rejectedLease = pool.authorizations[1]
                val source = rejected.groups.pool().single()
                assertTrue(rejected.resolve(source).isSuccess)
                val adoption = requireNotNull(rejected.adopt())
                assertTrue(foregroundLease.isCurrent()); assertTrue(rejectedLease.isCurrent())
                adoption.rollback()
                assertTrue(foregroundLease.isCurrent()); assertTrue(rejectedLease.isRetired())
                assertTrue(repo.resolve(foreground, episode).isSuccess)
            } finally { rejected.close() }

            val approved = requireNotNull(repo.openSourcePreparation(MediaType.SERIES, "tt123456", episode))
            try {
                approved.updates().collect {}
                val incomingLease = pool.authorizations[2]
                val incoming = approved.groups.pool().single()
                assertTrue(approved.resolve(incoming).isSuccess)
                val adoption = requireNotNull(approved.adopt())
                // Adoption remains reversible until the host acknowledges publication.
                assertTrue(foregroundLease.isCurrent()); assertTrue(incomingLease.isCurrent())
                adoption.commitPublished()
                assertTrue(foregroundLease.isRetired()); assertTrue(incomingLease.isCurrent())
                assertTrue(repo.resolve(incoming, episode).isSuccess)
                adoption.commitPublished()
                assertTrue(foregroundLease.isRetired()); assertTrue(incomingLease.isCurrent())
                assertTrue(repo.resolve(incoming, episode).isSuccess)
                assertTrue(adoption.groups.any { it.base == SourceIndexClient.GROUP_ID })
                adoption.rollback()
                assertTrue(incomingLease.isCurrent())
                assertTrue(repo.resolve(incoming, episode).isSuccess)
            } finally { approved.close() }
        } }
    }

    @Test fun profileSwitchAndMountedSessionReplacementRejectCapturedPoolBindings() = runBlocking {
        for (switchProfile in listOf(true, false)) {
            SourceIndexLifecycle.invalidate()
            open().use { first -> open().use { second ->
                var mounted = first
                PoolFixture({ mounted }, { _, _ -> listOf(pooled()) }).use { pool ->
                    val repo = repository(pool, { mounted })
                    val original = repo.streams(MediaType.SERIES, "tt123456", episode.id).getOrThrow().pool().single()
                    if (switchProfile) first.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", "guest"))) else mounted = second
                    assertTrue(repo.resolve(original, episode).isFailure)
                    val replacement = repo.streams(MediaType.SERIES, "tt123456", episode.id).getOrThrow().pool().single()
                    assertNotEquals(original.nativePlaybackToken, replacement.nativePlaybackToken)
                    assertEquals(if (switchProfile) "guest" else "owner", repo.resolve(replacement, episode).getOrThrow().playbackContext!!.owner.profileId)
                    assertTrue(repo.resolve(original, episode).isFailure)
                }
            } }
        }
    }

    @Test fun sameHostIndependentAddonConfigurationsRetainTheirBindingsAfterPoolOptOut() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val addons = listOf("https://addon.invalid/config-one/manifest.json", "https://addon.invalid/config-two/manifest.json")
        open(runtime = Runtime(addons)).use { session -> PoolFixture({ session }, { _, _ -> listOf(pooled()) }).use { pool ->
            val repo = repository(pool, { session })
            val groups = repo.streams(MediaType.SERIES, "tt123456", episode.id).getOrThrow()
            val ordinaryGroups = groups.filter { it.base != SourceIndexClient.GROUP_ID }
            assertEquals(listOf("addon.invalid", "addon.invalid"), ordinaryGroups.map { it.addon })
            assertEquals(addons, ordinaryGroups.map { it.base })
            assertEquals(2, ordinaryGroups.map { it.sourceInstanceId }.toSet().size)
            val ordinary = ordinaryGroups.flatMap { it.streams }
            assertEquals(2, ordinary.mapNotNull { it.nativePlaybackToken }.toSet().size)
            pool.optOut(); withTimeout(2_000) { repo.sourceInvalidations().first() }
            assertTrue(repo.resolve(groups.pool().single(), episode).isFailure)
            ordinary.forEach { assertTrue(repo.resolve(it, episode).isSuccess) }
        } }
    }
}
