package com.vortx.android.home

import com.vortx.android.model.Catalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HomeRailPreferencesTest {
    @Test
    fun `saved order drops unknowns and appends newly shipped rails`() {
        val arranged = HomeRailPolicy.normalizedOrder(
            savedKeys = listOf("addonCatalogs", "unknown", "topPicks", "addonCatalogs"),
            defaults = listOf(HomeRail.TOP_PICKS, HomeRail.TRAKT_WATCHLIST, HomeRail.ADDON_CATALOGS),
        )

        assertEquals(
            listOf(HomeRail.ADDON_CATALOGS, HomeRail.TOP_PICKS, HomeRail.TRAKT_WATCHLIST),
            arranged,
        )
    }

    @Test
    fun `continue watching stays first while sections reorder and hide`() {
        val rows = listOf(
            catalog(HomeRail.CONTINUE_CATALOG_ID),
            catalog("addon-a|movie|popular"),
            catalog(HomeRail.TOP_PICKS.catalogId),
            catalog(HomeRail.TRAKT_WATCHLIST.catalogId),
            catalog("addon-b|series|trending"),
        )
        val layout = HomeRailLayout(
            order = listOf(HomeRail.TRAKT_WATCHLIST, HomeRail.ADDON_CATALOGS, HomeRail.TOP_PICKS),
            hidden = setOf(HomeRail.TOP_PICKS),
        )

        assertEquals(
            listOf(
                HomeRail.CONTINUE_CATALOG_ID,
                HomeRail.TRAKT_WATCHLIST.catalogId,
                "addon-a|movie|popular",
                "addon-b|series|trending",
            ),
            HomeRailPolicy.arrangeCatalogs(
                rows,
                listOf(HomeRail.TOP_PICKS, HomeRail.TRAKT_WATCHLIST, HomeRail.ADDON_CATALOGS),
                layout,
            ).map(Catalog::id),
        )
    }

    @Test
    fun `continue watching cannot be hidden by a rail preference`() {
        val rows = listOf(catalog(HomeRail.CONTINUE_CATALOG_ID), catalog("addon|movie|popular"))
        val layout = HomeRailLayout(
            order = HomeRail.phoneDefaultOrder,
            hidden = HomeRail.entries.toSet(),
        )

        assertEquals(
            listOf(HomeRail.CONTINUE_CATALOG_ID),
            HomeRailPolicy.arrangeCatalogs(rows, HomeRail.phoneDefaultOrder, layout).map(Catalog::id),
        )
    }

    @Test
    fun `move is bounded and does not mutate its input`() {
        val original = listOf(HomeRail.TOP_PICKS, HomeRail.TRAKT_WATCHLIST, HomeRail.ADDON_CATALOGS)

        assertEquals(
            listOf(HomeRail.TRAKT_WATCHLIST, HomeRail.TOP_PICKS, HomeRail.ADDON_CATALOGS),
            HomeRailPolicy.move(original, HomeRail.TRAKT_WATCHLIST, -1),
        )
        assertNull(HomeRailPolicy.move(original, HomeRail.TOP_PICKS, -1))
        assertNull(HomeRailPolicy.move(original, HomeRail.ADDON_CATALOGS, 1))
        assertEquals(listOf(HomeRail.TOP_PICKS, HomeRail.TRAKT_WATCHLIST, HomeRail.ADDON_CATALOGS), original)
    }

    @Test
    fun `storage keys exactly match the Apple settings contract`() {
        assertEquals("vortx.home.railOrder", HomeRailPreferences.ORDER_KEY)
        assertEquals("vortx.home.railHidden", HomeRailPreferences.HIDDEN_KEY)
    }

    private fun catalog(id: String) = Catalog(id = id, title = id, items = emptyList())
}
