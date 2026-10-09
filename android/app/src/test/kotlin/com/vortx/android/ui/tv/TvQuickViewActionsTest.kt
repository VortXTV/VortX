package com.vortx.android.ui.tv

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.library.WatchlistPersistence
import com.vortx.android.library.WatchlistStore
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Executes the same action owner and real store adapter used by the TV modal. No synthetic UI clicks. */
class TvQuickViewActionsTest {
    private val movie = MetaItem("tt123", MediaType.MOVIE, "Title")

    @Test fun `Watch closes preview then dispatches typed title and captured owner`() {
        Fixture().use { f ->
            assertTrue(f.actions.watch())
            assertEquals(listOf("close", "watch"), f.events)
            assertEquals(movie, f.watched?.first)
            assertEquals(f.initialOwner, f.watched?.second)
            assertNull(f.detail)
        }
    }

    @Test fun `Details has its own navigation callback and never starts Watch`() {
        Fixture().use { f ->
            assertTrue(f.actions.details())
            assertEquals(listOf("close", "details"), f.events)
            assertEquals(movie, f.detail)
            assertNull(f.watched)
        }
    }

    @Test fun `old preview cannot navigate or capture a mutation after owner rebind`() {
        Fixture().use { f ->
            f.owner = f.owner.copy(revision = 2)
            assertFalse(f.actions.watch())
            assertFalse(f.actions.details())
            assertTrue(runCatching { f.actions.captureWatchlistToggle() }.isFailure)
            assertTrue(f.events.isEmpty())
            assertEquals(0, f.persistence.writes)
        }
    }

    @Test fun `close cannot transfer navigation to a newly mounted owner`() {
        Fixture(closeChangesOwner = true).use { f ->
            assertFalse(f.actions.watch())
            assertEquals(listOf("close"), f.events)
            assertNull(f.watched)
        }
    }

    @Test fun `real Watchlist capture occurs in click and toggle changes the current projection`() = runBlocking {
        Fixture().use { f ->
            val intent = f.actions.captureWatchlistToggle()
            assertEquals(f.initialOwner.profileId, intent.operation.profileId)
            assertEquals(movie.id, intent.entry.id)
            assertEquals(0, f.persistence.writes)
            assertTrue(f.actions.toggleWatchlist(intent))
            assertTrue(f.store.isWatchlisted(movie.id, movie.type))
            assertFalse(f.actions.toggleWatchlist(f.actions.captureWatchlistToggle()))
            assertFalse(f.store.isWatchlisted(movie.id, movie.type))
            assertEquals(2, f.persistence.writes)
        }
    }

    @Test fun `queued click retains original authority and cannot mutate the replacement owner`() = runBlocking {
        Fixture().use { f ->
            val intent = f.actions.captureWatchlistToggle()
            f.owner = f.owner.copy(profileId = "other", revision = 2)
            assertTrue(runCatching { f.actions.toggleWatchlist(intent) }.isFailure)
            assertEquals("profile", intent.operation.profileId)
            assertEquals(0, f.persistence.writes)
            assertFalse(f.store.isWatchlisted(movie.id, movie.type))
        }
    }

    @Test fun `failed real persistence does not report successful membership`() = runBlocking {
        Fixture().use { f ->
            f.persistence.failWrites = true
            val intent = f.actions.captureWatchlistToggle()
            assertTrue(runCatching { f.actions.toggleWatchlist(intent) }.isFailure)
            assertFalse(f.store.isWatchlisted(movie.id, movie.type))
        }
    }

    private inner class Fixture(closeChangesOwner: Boolean = false) : AutoCloseable {
        val initialOwner = ContinueWatchingOwner("profile", "account", "principal", false, 1)
        var owner = initialOwner
        val persistence = MemoryPersistence()
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val store = WatchlistStore(persistence, { owner.profileId }, {}, scope, Dispatchers.Unconfined)
        val events = mutableListOf<String>()
        var watched: Pair<MetaItem, ContinueWatchingOwner>? = null
        var detail: MetaItem? = null
        val actions = TvQuickViewActions(TvQuickViewSelection(movie, initialOwner), store, { owner },
            onClose = { events += "close"; if (closeChangesOwner) owner = owner.copy(revision = 2) },
            onWatch = { item, captured -> events += "watch"; watched = item to captured },
            onDetails = { events += "details"; detail = it })
        override fun close() { scope.cancel() }
    }

    private class MemoryPersistence : WatchlistPersistence {
        private val values = mutableMapOf<String, String>()
        var writes = 0
        var failWrites = false
        override fun read(key: String): String? = values[key]
        override fun write(key: String, value: String): Boolean {
            writes++
            if (failWrites) return false
            values[key] = value
            return true
        }
    }
}
