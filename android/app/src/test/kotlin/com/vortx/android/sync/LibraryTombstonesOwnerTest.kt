package com.vortx.android.sync

import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class LibraryTombstonesOwnerTest {
    private class Memory : LibraryTombstonePersistence {
        val maps = mutableMapOf<String, Map<String, Double>>()
        val legacy = mutableMapOf<String, Set<String>>()
        override fun readMap(key: String) = maps[key].orEmpty()
        override fun writeMap(key: String, value: Map<String, Double>) { maps[key] = value.toMap() }
        override fun readLegacy(key: String) = legacy[key].orEmpty()
        override fun writeLegacy(key: String, value: Set<String>) { legacy[key] = value.toSet() }
    }

    @Before fun reset() { LibraryTombstones.activateAccount(null) }
    @After fun clearBinding() { LibraryTombstones.activateAccount(null) }

    @Test fun `unassigned legacy and signed out writes never migrate or export as next account`() {
        val persistence = Memory().apply {
            maps["stremiox.library.removedAt"] = mapOf("tt1" to 2000.0)
            legacy["stremiox.library.deleted"] = setOf("tt2")
        }
        val local = LibraryTombstones(persistence) { 3000.0 }
        assertEquals(setOf("tt1", "tt2"), local.all())
        assertTrue(local.tombstone("tt3"))
        assertTrue(local.timestampsForSync().isEmpty())
        assertFalse(local.merge(listOf("tt4"), emptyMap()))
        LibraryTombstones.activateAccount("B")
        val b = LibraryTombstones(persistence)
        assertTrue(b.all().isEmpty())
        assertTrue(b.timestampsForSync().isEmpty())
        assertFalse(local.tombstone("tt5"))
        LibraryTombstones.activateAccount(null)
        assertEquals(setOf("tt1", "tt2", "tt3"), LibraryTombstones(persistence).all())
    }

    @Test fun `A B A restores own stamps without reviving old capability or conflating case sensitive owners`() {
        val persistence = Memory()
        LibraryTombstones.activateAccount("A")
        val a = LibraryTombstones(persistence) { 2000.0 }
        a.tombstone("tt1")
        LibraryTombstones.activateAccount("a")
        val other = LibraryTombstones(persistence) { 3000.0 }
        assertTrue(other.all().isEmpty())
        other.tombstone("tt2")
        assertFalse(a.forget("tt1"))
        assertTrue(a.timestampsForSync().isEmpty())
        LibraryTombstones.activateAccount("A")
        val returned = LibraryTombstones(persistence)
        assertEquals(setOf("tt1"), returned.all())
        assertEquals(2000.0, returned.timestampsForSync()["tt1"]?.get("removedAt"))
        assertFalse(a.tombstone("tt3"))
        assertFalse(other.tombstone("tt4"))
        assertEquals(setOf("tt1"), returned.all())
    }

    @Test fun `delayed captured A mutator cannot write B or returned A`() {
        val persistence = Memory()
        LibraryTombstones.activateAccount("A")
        val a = LibraryTombstones(persistence) { 2000.0 }
        val start = CountDownLatch(1)
        val release = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val future = executor.submit<Boolean> {
                start.countDown()
                check(release.await(2, TimeUnit.SECONDS))
                a.tombstone("tt1")
            }
            assertTrue(start.await(1, TimeUnit.SECONDS))
            LibraryTombstones.activateAccount("B")
            release.countDown()
            assertFalse(future.get(1, TimeUnit.SECONDS))
            assertTrue(LibraryTombstones(persistence).all().isEmpty())
            LibraryTombstones.activateAccount("A")
            assertTrue(LibraryTombstones(persistence).all().isEmpty())
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun `reentrant owner replacement during clock read prevents all persistent writes`() {
        val persistence = Memory()
        LibraryTombstones.activateAccount("A")
        val a = LibraryTombstones(persistence) { LibraryTombstones.activateAccount("B"); 4000.0 }
        assertFalse(a.tombstone("tt1"))
        assertTrue(persistence.maps.isEmpty())
        assertTrue(persistence.legacy.isEmpty())
    }
}
