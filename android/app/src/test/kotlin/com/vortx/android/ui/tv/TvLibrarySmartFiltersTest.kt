package com.vortx.android.ui.tv

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// Unit coverage for the pure TV Library segment + smart-filter logic (TvLibrarySmartFilters.kt), the
/// parity twin of Apple `LibrarySegment` / `LibrarySmartFilter`.
class TvLibrarySmartFiltersTest {

    private fun item(
        id: String,
        type: MediaType = MediaType.MOVIE,
        watched: Boolean = false,
        progress: Float? = null,
        runtimeMinutes: Int? = null,
    ) = MetaItem(
        id = id,
        type = type,
        name = id,
        watched = watched,
        progress = progress,
        previewRuntimeMinutes = runtimeMinutes,
    )

    @Test
    fun `anime id prefixes bucket to Anime over the media type`() {
        for (id in listOf("kitsu:1", "anilist:2", "mal:3", "anidb:4", "KITSU:5")) {
            assertEquals(LibrarySegment.ANIME, LibrarySegment.bucket(item(id, MediaType.SERIES)))
        }
    }

    @Test
    fun `non-anime titles bucket by media type`() {
        assertEquals(LibrarySegment.MOVIES, LibrarySegment.bucket(item("tt1", MediaType.MOVIE)))
        assertEquals(LibrarySegment.SHOWS, LibrarySegment.bucket(item("tt2", MediaType.SERIES)))
        assertEquals(LibrarySegment.SHOWS, LibrarySegment.bucket(item("tt3", MediaType.TV)))
    }

    @Test
    fun `segment bar hidden for a single bucket and shown with All plus present buckets`() {
        val moviesOnly = listOf(item("tt1", MediaType.MOVIE), item("tt2", MediaType.MOVIE))
        assertEquals(emptyList<LibrarySegment>(), LibrarySegment.availableSegments(moviesOnly))

        val mixed = listOf(
            item("tt1", MediaType.MOVIE),
            item("tt2", MediaType.SERIES),
            item("kitsu:9", MediaType.SERIES),
        )
        assertEquals(
            listOf(LibrarySegment.ALL, LibrarySegment.MOVIES, LibrarySegment.SHOWS, LibrarySegment.ANIME),
            LibrarySegment.availableSegments(mixed),
        )
    }

    @Test
    fun `segment filter keeps only the bucket`() {
        val items = listOf(item("tt1", MediaType.MOVIE), item("kitsu:2", MediaType.SERIES))
        assertEquals(listOf(items[1]), LibrarySegment.ANIME.filter(items))
        assertEquals(items, LibrarySegment.ALL.filter(items))
    }

    @Test
    fun `smart filter predicates match Apple`() {
        assertTrue(LibrarySmartFilter.UNWATCHED.matches(item("a", watched = false)))
        assertFalse(LibrarySmartFilter.UNWATCHED.matches(item("a", watched = true)))
        assertTrue(LibrarySmartFilter.WATCHED.matches(item("a", watched = true)))
        assertTrue(LibrarySmartFilter.IN_PROGRESS.matches(item("a", progress = 0.5f)))
        assertFalse(LibrarySmartFilter.IN_PROGRESS.matches(item("a", progress = 0.95f)))
        assertFalse(LibrarySmartFilter.IN_PROGRESS.matches(item("a", progress = 0f)))
        assertTrue(LibrarySmartFilter.SHORT.matches(item("a", runtimeMinutes = 42)))
        assertFalse(LibrarySmartFilter.SHORT.matches(item("a", runtimeMinutes = 120)))
        assertFalse(LibrarySmartFilter.SHORT.matches(item("a", runtimeMinutes = null)))
    }

    @Test
    fun `only partitioning filters are applicable`() {
        // All unwatched, none watched, none in-progress, none short -> no filter partitions the set.
        val allUnwatched = listOf(item("a"), item("b"), item("c"))
        assertEquals(emptyList<LibrarySmartFilter>(), LibrarySmartFilter.applicable(allUnwatched))

        // One watched among three -> Unwatched and Watched both partition.
        val mixed = listOf(item("a", watched = true), item("b"), item("c"))
        assertEquals(
            listOf(LibrarySmartFilter.UNWATCHED, LibrarySmartFilter.WATCHED),
            LibrarySmartFilter.applicable(mixed),
        )
    }

    @Test
    fun `watched and unwatched are mutually exclusive when toggled`() {
        val afterWatched = LibrarySmartFilter.toggle(emptySet(), LibrarySmartFilter.WATCHED)
        assertEquals(setOf(LibrarySmartFilter.WATCHED), afterWatched)
        val afterUnwatched = LibrarySmartFilter.toggle(afterWatched, LibrarySmartFilter.UNWATCHED)
        assertEquals(setOf(LibrarySmartFilter.UNWATCHED), afterUnwatched)
        val cleared = LibrarySmartFilter.toggle(afterUnwatched, LibrarySmartFilter.UNWATCHED)
        assertEquals(emptySet<LibrarySmartFilter>(), cleared)
    }

    @Test
    fun `apply is AND combined`() {
        val items = listOf(
            item("a", watched = false, runtimeMinutes = 40),
            item("b", watched = false, runtimeMinutes = 200),
            item("c", watched = true, runtimeMinutes = 40),
        )
        val shown = LibrarySmartFilter.apply(items, setOf(LibrarySmartFilter.UNWATCHED, LibrarySmartFilter.SHORT))
        assertEquals(listOf(items[0]), shown)
        assertEquals(items, LibrarySmartFilter.apply(items, emptySet()))
    }
}
