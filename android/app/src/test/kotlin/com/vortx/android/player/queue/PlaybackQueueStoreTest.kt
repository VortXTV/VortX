package com.vortx.android.player.queue

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PlaybackQueueStoreTest {
    private val a = ContinueWatchingOwner("profile-a", "slot-a", "principal-a", true, 1L)
    private val b = ContinueWatchingOwner("profile-b", "slot-b", "principal-b", true, 2L)
    private fun movie(n: Int) = MetaItem("tt$n", MediaType.MOVIE, "Movie $n")
    private fun entry(n: Int) = PlaybackQueueEntry(UUID(0L, n.toLong()).toString(), movie(n))

    private class MemoryPersistence : PlaybackQueuePersistence {
        val values = mutableMapOf<String, String>()
        val reads = mutableListOf<String>()
        val writes = mutableListOf<Pair<String, String>>()
        var failReads = false
        var failWrites = false
        var onRead: ((String) -> Unit)? = null
        override fun read(key: String): String? {
            reads += key
            if (failReads) error("Synthetic queue read failure")
            val retained = values[key]
            onRead?.invoke(key)
            return retained
        }
        override fun write(key: String, value: String): Boolean {
            writes += key to value
            if (failWrites) return false
            values[key] = value
            return true
        }
    }

    @Test fun `bind is initially unavailable then loads only its owner namespace without writing`() = runTest {
        val persistence = MemoryPersistence().apply {
            values[PlaybackQueueModel.storageKey(a)] = PlaybackQueueCodec.encode(listOf(entry(1)))
            values[PlaybackQueueModel.storageKey(b)] = PlaybackQueueCodec.encode(listOf(entry(2)))
        }
        var current = a
        val store = PlaybackQueueStore(persistence, this, { current }, StandardTestDispatcher(testScheduler))
        store.bindOwner(a)
        assertFalse(store.state.value.ready)
        assertTrue(store.state.value.entries.isEmpty())
        assertTrue(persistence.reads.isEmpty())
        runCurrent()
        assertTrue(store.state.value.ready)
        assertEquals(listOf("tt1"), store.state.value.entries.map { it.item.id })
        assertEquals(listOf(PlaybackQueueModel.storageKey(a)), persistence.reads)
        assertTrue(persistence.writes.isEmpty())
        current = b
        store.bindOwner(b)
        assertEquals(b, store.state.value.owner)
        assertTrue(store.state.value.entries.isEmpty())
        assertFalse(store.state.value.ready)
        runCurrent()
        assertEquals(listOf("tt2"), store.state.value.entries.map { it.item.id })
    }

    @Test fun `accepted mutations persist in admission order rather than IO scheduling order`() = runTest {
        val persistence = MemoryPersistence()
        val store = PlaybackQueueStore(persistence, this, { a }, StandardTestDispatcher(testScheduler))
        store.bindOwner(a)
        runCurrent()
        assertTrue(store.add(a, movie(1)))
        val firstId = store.state.value.entries.single().id
        assertTrue(store.add(a, movie(2)))
        val secondId = store.state.value.entries.last().id
        assertTrue(store.move(a, secondId, -1))
        assertTrue(store.remove(a, firstId))
        assertTrue(persistence.writes.isEmpty())
        runCurrent()
        assertEquals(listOf(listOf("tt1"), listOf("tt1", "tt2"), listOf("tt2", "tt1"), listOf("tt2")),
            persistence.writes.map { (_, json) -> PlaybackQueueCodec.decode(json).map { it.item.id } })
        assertTrue(persistence.writes.all { it.first == PlaybackQueueModel.storageKey(a) })
        assertEquals(listOf("tt2"), PlaybackQueueCodec.decode(persistence.values.getValue(PlaybackQueueModel.storageKey(a))).map { it.item.id })
    }

    @Test fun `accepted outgoing-owner write drains to its original key before rapid ABA reload`() = runTest {
        val persistence = MemoryPersistence()
        var current = a
        val store = PlaybackQueueStore(persistence, this, { current }, StandardTestDispatcher(testScheduler))
        store.bindOwner(a)
        runCurrent()
        assertTrue(store.add(a, movie(1)))
        val oldToken = requireNotNull(store.first(a))
        current = b
        store.bindOwner(b)
        val returnedA = a.copy(revision = 3L)
        current = returnedA
        store.bindOwner(returnedA)
        assertFalse(store.accepts(oldToken))
        assertFalse(store.state.value.ready)
        runCurrent()
        assertEquals(returnedA, store.state.value.owner)
        assertTrue(store.state.value.ready)
        assertEquals(listOf("tt1"), store.state.value.entries.map { it.item.id })
        assertEquals(listOf(PlaybackQueueModel.storageKey(a)), persistence.writes.map { it.first })
        assertNull(store.first(a))
        assertNotNull(store.first(returnedA))
        assertFalse(store.consumeAfterAccepted(oldToken))
    }

    @Test fun `a reentrant successor owner during read cannot publish predecessor metadata`() = runTest {
        val persistence = MemoryPersistence().apply {
            values[PlaybackQueueModel.storageKey(a)] = PlaybackQueueCodec.encode(listOf(entry(1)))
            values[PlaybackQueueModel.storageKey(b)] = PlaybackQueueCodec.encode(listOf(entry(2)))
        }
        var current = a
        lateinit var store: PlaybackQueueStore
        store = PlaybackQueueStore(persistence, this, { current }, StandardTestDispatcher(testScheduler))
        persistence.onRead = { key ->
            if (key == PlaybackQueueModel.storageKey(a)) {
                persistence.onRead = null
                current = b
                store.bindOwner(b)
            }
        }
        store.bindOwner(a)
        runCurrent()
        assertEquals(b, store.state.value.owner)
        assertTrue(store.state.value.ready)
        assertEquals(listOf("tt2"), store.state.value.entries.map { it.item.id })
        assertTrue(persistence.writes.isEmpty())
    }

    @Test fun `unrecognized saved document is retained byte-for-byte and cannot be overwritten by add`() = runTest {
        val persistence = MemoryPersistence()
        val key = PlaybackQueueModel.storageKey(a)
        val original = """{"schema":2,"entries":[],"future":"keep-me"}"""
        persistence.values[key] = original
        val store = PlaybackQueueStore(persistence, this, { a }, StandardTestDispatcher(testScheduler))
        store.bindOwner(a)
        runCurrent()
        assertFalse(store.state.value.ready)
        assertNotNull(store.state.value.error)
        assertFalse(store.add(a, movie(1)))
        assertEquals(original, persistence.values[key])
        assertTrue(persistence.writes.isEmpty())
    }

    @Test fun `failed read stays unavailable until explicit retry without rewriting retained data`() = runTest {
        val persistence = MemoryPersistence().apply { failReads = true }
        val key = PlaybackQueueModel.storageKey(a)
        val original = PlaybackQueueCodec.encode(listOf(entry(1)))
        persistence.values[key] = original
        val store = PlaybackQueueStore(persistence, this, { a }, StandardTestDispatcher(testScheduler))
        store.bindOwner(a)
        runCurrent()
        assertFalse(store.state.value.ready)
        assertNotNull(store.state.value.error)
        assertFalse(store.add(a, movie(2)))
        assertEquals(original, persistence.values[key])
        assertTrue(persistence.writes.isEmpty())
        persistence.failReads = false
        store.retryLoad(a)
        runCurrent()
        assertTrue(store.state.value.ready)
        assertNull(store.state.value.error)
        assertEquals(listOf("tt1"), store.state.value.entries.map { it.item.id })
        assertTrue(persistence.writes.isEmpty())
    }

    @Test fun `capture does not save and accepted current token consumes only its selected duplicate`() = runTest {
        val persistence = MemoryPersistence()
        val key = PlaybackQueueModel.storageKey(a)
        val second = entry(2).copy(item = movie(1))
        persistence.values[key] = PlaybackQueueCodec.encode(listOf(entry(1), second))
        val store = PlaybackQueueStore(persistence, this, { a }, StandardTestDispatcher(testScheduler))
        store.bindOwner(a)
        runCurrent()
        val token = requireNotNull(store.capture(a, second.id))
        assertTrue(store.accepts(token))
        assertEquals(2, store.state.value.entries.size)
        assertTrue(persistence.writes.isEmpty())
        assertTrue(store.consumeAfterAccepted(token))
        assertEquals(listOf(entry(1)), store.state.value.entries)
        assertFalse(store.consumeAfterAccepted(token))
        runCurrent()
        assertEquals(1, persistence.writes.size)
        assertEquals(key, persistence.writes.single().first)
        assertEquals(listOf(entry(1)), PlaybackQueueCodec.decode(persistence.values.getValue(key)))
    }

    @Test fun `failed save disables further edits and explicit retry reloads only saved state`() = runTest {
        val persistence = MemoryPersistence().apply { failWrites = true }
        val store = PlaybackQueueStore(persistence, this, { a }, StandardTestDispatcher(testScheduler))
        store.bindOwner(a)
        runCurrent()
        assertTrue(store.add(a, movie(1)))
        runCurrent()
        assertFalse(store.state.value.ready)
        assertNotNull(store.state.value.error)
        assertFalse(store.add(a, movie(2)))
        assertTrue(persistence.values.isEmpty())
        persistence.failWrites = false
        store.retryLoad(a)
        runCurrent()
        assertTrue(store.state.value.ready)
        assertTrue(store.state.value.entries.isEmpty())
        assertNull(store.state.value.error)
        assertTrue(store.add(a, movie(2)))
        runCurrent()
        assertEquals(listOf("tt2"), PlaybackQueueCodec.decode(persistence.values.getValue(PlaybackQueueModel.storageKey(a))).map { it.item.id })
    }

    @Test fun `pending IO bound rejects overflow without dropping admitted entries and recovers after drain`() = runTest {
        val persistence = MemoryPersistence()
        val store = PlaybackQueueStore(persistence, this, { a }, StandardTestDispatcher(testScheduler))
        store.bindOwner(a)
        runCurrent()
        repeat(32) { index -> assertTrue(store.add(a, movie(index + 1))) }
        assertEquals(32, store.state.value.entries.size)
        assertFalse(store.add(a, movie(33)))
        assertEquals(32, store.state.value.entries.size)
        assertNotNull(store.state.value.error)
        runCurrent()
        assertEquals(32, persistence.writes.size)
        assertNull(store.state.value.error)
        assertTrue(store.add(a, movie(33)))
        runCurrent()
        assertEquals(33, PlaybackQueueCodec.decode(persistence.values.getValue(PlaybackQueueModel.storageKey(a))).size)
    }

    @Test fun `owner lookup failure and explicit invalidation cannot use a remembered queue token`() = runTest {
        val persistence = MemoryPersistence()
        var unavailable = false
        val store = PlaybackQueueStore(persistence, this, {
            if (unavailable) error("Synthetic owner unavailable") else a
        }, StandardTestDispatcher(testScheduler))
        store.bindOwner(a)
        runCurrent()
        assertTrue(store.add(a, movie(1)))
        val token = requireNotNull(store.first(a))
        unavailable = true
        assertFalse(store.accepts(token))
        assertNull(store.capture(a, token.entry.id))
        assertFalse(store.consumeAfterAccepted(token))
        assertFalse(store.remove(a, token.entry.id))
        unavailable = false
        store.invalidate()
        assertNull(store.state.value.owner)
        assertTrue(store.state.value.entries.isEmpty())
        assertFalse(store.accepts(token))
        runCurrent()
        // The previously admitted add may still finish, but only in its captured A namespace.
        assertEquals(listOf(PlaybackQueueModel.storageKey(a)), persistence.writes.map { it.first })
    }
}
