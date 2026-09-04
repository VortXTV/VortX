package com.vortx.android.profile

import com.vortx.android.backup.SettingsBackup
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileDiscoveryPreferencesCodecTest {
    @Test
    fun `discovery snapshot round trips with Apple's exact field names`() {
        val snapshot = ProfileDiscoveryPreferences(
            hiddenCatalogs = listOf("a", "b"),
            catalogOrder = listOf("b", "a"),
            hiddenHubCategories = listOf("section:genres"),
            regionOverrideCaptured = true,
            regionOverride = "GB",
            filtersCaptured = true,
            filtersData = "eyJtaW5ZZWFyIjoyMDIwfQ==",
            selectedProviders = listOf(8, 119),
            providerOrder = listOf(119, 8),
            tabVisibilityCaptured = true,
            hideLiveTab = true,
            hideDiscoverTab = false,
            hideLibraryTab = true,
            hideSearchTab = false,
        )
        val profile = UserProfile(name = "Viewer", avatar = "🍿", discovery = snapshot)
        val encoded = UserProfile.encodeProfile(profile)

        val discovery = encoded.getJSONObject("discovery")
        listOf(
            "hiddenCatalogs", "catalogOrder", "hiddenHubCategories", "regionOverrideCaptured",
            "regionOverride", "filtersCaptured", "filtersData", "selectedProviders", "providerOrder",
            "tabVisibilityCaptured", "hideLiveTab", "hideDiscoverTab", "hideLibraryTab", "hideSearchTab",
        ).forEach { assertTrue("missing $it", discovery.has(it)) }
        assertEquals(snapshot, UserProfile.decodeProfile(encoded).discovery)
    }

    @Test
    fun `legacy roster remains nullable while explicit clears survive`() {
        val legacy = JSONObject().apply {
            put("id", UserProfile.OWNER_ID)
            put("name", "Main")
            put("avatar", "🍿")
        }
        assertNull(UserProfile.decodeProfile(legacy).discovery)

        val clear = ProfileDiscoveryPreferences(
            regionOverrideCaptured = true,
            filtersCaptured = true,
            tabVisibilityCaptured = true,
        )
        val decoded = UserProfile.decodeProfile(UserProfile.encodeProfile(UserProfile(name = "Viewer", avatar = "🍿", discovery = clear))).discovery
        requireNotNull(decoded)
        assertTrue(decoded.regionOverrideCaptured == true)
        assertNull(decoded.regionOverride)
        assertTrue(decoded.filtersCaptured == true)
        assertNull(decoded.filtersData)
        assertTrue(decoded.tabVisibilityCaptured == true)
        assertNull(decoded.hideLiveTab)
    }

    @Test
    fun `active discovery projection cannot enter global backup sync`() {
        ProfileDiscoveryPreferencesStore.activeProjectionKeys.forEach { key ->
            assertFalse("must not sync active projection $key", SettingsBackup.isSyncable(key))
        }
        assertTrue(SettingsBackup.isSyncable("vortx.downloads.autoDeleteWatched"))
    }

    @Test
    fun `partial tab payload owns only populated tab fields`() {
        assertTrue(ProfileDiscoveryPreferencesStore.tabFieldIsAuthoritative(null, true))
        assertFalse(ProfileDiscoveryPreferencesStore.tabFieldIsAuthoritative(null, null))
        assertTrue(ProfileDiscoveryPreferencesStore.tabFieldIsAuthoritative(true, null))
    }

    @Test
    fun `active profile discovery edit remains roster serializable immediately`() {
        val edited = UserProfile(
            name = "Main",
            avatar = "🍿",
            discovery = ProfileDiscoveryPreferences(
                regionOverrideCaptured = true,
                filtersCaptured = true,
                filtersData = "e30=",
                tabVisibilityCaptured = true,
                hideLiveTab = true,
            ),
        )
        assertEquals(edited.discovery, UserProfile.decodeRoster(UserProfile.encodeRoster(listOf(edited)))!!.single().discovery)
    }

    @Test
    fun `discovery-only capture never changes the existing playback payload`() {
        val playback = PlaybackPrefs(
            audioLang = "ja", subtitleLang = "en", forcedPolicy = "forced", subFont = "Arial",
            subSize = "medium", subColor = "FFFFFF", subBackground = "none",
        )
        val before = UserProfile(name = "Main", avatar = "🍿", playback = playback)
        val after = requireNotNull(before.withDiscoverySnapshot(ProfileDiscoveryPreferences(hideLiveTab = true)))

        assertEquals(playback, after.playback)
        assertTrue(after.discovery?.hideLiveTab == true)
        assertNull(after.withDiscoverySnapshot(requireNotNull(after.discovery)))
    }

    @Test
    fun `discovery capture replaces and pushes once without touching playback`() {
        val playback = PlaybackPrefs("ja", "en", "forced", "Arial", "medium", "FFFFFF", "none")
        val profile = UserProfile(name = "Main", avatar = "🍿", playback = playback)
        var replaced: UserProfile? = null
        var pushes = 0

        assertTrue(
            applyDiscoveryCaptureTransition(
                profile,
                ProfileDiscoveryPreferences(filtersCaptured = true, filtersData = "e30="),
                replace = { replaced = it },
                persistAndPush = { pushes++ },
            ),
        )
        assertEquals(playback, replaced?.playback)
        assertEquals(1, pushes)
        assertFalse(
            applyDiscoveryCaptureTransition(
                requireNotNull(replaced),
                requireNotNull(replaced).discovery!!,
                replace = { error("unchanged snapshot must not replace") },
                persistAndPush = { error("unchanged snapshot must not push") },
            ),
        )
    }

    @Test
    fun `projection application does not recurse into a discovery capture`() {
        assertFalse(shouldCaptureDiscovery(applyingProjection = true))
        assertTrue(shouldCaptureDiscovery(applyingProjection = false))
    }
}
