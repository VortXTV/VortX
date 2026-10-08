package com.vortx.android.engine

import com.vortx.android.data.DurableWatchReclaimCoordinator
import com.vortx.android.data.DurableWatchedPlaybackReceipt
import com.vortx.android.data.PlayerResourceReleaseGate
import com.vortx.android.downloads.WatchedDownloadReclaimRequest
import com.vortx.android.downloads.DownloadAutoDeleteWatchedAdmission
import com.vortx.android.model.PlaybackContext
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.SessionOwnerSnapshot
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.crypto.KeyGenerator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Counts cleanup callbacks only: never constructs a player or deletes a download. */
class NativeDurableWatchReceiptJniTest {
    private val scope = VortxAccountScope("account.receipt-fixture", "owner")
    private class Store : VortxCheckpointStore {
        var value: String? = null
        var failWrite = false
        var reads = 0
        var failReadAt = Int.MAX_VALUE
        override fun read(scope: VortxAccountScope): String? { reads++; check(reads < failReadAt); return value }
        override fun commit(scope: VortxAccountScope, snapshot: String) { check(!failWrite); value = snapshot }
    }
    private fun bindings(): VortxRuntimeBindings {
        val path = System.getenv("VORTX_JNI_LIBRARY")
        assumeTrue("Reviewed JNI required", System.getenv("VORTX_JNI_SYNC") == "1" && !path.isNullOrBlank())
        System.load(requireNotNull(path))
        return object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
            override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
            override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
        }
    }
    private fun noNetwork() = object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No resources allowed")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network allowed")
    }
    private fun open(store: VortxCheckpointStore) = VortxNativeSession.open(scope, "Owner", bindings(), store, noNetwork(), true)
    private fun repository(session: () -> VortxNativeSession) = NativeCatalogRepository(
        captureReclaimAdmission = { _, _ -> { action -> action() } }, sessionProvider = session)
    private fun context(video: String = "movie", series: Boolean = false) = PlaybackContext(
        PlaybackContext.Owner("owner", true), if (series) "series" else video, video, if (series) "series" else "movie",
        if (series) 1 else null, if (series) 2 else null, "Local fixture", null, PlaybackContext.Provenance(null, null, false, null, null))
    private suspend fun finish(repository: NativeCatalogRepository, context: PlaybackContext = context(), position: Long = 95_000): DurableWatchedPlaybackReceipt? {
        val token = repository.beginPlaybackSession(context, repository.continueWatchingOwner()).getOrThrow()
        return repository.endPlaybackSessionWithDurableWatchReceipt(token, position, 100_000).getOrThrow()
    }

    @Test fun `encrypted native finish receipt waits for actual decoder and lease release`() = runBlocking {
        val directory = Files.createTempDirectory(File("build").toPath(), "native-durable-receipt-").toFile()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val store = VortxEncryptedCheckpointStore(directory) { key }
        try { open(store).use { session ->
            val repository = repository { session }; val captured = context()
            val receipt = requireNotNull(finish(repository, captured))
            var callbacks = 0
            assertFalse(repository.reclaimAfterDurableWatchedPlaybackReceipt(receipt.copy()) { callbacks++; true })
            val coordinator = DurableWatchReclaimCoordinator(WatchedDownloadReclaimRequest.from(captured, "file:///fixture-never-opened"), receipt.owner) { proof, _ ->
                repository.reclaimAfterDurableWatchedPlaybackReceipt(proof) { callbacks++; true }
            }
            val gate = PlayerResourceReleaseGate()
            gate.registerReleaseCallback("fixture") { coordinator.onResourcesReleased() }
            gate.decoderBound(); gate.leaseBound(); coordinator.onDurableWatch(receipt)
            gate.sessionDisposed(); gate.decoderReleased(); assertEquals(0, callbacks)
            gate.leaseReleased(); assertEquals(1, callbacks)
            assertFalse(repository.reclaimAfterDurableWatchedPlaybackReceipt(receipt) { callbacks++; true })
            assertEquals(1, callbacks)
        } } finally { directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }

    @Test fun `partial or zero playback cannot issue receipt from an earlier watched record`() = runBlocking {
        open(Store()).use { session ->
            val repository = repository { session }
            assertNull(finish(repository, position = 20_000))
            assertNotNull(finish(repository))
            assertNull(finish(repository, position = 20_000))
            val token = repository.beginPlaybackSession(context(), repository.continueWatchingOwner()).getOrThrow()
            assertNull(repository.endPlaybackSessionWithDurableWatchReceipt(token, 0, 0).getOrThrow())
        }
    }

    @Test fun `failed checkpoint or fresh readback never authorizes cleanup`() = runBlocking {
        val store = Store()
        open(store).use { session ->
            val repository = repository { session }
            var token = repository.beginPlaybackSession(context(), repository.continueWatchingOwner()).getOrThrow()
            val before = store.value; store.failWrite = true
            assertTrue(repository.endPlaybackSessionWithDurableWatchReceipt(token, 95_000, 100_000).isFailure)
            assertEquals(before, store.value)
            store.failWrite = false
            token = repository.beginPlaybackSession(context(), repository.continueWatchingOwner()).getOrThrow()
            // The dispatch commit/readback succeeds; the independent committed-query read fails.
            store.failReadAt = store.reads + 2
            assertTrue(repository.endPlaybackSessionWithDurableWatchReceipt(token, 95_000, 100_000).isFailure)
            store.failReadAt = Int.MAX_VALUE
            val receipt = requireNotNull(finish(repository))
            store.value = "{}"
            var callbacks = 0
            assertFalse(repository.reclaimAfterDurableWatchedPlaybackReceipt(receipt) { callbacks++; true })
            assertEquals(0, callbacks)
        }
    }

    @Test fun `exact episode unwatch and later rewatch invalidate the original receipt`() = runBlocking {
        open(Store()).use { session ->
            val repository = repository { session }; val episode = context("opaque-episode", true)
            val receipt = requireNotNull(finish(repository, episode))
            var callbacks = 0
            assertFalse(repository.reclaimAfterDurableWatchedPlaybackReceipt(receipt.copy(context = episode.copy(videoId = "foreign"))) { callbacks++; true })
            session.dispatch(listOf(JSONObject("""{"type":"reset_watched","metaId":"series","videoId":"opaque-episode"}""")))
            assertFalse(repository.reclaimAfterDurableWatchedPlaybackReceipt(receipt) { callbacks++; true })
            assertNotNull(finish(repository, episode))
            assertFalse(repository.reclaimAfterDurableWatchedPlaybackReceipt(receipt) { callbacks++; true })
            assertEquals(0, callbacks)
        }
    }

    @Test fun `superseded terminal tokens and same account cold reopen cannot reclaim`() = runBlocking {
        val store = Store(); var mounted: VortxNativeSession? = open(store)
        val repository = repository { requireNotNull(mounted) }
        try {
            val old = repository.beginPlaybackSession(context("old"), repository.continueWatchingOwner()).getOrThrow()
            val current = repository.beginPlaybackSession(context("current"), repository.continueWatchingOwner()).getOrThrow()
            val before = store.value
            assertNull(repository.endPlaybackSessionWithDurableWatchReceipt(old, 99_000, 100_000).getOrThrow())
            assertEquals(before, store.value)
            val receipt = requireNotNull(repository.endPlaybackSessionWithDurableWatchReceipt(current, 95_000, 100_000).getOrThrow())
            mounted!!.close(); mounted = open(store)
            var callbacks = 0
            assertFalse(repository.reclaimAfterDurableWatchedPlaybackReceipt(receipt) { callbacks++; true })
            val fresh = requireNotNull(finish(repository))
            mounted.dispatch(listOf(JSONObject("""{"type":"add_profile","id":"guest","name":"Guest"}"""), JSONObject("""{"type":"switch_profile","id":"guest"}""")))
            assertFalse(repository.reclaimAfterDurableWatchedPlaybackReceipt(fresh) { callbacks++; true })
            assertEquals(0, callbacks)
        } finally { mounted?.close() }
    }

    @Test fun `ordinary progress completion followed by terminal completion issues a fresh receipt`() = runBlocking {
        open(Store()).use { session ->
            val repository = repository { session }
            val token = repository.beginPlaybackSession(context(), repository.continueWatchingOwner()).getOrThrow()
            repository.reportProgress(token, 92_000, 100_000).getOrThrow()
            val receipt = requireNotNull(repository.endPlaybackSessionWithDurableWatchReceipt(token, 95_000, 100_000).getOrThrow())
            assertTrue(repository.reclaimAfterDurableWatchedPlaybackReceipt(receipt) { true })
        }
    }

    private class Auth {
        val lock = Any()
        var owner = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000456", 1)
        var beforeAdmission: (() -> Unit)? = null
        fun current(): SessionOwnerSnapshot.Account = synchronized(lock) { owner }
        fun capture(): ((() -> Boolean) -> Boolean) {
            val captured = current()
            return { action ->
                beforeAdmission?.also { beforeAdmission = null }?.invoke()
                synchronized(lock) { owner == captured && action() }
            }
        }
    }
    private suspend fun mounted(auth: Auth, dispose: MutableList<() -> Unit>): NativeAccountCoordinator {
        val coordinator = NativeAccountCoordinator(bindings(), Store(), ::noNetwork, { auth.current() == it }, { dispose.add(it) }, {})
        val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true)
        val doc = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode()))
            .put("rosterModified", 1).put("library", JSONArray()).put("addons", JSONArray()))
        val account = auth.current()
        assertTrue(coordinator.applyDocument(account, doc) { auth.current() == account })
        return coordinator
    }
    private fun repository(coordinator: NativeAccountCoordinator, auth: Auth,
                           outerAdmission: ((() -> Boolean) -> Boolean) = { it() }) = NativeCatalogRepository(
        captureReclaimAdmission = { session, owner -> captureNativeReclaimAdmission(coordinator, session, owner, auth::current, auth::capture) },
        withReclaimLifecycle = outerAdmission,
        sessionProvider = coordinator::session)

    @Test fun `retirement after preliminary owner check but before atomic admission suppresses callback`() = runBlocking {
        val auth = Auth(); val closes = mutableListOf<() -> Unit>(); val coordinator = mounted(auth, closes)
        try {
            val repository = repository(coordinator, auth)
            val context = context().copy(owner = PlaybackContext.Owner(UserProfile.OWNER_ID, true))
            val receipt = requireNotNull(finish(repository, context)); var callbacks = 0
            auth.beforeAdmission = { synchronized(auth.lock) {
                // Same-account logout/rebind epoch, while the old native close is deliberately queued.
                auth.owner = auth.owner.copy(generation = 2); coordinator.retire()
            } }
            assertFalse(repository.reclaimAfterDurableWatchedPlaybackReceipt(receipt) { callbacks++; true })
            assertEquals(0, callbacks); assertEquals(1, closes.size)
        } finally { coordinator.retire(); closes.forEach { it() } }
    }

    @Test fun `already admitted callback linearizes before concurrent account retirement`() = runBlocking {
        val auth = Auth(); val closes = mutableListOf<() -> Unit>(); val coordinator = mounted(auth, closes)
        val downloadLock = Any()
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val attempted = CountDownLatch(1)
        val order = java.util.Collections.synchronizedList(mutableListOf<String>())
        try {
            val repository = repository(coordinator, auth) { action ->
                DownloadAutoDeleteWatchedAdmission.admit(downloadLock, { true }, { false }, action)
            }
            val receipt = requireNotNull(finish(repository, context().copy(owner = PlaybackContext.Owner(UserProfile.OWNER_ID, true))))
            val reclaim = async(Dispatchers.IO) { repository.reclaimAfterDurableWatchedPlaybackReceipt(receipt) {
                assertTrue(Thread.holdsLock(downloadLock)); assertTrue(Thread.holdsLock(auth.lock))
                order += "callback"; entered.countDown(); check(release.await(10, TimeUnit.SECONDS)); order += "finished"; true
            } }
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            val retired = async(Dispatchers.IO) {
                attempted.countDown()
                synchronized(auth.lock) { auth.owner = auth.owner.copy(generation = 2); coordinator.retire(); order += "retired" }
            }
            assertTrue(attempted.await(10, TimeUnit.SECONDS)); assertFalse(retired.isCompleted)
            release.countDown(); assertTrue(reclaim.await()); retired.await()
            assertEquals(listOf("callback", "finished", "retired"), order)
        } finally { release.countDown(); coordinator.retire(); closes.forEach { it() } }
    }

    @Test fun `download bookkeeping can finish its auth check before reclaim acquires native fences`() = runBlocking {
        val auth = Auth(); val closes = mutableListOf<() -> Unit>(); val coordinator = mounted(auth, closes)
        val downloadLock = Any(); val queued = CountDownLatch(1); val attempting = CountDownLatch(1)
        val allowAuthCheck = CountDownLatch(1)
        val order = java.util.Collections.synchronizedList(mutableListOf<String>())
        try {
            val repository = repository(coordinator, auth) { action ->
                attempting.countDown()
                DownloadAutoDeleteWatchedAdmission.admit(downloadLock, { true }, { false }, action)
            }
            val receipt = requireNotNull(finish(repository, context().copy(owner = PlaybackContext.Owner(UserProfile.OWNER_ID, true))))
            val bookkeeping = async(Dispatchers.IO) { synchronized(downloadLock) {
                queued.countDown(); check(allowAuthCheck.await(10, TimeUnit.SECONDS))
                auth.current(); order += "queue-owner-check"
            } }
            assertTrue(queued.await(10, TimeUnit.SECONDS))
            val reclaim = async(Dispatchers.IO) { repository.reclaimAfterDurableWatchedPlaybackReceipt(receipt) {
                // Production DownloadManager re-enters this monitor. It must already be held,
                // not acquired for the first time underneath native/authentication monitors.
                assertTrue(Thread.holdsLock(downloadLock)); assertTrue(Thread.holdsLock(auth.lock))
                order += "reclaim"; true
            } }
            assertTrue(attempting.await(10, TimeUnit.SECONDS)); allowAuthCheck.countDown()
            bookkeeping.await(); assertTrue(reclaim.await())
            assertEquals(listOf("queue-owner-check", "reclaim"), order)
        } finally { allowAuthCheck.countDown(); coordinator.retire(); closes.forEach { it() } }
    }
}
