package com.vortx.android.engine

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomePaginationTest {
    @Test
    fun `row next page action preserves the engine catalog index`() {
        val envelope = JSONObject(EngineActions.loadBoardRowNextPage(7))
        val action = envelope.getJSONObject("action")
        val args = action.getJSONObject("args")

        assertEquals("board", envelope.getString("field"))
        assertEquals("CatalogsWithExtra", action.getString("action"))
        assertEquals("LoadNextPage", args.getString("action"))
        assertEquals(7, args.getInt("args"))
    }

    @Test
    fun `board parser retains engine index loading state and unique appended items`() {
        val ready = page(
            "Ready",
            JSONArray()
                .put(meta("tt1", "One"))
                .put(meta("tt1", "Repeated"))
                .put(meta("tt2", "Two")),
        )
        val loading = page("Loading", null)
        val board = JSONObject()
            .put("catalogs", JSONArray().put(JSONArray().put(ready).put(loading)))
            .toString()

        val rows = EngineState.parseCatalogs(board)

        assertEquals(1, EngineState.boardCatalogCount(board))
        assertEquals(listOf("tt1", "tt2"), rows.single().items.map { it.id })
        assertEquals(0, rows.single().engineIndex)
        assertTrue(rows.single().pageLoading)
    }

    @Test
    fun `vertical board loads widen once per settled event`() {
        val state = HomePaginationState(initialRows = 12, rowStep = 12)
        assertEquals(12, state.reset())
        assertNull(state.claimMoreRows())

        state.onBoardEvent(total = 31, rows = listOf(row(2)))
        assertEquals(24, state.claimMoreRows())
        assertNull(state.claimMoreRows())

        state.onBoardEvent(total = 31, rows = listOf(row(2)))
        assertEquals(31, state.claimMoreRows())
        state.abortMoreRows()
        assertEquals(31, state.claimMoreRows())
    }

    @Test
    fun `row loads stay gated until settlement and stop after no growth`() {
        val state = HomePaginationState(initialRows = 12, rowStep = 12)
        state.reset()
        assertNull(state.claimNextPage(row(2)))

        state.onBoardEvent(total = 4, rows = listOf(row(2)))
        assertEquals(2, state.claimNextPage(row(2)))
        assertNull(state.claimNextPage(row(2)))

        state.onBoardEvent(total = 4, rows = listOf(row(2, loading = true)))
        assertNull(state.claimNextPage(row(2)))

        state.onBoardEvent(total = 4, rows = listOf(row(2, count = 3)))
        assertTrue(state.rowHasNextPage(2))
        assertEquals(2, state.claimNextPage(row(2, count = 3)))

        state.onBoardEvent(total = 4, rows = listOf(row(2, count = 3)))
        assertFalse(state.rowHasNextPage(2))
        assertNull(state.claimNextPage(row(2, count = 3)))
    }

    private fun row(index: Int, count: Int = 2, loading: Boolean = false) = Catalog(
        id = "row-$index",
        title = "Row $index",
        items = List(count) { item -> MetaItem("tt$item", MediaType.MOVIE, "Item $item") },
        engineIndex = index,
        hasNextPage = true,
        pageLoading = loading,
    )

    private fun page(type: String, items: JSONArray?): JSONObject = JSONObject()
        .put(
            "request",
            JSONObject()
                .put("base", "https://addon.example/")
                .put("path", JSONObject().put("type", "movie").put("id", "popular")),
        )
        .put(
            "content",
            JSONObject().put("type", type).apply {
                if (items != null) put("content", items)
            },
        )

    private fun meta(id: String, name: String): JSONObject = JSONObject()
        .put("_id", id)
        .put("type", "movie")
        .put("name", name)
}
