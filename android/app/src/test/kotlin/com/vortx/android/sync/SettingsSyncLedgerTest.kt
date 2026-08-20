package com.vortx.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsSyncLedgerTest {
    @Test
    fun dirtyLocalClearWinsAgainstLaterRemoteValueUntilAcknowledged() {
        val key = "stremiox.theme.oled"
        val local = mapOf(key to SettingsSyncLedger.Stamp(10, "device-a", tombstone = true, dirty = true))
        val remote = mapOf(key to SettingsSyncLedger.Stamp(20, "device-b", tombstone = false, dirty = false))

        val folded = SettingsSyncLedger.foldRecords(local, remote)

        assertTrue(folded.applyRemote.isEmpty())
        assertTrue(requireNotNull(folded.records[key]).tombstone)
        assertTrue(requireNotNull(folded.records[key]).dirty)
    }

    @Test
    fun acknowledgedRemoteClearWinsAndIsAppliedWithoutResurrection() {
        val key = "stremiox.theme.oled"
        val local = mapOf(key to SettingsSyncLedger.Stamp(10, "device-a", tombstone = false, dirty = false))
        val remote = mapOf(key to SettingsSyncLedger.Stamp(20, "device-b", tombstone = true, dirty = false))

        val folded = SettingsSyncLedger.foldRecords(local, remote)

        assertEquals(setOf(key), folded.applyRemote)
        assertTrue(requireNotNull(folded.records[key]).tombstone)
        assertFalse(requireNotNull(folded.records[key]).dirty)
    }

    @Test
    fun equalClockUsesStableDeviceTieBreakRatherThanIterationOrder() {
        val key = "stremiox.theme.oled"
        val local = mapOf(key to SettingsSyncLedger.Stamp(42, "device-a", tombstone = false, dirty = false))
        val remote = mapOf(key to SettingsSyncLedger.Stamp(42, "device-z", tombstone = true, dirty = false))

        val folded = SettingsSyncLedger.foldRecords(local, remote)

        assertTrue(requireNotNull(folded.records[key]).tombstone)
        assertEquals(setOf(key), folded.applyRemote)
    }
}
