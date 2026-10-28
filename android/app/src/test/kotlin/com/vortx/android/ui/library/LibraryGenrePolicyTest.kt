package com.vortx.android.ui.library

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.*
import org.junit.Test
import java.util.Locale

class LibraryGenrePolicyTest {
    private fun item(id: String, type: MediaType = MediaType.MOVIE, genres: List<String> = emptyList(), watched: Boolean = false) =
        MetaItem(id, type, id, genres = genres, watched = watched)
    @Test fun `All and Unknown retain older titles and order without mutating models`() {
        val rows = listOf(item("unknown"), item("known", genres = listOf("Drama")), item("blank", genres = listOf(" ")))
        assertEquals(rows, LibraryGenrePolicy.filter(rows, LibraryGenrePolicy.Choice.All))
        assertEquals(listOf(rows[0], rows[2]), LibraryGenrePolicy.filter(rows, LibraryGenrePolicy.Choice.Unknown))
        assertEquals(emptyList<String>(), rows[0].genres)
    }
    @Test fun `genre filtering keeps exact rows through type and watched refinements`() {
        val movie = item("same", genres = listOf(" Drama ", "drama"))
        val series = item("same", MediaType.SERIES, listOf("Comedy"), watched = true)
        val drama = item("other", genres = listOf("Drama"), watched = true)
        val rows = listOf(series, movie, drama)
        val narrowed = LibraryGenrePolicy.filter(LibrarySegment.MOVIES.filter(rows), LibraryGenrePolicy.Choice.genre("DRAMA"))
        assertEquals(listOf(movie, drama), narrowed)
        assertEquals(listOf(drama), LibrarySmartFilter.apply(narrowed, setOf(LibrarySmartFilter.WATCHED)))
        assertEquals(listOf(series), LibraryGenrePolicy.filter(rows, LibraryGenrePolicy.Choice.genre("comedy")))
    }
    @Test fun `genre with no watched matches never relaxes a selected watched filter`() {
        val rows = listOf(item("drama", genres = listOf("Drama")), item("comedy", genres = listOf("Comedy"), watched = true))
        assertTrue(LibraryGenrePolicy.refine(rows, LibraryGenrePolicy.Choice.genre("Drama"), setOf(LibrarySmartFilter.WATCHED)).isEmpty())
        assertEquals(listOf(rows[1]), LibraryGenrePolicy.refine(rows, LibraryGenrePolicy.Choice.All, setOf(LibrarySmartFilter.WATCHED)))
    }
    @Test fun `choice identity is stable and cannot collide with provider genre labels`() {
        val selected = LibraryGenrePolicy.Choice.genre("Drama")
        val before = LibraryGenrePolicy.choices(listOf(item("a", genres = listOf("Drama"))), selected)
        val after = LibraryGenrePolicy.choices(listOf(item("a", genres = listOf("Action", "DRAMA"))), selected)
        assertEquals(before.first { it == selected }.id, after.first { it == selected }.id)
        assertEquals(1, after.count { it == selected })
        assertNotEquals(LibraryGenrePolicy.Choice.Unknown, LibraryGenrePolicy.Choice.genre("Unknown genre"))
        assertNotEquals(LibraryGenrePolicy.Choice.All, LibraryGenrePolicy.Choice.genre("All genres"))
    }
    @Test fun `last matching title removal keeps selected control and explicit empty result`() {
        val selected = LibraryGenrePolicy.Choice.genre("Drama")
        val rows = listOf(item("unknown"))
        assertTrue(LibraryGenrePolicy.choices(rows, selected).contains(selected))
        assertTrue(LibraryGenrePolicy.filter(rows, selected).isEmpty())
        assertEquals(rows, LibraryGenrePolicy.filter(rows, LibraryGenrePolicy.Choice.All))
    }
    @Test fun `retained type selection falls back to All when its last bucket disappears`() {
        val movies = listOf(item("film", genres = listOf("Drama")))
        assertEquals(LibrarySegment.ALL, LibrarySegment.SHOWS.effective(movies))
        assertEquals(movies, LibrarySegment.SHOWS.effective(movies).filter(movies))
        assertEquals(LibrarySegment.MOVIES, LibrarySegment.MOVIES.effective(movies + item("show", MediaType.SERIES)))
    }
    @Test fun `current owner snapshots and system locale cannot supply old facts`() {
        val selected = LibraryGenrePolicy.Choice.genre("Drama")
        assertTrue(LibraryGenrePolicy.filter(listOf(item("same", genres = listOf("Horror"))), selected).isEmpty())
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            assertEquals("genre:history", LibraryGenrePolicy.Choice.genre("HISTORY").id)
        } finally { Locale.setDefault(previous) }
    }
}
