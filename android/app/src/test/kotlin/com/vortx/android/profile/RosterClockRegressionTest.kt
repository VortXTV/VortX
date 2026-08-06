package com.vortx.android.profile

import com.vortx.android.backup.SettingsBackup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class RosterClockRegressionTest {

    @Test
    fun newerFractionWithinTheSameSecondWinsAndBecomesTheWatermark() {
        val fold = rosterClockDecision(localModified = 10.125, incomingModified = 10.875)

        assertTrue(fold.preferIncoming)
        assertEquals(10.875, fold.effectiveModified, 0.0)
    }

    @Test
    fun olderOrMissingIncomingClockCannotRegressTheWatermark() {
        val older = rosterClockDecision(localModified = 20.75, incomingModified = 20.25)
        val missing = rosterClockDecision(localModified = 20.75, incomingModified = null)

        assertFalse(older.preferIncoming)
        assertEquals(20.75, older.effectiveModified, 0.0)
        assertFalse(missing.preferIncoming)
        assertEquals(20.75, missing.effectiveModified, 0.0)
    }

    @Test
    fun exactBitsRoundTripFractionsAndLegacyWholeSecondsMigrateSafely() {
        val fractional = 1_722_345_678.9876542

        assertEquals(
            fractional,
            requireNotNull(decodeStoredRosterClock(fractional.toRawBits(), legacySeconds = 7L)),
            0.0,
        )
        assertEquals(7.0, requireNotNull(decodeStoredRosterClock(null, legacySeconds = 7L)), 0.0)
        assertEquals(
            7.0,
            requireNotNull(decodeStoredRosterClock(Double.NaN.toRawBits(), legacySeconds = 7L)),
            0.0,
        )
    }

    @Test
    fun identicalPayloadAdoptsWatermarkWithoutPushAndRepublishesThatExactClock() {
        val same = UserProfile(
            id = "33000000-0000-0000-0000-000000000003",
            name = "Same",
            avatar = "S",
        )
        val transition = rosterPullMergeTransition(
            local = listOf(same),
            incoming = listOf(same),
            deletedProfileIDs = emptySet(),
            localModified = 50.125,
            incomingModified = 50.875,
        )

        assertFalse(transition.contentChanged)
        assertFalse(transition.pushRequired)
        assertEquals(50.875, transition.effectiveModified, 0.0)

        var replaced = false
        var adopted: Double? = null
        var pushCount = 0
        applyRosterPullMergeTransition(
            transition = transition,
            replaceProfiles = { replaced = true },
            adoptWatermark = { adopted = it },
            schedulePush = { pushCount += 1 },
        )
        assertFalse(replaced)
        assertEquals(50.875, requireNotNull(adopted), 0.0)
        assertEquals(0, pushCount)

        val republished = SettingsBackup.settingsBlobFor(
            pulledBlob = null,
            roster = transition.profiles,
            rosterModifiedSeconds = requireNotNull(adopted),
            bundleId = "com.vortx.android",
            now = Date(0L),
        )
        assertEquals(50.875, requireNotNull(SettingsBackup.rosterModifiedFromBlob(republished)), 0.0)
    }
}
