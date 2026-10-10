package com.vortx.android.ui.search

import com.vortx.android.home.CollectionsHubLabel
import com.vortx.android.home.CollectionsHubSnapshot
import com.vortx.android.home.CollectionsHubTarget
import com.vortx.android.home.CollectionsHubTile
import org.junit.Assert.*
import org.junit.Test

class SearchCollectionsTest {
    @Test fun `collections match only existing visible titles retaining original target and order`() {
        val first = tile("accent", "Café Stories")
        val other = tile("other", "Action")
        val last = tile("last", "Cafe Classics")
        val snapshot = CollectionsHubSnapshot(enabled = true, discover = listOf(first, other),
            streaming = listOf(first), genres = listOf(last))
        val result = searchCollectionTiles(" CAFE ", snapshot, ::title)
        assertEquals(listOf(first, last), result)
        assertSame(first.target, result.first().target)
        assertTrue(searchCollectionTiles("no such collection", snapshot, ::title).isEmpty())
        assertTrue(searchCollectionTiles("c", snapshot, ::title).isEmpty())
        assertTrue(searchCollectionTiles("cafe", snapshot.copy(enabled = false), ::title).isEmpty())
    }
    private fun tile(id: String, name: String): CollectionsHubTile {
        val target = CollectionsHubTarget.Service(id.hashCode(), name)
        return CollectionsHubTile(id, CollectionsHubLabel.Literal(name), target = target)
    }
    private fun title(label: CollectionsHubLabel) = (label as CollectionsHubLabel.Literal).value
}
