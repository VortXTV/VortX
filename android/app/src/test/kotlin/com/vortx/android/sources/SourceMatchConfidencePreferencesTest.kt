package com.vortx.android.sources

import com.vortx.android.engine.NativeHostPreferences
import com.vortx.android.engine.VortxAccountScope
import android.content.SharedPreferences
import com.vortx.android.profile.PlaybackPrefs
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.VortXCrypto
import com.vortx.android.sync.VortXSyncDoc
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.Proxy

class SourceMatchConfidencePreferencesTest {
    private fun playback(threshold: Int?) = PlaybackPrefs("en", "en", "forced", "Arial", "medium", "FFFFFF", "none",
        matchConfidenceThreshold = threshold, includeKeywords = "web", maxResolution = 1080)

    @Test fun rosterSummaryAndEncryptedNativePreferencesRetainTwoDifferentProfileThresholds() {
        val scope = VortxAccountScope("account.00000000-0000-0000-0000-000000000123", UserProfile.OWNER_ID)
        val other = "00000000-0000-0000-0000-000000000456"
        val profiles = JSONObject().put(scope.ownerProfileID, JSONObject().put("playback", PlaybackPrefs.encode(playback(90))))
            .put(other, JSONObject().put("playback", PlaybackPrefs.encode(playback(0))))
        val state = NativeHostPreferences.recordProfiles(scope, NativeHostPreferences.local(scope), JSONObject(), profiles)
        val key = ByteArray(32) { 23 } // Disposable public fixture bytes, not an account key.
        val account = "fixture-source-confidence"
        val version = 1234L
        val box = requireNotNull(VortXCrypto.sealDocument(key, state.getJSONObject("document").toString().toByteArray(), account, version, true))
        val opened = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, box, account, version))))
        assertNull(VortXCrypto.openDocument(key, box, account, version + 1))
        val merged = NativeHostPreferences.merge(scope, NativeHostPreferences.local(scope), opened)
        val roster = JSONObject().put(scope.ownerProfileID, JSONObject().put("name", "Main").put("deleted", false))
            .put(other, JSONObject().put("name", "Other").put("deleted", false))
        val projected = NativeHostPreferences.projectProfiles(merged, profiles, roster)
        NativeHostPreferences.validateProjectedProfiles(projected)
        assertEquals(90, PlaybackPrefs.decode(projected.getJSONObject(scope.ownerProfileID).getJSONObject("playback")).matchConfidenceThreshold)
        assertEquals(0, PlaybackPrefs.decode(projected.getJSONObject(other).getJSONObject("playback")).matchConfidenceThreshold)
        val summary = VortXSyncDoc.playbackSummary(playback(75))
        assertEquals(75, VortXSyncDoc.playbackFromSummary(summary).matchConfidenceThreshold)
        assertEquals("web", VortXSyncDoc.playbackFromSummary(summary).includeKeywords)
        assertEquals(1080, VortXSyncDoc.playbackFromSummary(summary).maxResolution)
        assertEquals(playback(90), PlaybackPrefs.decode(PlaybackPrefs.encode(playback(90))))
    }

    @Test fun oldRostersRemainUnsetAndNativeCarrierRejectsMalformedPercentages() {
        val old = PlaybackPrefs.encode(playback(null))
        assertFalse(old.has("matchConfidenceThreshold"))
        assertNull(PlaybackPrefs.decode(old).matchConfidenceThreshold)
        assertNull(VortXSyncDoc.playbackFromSummary(JSONObject()).matchConfidenceThreshold)
        val scope = VortxAccountScope("account.00000000-0000-0000-0000-000000000123", UserProfile.OWNER_ID)
        for (bad in listOf(-1, 101, 1.5, "90", true, JSONObject())) {
            val profile = JSONObject().put(scope.ownerProfileID, JSONObject().put("playback", JSONObject().put("matchConfidenceThreshold", bad)))
            assertTrue("Rejected $bad", runCatching {
                NativeHostPreferences.recordProfiles(scope, NativeHostPreferences.local(scope), JSONObject(), profile)
            }.isFailure)
        }
        assertTrue(SourceSettingsRevision.affectsSourceResults(SourcePreferencesStore.MATCH_CONFIDENCE_KEY))
    }

    @Test fun actualProfilePreferenceApplyResetsOlderProfileAndPreservesPartialSync() {
        val values = mutableMapOf<String, Int>()
        lateinit var editor: SharedPreferences.Editor
        editor = Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader,
            arrayOf(SharedPreferences.Editor::class.java)) { _, method, args ->
            when (method.name) {
                "putInt" -> { values[args!![0] as String] = args[1] as Int; editor }
                else -> error("Unexpected editor operation ${method.name}")
            }
        } as SharedPreferences.Editor
        val main = UserProfile(name = "Main", avatar = "star", playback = playback(90))
        val older = UserProfile(name = "Older", avatar = "moon", playback = playback(null))
        SourcePreferencesStore.applyProfileMatchConfidence(editor, main.playback?.matchConfidenceThreshold, true)
        assertEquals(90, values[SourcePreferencesStore.MATCH_CONFIDENCE_KEY])
        SourcePreferencesStore.applyProfileMatchConfidence(editor, older.playback?.matchConfidenceThreshold, false)
        assertEquals(90, values[SourcePreferencesStore.MATCH_CONFIDENCE_KEY])
        SourcePreferencesStore.applyProfileMatchConfidence(editor, older.playback?.matchConfidenceThreshold, true)
        assertEquals(0, values[SourcePreferencesStore.MATCH_CONFIDENCE_KEY])
        SourcePreferencesStore.applyProfileMatchConfidence(editor, main.playback?.matchConfidenceThreshold, true)
        assertEquals(90, values[SourcePreferencesStore.MATCH_CONFIDENCE_KEY])
    }
}
