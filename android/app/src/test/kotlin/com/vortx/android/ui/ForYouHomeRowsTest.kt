package com.vortx.android.ui

import com.vortx.android.foryou.ForYouCollectionRow
import com.vortx.android.foryou.ForYouInterestRow
import com.vortx.android.foryou.ForYouQuery
import com.vortx.android.foryou.ForYouInterests
import com.vortx.android.foryou.ForYouReason
import com.vortx.android.foryou.ForYouRows
import com.vortx.android.foryou.SmartCollection
import com.vortx.android.foryou.SmartCollectionRules
import com.vortx.android.foryou.englishForYouTitle
import com.vortx.android.foryou.forYouCatalogs
import com.vortx.android.foryou.forYouReason
import com.vortx.android.home.HomeRail
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate

class ForYouHomeRowsTest {
    private fun catalog(id: String) = Catalog(id, id, listOf(MetaItem(id = "tt1", type = MediaType.MOVIE, name = "x")))
    private fun ids(rows: List<HomeRowItem>) = rows.map(::homeRowKey)
    private val order = HomeRail.tvDefaultOrder

    @Test fun `heading sits right above the first For You row`() {
        val rows = homeRowsWithHub(listOf(catalog("continue"), catalog("vortx.home.forYou:forYou.genre.scifi"),
            catalog("vortx.home.forYou:forYou.person.7"), catalog("vortx.home.topPicks")), hubSlot = null)
        assertEquals(listOf("continue", "vortx.home.forYou.header", "vortx.home.forYou:forYou.genre.scifi",
            "vortx.home.forYou:forYou.person.7", "vortx.home.topPicks"), ids(homeRowsWithForYou(rows, order, showInvite = true)))
    }

    @Test fun `invite takes For You's slot only when there are no rows and it is wanted`() {
        val rows = homeRowsWithHub(listOf(catalog("continue"), catalog("vortx.home.topPicks")), hubSlot = 1)
        assertEquals(listOf("continue", "vortx.home.forYou.invite", "vortx.home.collectionsHub", "vortx.home.topPicks"),
            ids(homeRowsWithForYou(rows, order, showInvite = true)))
        assertEquals(ids(rows), ids(homeRowsWithForYou(rows, order, showInvite = false)))
        val noForYou = order.filterNot { it == HomeRail.FOR_YOU }
        assertEquals(ids(rows), ids(homeRowsWithForYou(rows, noForYou, showInvite = true)))
    }

    @Test fun `catalogs carry the section and the reason`() {
        val plan = ForYouQuery.plan(ForYouInterests(genres = listOf("scifi"), people = listOf(com.vortx.android.foryou.ForYouPerson(7, "P"))),
            LocalDate.of(2026, 10, 13))
        val items = listOf(MetaItem(id = "tt1", type = MediaType.MOVIE, name = "x"))
        val collection = SmartCollection.make("Mine", SmartCollectionRules(), true)
        val catalogs = forYouCatalogs(ForYouRows(plan.map { ForYouInterestRow(it, items) }, listOf(ForYouCollectionRow(collection, items))),
            ::englishForYouTitle)
        assertEquals(listOf(HomeRail.FOR_YOU, HomeRail.FOR_YOU, HomeRail.SMART_COLLECTIONS), catalogs.map(HomeRail::forCatalog))
        assertEquals(listOf(ForYouReason.INTERESTS, ForYouReason.PEOPLE, ForYouReason.COLLECTION), catalogs.map(::forYouReason))
        assertEquals(listOf("Scifi you'd rate highly", "With P", "Mine"), catalogs.map { it.title })
    }
}
