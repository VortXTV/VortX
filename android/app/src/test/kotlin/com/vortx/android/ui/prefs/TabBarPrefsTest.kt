package com.vortx.android.ui.prefs

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TabBarPrefsTest {

    @Test
    fun `tab keys match the Apple vocabulary`() {
        assertEquals(
            setOf(
                "vortx.tabs.hide.discover",
                "vortx.tabs.hide.live",
                "vortx.tabs.hide.library",
                "vortx.tabs.hide.search",
            ),
            setOf(
                TabBarPrefs.HIDE_DISCOVER_KEY,
                TabBarPrefs.HIDE_LIVE_KEY,
                TabBarPrefs.HIDE_LIBRARY_KEY,
                TabBarPrefs.HIDE_SEARCH_KEY,
            ),
        )
    }

    @Test
    fun `home and settings remain visible when every optional tab is hidden`() {
        val hidden = TabBarPrefs.State(
            hideDiscover = true,
            hideLive = true,
            hideLibrary = true,
            hideSearch = true,
        )

        assertTrue(hidden.isVisible(TabSlot.HOME))
        assertTrue(hidden.isVisible(TabSlot.SETTINGS))
        assertFalse(hidden.isVisible(TabSlot.DISCOVER))
        assertFalse(hidden.isVisible(TabSlot.LIVE))
        assertFalse(hidden.isVisible(TabSlot.LIBRARY))
        assertFalse(hidden.isVisible(TabSlot.SEARCH))
    }

    @Test
    fun `hiding the selected tab resolves selection to home`() {
        val hidden = TabBarPrefs.State(
            hideDiscover = true,
            hideLive = false,
            hideLibrary = false,
            hideSearch = false,
        )

        assertEquals(TabSlot.HOME, hidden.resolveSelected(TabSlot.DISCOVER))
        assertEquals(TabSlot.LIBRARY, hidden.resolveSelected(TabSlot.LIBRARY))
        assertEquals(TabSlot.SETTINGS, hidden.resolveSelected(TabSlot.SETTINGS))
    }
}
