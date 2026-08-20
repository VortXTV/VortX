package com.vortx.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject

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

    @Test
    fun storedDirtyRevisionSurvivesRestartDecode() {
        val key = "stremiox.theme.oled"
        val stored = JSONObject().put(key, JSONObject()
            .put("clock", 81)
            .put("device", "device-a")
            .put("tombstone", true)
            .put("dirty", true))

        val decoded = SettingsSyncLedger.decodeStored(stored)

        assertTrue(requireNotNull(decoded[key]).dirty)
        assertTrue(requireNotNull(decoded[key]).tombstone)
    }

    @Test
    fun acknowledgementLeavesEditMadeDuringPutDirty() {
        val key = "stremiox.theme.oled"
        val sent = SettingsSyncLedger.Stamp(10, "device-a", tombstone = false, dirty = true)
        val editedDuringPut = SettingsSyncLedger.Stamp(11, "device-a", tombstone = true, dirty = true)

        val acknowledged = SettingsSyncLedger.acknowledgeRecords(mapOf(key to editedDuringPut), mapOf(key to sent))

        assertTrue(requireNotNull(acknowledged[key]).dirty)
        assertTrue(requireNotNull(acknowledged[key]).tombstone)
    }

    @Test
    fun acknowledgementClearsOnlyExactPublishedRevision() {
        val key = "stremiox.theme.oled"
        val sent = SettingsSyncLedger.Stamp(10, "device-a", tombstone = false, dirty = true)

        val acknowledged = SettingsSyncLedger.acknowledgeRecords(mapOf(key to sent), mapOf(key to sent))

        assertFalse(requireNotNull(acknowledged[key]).dirty)
    }

    @Test
    fun unappliedRemoteRevisionRemainsReplayableAfterFailure() {
        val key = "stremiox.theme.oled"
        val remote = mapOf(key to SettingsSyncLedger.Stamp(20, "device-b", tombstone = false, dirty = false))

        // A malformed carrier or failed synchronous preference write deliberately does not commit the preview.
        val first = SettingsSyncLedger.foldRecords(emptyMap(), remote)
        val retry = SettingsSyncLedger.foldRecords(emptyMap(), remote)

        assertEquals(setOf(key), first.applyRemote)
        assertEquals(setOf(key), retry.applyRemote)
    }

    @Test
    fun partialLedgerLeavesUnrevisionedCarrierKeysOnLegacyPath() {
        val revised = "stremiox.theme.oled"
        val legacy = "stremiox.languageOverride"
        val keys = SettingsSyncLedger.unrevisionedKeys(
            carrierKeys = setOf(revised, legacy),
            revisions = mapOf(revised to SettingsSyncLedger.Stamp(1, "device-b", false, false)),
        )

        assertEquals(setOf(legacy), keys)
    }

    @Test
    fun documentMergePreservesUnknownFutureRevision() {
        val known = "stremiox.theme.oled"
        val existing = JSONObject().put("future.setting", JSONObject().put("clock", 9).put("opaque", "keep"))
        val merged = SettingsSyncLedger.mergeDocumentRevisions(
            existing,
            mapOf(known to SettingsSyncLedger.Stamp(12, "device-a", tombstone = false, dirty = true)),
        )

        assertEquals("keep", merged.getJSONObject("future.setting").getString("opaque"))
        assertEquals(12L, merged.getJSONObject(known).getLong("clock"))
        assertFalse(merged.getJSONObject(known).has("dirty"))
    }

    @Test
    fun documentMergePreservesFutureFieldsInsideKnownRevision() {
        val known = "stremiox.theme.oled"
        val existing = JSONObject().put(known, JSONObject()
            .put("clock", 1)
            .put("device", "device-old")
            .put("futureProof", JSONObject().put("mode", "keep")))

        val merged = SettingsSyncLedger.mergeDocumentRevisions(
            existing,
            mapOf(known to SettingsSyncLedger.Stamp(12, "device-a", tombstone = true, dirty = true)),
        )

        assertEquals("keep", merged.getJSONObject(known).getJSONObject("futureProof").getString("mode"))
        assertTrue(merged.getJSONObject(known).getBoolean("tombstone"))
    }
}
