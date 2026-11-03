package com.vortx.android.profile

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.data.AddonTombstonePersistence
import com.vortx.android.data.AddonTombstones
import com.vortx.android.sync.LibraryTombstonePersistence
import com.vortx.android.sync.LibraryTombstones
import com.vortx.android.sync.RevisionContext
import com.vortx.android.sync.SessionOwnerSnapshot
import java.lang.reflect.Proxy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RestoreProfileDirectWritersTest {
    private val gate = RestoreProfileDirectWriters
    private val account = "00000000-0000-0000-0000-000000000456"
    private val url = "https://fixture.invalid/manifest.json"

    private class AddonStore : AddonTombstonePersistence {
        val values = mutableMapOf<String, String>()
        var onRead: () -> Unit = {}
        override fun read(key: String): String? { onRead(); return values[key] }
        override fun write(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }

    private class LibraryStore : LibraryTombstonePersistence {
        val values = mutableMapOf<String, Map<String, Double>>()
        val legacy = mutableMapOf<String, Set<String>>()
        override fun readMap(key: String): Map<String, Double> = values[key].orEmpty()
        override fun writeMap(key: String, value: Map<String, Double>) { values[key] = value.toMap() }
        override fun readLegacy(key: String): Set<String> = legacy[key].orEmpty()
        override fun writeLegacy(key: String, value: Set<String>) { legacy[key] = value.toSet() }
    }

    private fun prefs(onEdit: () -> Unit): SharedPreferences {
        val editor = Proxy.newProxyInstance(javaClass.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { self, method, _ ->
            when (method.name) {
                "putString" -> self
                "apply" -> null
                else -> error("Unexpected editor method " + method.name)
            }
        } as SharedPreferences.Editor
        return Proxy.newProxyInstance(javaClass.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, _ ->
            when (method.name) {
                "getString" -> null
                "edit" -> { onEdit(); editor }
                else -> error("Unexpected preference method " + method.name)
            }
        } as SharedPreferences
    }

    @Test fun preExistingDirectWriterRefusesNewReservationAndKeepsItsChange() {
        val storage = AddonStore()
        val addons = AddonTombstones(storage, { 10.0 }, { account })
        storage.onRead = { assertNull(gate.reserve()) }
        assertTrue(addons.tombstone(url))
        assertTrue(storage.values.isNotEmpty())
        gate.release(checkNotNull(gate.reserve()))
    }

    @Test fun heldLaneRefusesActualProfileOverlayAndTombstoneWritersBeforeEdit() {
        val addonsStorage = AddonStore()
        val libraryStorage = LibraryStore()
        val addons = AddonTombstones(addonsStorage, { 10.0 }, { account })
        LibraryTombstones.activateAccount(account)
        val library = LibraryTombstones(libraryStorage) { 10.0 }
        var edits = 0
        var projection = 0
        val overlay = WatchOverlayStore(prefs { edits++ }, onOverlayChanged = { projection++ })
        val held = checkNotNull(gate.reserve())
        try {
            assertTrue(runCatching { addons.tombstone(url) }.isFailure)
            assertTrue(runCatching { library.tombstone("tt123") }.isFailure)
            assertTrue(runCatching { overlay.activate("profile", false) }.isFailure)
            assertTrue(runCatching { overlay.clearCache("profile") }.isFailure)
            assertEquals(0, edits)
            assertEquals(0, projection)
            assertTrue(addonsStorage.values.isEmpty())
            assertTrue(libraryStorage.values.isEmpty())
            gate.requireCurrent(held)
        } finally {
            gate.release(held)
            LibraryTombstones.activateAccount(null)
        }
        assertTrue(addons.tombstone(url))
    }

    @Test fun ownerRetirementRevokesWithoutReleasingOriginalSlotAndNoABA() {
        val held = checkNotNull(gate.reserve())
        try {
            AddonTombstones.activateAccount(account)
            assertTrue(runCatching { gate.requireCurrent(held) }.isFailure)
            assertNull(gate.reserve())
            AddonTombstones.activateAccount(null)
            assertNull(gate.reserve())
        } finally {
            gate.release(held)
        }
        val successor = checkNotNull(gate.reserve())
        try {
            gate.requireCurrent(successor)
            assertTrue(runCatching { gate.requireCurrent(held) }.isFailure)
        } finally { gate.release(successor) }
    }

    @Test fun actualProfileStoreHoldStaysReservedUntilItsRevokedOperationReturns() = runBlocking {
        val constructor = ProfileStore::class.java.getDeclaredConstructor(Context::class.java)
        constructor.isAccessible = true
        val profiles = constructor.newInstance(RevisionContext())
        val owner = SessionOwnerSnapshot.Account(account, 1)
        val result = profiles.withRestoreDirectExclusion(owner, requireOriginal = {}) { held ->
            held.requireCurrent(owner)
            assertNull(gate.reserve())
            profiles.selectionPending = true
            assertThrows(IllegalStateException::class.java) { held.requireCurrent(owner) }
            assertNull(gate.reserve())
            "completed"
        }
        assertEquals("completed", result)
        gate.release(checkNotNull(gate.reserve()))
    }

    @Test fun delayedOverlayPushAndPreExistingLocalDataCannotBecomeIdle() = runBlocking {
        val overlayScope = CoroutineScope(coroutineContext + SupervisorJob())
        val overlay = WatchOverlayStore(prefs { }, scope = overlayScope)
        try {
            overlay.activate("profile", false)
            val original = checkNotNull(overlay.captureRestoreIdle())
            overlay.recordProgress("tt123", "tt123", 20.0, 200.0, "Fixture", "movie", null)
            assertFalse(original())
            assertNull(overlay.captureRestoreIdle())
            overlay.removeWatchEntry("tt123")
            assertTrue(overlay.watch.isEmpty())
            assertNull(overlay.captureRestoreIdle())
        } finally { overlayScope.cancel() }
    }
}
