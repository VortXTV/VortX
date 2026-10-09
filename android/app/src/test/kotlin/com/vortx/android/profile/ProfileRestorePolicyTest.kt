package com.vortx.android.profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileRestorePolicyTest {
    @Test fun `native profile-bearing restore refuses the whole file before writer runs`() {
        for (key in listOf("stremiox.profiles", "stremiox.profiles.modified", "stremiox.profiles.deleted",
            "stremiox.profiles.active", "stremiox.profiles.watch.child", "stremiox.profiles.lastStream.child",
            "stremiox.profile.disabledAddons", "stremiox.profile.isKids", "stremiox.profiles.foreignFutureField")) {
            var writes = 0
            val error = runCatching {
                withLocalSettingsRestoreAdmission(true, setOf(key, "stremiox.posterStyle")) { writes++ }
            }.exceptionOrNull()
            assertTrue(error is IllegalArgumentException)
            assertTrue(error?.message.orEmpty().contains("VortX account"))
            assertTrue(error?.message.orEmpty().contains("No settings have been changed"))
            assertEquals(0, writes)
        }
    }

    @Test fun `unsupported profile value cannot hide behind writable settings-only values`() {
        // A typed decoder can omit an unsupported roster object; admission must use original source keys.
        val source = linkedMapOf<String, Any>("stremiox.profiles" to mapOf("unsupported" to true), "stremiox.posterStyle" to "rounded")
        val writable = source.filterKeys { it != "stremiox.profiles" }
        var writes = 0
        assertTrue(runCatching {
            withLocalSettingsRestoreAdmission(true, source.keys) { writes++; writable }
        }.exceptionOrNull() is IllegalArgumentException)
        assertEquals(0, writes)
        assertEquals(setOf("stremiox.posterStyle"), writable.keys)
    }

    @Test fun `non-native profile-bearing file remains unchanged and writer executes once`() {
        val original = linkedMapOf("stremiox.profiles" to "exact roster", "stremiox.profiles.watch.child" to "exact overlay",
            "stremiox.posterStyle" to "rounded")
        val written = linkedMapOf<String, String>()
        var writes = 0
        val result = withLocalSettingsRestoreAdmission(false, original.keys) {
            writes++; written.putAll(original); "restored"
        }
        assertEquals("restored", result)
        assertEquals(1, writes)
        assertEquals(original, written)
    }

    @Test fun `native settings-only file still reaches writer`() {
        var writes = 0
        withLocalSettingsRestoreAdmission(true, setOf("stremiox.posterStyle")) { writes++ }
        assertEquals(1, writes)
        assertEquals(42, withLocalSettingsRestoreAdmission(true, emptySet()) { 42 })
    }

    @Test fun `native reload only publishes mounted profiles and never reads legacy prefs`() {
        var roster = listOf("old facade")
        var legacyReads = 0
        if (!refreshNativeProfilesForReload(true) { roster = listOf("mounted native profile") }) {
            legacyReads++; roster = listOf("unscoped preference profile")
        }
        assertEquals(listOf("mounted native profile"), roster)
        assertEquals(0, legacyReads)
    }

    @Test fun `unavailable native reload fails without adopting preference profiles`() {
        var legacyReads = 0
        val error = runCatching {
            if (!refreshNativeProfilesForReload(true) { error("Native account unavailable") }) legacyReads++
        }.exceptionOrNull()
        assertTrue(error is IllegalStateException)
        assertEquals(0, legacyReads)
    }

    @Test fun `non-native reload leaves legacy read enabled`() {
        var nativeReads = 0
        assertFalse(refreshNativeProfilesForReload(false) { nativeReads++ })
        assertEquals(0, nativeReads)
    }

    @Test fun `native export snapshot omits profile keys passes admission and preserves original preferences`() {
        val original = linkedMapOf("stremiox.profiles" to "exact roster", "stremiox.profiles.active" to "owner",
            "stremiox.profiles.modified" to "exact clock", "stremiox.profiles.deleted" to "exact deletes",
            "stremiox.profiles.watch.child" to "exact overlay", "stremiox.profiles.lastStream.child" to "exact stream",
            "stremiox.profile.disabledAddons" to "exact addon setting", "stremiox.profile.isKids" to "true",
            "stremiox.posterStyle" to "rounded")
        val before = original.toMap()
        val exported = localSettingsBackupInput(true, original)
        assertEquals(mapOf("stremiox.posterStyle" to "rounded"), exported)
        var writes = 0
        withLocalSettingsRestoreAdmission(true, exported.keys) { writes++ }
        assertEquals(1, writes)
        assertEquals(before, original)
    }

    @Test fun `non-native export retains exact original profiles and settings`() {
        val original = linkedMapOf("stremiox.profiles" to "exact roster", "stremiox.profiles.watch.child" to "exact overlay",
            "stremiox.profile.isKids" to "false", "stremiox.posterStyle" to "rounded")
        val exported = localSettingsBackupInput(false, original)
        assertSame(original, exported)
        assertEquals(original, exported)
    }
}
