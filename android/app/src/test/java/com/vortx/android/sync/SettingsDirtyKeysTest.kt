package com.vortx.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-logic tests for the LOCAL-WINS settings dirty map, mirroring Apple's standalone
 * `SettingsDirtyKeys` swiftc suite. No Android framework types: the object under test is pure Kotlin.
 */
class SettingsDirtyKeysTest {

    private val syncable: (String) -> Boolean = { it.startsWith("stremiox.") }

    @Test
    fun `changed keys detects add remove and change`() {
        val from = mapOf("stremiox.a" to "x", "stremiox.b" to 1, "other.key" to "z")
        val to = mapOf("stremiox.a" to "y", "stremiox.c" to true, "other.key" to "CHANGED")
        val changed = SettingsDirtyKeys.changedSyncableKeys(from, to, syncable)
        // a: value change; b: removed; c: added. other.key differs but is NOT syncable.
        assertEquals(setOf("stremiox.a", "stremiox.b", "stremiox.c"), changed)
    }

    @Test
    fun `equal snapshots produce no changes`() {
        val snap = mapOf("stremiox.a" to "x", "stremiox.set" to setOf("p", "q"))
        assertTrue(SettingsDirtyKeys.changedSyncableKeys(snap, snap, syncable).isEmpty())
        // Set equality is content-based regardless of iteration order / impl.
        val sameSet = mapOf("stremiox.a" to "x", "stremiox.set" to linkedSetOf("q", "p"))
        assertTrue(SettingsDirtyKeys.changedSyncableKeys(snap, sameSet, syncable).isEmpty())
    }

    @Test
    fun `present vs absent is a change but two absents are equal`() {
        val before: Map<String, Any?> = emptyMap()
        val after: Map<String, Any?> = mapOf("stremiox.n" to 5)
        assertTrue(
            SettingsDirtyKeys.changedSyncableKeys(before, after) { it.startsWith("stremiox.") }
                .contains("stremiox.n")
        )
        assertTrue(SettingsDirtyKeys.valuesEqual(null, null))
        assertFalse(SettingsDirtyKeys.valuesEqual(null, "v"))
    }

    @Test
    fun `mark overwrites stamps so a re-edit advances the stamp`() {
        val dirty = mutableMapOf<String, Double>()
        SettingsDirtyKeys.mark(setOf("k"), at = 1.0, into = dirty)
        SettingsDirtyKeys.mark(setOf("k"), at = 2.0, into = dirty)
        assertEquals(2.0, dirty["k"]!!, 0.0)
    }

    @Test
    fun `clearPushed clears only unchanged stamps`() {
        val snapshot = mapOf("pushed" to 1.0, "reEditedMidPush" to 1.0)
        val dirty = mutableMapOf("pushed" to 1.0, "reEditedMidPush" to 9.0, "neverPushed" to 3.0)
        SettingsDirtyKeys.clearPushed(snapshot, from = dirty)
        assertFalse(dirty.containsKey("pushed"))
        assertTrue(dirty.containsKey("reEditedMidPush"))   // newer stamp: its value was not in the pushed blob
        assertTrue(dirty.containsKey("neverPushed"))
    }
}
