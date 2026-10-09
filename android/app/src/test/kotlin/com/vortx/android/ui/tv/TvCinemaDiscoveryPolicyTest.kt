package com.vortx.android.ui.tv

import com.vortx.android.ui.prefs.TabBarPrefs
import com.vortx.android.ui.search.isSearchQueryEligible
import org.junit.Assert.*
import org.junit.Test

class TvCinemaDiscoveryPolicyTest {
    private val shown = TabBarPrefs.State(false, false, false, false)

    @Test fun `merged Search routes to its Discover owner even with hidden Search tab`() {
        for (hideSearch in listOf(false, true)) for (mergeHome in listOf(false, true)) {
            val hidden = shown.copy(hideSearch = hideSearch)
            assertEquals(TvCinemaRoute(if (mergeHome) TvDestination.HOME else TvDestination.DISCOVER, mergeHome),
                tvCinemaRoute(TvDestination.SEARCH, false, hidden, mergeHome, true))
            assertFalse(TvDestination.SEARCH in tvCinemaDestinations(hidden, mergeHome, true))
        }
    }

    @Test fun `hidden Discover closes merged Search including Home Browse`() {
        for (mergeHome in listOf(false, true)) {
            assertEquals(TvCinemaRoute(TvDestination.HOME),
                tvCinemaRoute(TvDestination.SEARCH, true, shown.copy(hideDiscover = true), mergeHome, true))
        }
    }

    @Test fun `turning merges off restores the actual browse owner and separate Search tab`() {
        assertEquals(TvCinemaRoute(TvDestination.DISCOVER), tvCinemaRouteAfterPreferencesChange(
            TvCinemaRoute(TvDestination.HOME, true), true, shown, false, false))
        assertTrue(TvDestination.SEARCH in tvCinemaDestinations(shown, false, false))
        assertEquals(TvCinemaRoute(TvDestination.SEARCH), tvCinemaRoute(TvDestination.SEARCH, false, shown, false, false))
    }

    @Test fun `hidden standalone Search heals to Home without manufacturing Browse`() {
        assertEquals(TvCinemaRoute(TvDestination.HOME), tvCinemaRoute(TvDestination.SEARCH, false, shown.copy(hideSearch = true), true, false))
    }

    @Test fun `preferences changed in Settings retain the current Settings route`() {
        for (mergeHome in listOf(false, true)) for (mergeSearch in listOf(false, true)) {
            assertEquals(TvCinemaRoute(TvDestination.SETTINGS), tvCinemaRouteAfterPreferencesChange(
                TvCinemaRoute(TvDestination.SETTINGS), false, shown, mergeHome, mergeSearch))
        }
    }

    @Test fun `all visibility combinations keep resolved route reachable`() {
        for (flags in 0..15) for (mergeHome in listOf(false, true)) for (mergeSearch in listOf(false, true)) {
            val hidden = TabBarPrefs.State(flags and 1 != 0, flags and 2 != 0, flags and 4 != 0, flags and 8 != 0)
            val visible = tvCinemaDestinations(hidden, mergeHome, mergeSearch)
            assertTrue(visible.containsAll(listOf(TvDestination.HOME, TvDestination.SETTINGS, TvDestination.DOWNLOADS, TvDestination.ADDONS)))
            for (requested in TvDestination.entries) {
                val resolved = tvCinemaRoute(requested, true, hidden, mergeHome, mergeSearch)
                assertTrue(resolved.destination in visible)
                if (resolved.homeBrowseSelected) assertTrue(mergeHome && !hidden.hideDiscover)
            }
        }
    }

    @Test fun `merged query gate displays Browse until real Search is eligible`() {
        for (query in listOf("", " ", "a", " a ")) assertFalse(isSearchQueryEligible(query))
        for (query in listOf("ab", "  ab  ", "movie")) assertTrue(isSearchQueryEligible(query))
    }
}
