package com.vortx.android.profile

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RosterClockRegressionTest {

    @Test
    fun newerIncomingClockWinsAndBecomesTheRepublishedWatermark() {
        val fold = rosterClockDecision(localModified = 10L, incomingModified = 20L)

        assertTrue(fold.preferIncoming)
        assertEquals(20L, fold.effectiveModified)
    }

    @Test
    fun olderOrMissingIncomingClockCannotRegressTheWatermark() {
        val older = rosterClockDecision(localModified = 20L, incomingModified = 10L)
        val missing = rosterClockDecision(localModified = 20L, incomingModified = null)

        assertFalse(older.preferIncoming)
        assertEquals(20L, older.effectiveModified)
        assertFalse(missing.preferIncoming)
        assertEquals(20L, missing.effectiveModified)
    }

    @Test
    fun mergePersistsTheClockOnBothEqualAndChangedPayloadPaths() {
        val profileStore = readSource("profile/ProfileStore.kt")
            .substringAfter("fun mergeInRoster(")
            .substringBefore("/** Whether [incoming]")
        val syncManager = readSource("sync/VortXSyncManager.kt")
            .substringAfter("private suspend fun mergeLocalIntoDoc")
            .substringBefore("private suspend fun syncDown")

        assertTrue(profileStore.contains("if (merged == profiles)"))
        assertEquals(2, Regex("adoptRosterWatermark\\(clock\\.effectiveModified\\)").findAll(profileStore).count())
        assertTrue(syncManager.contains("rosterModifiedSeconds = store.rosterModified"))
        assertTrue(syncManager.contains("VortXSyncDoc.buildVortx(store"))
    }

    private fun readSource(relative: String): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/$relative"),
            File("app/src/main/kotlin/com/vortx/android/$relative"),
            File("android/app/src/main/kotlin/com/vortx/android/$relative"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relative from ${File(".").absolutePath}")
    }
}
