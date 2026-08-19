package com.vortx.android.engine

import com.vortx.android.model.MediaType
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineSearchStateTest {
    @Test
    fun `search update keeps typed first wins results across addon rows`() {
        val state = searchState(
            selected = true,
            catalogs = JSONArray()
                .put(
                    JSONArray().put(
                        page(
                            "Ready",
                            JSONArray()
                                .put(meta("shared", "movie", "First movie"))
                                .put(meta("shared", "series", "Series")),
                        ),
                    ),
                )
                .put(
                    JSONArray().put(
                        page(
                            "Ready",
                            JSONArray()
                                .put(meta("shared", "movie", "Later movie"))
                                .put(meta("other", "movie", "Other")),
                        ),
                    ),
                ),
        )

        val (items, isLoading) = EngineState.parseSearchUpdate(state, requestedEnd = 30)

        assertEquals(listOf("First movie", "Series", "Other"), items.map { it.name })
        assertEquals(listOf(MediaType.MOVIE, MediaType.SERIES, MediaType.MOVIE), items.map { it.type })
        assertFalse(isLoading)
    }

    @Test
    fun `nil is range gated while explicit loading always keeps search unsettled`() {
        val nilInRange = searchState(
            selected = true,
            catalogs = JSONArray().put(JSONArray().put(JSONObject())),
        )
        val loadingInRange = searchState(
            selected = true,
            catalogs = JSONArray().put(JSONArray().put(page("Loading", null))),
        )
        val loadingPastRange = searchState(
            selected = true,
            catalogs = JSONArray()
                .put(JSONArray().put(page("Ready", JSONArray())))
                .put(JSONArray().put(page("Loading", null))),
        )

        assertTrue(EngineState.parseSearchUpdate(nilInRange, requestedEnd = 0).second)
        assertTrue(EngineState.parseSearchUpdate(loadingInRange, requestedEnd = 0).second)
        assertTrue(EngineState.parseSearchUpdate(loadingPastRange, requestedEnd = 0).second)
    }

    @Test
    fun `unselected empty and unrequested nil pages are settled`() {
        val unselected = searchState(
            selected = false,
            catalogs = JSONArray().put(JSONArray().put(page("Loading", null))),
        )
        val noPlan = searchState(selected = true, catalogs = JSONArray())
        val nilPastRange = searchState(
            selected = true,
            catalogs = JSONArray()
                .put(JSONArray().put(page("Ready", JSONArray())))
                .put(JSONArray().put(JSONObject())),
        )

        assertFalse(EngineState.parseSearchUpdate(unselected, requestedEnd = 30).second)
        assertFalse(EngineState.parseSearchUpdate(noPlan, requestedEnd = 30).second)
        assertFalse(EngineState.parseSearchUpdate(nilPastRange, requestedEnd = 0).second)
    }

    private fun searchState(selected: Boolean, catalogs: JSONArray): String = JSONObject()
        .put("selected", if (selected) JSONObject().put("extra", JSONArray()) else JSONObject.NULL)
        .put("catalogs", catalogs)
        .toString()

    private fun page(type: String, content: JSONArray?): JSONObject = JSONObject().put(
        "content",
        JSONObject().put("type", type).also { if (content != null) it.put("content", content) },
    )

    private fun meta(id: String, type: String, name: String): JSONObject = JSONObject()
        .put("id", id)
        .put("type", type)
        .put("name", name)
}
