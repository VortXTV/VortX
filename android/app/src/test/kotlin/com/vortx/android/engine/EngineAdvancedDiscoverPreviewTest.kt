package com.vortx.android.engine

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class EngineAdvancedDiscoverPreviewTest {
    @Test
    fun `discover preview carries certification runtime and season fields from links`() {
        val links = JSONArray()
            .put(link("Genres", "Drama"))
            .put(link("Content Rating", "PG-13"))
            .put(link("Runtime", "1h 32m"))
            .put(link("Seasons", "3 seasons"))
        val meta = JSONObject()
            .put("_id", "tt1")
            .put("type", "series")
            .put("name", "Preview")
            .put("releaseInfo", "2021-2024")
            .put("links", links)
        val state = JSONObject().put(
            "catalog",
            JSONArray().put(
                JSONObject()
                    .put("request", JSONObject().put("path", JSONObject().put("id", "popular").put("type", "series")))
                    .put("content", JSONObject().put("type", "Ready").put("content", JSONArray().put(meta))),
            ),
        )

        val item = EngineState.parseCatalogWithFilters(state.toString()).single().items.single()

        assertEquals("2021-2024", item.year)
        assertEquals("PG-13", item.certificationLabel)
        assertEquals(92, item.previewRuntimeMinutes)
        assertEquals(3, item.previewSeasonCount)
    }

    private fun link(category: String, name: String) = JSONObject().put("category", category).put("name", name)
}
