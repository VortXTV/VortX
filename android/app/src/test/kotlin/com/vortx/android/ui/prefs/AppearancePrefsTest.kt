package com.vortx.android.ui.prefs

import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.theme.VortXAccents
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppearancePrefsTest {

    @Test
    fun `appearance keys match the Apple vocabulary`() {
        assertEquals(
            setOf(
                "stremiox.theme.accent",
                "stremiox.theme.oled",
                "stremiox.theme.textScale",
            ),
            setOf(
                AppearancePrefs.ACCENT_KEY,
                AppearancePrefs.OLED_KEY,
                AppearancePrefs.TEXT_SCALE_KEY,
            ),
        )
    }

    @Test
    fun `royal accent and oled persist on the active profile model`() {
        val profile = profile().withAppearance(
            AppearancePrefs.State(
                accentId = VortXAccents.royal.id,
                oled = true,
                textScale = 1.2,
            ),
        )

        assertEquals("royal", profile.accentID)
        assertTrue(profile.oled)
        assertEquals(1.2, profile.textScale, 0.0)
    }

    @Test
    fun `material you remains preview only and is never persisted`() {
        val profile = profile().withAppearance(
            AppearancePrefs.State(
                accentId = VortXAccents.MATERIAL_YOU_ID,
                oled = false,
                textScale = 1.0,
            ),
        )

        assertEquals(VortXAccents.default.id, profile.accentID)
        assertFalse(profile.oled)
        assertTrue(VortXAccents.curated.any { it.id == VortXAccents.royal.id })
        assertFalse(VortXAccents.curated.any { it.id == VortXAccents.MATERIAL_YOU_ID })
    }

    @Test
    fun `text scale written to a profile is finite and clamped`() {
        val tooLarge = profile().withAppearance(
            AppearancePrefs.State("royal", false, 9.0),
        )
        val invalid = profile().withAppearance(
            AppearancePrefs.State("royal", false, Double.NaN),
        )

        assertEquals(AppearancePrefs.TEXT_SCALE_MAX, tooLarge.textScale, 0.0)
        assertEquals(AppearancePrefs.TEXT_SCALE_DEFAULT, invalid.textScale, 0.0)
    }

    private fun profile() = UserProfile(
        name = "Main",
        avatar = "🍿",
        accentID = "vortx",
        isOwner = true,
    )
}
