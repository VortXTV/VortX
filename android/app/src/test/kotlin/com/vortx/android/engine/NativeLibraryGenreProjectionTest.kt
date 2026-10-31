package com.vortx.android.engine

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.MetaDetail
import com.vortx.android.ui.library.LibraryGenrePolicy
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeLibraryGenreProjectionTest {
    @Test fun `Android origin save payload and public read preserve actually supplied genres`() {
        val item = MetaItem("same", MediaType.MOVIE, "Movie", poster = "https://fixture.invalid/p.jpg", genres = listOf(" Drama ", "drama", "Mystery"))
        val payload = nativeLibraryItemPayload(item)
        assertEquals(listOf("Drama", "Mystery"), (0 until payload.getJSONArray("genres").length()).map { payload.getJSONArray("genres").getString(it) })
        val read = nativeSavedLibraryItem(JSONObject(payload.toString()))
        assertEquals(listOf(read), LibraryGenrePolicy.filter(listOf(read), LibraryGenrePolicy.Choice.genre("drama")))
        assertEquals(item.id, read.id); assertEquals(item.type, read.type); assertEquals(item.poster, read.poster)
        assertEquals("", nativeSavedLibraryItem(nativeLibraryItemPayload(item.copy(poster = ""))).poster)
        assertEquals(setOf("kind", "id", "type", "name", "poster", "genres"), payload.keys().asSequence().toSet())
    }
    @Test fun `default empty and blank metadata do not manufacture a known empty native write`() {
        for (genres in listOf(emptyList(), listOf(" ", "\n"))) {
            val item = MetaItem("unknown", MediaType.MOVIE, "Unknown", genres = genres)
            val payload = nativeLibraryItemPayload(item)
            assertFalse(payload.has("genres"))
            val read = nativeSavedLibraryItem(payload)
            assertEquals(listOf(read), LibraryGenrePolicy.filter(listOf(read), LibraryGenrePolicy.Choice.Unknown))
        }
    }
    @Test fun `public projection treats opaque and mixed fields as Unknown without dropping row`() {
        for (value in listOf(JSONObject.NULL, JSONObject().put("future", "keep"), JSONArray().put("Drama").put(1))) {
            val raw = JSONObject().put("kind", "standard").put("id", "x").put("type", "series").put("name", "Show").put("genres", value)
            val original = raw.toString(); val item = nativeSavedLibraryItem(raw)
            assertTrue(item.genres.isEmpty()); assertEquals("x", item.id); assertEquals(original, raw.toString())
        }
    }
    @Test fun `accepted cache fallback requires exact type and id and preserves cached data`() {
        val sparse = MetaItem("same", MediaType.MOVIE, "Movie")
        val correct = MetaDetail("same", MediaType.MOVIE, "Movie", genres = listOf("Drama"))
        assertTrue(nativeLibraryItemPayload(sparse, correct).has("genres"))
        assertFalse(nativeLibraryItemPayload(sparse, correct.copy(type = MediaType.SERIES)).has("genres"))
        assertFalse(nativeLibraryItemPayload(sparse, correct.copy(id = "other")).has("genres"))
        val explicit = nativeLibraryItemPayload(sparse.copy(genres = listOf("Comedy")), correct)
        assertEquals("Comedy", explicit.getJSONArray("genres").getString(0))
        assertEquals(listOf("Drama"), correct.genres)
    }
    @Test fun `same public id in distinct types retains separate genre arrays`() {
        val movie = nativeSavedLibraryItem(nativeLibraryItemPayload(MetaItem("same", MediaType.MOVIE, "Movie", genres = listOf("Drama"))))
        val series = nativeSavedLibraryItem(nativeLibraryItemPayload(MetaItem("same", MediaType.SERIES, "Show", genres = listOf("Comedy"))))
        assertEquals(listOf(series), LibraryGenrePolicy.filter(listOf(movie, series), LibraryGenrePolicy.Choice.genre("Comedy")))
    }
}
