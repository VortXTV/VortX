package com.vortx.android.backup

import com.vortx.android.profile.UserProfile
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import java.util.Date

class SettingsBackupInteropTest {

    private val deniedKeys = listOf(
        "AppleLanguages",
        "NSNavLastRootDirectory",
        "com.apple.example",
        "WebKitLocalStorage",
        "WebDatabaseDirectory",
        "PKInstallHistory",
        "MetricKitPayload",
        "INNextRefreshDate",
        "stremiox.diskCacheBytes",
        "stremiox.serverURL",
        "stremiox.videoUpscaling",
        "stremiox.dvRemux",
        "vortx.pgsSubtitleOCR",
        "vortx.downloads.queueOrder",
        "vortx.downloads.maxConcurrent",
        "vortx.moveSeeding.launchNagDismissedBuild",
        "vortx.sync.lastSyncedVersion.account",
        "kcinvalidated.account",
        "kcfallback.account",
    )

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

    @Test
    fun everyCurrentAppleDeniedKeyAndPrefixIsNotSyncable() {
        deniedKeys.forEach { key ->
            assertFalse("must not sync $key", SettingsBackup.isSyncable(key))
        }
        assertTrue(SettingsBackup.isSyncable("vortx.downloads.autoDeleteWatched"))
        assertTrue(SettingsBackup.isSyncable("vortx.future.setting"))
    }

    @Test
    fun poisonedIncomingBlobIsScrubbedWhileSafeUnknownSettingsSurvive() {
        val cloudProfile = profile(name = "Cloud")
        val poisoned = LinkedHashMap<String, Any>().apply {
            deniedKeys.forEach { key -> put(key, "must-not-survive") }
            put("vortx.downloads.autoDeleteWatched", true)
            put("vortx.future.setting", listOf("one", "two"))
            put(
                SettingsBackup.ROSTER_KEY,
                UserProfile.encodeRoster(listOf(cloudProfile)).toByteArray(Charsets.UTF_8),
            )
            put(SettingsBackup.MODIFIED_KEY, 1.0)
        }
        val original = blobFromDomain(poisoned)

        val decoded = SettingsBackup.decodeDomain(Base64.getDecoder().decode(original))
        deniedKeys.forEach { key -> assertFalse("decoded $key", requireNotNull(decoded).containsKey(key)) }
        assertEquals(true, decoded?.get("vortx.downloads.autoDeleteWatched"))
        assertEquals(listOf("one", "two"), decoded?.get("vortx.future.setting"))

        val rebuilt = SettingsBackup.settingsBlobFor(
            pulledBlob = original,
            roster = listOf(profile(name = "Local")),
            rosterModifiedSeconds = 2L,
            bundleId = "com.vortx.android",
            now = Date(0L),
        )
        val rawRebuilt = rawDomain(rebuilt)
        deniedKeys.forEach { key -> assertFalse("rebuilt $key", rawRebuilt.containsKey(key)) }
        assertEquals(true, rawRebuilt["vortx.downloads.autoDeleteWatched"])
        assertEquals(listOf("one", "two"), rawRebuilt["vortx.future.setting"])
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

    private fun rawDomain(blob: String?): Map<String, Any> {
        val envelopeBytes = Base64.getDecoder().decode(requireNotNull(blob))
        val envelope = JSONObject(String(envelopeBytes, Charsets.UTF_8))
        val plist = Base64.getDecoder().decode(envelope.getString("payloadBase64"))
        val decoded = requireNotNull(BinaryPlist.decode(plist) as? Map<*, *>)
        return decoded.entries.associate { (key, value) ->
            require(key is String && value != null)
            key to value
        }
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
