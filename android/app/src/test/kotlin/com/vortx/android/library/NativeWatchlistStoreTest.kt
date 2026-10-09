package com.vortx.android.library

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeWatchlistStoreTest {
    private val movie = MetaItem("tt123", MediaType.MOVIE, "Movie")

    @Test fun `native construction with absent gateway never reads or writes unqualified local data`() = runBlocking {
        fixture(native = true).use { f ->
            assertEquals(0, f.persistence.reads)
            assertEquals(0, f.persistence.writes)
            assertTrue(f.store.items.value.isEmpty())
            assertNotNull(f.store.error.value)
            assertTrue(runCatching { f.store.captureToggle(movie) }.isFailure)
            assertEquals(0, f.persistence.reads)
        }
    }

    @Test fun `native projection uses typed identities and never touches the flat ledger`() = runBlocking {
        fixture().use { f ->
            f.gateway.put("tt123", "series")
            f.install()
            assertFalse(f.store.isWatchlisted("tt123", MediaType.MOVIE))
            assertTrue(f.store.isWatchlisted("tt123", MediaType.SERIES))
            val intent = f.store.captureToggle(movie)
            assertTrue(f.store.toggle(intent))
            assertEquals(setOf(MediaType.MOVIE, MediaType.SERIES), f.store.items.value.map { it.type }.toSet())
            assertFalse(f.store.toggle(f.store.captureToggle(movie)))
            assertEquals(listOf(MediaType.SERIES), f.store.items.value.map { it.type })
            assertEquals(0, f.persistence.reads)
            assertEquals(0, f.persistence.writes)
            assertTrue(f.gateway.registers.getJSONObject(NativeWatchlistCodec.field("tt123", "movie")).isNull("value"))
        }
    }

    @Test fun `membership publishes only after acknowledged async mutation`() = runBlocking {
        fixture().use { f ->
            f.install()
            f.gateway.awaitAck = CompletableDeferred()
            val intent = f.store.captureToggle(movie)
            val work = async(Dispatchers.Unconfined) { f.store.toggle(intent) }
            assertFalse(work.isCompleted)
            assertFalse(f.store.isWatchlisted(movie.id, movie.type))
            f.gateway.awaitAck!!.complete(Unit)
            assertTrue(work.await())
            assertTrue(f.store.isWatchlisted(movie.id, movie.type))
            assertEquals(intent.operation.native!!.snapshot.owner, f.gateway.receivedOwner)
        }
    }

    @Test fun `failed native checkpoint acknowledgement cannot publish membership`() = runBlocking {
        fixture().use { f ->
            f.install()
            f.gateway.failMutation = true
            assertTrue(runCatching { f.store.toggle(f.store.captureToggle(movie)) }.isFailure)
            assertFalse(f.store.isWatchlisted(movie.id, movie.type))
            assertTrue(f.gateway.registers.length() == 0)
        }
    }

    @Test fun `success without requested readback is rejected instead of UI success`() = runBlocking {
        fixture().use { f ->
            f.install()
            f.gateway.ignoreChange = true
            assertTrue(runCatching { f.store.toggle(f.store.captureToggle(movie)) }.isFailure)
            assertFalse(f.store.isWatchlisted(movie.id, movie.type))
        }
    }

    @Test fun `same profile account rebind clears synchronously and queued intent cannot recapture authority`() = runBlocking {
        fixture().use { f ->
            f.gateway.put("tt-old", "movie")
            f.install()
            val intent = f.store.captureToggle(movie)
            f.store.invalidateNativeAuthority()
            f.gateway.rebind()
            assertTrue(f.store.items.value.isEmpty())
            assertTrue(runCatching { f.store.toggle(intent) }.isFailure)
            assertEquals(0, f.gateway.mutations)
            f.store.reload()
            assertTrue(f.store.items.value.isEmpty())
        }
    }

    @Test fun `gateway independently rejects stale capture even without a local lifecycle callback`() = runBlocking {
        fixture().use { f ->
            f.install()
            val intent = f.store.captureToggle(movie)
            val expected = intent.operation.native!!.snapshot.owner
            f.gateway.rebind()
            assertTrue(runCatching { f.store.toggle(intent) }.isFailure)
            assertEquals(expected, f.gateway.receivedOwner)
            assertFalse(f.gateway.registers.has(NativeWatchlistCodec.field(movie.id, movie.type.id)))
        }
    }

    @Test fun `atomic publication refuses a revision changed after reload capture`() = runBlocking {
        fixture().use { f ->
            f.gateway.put("tt-initial", "movie")
            f.install()
            f.gateway.put("tt-stale", "movie")
            f.gateway.skipPublicationHooks = 1 // Let capture bookkeeping pass; race the final publish.
            f.gateway.beforePublication = {
                f.gateway.advanceRevision()
                f.gateway.registers = JSONObject()
                f.gateway.put("tt-current", "movie")
            }
            f.store.reload()
            assertFalse(f.store.items.value.any { it.id == "tt-stale" })
            f.store.reload()
            assertEquals(listOf("tt-current"), f.store.items.value.map { it.id })
        }
    }

    @Test fun `obsolete capture cannot clear a newer same profile projection during bookkeeping`() = runBlocking {
        fixture().use { f ->
            f.gateway.put("tt-initial", "movie")
            f.install()
            f.gateway.afterCapture = {
                f.gateway.advanceRevision()
                f.gateway.registers = JSONObject()
                f.gateway.put("tt-current", "movie")
                runBlocking { f.store.reload() }
            }
            assertTrue(runCatching { f.store.captureToggle(movie) }.isFailure)
            assertEquals(listOf("tt-current"), f.store.items.value.map { it.id })
            assertNull(f.store.error.value)
            assertEquals(0, f.gateway.mutations)
        }
    }

    @Test fun `obsolete native codec failure cannot clear fresh projection or publish its error`() = runBlocking {
        fixture().use { f ->
            f.gateway.put("tt-initial", "movie")
            f.install()
            f.gateway.registers.put("watchlist.movie.bad", JSONObject())
            f.gateway.skipPublicationHooks = 1 // Race the operation-specific error, not bookkeeping.
            f.gateway.beforePublication = {
                f.gateway.advanceRevision()
                f.gateway.registers = JSONObject()
                f.gateway.put("tt-current", "movie")
                runBlocking { f.store.reload() }
            }
            f.store.requestReload()
            assertEquals(listOf("tt-current"), f.store.items.value.map { it.id })
            assertNull(f.store.error.value)
        }
    }

    @Test fun `native cap rejects new item and preserves all converged entries`() = runBlocking {
        fixture().use { f ->
            (0..1000).forEach { f.gateway.put("tt-$it", "movie") }
            f.install()
            assertEquals(1001, f.store.items.value.size)
            assertTrue(runCatching { f.store.toggle(f.store.captureToggle(movie)) }.isFailure)
            assertEquals(0, f.gateway.mutations)
            assertEquals(1001, f.store.items.value.size)
            assertFalse(f.store.toggle(f.store.captureToggle(MetaItem("tt-0", MediaType.MOVIE, "Remove"))))
            assertEquals(1000, f.store.items.value.size)
        }
    }

    @Test fun `legacy failed disk commit throws and never publishes success`() = runBlocking {
        fixture(native = false).use { f ->
            f.store.reload()
            f.persistence.commit = false
            assertTrue(runCatching { f.store.toggle(movie) }.isFailure)
            assertFalse(f.store.isWatchlisted(movie.id))
            assertEquals(1, f.persistence.writes)
            assertEquals(null, f.persistence.value)
        }
    }

    private fun fixture(native: Boolean = true) = Fixture(native)

    private class Fixture(native: Boolean) : AutoCloseable {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val persistence = Persistence()
        val gateway = Gateway()
        val store = WatchlistStore(persistence, { "PROFILE" }, {}, scope, Dispatchers.Unconfined, { 123.5 }, { native })
        fun install() = store.installNativeGateway(gateway) { true }
        override fun close() = scope.cancel()
    }

    private class Persistence : WatchlistPersistence {
        var reads = 0; var writes = 0; var commit = true; var value: String? = null
        override fun read(key: String): String? { reads++; return value }
        override fun write(key: String, value: String): Boolean { writes++; if (commit) this.value = value; return commit }
    }

    private class Gateway : NativeWatchlistGateway {
        data class Epoch(override val accountId: String = "ACCOUNT", override val profileId: String = "PROFILE",
            val session: Int = 0, val revision: Long = 0) : NativeWatchlistGateway.Owner
        var owner = Epoch()
        var registers = JSONObject()
        var mutations = 0
        var receivedOwner: NativeWatchlistGateway.Owner? = null
        var awaitAck: CompletableDeferred<Unit>? = null
        var failMutation = false
        var ignoreChange = false
        var beforePublication: (() -> Unit)? = null
        var skipPublicationHooks = 0
        var afterCapture: (() -> Unit)? = null
        override val changes: Flow<Unit> = MutableSharedFlow()
        override fun capture(): Result<NativeWatchlistGateway.Snapshot> {
            val read = snapshot()
            afterCapture.also { afterCapture = null }?.invoke()
            return Result.success(read)
        }
        override fun publishIfCurrent(expected: NativeWatchlistGateway.Owner, publication: () -> Unit): Boolean {
            if (skipPublicationHooks > 0) skipPublicationHooks--
            else beforePublication.also { beforePublication = null }?.invoke()
            if (expected != owner) return false
            publication()
            return true
        }
        override suspend fun mutate(expected: NativeWatchlistGateway.Owner, changes: JSONObject): Result<NativeWatchlistGateway.Snapshot> = runCatching {
            receivedOwner = expected
            awaitAck?.await()
            check(expected == owner) { "Stale immutable capture" }
            check(!failMutation) { "Checkpoint failed" }
            mutations++
            if (!ignoreChange) for (field in changes.keys()) {
                NativeWatchlistCodec.validate(field, changes.get(field))
                registers.put(field, register(changes.get(field)))
            }
            advanceRevision()
            snapshot()
        }
        fun put(id: String, type: String) {
            registers.put(NativeWatchlistCodec.field(id, type), register(NativeWatchlistCodec.value(WatchlistEntry(id, type, id, null, 123.5))))
        }
        fun advanceRevision() { owner = owner.copy(revision = owner.revision + 1) }
        fun rebind() { owner = owner.copy(session = owner.session + 1, revision = 0); registers = JSONObject() }
        private fun snapshot() = NativeWatchlistGateway.Snapshot(owner, JSONObject(registers.toString()))
        private fun register(value: Any) = JSONObject().put("clock", owner.revision + 1)
            .put("actor", "11111111-1111-1111-1111-111111111111").put("value", value)
    }
}
