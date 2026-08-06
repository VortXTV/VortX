package com.vortx.android.backup

import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.VortXSyncDoc
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigInteger
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
            rosterModifiedSeconds = 42.875,
            bundleId = "com.vortx.android",
            now = Date(0L),
        )

        assertEquals(roster, SettingsBackup.rosterFromBlob(blob))
        assertEquals(42.875, requireNotNull(SettingsBackup.rosterModifiedFromBlob(blob)), 0.0)
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
                SettingsBackup.MODIFIED_KEY to 10.25,
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
            fallbackModifiedSeconds = 100.0,
        )

        assertEquals(listOf(appleProfile, androidOnly), resolved.roster)
        assertEquals(10.25, requireNotNull(resolved.modifiedSeconds), 0.0)
    }

    @Test
    fun newerFullVortxRosterBeatsOlderSettingsFieldsAndCarriesTheClockForward() {
        val sharedId = "22000000-0000-0000-0000-000000000002"
        val oldSettings = profile(id = sharedId, name = "Old settings")
        val newFullRoster = profile(id = sharedId, name = "New full roster")
        val oldBlob = blobFromDomain(
            mapOf(
                SettingsBackup.ROSTER_KEY to
                    UserProfile.encodeRoster(listOf(oldSettings)).toByteArray(Charsets.UTF_8),
                SettingsBackup.MODIFIED_KEY to 10.25,
            ),
        )

        val parsed = VortXSyncDoc.parse(
            JSONObject().put(
                "vortx",
                JSONObject()
                    .put("roster", JSONArray().put(UserProfile.encodeProfile(newFullRoster)))
                    .put("rosterModified", 20.75),
            ),
        )
        assertTrue(parsed.rosterIsLossless)
        val resolved = SettingsBackup.resolveRosterForPull(
            pulledBlob = oldBlob,
            fallbackRoster = parsed.roster,
            fallbackModifiedSeconds = parsed.rosterModifiedSeconds,
            fallbackIsLossless = parsed.rosterIsLossless,
        )

        assertEquals(listOf(newFullRoster), resolved.roster)
        assertEquals(20.75, requireNotNull(resolved.modifiedSeconds), 0.0)

        // Models pull-then-repush: the adopted maximum watermark must replace the old settings stamp.
        val republished = SettingsBackup.settingsBlobFor(
            pulledBlob = oldBlob,
            roster = requireNotNull(resolved.roster),
            rosterModifiedSeconds = requireNotNull(resolved.modifiedSeconds),
            bundleId = "com.vortx.android",
            now = Date(0L),
        )
        assertEquals(listOf(newFullRoster), SettingsBackup.rosterFromBlob(republished))
        assertEquals(20.75, requireNotNull(SettingsBackup.rosterModifiedFromBlob(republished)), 0.0)
    }

    @Test
    fun vortxCarrierPublishesAndParsesFractionalRosterClocksWithoutTruncation() {
        val published = JSONObject()
        VortXSyncDoc.writeRosterModified(published, 80.625)

        val parsedPublished = VortXSyncDoc.parse(JSONObject().put("vortx", published))
        assertEquals(80.625, requireNotNull(parsedPublished.rosterModifiedSeconds), 0.0)

        val parsedAppleMillis = VortXSyncDoc.parse(
            JSONObject().put("vortx", JSONObject().put("updatedAt", 80_625L)),
        )
        assertEquals(80.625, requireNotNull(parsedAppleMillis.rosterModifiedSeconds), 0.0)
    }

    @Test
    fun appleSubBrightnessSurvivesFullRosterAndSummaryRoundTrips() {
        val appleProfileJson = JSONObject()
            .put("id", "23000000-0000-0000-0000-000000000002")
            .put("name", "Apple")
            .put("avatar", "A")
            .put("accentID", "ember")
            .put("oled", false)
            .put("textScale", 1.0)
            .put("usesOwnAccount", false)
            .put("isOwner", false)
            .put("familyEdit", false)
            .put("isKids", false)
            .put(
                "playback",
                JSONObject()
                    .put("audioLang", "en")
                    .put("subtitleLang", "en")
                    .put("forcedPolicy", "forced")
                    .put("subFont", "modern")
                    .put("subSize", "m")
                    .put("subColor", "white")
                    .put("subBackground", "outline")
                    .put("subBrightness", "75"),
            )
        val appleBlob = blobFromDomain(
            mapOf(
                SettingsBackup.ROSTER_KEY to
                    JSONArray().put(appleProfileJson).toString().toByteArray(Charsets.UTF_8),
                SettingsBackup.MODIFIED_KEY to 30.0,
            ),
        )
        val decoded = requireNotNull(SettingsBackup.rosterFromBlob(appleBlob)).single()
        assertEquals("75", decoded.playback?.subBrightness)

        val rebuilt = SettingsBackup.settingsBlobFor(
            pulledBlob = appleBlob,
            roster = listOf(decoded),
            rosterModifiedSeconds = 30.0,
            bundleId = "com.vortx.android",
            now = Date(0L),
        )
        val rawRoster = String(rawDomain(rebuilt)[SettingsBackup.ROSTER_KEY] as ByteArray, Charsets.UTF_8)
        assertEquals("75", JSONArray(rawRoster).getJSONObject(0).getJSONObject("playback").getString("subBrightness"))
        assertEquals("75", VortXSyncDoc.playbackSummary(requireNotNull(decoded.playback)).getString("subBrightness"))

        val summaryDoc = JSONObject().put(
            "vortx",
            JSONObject().put(
                "profiles",
                JSONArray().put(
                    JSONObject()
                        .put("id", decoded.id)
                        .put("name", decoded.name)
                        .put("settings", JSONObject().put("playback", JSONObject()
                            .put("audioLang", "en")
                            .put("subtitleLang", "en")
                            .put("forced", "forced")
                            .put("subFont", "modern")
                            .put("subSize", "m")
                            .put("subColor", "white")
                            .put("subBackground", "outline")
                            .put("subBrightness", "75"))),
                ),
            ),
        )
        assertEquals("75", VortXSyncDoc.parse(summaryDoc).roster?.single()?.playback?.subBrightness)
    }

    @Test
    fun malformedPulledBlobIsNeverReplacedByALocalSnapshot() {
        val roster = listOf(profile(name = "Local"))

        assertNull(
            SettingsBackup.settingsBlobFor(
                pulledBlob = "not-base64",
                roster = roster,
                rosterModifiedSeconds = 1.0,
                bundleId = "com.vortx.android",
            ),
        )
        assertNull(
            SettingsBackup.settingsBlobFor(
                pulledBlob = JSONObject().put("unexpected", true),
                roster = roster,
                rosterModifiedSeconds = 1.0,
                bundleId = "com.vortx.android",
            ),
        )
    }

    @Test
    fun envelopeRequiresEveryAppleCodableFieldWithItsWireType() {
        val valid = JSONObject(
            String(
                requireNotNull(
                    SettingsBackup.encode(
                        domain = mapOf("vortx.future.setting" to true),
                        bundleId = "com.vortx.apple",
                        app = "VortX",
                        now = Date(0L),
                    ),
                ),
                Charsets.UTF_8,
            ),
        )
        val required = listOf("format", "schema", "app", "bundleID", "createdAt", "keyCount", "payloadBase64")
        required.forEach { key ->
            val missing = JSONObject(valid.toString()).apply { remove(key) }
            assertNull("missing $key", SettingsBackup.decodeDomain(missing.toString().toByteArray()))
            assertNull("missing $key must not be rewritten", rewriteMalformedEnvelope(missing))
        }
        val wrongTypes = mapOf<String, Any>(
            "format" to 1,
            "schema" to "1",
            "app" to true,
            "bundleID" to 7,
            "createdAt" to 0,
            "keyCount" to "1",
            "payloadBase64" to false,
        )
        wrongTypes.forEach { (key, value) ->
            val malformed = JSONObject(valid.toString()).put(key, value)
            assertNull("wrong type $key", SettingsBackup.decodeDomain(malformed.toString().toByteArray()))
            assertNull("wrong type $key must not be rewritten", rewriteMalformedEnvelope(malformed))
        }
        for (compatible in listOf(
            "1970-01-01T00:00:00.123Z",
            "1970-01-01T01:00:00+01:00",
            "1970-01-01T00:00:00+0000",
            "1970-01-01T00:00:00+00",
        )) {
            val compatibleDate = JSONObject(valid.toString()).put("createdAt", compatible)
            assertTrue(
                "Apple-compatible date $compatible",
                SettingsBackup.decodeDomain(compatibleDate.toString().toByteArray()) != null,
            )
        }
        val badDate = JSONObject(valid.toString()).put("createdAt", "not-an-iso8601-date")
        assertNull("invalid date", SettingsBackup.decodeDomain(badDate.toString().toByteArray()))
        assertNull("bad date must not be rewritten", rewriteMalformedEnvelope(badDate))
        val lowercaseDate = JSONObject(valid.toString()).put("createdAt", "1970-01-01t00:00:00z")
        assertNull("Foundation rejects lowercase t/z", SettingsBackup.decodeDomain(lowercaseDate.toString().toByteArray()))

        for (outsideSwiftInt in listOf(
            BigInteger("9223372036854775808"),
            BigInteger("-9223372036854775809"),
        )) {
            val outOfRange = JSONObject(valid.toString()).put("schema", outsideSwiftInt)
            assertNull("out-of-range Swift Int", SettingsBackup.decodeDomain(outOfRange.toString().toByteArray()))
            assertNull("out-of-range Swift Int must not be rewritten", rewriteMalformedEnvelope(outOfRange))
        }
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
            rosterModifiedSeconds = 2.0,
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
            rosterModifiedSeconds = 9.5,
            bundleId = "com.vortx.android",
            now = Date(0L),
        )

        val domain = decodedDomain(rebuilt)
        assertEquals("fr", domain["stremiox.audioLanguage"])
        assertEquals(listOf("one", "two"), domain["vortx.future.setting"])
        assertEquals("KEEP-THIS-ACTIVE-ID", domain[SettingsBackup.ACTIVE_KEY])
        assertEquals(listOf(after), SettingsBackup.rosterFromBlob(rebuilt))
        assertEquals(9.5, requireNotNull(SettingsBackup.rosterModifiedFromBlob(rebuilt)), 0.0)
    }

    @Test
    fun absentOrMalformedSettingsFallsBackToTheVortxRoster() {
        val fallback = listOf(profile(name = "Fallback"))

        for (blob in listOf<Any?>(null, "broken", JSONObject.NULL, 7)) {
            val resolved = SettingsBackup.resolveRosterForPull(blob, fallback, 55.0)
            assertEquals(fallback, resolved.roster)
            assertEquals(55.0, requireNotNull(resolved.modifiedSeconds), 0.0)
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
            rosterModifiedSeconds = 2.0,
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

    private fun rewriteMalformedEnvelope(envelope: JSONObject): String? =
        SettingsBackup.settingsBlobFor(
            pulledBlob = Base64.getEncoder().encodeToString(envelope.toString().toByteArray()),
            roster = listOf(profile(name = "Local")),
            rosterModifiedSeconds = 1.0,
            bundleId = "com.vortx.android",
        )

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
