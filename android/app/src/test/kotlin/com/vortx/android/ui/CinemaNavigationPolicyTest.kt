package com.vortx.android.ui

import com.vortx.android.ui.prefs.TabBarPrefs
import com.vortx.android.ui.prefs.TabSlot
import com.vortx.android.ui.prefs.isVisible
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CinemaNavigationPolicyTest {
    private val visible = TabBarPrefs.State(false, false, false, false)
    private fun route(tab: TabSlot, hidden: TabBarPrefs.State = visible, homeMerge: Boolean = true,
        searchMerge: Boolean = false, mode: CinemaHomeMode = CinemaHomeMode.FEATURED) =
        cinemaTabRoute(tab, mode, hidden, homeMerge, searchMerge)

    @Test fun `old Discover restores to Home Browse and hidden Discover restores Featured`() {
        assertEquals(CinemaTabRoute(TabSlot.HOME, CinemaHomeMode.BROWSE), route(TabSlot.DISCOVER))
        assertEquals(CinemaTabRoute(TabSlot.HOME, CinemaHomeMode.FEATURED), route(TabSlot.DISCOVER, visible.copy(hideDiscover = true)))
        assertEquals(TabSlot.DISCOVER, route(TabSlot.DISCOVER, homeMerge = false).tab)
    }

    @Test fun `old Search folds into actual browse owner before hidden checks`() {
        assertEquals(CinemaTabRoute(TabSlot.HOME, CinemaHomeMode.BROWSE), route(TabSlot.SEARCH, searchMerge = true))
        assertEquals(TabSlot.DISCOVER, route(TabSlot.SEARCH, homeMerge = false, searchMerge = true).tab)
        assertEquals(CinemaTabRoute(TabSlot.HOME, CinemaHomeMode.BROWSE), route(TabSlot.SEARCH, visible.copy(hideSearch = true), searchMerge = true))
        assertEquals(CinemaTabRoute(TabSlot.HOME, CinemaHomeMode.FEATURED), route(TabSlot.SEARCH, visible.copy(hideDiscover = true), searchMerge = true))
        assertEquals(TabSlot.SEARCH, route(TabSlot.SEARCH, visible.copy(hideDiscover = true), searchMerge = false).tab)
        assertEquals(TabSlot.HOME, route(TabSlot.SEARCH, visible.copy(hideSearch = true), searchMerge = false).tab)
    }

    @Test fun `merge off restores separate Discover without losing active Browse`() {
        val merged = route(TabSlot.DISCOVER)
        val separate = cinemaRouteAfterHomeMergeChange(merged, false, false, visible)
        assertEquals(CinemaTabRoute(TabSlot.DISCOVER, CinemaHomeMode.FEATURED), separate)
        assertEquals(merged, cinemaRouteAfterHomeMergeChange(separate, true, false, visible))
        assertEquals(CinemaTabRoute(TabSlot.HOME, CinemaHomeMode.FEATURED),
            cinemaRouteAfterHomeMergeChange(merged, false, false, visible.copy(hideDiscover = true)))
    }

    @Test fun `merged tabs preserve Live Library Search and all hide preferences`() {
        assertEquals(listOf(TabSlot.HOME, TabSlot.LIVE, TabSlot.LIBRARY, TabSlot.SEARCH, TabSlot.SETTINGS),
            cinemaVisibleTabs(visible, true, false))
        assertEquals(listOf(TabSlot.HOME, TabSlot.SETTINGS), cinemaVisibleTabs(visible.copy(hideLive = true, hideLibrary = true, hideSearch = true), true, false))
        assertFalse(cinemaVisibleTabs(visible, true, true).contains(TabSlot.SEARCH))
        assertTrue(cinemaVisibleTabs(visible, false, false).contains(TabSlot.DISCOVER))
    }

    @Test fun `every legacy tab and hidden combination resolves to a visible destination`() {
        for (mask in 0 until 16) {
            val hidden = TabBarPrefs.State(mask and 1 != 0, mask and 2 != 0, mask and 4 != 0, mask and 8 != 0)
            for (homeMerge in listOf(false, true)) for (searchMerge in listOf(false, true)) for (tab in TabSlot.entries) {
                val result = route(tab, hidden, homeMerge, searchMerge, CinemaHomeMode.BROWSE)
                assertTrue(hidden.isVisible(result.tab))
                assertTrue(result.tab in cinemaVisibleTabs(hidden, homeMerge, searchMerge))
                if (hidden.hideDiscover || !homeMerge) assertEquals(CinemaHomeMode.FEATURED, result.homeMode)
            }
        }
    }
}
