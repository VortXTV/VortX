package com.vortx.android.ui

import com.vortx.android.ui.prefs.TabSlot
import org.junit.Assert.*
import org.junit.Test

class CinemaAdaptiveNavigationTest {
    @Test fun `top chrome belongs to a wide tablet window not a landscape phone`() {
        assertTrue(cinemaUsesTopNavigation(800, 1280))
        assertTrue(cinemaUsesTopNavigation(1280, 800))
        assertFalse(cinemaUsesTopNavigation(920, 430))
        assertFalse(cinemaUsesTopNavigation(600, 1024))
        assertFalse(cinemaUsesTopNavigation(0, 0))
    }

    @Test fun `seven destinations use four main targets plus complete overflow`() {
        val plan = cinemaCompactNavigation(TabSlot.entries)
        assertEquals(listOf(TabSlot.HOME, TabSlot.DISCOVER, TabSlot.LIBRARY, TabSlot.SEARCH), plan.primary)
        assertEquals(listOf(TabSlot.LIVE, TabSlot.ADDONS, TabSlot.SETTINGS), plan.overflow)
        assertEquals(TabSlot.entries.toSet(), (plan.primary + plan.overflow).toSet())
    }

    @Test fun `every visible and merged configuration remains fully reachable without duplicates`() {
        for (mask in 0 until (1 shl TabSlot.entries.size)) {
            val visible = TabSlot.entries.filterIndexed { index, _ -> mask and (1 shl index) != 0 }
            val plan = cinemaCompactNavigation(visible + visible)
            assertEquals(visible.toSet(), (plan.primary + plan.overflow).toSet())
            assertEquals(visible.size, plan.primary.size + plan.overflow.size)
            assertTrue(plan.primary.size <= 5)
            if (plan.overflow.isNotEmpty()) assertEquals(4, plan.primary.size)
        }
    }

    @Test fun `small configurations preserve their displayed order without empty More`() {
        val visible = listOf(TabSlot.HOME, TabSlot.LIBRARY, TabSlot.ADDONS, TabSlot.SETTINGS)
        assertEquals(CinemaCompactNavigation(visible, emptyList()), cinemaCompactNavigation(visible))
    }

    @Test fun `current overflow selection is not silently turned into Settings`() {
        val plan = cinemaCompactNavigation(TabSlot.entries)
        assertTrue(TabSlot.ADDONS in plan.overflow)
        assertTrue(TabSlot.LIVE in plan.overflow)
        assertFalse(TabSlot.SEARCH in plan.overflow)
    }
}
