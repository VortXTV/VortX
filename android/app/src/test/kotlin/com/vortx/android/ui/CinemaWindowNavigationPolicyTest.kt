package com.vortx.android.ui

import com.vortx.android.ui.prefs.TabBarPrefs
import com.vortx.android.ui.prefs.TabSlot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CinemaWindowNavigationPolicyTest {
    private val visiblePrefs = TabBarPrefs.State(false, false, false, false)
    private val allTabs = TabSlot.entries.toList()

    @Test fun `measured phone tablet and split window widths choose only chrome`() {
        for (width in listOf(320f, 390f, 600f, 759.99f, Float.NaN, Float.POSITIVE_INFINITY)) {
            assertFalse(cinemaWindowNavigation(width, allTabs).topNavigation)
        }
        for (width in listOf(760f, 844f, 1024f, 1365f)) {
            val wide = cinemaWindowNavigation(width, allTabs)
            assertTrue(wide.topNavigation)
            assertEquals(allTabs, wide.primary)
            assertTrue(wide.overflow.isEmpty())
        }
    }

    @Test fun `compact seven destination layout matches Apple primary order and More`() {
        val compact = cinemaWindowNavigation(390f, allTabs)
        assertEquals(listOf(TabSlot.HOME, TabSlot.DISCOVER, TabSlot.LIBRARY, TabSlot.SEARCH), compact.primary)
        assertEquals(listOf(TabSlot.LIVE, TabSlot.ADDONS, TabSlot.SETTINGS), compact.overflow)
        assertTrue(compact.selectsOverflow(TabSlot.ADDONS))
        assertFalse(compact.selectsOverflow(TabSlot.SEARCH))
    }

    @Test fun `direct Addons owns its compact toolbar and wide chrome is navigation only`() {
        val compact = cinemaWindowNavigation(390f, allTabs)
        val wide = cinemaWindowNavigation(1024f, allTabs)
        assertFalse(compact.usesCompactTitleBar(TabSlot.ADDONS))
        for (destination in allTabs.filter { it != TabSlot.ADDONS }) {
            assertTrue(compact.usesCompactTitleBar(destination))
        }
        for (destination in allTabs) assertFalse(wide.usesCompactTitleBar(destination))
    }

    @Test fun `hidden merged tabs never reappear in More and every anchor remains reachable`() {
        for (mask in 0 until 16) {
            val prefs = TabBarPrefs.State(mask and 1 != 0, mask and 2 != 0, mask and 4 != 0, mask and 8 != 0)
            for (homeMerge in listOf(false, true)) for (searchMerge in listOf(false, true)) {
                val visible = cinemaVisibleTabs(prefs, homeMerge, searchMerge)
                val compact = cinemaWindowNavigation(600f, visible)
                val presented = compact.primary + compact.overflow
                assertEquals(visible.toSet(), presented.toSet())
                assertEquals(visible.size, presented.size)
                assertEquals(visible.filter { it in compact.primary }, compact.primary)
                assertEquals(visible.filter { it in compact.overflow }, compact.overflow)
                assertTrue(compact.primary.size + (if (compact.overflow.isEmpty()) 0 else 1) <= 5)
                assertTrue(TabSlot.HOME in compact.primary)
                assertTrue(TabSlot.ADDONS in presented)
                assertTrue(TabSlot.SETTINGS in presented)
                if (visible.size <= 5) {
                    assertEquals(visible, compact.primary)
                    assertTrue(compact.overflow.isEmpty())
                }
                assertEquals(visible, cinemaWindowNavigation(760f, visible).primary)
            }
        }
    }

    @Test fun `existing stored names and hidden preferences retain destination identities`() {
        val legacy = listOf("HOME", "DISCOVER", "LIVE", "LIBRARY", "SEARCH", "SETTINGS")
        legacy.forEach { name -> assertEquals(name, cinemaStoredTabSlot(name).name) }
        assertEquals(TabSlot.ADDONS, cinemaStoredTabSlot("ADDONS"))
        assertEquals(TabSlot.HOME, cinemaStoredTabSlot("removed-future-tab"))
        assertEquals(TabSlot.HOME, cinemaStoredTabSlot(null))
        val hidden = visiblePrefs.copy(hideDiscover = true, hideLive = true, hideLibrary = true, hideSearch = true)
        assertEquals(listOf(TabSlot.HOME, TabSlot.ADDONS, TabSlot.SETTINGS), cinemaVisibleTabs(hidden, false, false))
        assertEquals(CinemaTabRoute(TabSlot.ADDONS, CinemaHomeMode.FEATURED),
            cinemaTabRoute(cinemaStoredTabSlot("ADDONS"), CinemaHomeMode.FEATURED, hidden, true, true))
    }

    @Test fun `More selection and detail back retain the real destination through every resize`() {
        var selected = TabSlot.HOME
        val compact = cinemaWindowNavigation(390f, allTabs)
        for (destination in compact.overflow) {
            val action = cinemaNavigationSelection(selected, destination)
            assertEquals(destination, action.destination)
            assertFalse(action.popToRoot)
            selected = action.destination
            // Detail overlays retain this shell destination; returning to it must still select More.
            assertTrue(cinemaWindowNavigation(390f, allTabs).selectsOverflow(selected))
            for (width in listOf(1024f, 600f, 844f, 390f)) {
                val resized = cinemaWindowNavigation(width, allTabs)
                assertTrue(selected in resized.primary || selected in resized.overflow)
                assertEquals(destination, selected)
            }
            val reselect = cinemaNavigationSelection(selected, destination)
            assertTrue(reselect.popToRoot)
            assertEquals(destination, reselect.destination)
        }
    }

    @Test fun `Home Browse choice survives changing window chrome`() {
        val route = cinemaTabRoute(TabSlot.DISCOVER, CinemaHomeMode.FEATURED, visiblePrefs, true, false)
        val visible = cinemaVisibleTabs(visiblePrefs, true, false)
        for (width in listOf(390f, 1024f, 600f, 760f)) {
            assertTrue(route.tab in cinemaWindowNavigation(width, visible).primary)
            assertEquals(CinemaTabRoute(TabSlot.HOME, CinemaHomeMode.BROWSE), route)
        }
    }
}
