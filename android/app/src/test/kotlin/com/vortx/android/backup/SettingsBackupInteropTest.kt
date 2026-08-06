package com.vortx.android.backup

import com.vortx.android.profile.UserProfile
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import java.util.Date

class SettingsBackupInteropTest {

    @Test
    fun androidBlobCarriesTheLosslessRosterAppleReads() {
        val roster = listOf(
            profile(
                id = "10000000-0000-0000-0000-000000000001",
                name = "Android",
                usesOwnAccount = true,
                email = "android@example.test",
            ),
        )

        val blob = SettingsBackup.settingsBlobFor(
            pulledBlob = null,
            roster = roster,
            rosterModifiedSeconds = 42L,
            bundleId = "com.vortx.android",
            now = Date(0L),
        )

        assertEquals(roster, SettingsBackup.rosterFromBlob(blob))
        assertEquals(42L, SettingsBackup.rosterModifiedFromBlob(blob))
        val domain = decodedDomain(blob)
        assertArrayEquals(
            UserProfile.encodeRoster(roster).toByteArray(Charsets.UTF_8),
            domain[SettingsBackup.ROSTER_KEY] as ByteArray,
        )
    }

    @Test
    fun appleSettingsRosterWinsLossySummaryFieldsWithoutDroppingUniqueProfiles() {
        val sharedId = "20000000-0000-0000-0000-000000000002"
        val appleProfile = profile(
            id = sharedId,
            name = "Apple full profile",
            usesOwnAccount = true,
            email = "apple@example.test",
        )
        val androidOnly = profile(
            id = "30000000-0000-0000-0000-000000000003",
            name = "Android only",
        )
        val appleBlob = blobFromDomain(
            mapOf(
                SettingsBackup.ROSTER_KEY to
                    UserProfile.encodeRoster(listOf(appleProfile)).toByteArray(Charsets.UTF_8),
                SettingsBackup.MODIFIED_KEY to 73.0,
            ),
        )
        val lossySummaryProfile = appleProfile.copy(
            name = "Lossy summary",
            usesOwnAccount = false,
            email = null,
        )

        val resolved = SettingsBackup.resolveRosterForPull(
            pulledBlob = appleBlob,
            fallbackRoster = listOf(lossySummaryProfile, androidOnly),
            fallbackModifiedSeconds = 70L,
        )

        assertEquals(listOf(appleProfile, androidOnly), resolved.roster)
        assertEquals(73L, resolved.modifiedSeconds)
    }

    @Test
    fun malformedPulledBlobIsNeverReplacedByALocalSnapshot() {
        val roster = listOf(profile(name = "Local"))

        assertNull(
            SettingsBackup.settingsBlobFor(
                pulledBlob = "not-base64",
                roster = roster,
                rosterModifiedSeconds = 1L,
                bundleId = "com.vortx.android",
            ),
        )
        assertNull(
            SettingsBackup.settingsBlobFor(
                pulledBlob = JSONObject().put("unexpected", true),
                roster = roster,
                rosterModifiedSeconds = 1L,
                bundleId = "com.vortx.android",
            ),
        )
    }

    @Test
    fun emptyLocalRosterNeverZerosAnExistingSettingsBlob() {
        val original = blobFromDomain(
            mapOf(
                "stremiox.audioLanguage" to "fr",
                SettingsBackup.ROSTER_KEY to
                    UserProfile.encodeRoster(listOf(profile(name = "Cloud"))).toByteArray(Charsets.UTF_8),
            ),
        )

        val rebuilt = SettingsBackup.settingsBlobFor(
            pulledBlob = original,
            roster = emptyList(),
            rosterModifiedSeconds = 2L,
            bundleId = "com.vortx.android",
        )

        assertNull(rebuilt)
        assertEquals("fr", decodedDomain(original)["stremiox.audioLanguage"])
    }

    @Test
    fun rosterRewritePreservesEveryForeignSyncableSetting() {
        val original = blobFromDomain(
            mapOf(
                "stremiox.audioLanguage" to "fr",
                "vortx.future.setting" to listOf("one", "two"),
                SettingsBackup.ACTIVE_KEY to "KEEP-THIS-ACTIVE-ID",
                SettingsBackup.ROSTER_KEY to
                    UserProfile.encodeRoster(listOf(profile(name = "Before"))).toByteArray(Charsets.UTF_8),
                SettingsBackup.MODIFIED_KEY to 1.0,
            ),
        )
        val after = profile(name = "After")

        val rebuilt = SettingsBackup.settingsBlobFor(
            pulledBlob = original,
            roster = listOf(after),
            rosterModifiedSeconds = 9L,
            bundleId = "com.vortx.android",
            now = Date(0L),
        )

        val domain = decodedDomain(rebuilt)
        assertEquals("fr", domain["stremiox.audioLanguage"])
        assertEquals(listOf("one", "two"), domain["vortx.future.setting"])
        assertEquals("KEEP-THIS-ACTIVE-ID", domain[SettingsBackup.ACTIVE_KEY])
        assertEquals(listOf(after), SettingsBackup.rosterFromBlob(rebuilt))
        assertEquals(9L, SettingsBackup.rosterModifiedFromBlob(rebuilt))
    }

    @Test
    fun absentOrMalformedSettingsFallsBackToTheVortxRoster() {
        val fallback = listOf(profile(name = "Fallback"))

        for (blob in listOf<Any?>(null, "broken", JSONObject.NULL, 7)) {
            val resolved = SettingsBackup.resolveRosterForPull(blob, fallback, 55L)
            assertEquals(fallback, resolved.roster)
            assertEquals(55L, resolved.modifiedSeconds)
        }
    }

    private fun blobFromDomain(domain: Map<String, Any>): String {
        val bytes = SettingsBackup.encode(
            domain = domain,
            bundleId = "com.vortx.apple",
            app = "VortX",
            now = Date(0L),
        )
        assertTrue("fixture domain must encode", bytes != null)
        return Base64.getEncoder().encodeToString(bytes!!)
    }

    private fun decodedDomain(blob: String?): Map<String, Any> {
        val bytes = Base64.getDecoder().decode(requireNotNull(blob))
        return requireNotNull(SettingsBackup.decodeDomain(bytes))
    }

    private fun profile(
        id: String = UserProfile.newId(),
        name: String,
        usesOwnAccount: Boolean = false,
        email: String? = null,
    ): UserProfile = UserProfile(
        id = id,
        name = name,
        avatar = "P",
        usesOwnAccount = usesOwnAccount,
        email = email,
    )
}
